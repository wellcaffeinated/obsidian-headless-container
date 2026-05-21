#!/bin/bash
# Root-mode bootstrap: adapt the obsidian user's UID/GID to match PUID/PGID,
# fix ownership of bind-mounted state dirs, then drop privileges.
set -euo pipefail

PUID="${PUID:-1000}"
PGID="${PGID:-1000}"

log() { printf '[entrypoint] %s\n' "$*" >&2; }

current_uid=$(id -u obsidian)
current_gid=$(id -g obsidian)

if [[ "${PGID}" != "${current_gid}" ]]; then
    log "remapping obsidian group GID ${current_gid} -> ${PGID}"
    groupmod -o -g "${PGID}" obsidian
fi
if [[ "${PUID}" != "${current_uid}" ]]; then
    log "remapping obsidian user UID ${current_uid} -> ${PUID}"
    usermod -o -u "${PUID}" obsidian
fi

# Fix ownership of dirs we own/manage. Vault contents are deliberately NOT
# chowned -- we assume PUID already matches the host vault owner.
chown -R "${PUID}:${PGID}" /home/obsidian
chown "${PUID}:${PGID}" /run/obsidian 2>/dev/null || true

# Start a system D-Bus so Obsidian's Electron/Chromium layer stops emitting
# "Failed to connect to the bus" on every CLI invocation.
mkdir -p /run/dbus
rm -f /run/dbus/pid
dbus-daemon --system --fork

exec gosu obsidian /opt/entrypoint-user.sh "$@"
