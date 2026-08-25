# Why the daemon runs with these Chromium flags

`entrypoint-user.sh` launches Obsidian as:

```
obsidian --no-sandbox --disable-gpu --disable-dev-shm-usage \
         --disable-gpu-process-crash-limit --enable-logging
```

Two of those exist because Chromium, under this container's conditions, kills the
*browser* process — and with it the daemon, the socket, and every client of the
socket. Both aborts surface identically: `int3`, status 133 (SIGTRAP),
indistinguishable from any other Chromium CHECK. This page records what each one
was, so a future reader can tell whether dropping a flag is safe.

## `--no-sandbox --disable-gpu`

Expected in a headless container with no GPU and no user namespaces. Nothing
subtle here.

## `--disable-gpu-process-crash-limit`

Obsidian 1.13 is Electron 43 / Chromium 150, up from 39 / 142 in 1.12, and that
Chromium spawns a GPU process **even under `--disable-gpu`** — which only turns
off acceleration. The process hosts the display compositor, so it cannot be
flagged away: `--disable-software-rasterizer` and `--disable-gpu-compositing`
both leave it running. Obsidian 1.12 had no such process at all.

Chromium counts that process's deaths and, on the third, deliberately aborts the
browser process — `GPU process isn't usable. Goodbye.` That abort spares an
interactive user a black window. Here it takes down a daemon whose only job is
answering CLI calls that never touch a pixel.

Reproduced against both versions: killing the GPU process three times on 1.13.7
exits the container 133; 1.12.7 has no GPU process to kill. With the flag, 14
kills left the container up and the CLI answering throughout.

What killed the GPU process in production was never recovered — that output went
to `/dev/null` before the log capture landed. The host journal showed no OOM
kill. The flag makes the cause survivable rather than fatal.

## `--enable-logging`

Paired with the flag above, deliberately. The browser prints **nothing** per GPU
death — verified across those 14 — so the fatal abort was the only evidence the
deaths ever happened. Removing the abort without adding logging would have made a
respawn loop completely invisible. Chromium's diagnostics leave one line per GPU
start: 5 lines over a 60-call run, against the 62 the daemon writes anyway.

## `--disable-dev-shm-usage`

Chromium keeps renderer shared memory in `/dev/shm`, which Docker sizes at
**64 MiB** by default. Every vault the CLI names stays open in a window with a
renderer of its own, and that is not idle memory.

The trigger is the vault sweep the notebook skills run on every fresh session —
`obsidian vaults`, then `vault=<each> file path=CLAUDE.md` — to work out which
vault holds the conventions. With four vaults, instrumenting `/dev/shm` once a
second gives:

```
round 1 (opens all four vaults):  16 MB
round 2:                          16 → 53 → 62 MB, then status 133
```

62 MiB was the last sample before the daemon died on an allocation that did not
fit. Unlike the GPU abort, this one prints nothing at all — the daemon log ends
mid-sweep and `docker logs` shows only the restart. That is what an unexplained
`fling: cannot connect to ...: No such file or directory` in a client session
means.

Crossing the last 2 MiB is a coin flip: a build without the flag has passed a
two-pass sweep. So the smoke test asserts `/dev/shm` *usage* (zero with the flag,
tens of MiB without) rather than the crash, and keeps a liveness check for the
run that does trip the cliff.

`--shm-size=1g` on the container fixes the same thing from the outside. The flag
is preferred because it travels with the image instead of depending on how each
deployment runs it.

### It is not a throughput trade

The flag moves the segments to `/tmp` — the container filesystem, page-cache
backed, with no fixed ceiling. Benchmarked against the same image run with
`--shm-size=1g` (segments still in tmpfs), two alternating passes, 40 calls each
over the socket with the `fling` client:

| | `--disable-dev-shm-usage` | tmpfs control |
|---|---|---|
| startup → socket ready | 5905 / 5898 ms | 6045 / 5944 ms |
| `read` call, mean | 116.5 / 126.6 ms | 127.7 / 129.7 ms |
| median / p90 | 114–126 / 124–131 ms | 126–129 / 132–137 ms |
| total RSS, 4 vaults open | 1477 MB | 1473 MB |
| `/dev/shm` | 0 MB | 53–54 MB |

The flagged runs came out marginally faster, which is noise — the flag's own two
passes differ by more than the gap between variants.

The whole cost is disk writes, and they are one-time. Container block IO:

```
idle after ready:            3.3 MB
after the vaults open:      65.3 MB   ← ~62 MB of writeback
after 6 more vault sweeps:  65.3 MB   ← nothing
after 40 same-vault reads:  65.5 MB   ← nothing
```

The tmpfs control wrote 0.9 MB across the same work. What the flag would cost is
compositor traffic against a file instead of RAM — video, canvas, scrolling. This
daemon draws to nothing; the segments fill at vault-open and then sit still.
