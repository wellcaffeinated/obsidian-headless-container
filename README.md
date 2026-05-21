# Obsidian Headless Container

Run [Obsidian](https://obsidian.md) headlessly in a Docker container and expose
its [CLI](https://help.obsidian.md/cli) over a Unix Domain Socket so that any
process — on the host or in a sibling container — can invoke `obsidian <cmd>`
transparently.

Built on:

- [obsidianless](https://github.com/lucastraba/obsidianless) — the prior art for
  running Obsidian headlessly under Xvfb with `"cli": true` pre-seeded.
- [ssrv](https://github.com/VHSgunzo/ssrv) — a static Go binary that relays
  argv, stdin, stdout/stderr and the exit code over a Unix socket.

> [!IMPORTANT]
> The Obsidian CLI is a [Catalyst](https://obsidian.md/pricing) feature ($25
> one-time). This container does not bypass that — it enables the existing CLI
> headlessly so it can be used from servers, agents, and CI.

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

### Option A: ssrv shim (recommended)

Installs the `ssrv` client and a tiny `obsidian` wrapper that targets the
socket.

```sh
sudo ./scripts/install-host-shim.sh
obsidian version
obsidian read path=note.md
obsidian search query=meeting
```

Override the socket location per-call: `OBSIDIAN_SOCK=unix:/elsewhere.sock obsidian version`.

**Tradeoffs:** requires `ssrv` on the host (one static binary) and the socket
bind mount. The exact same shim works inside other containers — no Docker
runtime knowledge in the call path.

> [!WARNING]
> `ssrv` lowercases the `-sock` path it is given. The socket directory must
> therefore be an **all-lowercase path** on both ends. The default
> `/run/obsidian` is fine; avoid bind-mounting the socket under a path with
> uppercase characters (e.g. `/Users/Alice/...`, `/tmp/tmp.AbC123/...`).

### Option B: `docker exec` shell function

Source the helper from your `.bashrc` / `.zshrc`:

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
| `OBSIDIAN_SOCK_PATH` | `/run/obsidian/obsidian.sock` | Where the ssrv server listens                          |

The container starts as root, remaps the `obsidian` user's UID/GID to match
`PUID`/`PGID`, then drops privileges via `gosu` before launching Obsidian.
Vault contents are never chowned — `PUID` is expected to match the host owner
of the vault directory.

Build args (for `docker build`):

| Arg                | Default        |
| ------------------ | -------------- |
| `OBSIDIAN_VERSION` | `1.12.7`       |
| `SSRV_VERSION`     | `0.3.4`        |
| `SSRV_BUILD`       | `r0.g85a1f7f`  |

## Security model

`ssrv` is an unrestricted exec relay — any client connected to the socket can
run arbitrary commands inside the container. The trust boundary is the
socket's filesystem permissions (and the volume mounts you set up). Treat
"has the socket" as equivalent to "has shell in the Obsidian container."

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

## Building locally

```sh
docker build -t obsidian-headless .
./scripts/smoke-test.sh
```

## License

MIT. See [LICENSE](./LICENSE).
