#!/bin/bash
# Unprivileged entrypoint: brings up Xvfb, generates obsidian.json, launches
# Obsidian, waits for readiness, then hands off to the ssrv relay.
set -euo pipefail

OBSIDIAN_BIN="${OBSIDIAN_BIN:-/opt/obsidian/obsidian}"
OBSIDIAN_SOCK_PATH="${OBSIDIAN_SOCK_PATH:-/run/obsidian/obsidian.sock}"
VAULTS_DIR="${VAULTS_DIR:-/vaults}"
CONFIG_DIR="${HOME}/.config/obsidian"
CONFIG_FILE="${CONFIG_DIR}/obsidian.json"
TEMPLATE_FILE="${TEMPLATE_FILE:-/opt/obsidian.json.template}"
DEFAULT_VAULT="${DEFAULT_VAULT:-}"
READY_TIMEOUT="${READY_TIMEOUT:-120}"

log() { printf '[entrypoint] %s\n' "$*" >&2; }

xvfb_pid=""
obsidian_pid=""
cleanup() {
    log "shutting down"
    [[ -n "${obsidian_pid}" ]] && kill "${obsidian_pid}" 2>/dev/null || true
    [[ -n "${xvfb_pid}" ]] && kill "${xvfb_pid}" 2>/dev/null || true
    rm -f "${OBSIDIAN_SOCK_PATH}"
}
trap cleanup EXIT INT TERM

# 1. Clean stale Xvfb state from prior runs.
rm -f /tmp/.X99-lock /tmp/.X11-unix/X99 2>/dev/null || true

# 2. Start Xvfb.
log "starting Xvfb on :99"
Xvfb :99 -screen 0 1024x768x24 -nolisten tcp &
xvfb_pid=$!

# 3. Generate obsidian.json from /vaults/*.
mkdir -p "${CONFIG_DIR}"

mapfile -t vault_paths < <(find "${VAULTS_DIR}" -mindepth 1 -maxdepth 1 -type d | sort)
if [[ ${#vault_paths[@]} -eq 0 ]]; then
    log "ERROR: no vault directories found under ${VAULTS_DIR}. Bind-mount at least one."
    exit 1
fi

now_ms=$(($(date +%s%N) / 1000000))

default_path=""
if [[ -n "${DEFAULT_VAULT}" ]]; then
    candidate="${VAULTS_DIR}/${DEFAULT_VAULT}"
    if [[ -d "${candidate}" ]]; then
        default_path="${candidate}"
    else
        log "WARNING: DEFAULT_VAULT='${DEFAULT_VAULT}' not found under ${VAULTS_DIR}; falling back to first vault"
    fi
fi
[[ -z "${default_path}" ]] && default_path="${vault_paths[0]}"

vaults_json=$(
    for path in "${vault_paths[@]}"; do
        id=$(printf '%s' "${path}" | md5sum | cut -c1-16)
        open="false"
        [[ "${path}" == "${default_path}" ]] && open="true"
        jq -nc \
            --arg id "${id}" \
            --arg path "${path}" \
            --argjson ts "${now_ms}" \
            --argjson open "${open}" \
            '{($id): {path: $path, ts: $ts, open: $open}}'
    done | jq -sc 'add'
)

jq --argjson v "${vaults_json}" '.vaults = $v | .cli = true' \
    "${TEMPLATE_FILE}" > "${CONFIG_FILE}"

log "registered vaults:"
for path in "${vault_paths[@]}"; do
    marker="  "
    [[ "${path}" == "${default_path}" ]] && marker="* "
    log "${marker}${path}"
done

# 4. Launch Obsidian.
log "launching Obsidian (${OBSIDIAN_BIN})"
"${OBSIDIAN_BIN}" --no-sandbox --disable-gpu >/dev/null 2>&1 &
obsidian_pid=$!

# 5. Wait for the CLI to respond.
if ! /opt/wait-for-obsidian.sh "${READY_TIMEOUT}"; then
    log "ERROR: Obsidian did not become ready within ${READY_TIMEOUT}s"
    exit 1
fi
log "Obsidian is ready"

# 6. Hand off to ssrv. -env all so DISPLAY/HOME propagate to relayed commands.
mkdir -p "$(dirname "${OBSIDIAN_SOCK_PATH}")"
rm -f "${OBSIDIAN_SOCK_PATH}"
log "listening on unix:${OBSIDIAN_SOCK_PATH}"
exec ssrv -srv -sock "unix:${OBSIDIAN_SOCK_PATH}" -env all
