# obsidian-headless-container

Docker image that runs Obsidian headlessly (Xvfb + Electron) and exposes its CLI
over a Unix socket via [fling](https://github.com/wellcaffeinated/fling_rs). Consumers (the
host or other containers) call `obsidian <cmd>` through a shim that proxies the
socket.

## Architecture

- `entrypoint.sh` — runs as **root**: remaps the `obsidian` user to `PUID`/`PGID`,
  starts a system D-Bus, then `exec gosu obsidian entrypoint-user.sh`.
- `entrypoint-user.sh` — runs as the **obsidian** user: Xvfb on `:99`, generates
  `~/.config/obsidian/obsidian.json` by scanning `/vaults/*`, launches the
  Obsidian daemon, waits for readiness, starts `fling server` on the socket,
  then supervises all three.
- The daemon's stdout/stderr go to `/tmp/obsidian-daemon.log` (bounded by a
  background trimmer). On death the entrypoint decodes the signal and dumps
  the tail to stderr, so `docker logs` keeps the only forensic trail a
  Chromium abort leaves. Env: `DAEMON_LOG*`.
- The daemon runs with `--disable-gpu-process-crash-limit`, `--enable-logging`
  and `--disable-dev-shm-usage`. Two of those stop Chromium aborting the browser
  process — over a GPU process nothing here uses, and over a `/dev/shm` that four
  open vaults exhaust; the third is what makes the first one's failure visible.
  Both aborts exit 133 and one prints nothing at all, so a dropped flag shows up
  as an unexplained restart. **`docs/chromium-flags.md` has the full account** —
  read it before changing that line. Asserted by the smoke test.
- Socket: `/run/obsidian/obsidian.sock`. fling enforces an explicit allowlist
  (`/etc/fling/config.toml`); only the `obsidian` command is permitted. The
  trust boundary is still the socket's filesystem permissions.
- Requires **fling 0.2+**; the smoke test's version check needs 0.2.1+. The
  config sets `sandbox = false` (fling 0.2 confines
  relayed commands by default, which hides `/opt/obsidian` and the daemon's IPC
  socket) and pins `working_dir` (0.2 no longer inherits the server's cwd).

## Critical gotchas

- **Vault dirs must be writable by `PUID`.** Obsidian's CLI only responds once a
  vault is successfully *opened*. A root-owned or read-only vault dir leaves the
  CLI silently broken: `obsidian version` exits 0 with empty output and `help`
  appears to hang. Docker auto-creates bind-mount source paths as root — chown
  them to the host user before first run.
- **CLI calls must run as the daemon's user with the daemon's `HOME`.** The
  daemon writes its IPC socket to `~/.obsidian-cli.sock`. fling-relayed commands
  inherit the server process environment (fling server runs as `obsidian` with
  `HOME=/home/obsidian`). A plain `docker exec` of the binary runs as **root**,
  won't find the IPC socket, and produces no output — always go through fling.
- **No Catalyst or paid license is required.** The CLI works on the free tier
  with `"cli": true` in `obsidian.json` (Obsidian 1.12+).
- **Never `exec` fling from the entrypoint.** fling cannot tell whether the
  Obsidian daemon behind it is alive and will serve a socket with no backend
  indefinitely. With the daemon dead, a relayed call stops acting as a client
  and boots a *fresh* Electron app: it hangs, exits 255, and prints app startup
  noise (`Loaded main app package`, `Checking for update using Github`) instead
  of command output — while `docker ps` still shows the container healthy.
  `entrypoint-user.sh` therefore keeps the shell alive to `wait -n` on Xvfb,
  the daemon and fling, exiting non-zero when any of them dies so the restart
  policy recovers. Staying in the shell also reaps the daemon instead of
  leaving it `<defunct>`. The smoke test asserts this.

## Working on this repo

- **Always sync with remote before considering work done.** Run `git pull --rebase` (or `git fetch && git log origin/main`) before committing or declaring a task complete — the remote may have commits that need to be incorporated.

## Build & test

- Pinned versions are Dockerfile ARGs: `OBSIDIAN_VERSION`, `FLING_VERSION`.
- `./scripts/smoke-test.sh` builds the image and verifies the full path
  (build → run → `version`/`vault`/`read` via socket). Run it after any
  Dockerfile or entrypoint change.
- Verify CLI behavior through the fling socket, not via `docker exec` of the
  Obsidian binary directly.
