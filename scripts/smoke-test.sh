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
for cmd in bash sh id cat env; do
    output=$(docker exec "${container}" \
        fling --socket unix:/run/obsidian/obsidian.sock "${cmd}" 2>&1) && {
        echo "FAIL: fling accepted '${cmd}' — allowlist not enforced" >&2
        exit 1
    }
    if ! echo "${output}" | grep -qi "not in the allowlist\|allowlist"; then
        echo "FAIL: fling rejected '${cmd}' but error message was unexpected: ${output}" >&2
        exit 1
    fi
    echo "  blocked: ${cmd}"
done

echo
echo "SMOKE TEST PASSED"
