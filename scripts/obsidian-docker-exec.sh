# Source this file from your shell rc to get an `obsidian` function that
# proxies CLI calls into the headless Obsidian container via `docker exec`.
#
# Override the target container with OBSIDIAN_CONTAINER (default: obsidian).
#
# Usage:
#   source /path/to/obsidian-docker-exec.sh
#   obsidian version
#   OBSIDIAN_CONTAINER=my-obsidian obsidian read path=note.md
#
# Tradeoffs vs the fling shim:
#   - No extra binaries to install; only needs docker on the calling host
#   - Requires docker CLI access (membership in the docker group)
#   - Bypasses the fling socket entirely; ties the helper to docker as the runtime
#   - Slower per-call (docker exec spin-up vs. socket roundtrip)
#   - Skips the fling allowlist: this runs the Obsidian binary directly, so it
#     is not constrained by /etc/fling/config.toml

obsidian() {
    docker exec -i -e DISPLAY=:99 "${OBSIDIAN_CONTAINER:-obsidian}" \
        /opt/obsidian/obsidian --no-sandbox "$@"
}
