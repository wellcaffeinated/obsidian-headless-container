# Obsidian Headless Container

Run [Obsidian](https://obsidian.md) headlessly in a Docker container and expose
its [CLI](https://help.obsidian.md/cli) over a Unix Domain Socket so that any
process — on the host or in a sibling container — can invoke `obsidian <cmd>`
transparently.

Uses [fling](https://github.com/wellcaffeinated/fling_rs) — a static Rust binary
that relays argv, stdin, stdout/stderr and the exit code over a Unix socket,
behind an explicit command allowlist.

## Quick start

```sh
docker run -d --name obsidian \
    -v /path/to/your/vaults:/vaults \
    -v /run/obsidian:/run/obsidian \
    ghcr.io/wellcaffeinated/obsidian-headless-container:latest
```

Each top-level directory under `/vaults` is registered as an Obsidian vault.
The first one alphabetically is marked open; override with `-e DEFAULT_VAULT=name`.

The Unix socket lands at `/run/obsidian/obsidian.sock` inside the container.
Bind-mounting `/run/obsidian` on the host exposes it to bare metal and to
any sibling container that mounts the same path.

## Calling Obsidian from the host

Two options. The shim is recommended; the docker-exec function is a fallback.

### Option A: fling shim (recommended)

Installs the `fling` client and a tiny `obsidian` wrapper that targets the
socket.

```sh
sudo ./scripts/install-host-shim.sh
obsidian version
obsidian read path=note.md
obsidian search query=meeting
```

Override the socket location per-call: `OBSIDIAN_SOCK=unix:/elsewhere.sock obsidian version`.

**Tradeoffs:** requires `fling` on the host (one static binary) and the socket
bind mount. The exact same shim works inside other containers — no Docker
runtime knowledge in the call path.

### Option B: `docker exec` shell function

Source the helper for your `.bashrc` / `.zshrc`:

```sh
source ./scripts/obsidian-docker-exec.sh
obsidian version
```

**Tradeoffs:** no extra binaries; needs Docker access on the caller; bypasses
the socket entirely; slower per call (cold `docker exec` each time).

## Calling Obsidian from another container

Mount the same socket directory and install the shim during your image build:

```dockerfile
RUN curl -fsSL https://raw.githubusercontent.com/wellcaffeinated/obsidian-headless-container/main/scripts/install-host-shim.sh | sh
```

Then mount the socket in compose:

```yaml
services:
  agent:
    volumes:
      - /run/obsidian:/run/obsidian
    depends_on:
      - obsidian
```

`obsidian <cmd>` inside the agent transparently proxies to the Obsidian
container. No shared Docker network, no `docker.sock`, no extra config.

See [`docker-compose.example.yml`](./docker-compose.example.yml).

## Read-only vault access

To give a consumer container read-only access to the vault, run a *second*
Obsidian container with the vault bind-mounted `:ro` and its own socket. Then
mount that container's socket into the read-only consumer.

Filesystem-level enforcement is more robust than trying to blacklist Obsidian
subcommands — there are 80+ commands and `obsidian eval` runs arbitrary JS.

Caveat: Obsidian needs to write to `.obsidian/` (workspace state, plugin
caches). Mount the note content `:ro` but overlay `.obsidian/` as a separate
writable volume per container.

## Configuration

Environment variables understood by the entrypoint:

| Variable          | Default                          | Purpose                                                |
| ----------------- | -------------------------------- | ------------------------------------------------------ |
| `PUID`            | `1000`                           | UID to run Obsidian as. Set to `$(id -u)` so vault writes are owned by you on the host. |
| `PGID`            | `1000`                           | GID to run Obsidian as. Set to `$(id -g)`.             |
| `DEFAULT_VAULT`   | first vault alphabetically       | Name of the `/vaults/*` subdir to mark open at startup |
| `READY_TIMEOUT`   | `120`                            | Seconds to wait for Obsidian to respond before failing |
| `VAULTS_DIR`      | `/vaults`                        | Where to scan for vault subdirectories                 |
| `OBSIDIAN_SOCK_PATH` | `/run/obsidian/obsidian.sock` | Where the fling server listens                         |

The container starts as root, remaps the `obsidian` user's UID/GID to match
`PUID`/`PGID`, then drops privileges via `gosu` before launching Obsidian.
Vault contents are never chowned — `PUID` is expected to match the host owner
of the vault directory.

## Security model

`fling` is an allowlisting relay: `/etc/fling/config.toml` names the only
commands it will spawn, and this image allows exactly one — `obsidian`. A
client on the socket therefore cannot run arbitrary binaries in the container.

That is *not* the same as a sandbox. The allowlist constrains the command but
not its arguments, and `obsidian eval` executes arbitrary JavaScript inside the
app — with the vault mounted and network access. Treat "has the socket" as
equivalent to "can read and write the whole vault and run arbitrary JS in the
Obsidian process." The real trust boundary remains the socket's filesystem
permissions and the volume mounts you set up.

This image sets `sandbox = false`, opting out of fling's per-command
confinement (see the [fling README][fling] for what that does). Confining the
relayed process would gain nothing here: it is a thin client that forwards to a
long-running Obsidian daemon which is unconfined and already holds the vault
open. The container is the isolation boundary.

[fling]: https://github.com/wellcaffeinated/fling_rs

## Notes & limitations

- Container defaults to running as UID 1000. Set `PUID`/`PGID` to match your
  host user if you're not on `id -u == 1000`.
- `/run/obsidian` on the host must be writable by `PUID`. The entrypoint
  attempts a chown on startup but cannot succeed if the host directory was
  pre-created with restrictive ownership; either let docker create it via a
  named volume, or `sudo chown ${PUID}:${PGID} /run/obsidian` once.
- The container ships with `--no-sandbox --disable-gpu` for Electron;
  expected in a headless container without GPU or user namespaces.
- Indexing time on large vaults can extend startup well beyond the default
  `READY_TIMEOUT`; bump it as needed.
- **`base:query` can return empty output with exit code 0.** Obsidian
  materializes a Base *view* lazily, separately from the file index, and a
  query that lands before the view is ready returns nothing — no error, no
  stderr, no entry in `obsidian.log` or the captured console. On a 2000-note
  vault, `obsidian files total` reported every file immediately while a
  500-row view with a formula stayed empty for ~57s after startup, then
  returned in full. Heavier views recompute longer and fail more often, so an
  empty result is indistinguishable from a genuinely empty view. Retry until
  non-empty rather than trusting a single call. This is an upstream Obsidian
  behaviour, not a relay issue — it reproduces with `fling` entirely out of
  the call path.

## Building locally

```sh
docker build -t obsidian-headless .
./scripts/smoke-test.sh
```

## Credits

Inspired by [obsidianless](https://github.com/lucastraba/obsidianless)

## License

MIT. See [LICENSE](./LICENSE).
