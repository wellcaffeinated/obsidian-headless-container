#!/bin/bash
# End-to-end smoke test for the headless Obsidian container.
#
# Builds the image, runs it against a throwaway vault, exercises the CLI
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
vault_dir="${test_dir}/vaults/SmokeVault"

cleanup() {
    docker rm -f "${container}" >/dev/null 2>&1 || true
    rm -rf "${test_dir}"
}
trap cleanup EXIT

echo "==> building image"
docker build -t "${image}" .

echo "==> preparing throwaway vault at ${vault_dir}"
mkdir -p "${vault_dir}/.obsidian" "${sock_dir}"
echo "# hello smoke test" > "${vault_dir}/note.md"
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
