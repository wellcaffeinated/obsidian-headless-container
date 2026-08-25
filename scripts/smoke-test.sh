#!/bin/bash
# End-to-end smoke test for the headless Obsidian container.
#
# Builds the image, runs it against throwaway vaults, exercises the CLI
# from inside the container (via the fling server's own client mode), and
# tears down. Does not require the host shim to be installed.
#
# Usage:
#   ./scripts/smoke-test.sh
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
cd "${repo_root}"

image="obsidian-headless:smoke"
container="ohc-smoke"
test_dir=$(mktemp -d -t ohc-smoke.XXXXXX)
sock_dir="${test_dir}/sock"
# More than one vault: a single open vault hides the /dev/shm ceiling the check
# below exists to catch. The first name sorts first, so it stays the default
# vault; the rest carry spaces, as the real ones do.
vaults=("SmokeVault" "SmokeVault Two" "SmokeVault Three" "SmokeVault Four")

cleanup() {
    docker rm -f "${container}" >/dev/null 2>&1 || true
    rm -rf "${test_dir}"
}
trap cleanup EXIT

echo "==> building image"
docker build -t "${image}" .

echo "==> preparing ${#vaults[@]} throwaway vaults under ${test_dir}/vaults"
mkdir -p "${sock_dir}"
for v in "${vaults[@]}"; do
    mkdir -p "${test_dir}/vaults/${v}/.obsidian"
    echo "# hello smoke test" > "${test_dir}/vaults/${v}/note.md"
done
# Ensure the in-container UID 1000 can write
chmod -R a+rwX "${test_dir}"

echo "==> starting container as PUID=$(id -u) PGID=$(id -g)"
docker run -d --name "${container}" \
    -e PUID="$(id -u)" \
    -e PGID="$(id -g)" \
    -v "${test_dir}/vaults:/vaults" \
    -v "${sock_dir}:/run/obsidian" \
    "${image}" >/dev/null

echo "==> waiting for socket to appear (up to 180s)"
for _ in $(seq 1 90); do
    [[ -S "${sock_dir}/obsidian.sock" ]] && break
    if ! docker ps --filter "name=^${container}$" --format '{{.Names}}' | grep -q "${container}"; then
        echo "FAIL: container exited" >&2
        docker logs "${container}" >&2 || true
        exit 1
    fi
    sleep 2
done
if [[ ! -S "${sock_dir}/obsidian.sock" ]]; then
    echo "FAIL: socket never appeared" >&2
    echo "--- container logs ---" >&2
    docker logs "${container}" >&2 || true
    exit 1
fi

echo "==> verifying the image ships the pinned fling"
# Guards against silent drift between the Dockerfile pin and what is actually
# installed -- a mismatch is invisible at runtime until some version-specific
# behaviour changes under you. Needs fling 0.2.1+, which added --version.
pinned=$(grep -m1 '^ARG FLING_VERSION=' Dockerfile | cut -d= -f2)
actual=$(docker exec "${container}" fling --version 2>/dev/null | awk '{print $2}')
if [[ -z "${actual}" ]]; then
    echo "FAIL: 'fling --version' returned nothing (needs fling 0.2.1+)" >&2
    exit 1
fi
if [[ "${actual}" != "${pinned}" ]]; then
    echo "FAIL: image ships fling ${actual}, Dockerfile pins ${pinned}" >&2
    exit 1
fi
echo "  fling ${actual} matches the pin"

echo "==> calling 'obsidian version' through fling"
docker exec "${container}" fling --socket unix:/run/obsidian/obsidian.sock obsidian version

echo "==> calling 'obsidian vault' through fling"
docker exec "${container}" fling --socket unix:/run/obsidian/obsidian.sock obsidian vault

echo "==> calling 'obsidian read path=note.md' through fling"
docker exec "${container}" fling --socket unix:/run/obsidian/obsidian.sock obsidian read path=note.md

echo "==> verifying allowlist rejects unlisted commands"
# fling 0.2+ returns a uniform denial regardless of whether the command is
# unknown or merely disallowed, so the rules don't leak which commands exist.
for cmd in bash sh id cat env; do
    output=$(docker exec "${container}" \
        fling --socket unix:/run/obsidian/obsidian.sock "${cmd}" 2>&1) && {
        echo "FAIL: fling accepted '${cmd}' — allowlist not enforced" >&2
        exit 1
    }
    if ! echo "${output}" | grep -qi "not authorized"; then
        echo "FAIL: fling rejected '${cmd}' but error message was unexpected: ${output}" >&2
        exit 1
    fi
    echo "  blocked: ${cmd}"
done

echo "==> verifying open vaults do not consume /dev/shm"
# Open vaults exhaust the 64 MiB /dev/shm Docker gives a container by default
# and the browser process dies silently -- see docs/chromium-flags.md. Crossing
# the cliff is a coin flip, so the assertion is on usage (zero with the flag,
# tens of MiB without); the liveness check catches the run that does trip it.
for pass in 1 2; do
    for v in "${vaults[@]}"; do
        docker exec "${container}" fling --socket unix:/run/obsidian/obsidian.sock \
            obsidian "vault=${v}" file path=note.md >/dev/null 2>&1 || true
        state=$(docker inspect -f '{{.State.Status}}' "${container}" 2>/dev/null || echo gone)
        if [[ "${state}" != "running" ]]; then
            code=$(docker inspect -f '{{.State.ExitCode}}' "${container}" 2>/dev/null || echo '?')
            echo "FAIL: container died (${state}, code ${code}) on pass ${pass}, on vault '${v}'." >&2
            echo "      Open vaults exhausted /dev/shm — is --disable-dev-shm-usage still set?" >&2
            docker logs --tail 20 "${container}" >&2 || true
            exit 1
        fi
    done
done
shm_used=$(docker exec "${container}" df -m /dev/shm | awk 'NR==2 {print $3}')
if [[ -z "${shm_used}" ]] || (( shm_used > 4 )); then
    echo "FAIL: ${#vaults[@]} open vaults put ${shm_used:-?} MiB in /dev/shm; the cap is 64 MiB" >&2
    echo "      and the browser process dies silently (status 133) on the allocation" >&2
    echo "      that does not fit. Is --disable-dev-shm-usage still set?" >&2
    exit 1
fi
docker exec "${container}" fling --socket unix:/run/obsidian/obsidian.sock \
    obsidian read path=note.md >/dev/null
echo "  ${#vaults[@]} vaults open, /dev/shm holds ${shm_used} MiB, CLI still answering"

echo "==> verifying GPU process deaths do not take the container down"
# Obsidian 1.13 (Chromium 150) runs a GPU process even under --disable-gpu, and
# Chromium aborts the browser process on that process's third death -- exit 133,
# indistinguishable from any other Chromium CHECK. --disable-gpu-process-crash-limit
# in entrypoint-user.sh removes that policy; three kills is one past the limit,
# so this fails if the flag is ever dropped or stops working.
gpu_seen=0
for round in 1 2 3; do
    gpu_pid=$(docker exec "${container}" sh -c \
        'ps -eo pid,args --no-headers | grep -- "--type=gpu-process" | grep -v grep | head -1 | awk "{print \$1}"')
    if [[ -z "${gpu_pid}" ]]; then
        echo "  no GPU process present (round ${round}) — this Electron does not spawn one"
        break
    fi
    gpu_seen=1
    docker exec "${container}" kill -9 "${gpu_pid}" 2>/dev/null || true
    sleep 3
    state=$(docker inspect -f '{{.State.Status}}' "${container}" 2>/dev/null || echo gone)
    if [[ "${state}" != "running" ]]; then
        code=$(docker inspect -f '{{.State.ExitCode}}' "${container}" 2>/dev/null || echo '?')
        echo "FAIL: container died (${state}, code ${code}) after ${round} GPU process kill(s)." >&2
        echo "      Chromium aborted the browser process over a component nothing here uses." >&2
        docker logs --tail 20 "${container}" >&2 || true
        exit 1
    fi
done
if (( gpu_seen )); then
    docker exec "${container}" fling --socket unix:/run/obsidian/obsidian.sock \
        obsidian read path=note.md >/dev/null
    echo "  survived 3 GPU process kills, CLI still answering"
fi

# Must run last: it takes the container down on purpose.
echo "==> verifying the container exits when the Obsidian daemon dies"
docker exec "${container}" pkill -f -- '--no-sandbox --disable-gpu' || true
state="running"
for _ in $(seq 1 30); do
    state=$(docker inspect -f '{{.State.Status}}' "${container}" 2>/dev/null || echo gone)
    [[ "${state}" == "running" ]] || break
    sleep 1
done
if [[ "${state}" == "running" ]]; then
    echo "FAIL: daemon died but the container kept running — fling would serve" >&2
    echo "      a socket with no backend, and every call would boot a doomed" >&2
    echo "      Electron app instead of reaching the daemon." >&2
    docker logs --tail 20 "${container}" >&2 || true
    exit 1
fi
code=$(docker inspect -f '{{.State.ExitCode}}' "${container}" 2>/dev/null || echo '?')
if [[ "${code}" == "0" ]]; then
    echo "FAIL: container exited 0; 'restart: on-failure' would not recover it" >&2
    exit 1
fi
echo "  container exited (${state}, code ${code}) — restart policy can recover"

echo
echo "SMOKE TEST PASSED"
