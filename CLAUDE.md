# obsidian-headless-container

Docker image that runs Obsidian headlessly (Xvfb + Electron) and exposes its CLI
over a Unix socket via [ssrv](https://github.com/VHSgunzo/ssrv). Consumers (the
host or other containers) call `obsidian <cmd>` through a shim that proxies the
socket.

## Architecture

- `entrypoint.sh` — runs as **root**: remaps the `obsidian` user to `PUID`/`PGID`,
  starts a system D-Bus, then `exec gosu obsidian entrypoint-user.sh`.
- `entrypoint-user.sh` — runs as the **obsidian** user: Xvfb on `:99`, generates
  `~/.config/obsidian/obsidian.json` by scanning `/vaults/*`, launches the
  Obsidian daemon, waits for readiness, then `exec ssrv -srv` on the socket.
- Socket: `/run/obsidian/obsidian.sock`. ssrv runs unrestricted — socket access
  equals arbitrary exec in the container (by design; the trust boundary is the
  socket's filesystem permissions).

## Critical gotchas

- **Vault dirs must be writable by `PUID`.** Obsidian's CLI only responds once a
  vault is successfully *opened*. A root-owned or read-only vault dir leaves the
  CLI silently broken: `obsidian version` exits 0 with empty output and `help`
  appears to hang. Docker auto-creates bind-mount source paths as root — chown
  them to the host user before first run.
- **CLI calls must run as the daemon's user with the daemon's `HOME`.** The
  daemon writes its IPC socket to `~/.obsidian-cli.sock`. ssrv-relayed commands
  inherit this (the ssrv server runs as `obsidian` with `HOME=/home/obsidian`).
  A plain `docker exec` of the binary runs as **root**, won't find the IPC
  socket, and produces no output — always go through ssrv.
- **ssrv lowercases the `-sock` path.** All socket paths must be all-lowercase.
  The default `/run/obsidian` is fine; avoid bind-mounting the socket under a
  path with uppercase characters.
- **No Catalyst or paid license is required.** The CLI works on the free tier
  with `"cli": true` in `obsidian.json` (Obsidian 1.12+).

## Build & test

- Pinned versions are Dockerfile ARGs: `OBSIDIAN_VERSION`, `SSRV_VERSION`,
  `SSRV_BUILD`.
- `./scripts/smoke-test.sh` builds the image and verifies the full path
  (build → run → `version`/`vault`/`read` via socket). Run it after any
  Dockerfile or entrypoint change.
- Verify CLI behavior through the ssrv socket, not via `docker exec` of the
  Obsidian binary directly.
