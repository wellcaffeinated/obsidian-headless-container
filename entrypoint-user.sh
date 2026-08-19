#!/bin/bash
# Unprivileged entrypoint: brings up Xvfb, generates obsidian.json, launches
# Obsidian, waits for readiness, then hands off to the fling relay.
set -euo pipefail

OBSIDIAN_BIN="${OBSIDIAN_BIN:-/opt/obsidian/obsidian}"
OBSIDIAN_SOCK_PATH="${OBSIDIAN_SOCK_PATH:-/run/obsidian/obsidian.sock}"
VAULTS_DIR="${VAULTS_DIR:-/vaults}"
CONFIG_DIR="${HOME}/.config/obsidian"
CONFIG_FILE="${CONFIG_DIR}/obsidian.json"
TEMPLATE_FILE="${TEMPLATE_FILE:-/opt/obsidian.json.template}"
DEFAULT_VAULT="${DEFAULT_VAULT:-}"
READY_TIMEOUT="${READY_TIMEOUT:-120}"
DAEMON_LOG="${DAEMON_LOG:-/tmp/obsidian-daemon.log}"
DAEMON_LOG_TAIL="${DAEMON_LOG_TAIL:-40}"
DAEMON_LOG_LINE_CHARS="${DAEMON_LOG_LINE_CHARS:-500}"
DAEMON_LOG_MAX_BYTES="${DAEMON_LOG_MAX_BYTES:-1048576}"
DAEMON_LOG_TRIM_INTERVAL="${DAEMON_LOG_TRIM_INTERVAL:-300}"

log() { printf '[entrypoint] %s\n' "$*" >&2; }

# Bash reports a signal death as 128+signum; the number alone is opaque in a
# crash report (133 is SIGTRAP -- a Chromium CHECK/abort -- not an OOM kill,
# which would be 137/SIGKILL).
describe_status() {
    local s=$1
    if (( s > 128 && s < 192 )); then
        printf '%s (SIG%s)' "${s}" "$(kill -l $(( s - 128 )) 2>/dev/null || printf '?')"
    else
        printf '%s' "${s}"
    fi
}

# The daemon echoes every relayed CLI call, so its log grows for as long as the
# container lives -- and fastest exactly when something is wrong and a component
# is spewing errors in a loop. Keep it bounded to the recent past, which is all
# the crash dump below ever reads.
#
# Truncating in place is what makes this safe: the daemon holds the file open in
# append mode, so its next write lands at the new end. Replacing the file
# (mv/rename) would leave it writing to an unlinked inode forever.
trim_daemon_log() {
    while sleep "${DAEMON_LOG_TRIM_INTERVAL}"; do
        [[ -f "${DAEMON_LOG}" ]] || continue
        local size
        size=$(stat -c %s "${DAEMON_LOG}" 2>/dev/null || echo 0)
        (( size > DAEMON_LOG_MAX_BYTES )) || continue
        if tail -c "$(( DAEMON_LOG_MAX_BYTES / 2 ))" "${DAEMON_LOG}" > "${DAEMON_LOG}.trim" 2>/dev/null; then
            cat "${DAEMON_LOG}.trim" > "${DAEMON_LOG}"
        fi
        rm -f "${DAEMON_LOG}.trim"
    done
}

xvfb_pid=""
obsidian_pid=""
fling_pid=""
trimmer_pid=""
shutting_down=0
cleanup() {
    shutting_down=1
    log "shutting down"
    [[ -n "${trimmer_pid}" ]] && kill "${trimmer_pid}" 2>/dev/null || true
    [[ -n "${fling_pid}" ]] && kill "${fling_pid}" 2>/dev/null || true
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

mapfile -t vault_paths < <(find "${VAULTS_DIR}" -mindepth 1 -maxdepth 1 -type d -not -name '.*' | sort)
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
# Output is captured rather than discarded: when the daemon dies, its exit
# status alone says nothing about why. Chromium prints the CHECK failure or
# V8 fatal error immediately before trapping, so the tail dumped below is the
# only forensic trail a crash leaves. It goes to a file, not to stderr, so
# Electron's steady-state chatter stays out of `docker logs`.
: > "${DAEMON_LOG}"
"${OBSIDIAN_BIN}" --no-sandbox --disable-gpu >>"${DAEMON_LOG}" 2>&1 &
obsidian_pid=$!

# Deliberately not supervised by `wait -n` below: a dead trimmer costs disk,
# not correctness, and must not take a working container down.
trim_daemon_log &
trimmer_pid=$!

# 5. Wait for the CLI to respond.
if ! /opt/wait-for-obsidian.sh "${READY_TIMEOUT}"; then
    log "ERROR: Obsidian did not become ready within ${READY_TIMEOUT}s"
    exit 1
fi
log "Obsidian is ready"

# 6. Start fling. Env vars (DISPLAY, HOME) are inherited from this process.
mkdir -p "$(dirname "${OBSIDIAN_SOCK_PATH}")"
rm -f "${OBSIDIAN_SOCK_PATH}"
log "listening on unix:${OBSIDIAN_SOCK_PATH}"
fling server --socket "unix:${OBSIDIAN_SOCK_PATH}" --config /etc/fling/config.toml &
fling_pid=$!

# 7. Supervise. fling is deliberately *not* exec'd: it has no idea whether the
# Obsidian daemon behind it is alive, and will happily keep serving a socket
# with no backend. Every call then boots a fresh Electron app instead of
# reaching the daemon, hangs, and exits non-zero — while the container still
# looks healthy from the outside. Staying in the shell also means this process
# reaps the daemon rather than leaving it a zombie.
#
# So: wait for whichever of the three dies first and take the container down
# with it, letting the restart policy rebuild a working set.
# `|| status=$?` keeps `set -e` from aborting before the diagnostics below:
# wait returns the dead process's own (non-zero) status.
status=0
wait -n "${obsidian_pid}" "${fling_pid}" "${xvfb_pid}" || status=$?

# A signal-driven stop (docker stop) runs cleanup first; that is not a failure.
if (( shutting_down )); then
    exit 0
fi

if ! kill -0 "${obsidian_pid}" 2>/dev/null; then
    log "ERROR: Obsidian daemon exited (status $(describe_status "${status}")) — the CLI cannot work without it"
    if [[ -s "${DAEMON_LOG}" ]]; then
        log "last ${DAEMON_LOG_TAIL} lines of ${DAEMON_LOG}:"
        tail -n "${DAEMON_LOG_TAIL}" "${DAEMON_LOG}" | cut -c "1-${DAEMON_LOG_LINE_CHARS}" >&2
    else
        log "(${DAEMON_LOG} is empty — the daemon died without saying anything)"
    fi
elif ! kill -0 "${fling_pid}" 2>/dev/null; then
    log "ERROR: fling server exited (status $(describe_status "${status}"))"
elif ! kill -0 "${xvfb_pid}" 2>/dev/null; then
    log "ERROR: Xvfb exited (status $(describe_status "${status}"))"
fi

# Always fail, so `restart: on-failure` also recreates the container when a
# component exits 0.
log "exiting so the container restart policy can recover"
exit $(( status == 0 ? 1 : status ))
