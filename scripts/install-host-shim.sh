#!/bin/sh
# Installs the fling client binary and an `obsidian` wrapper that proxies
# CLI calls over the Unix socket exposed by the headless Obsidian container.
#
# Usage:
#   sudo ./install-host-shim.sh                # install to /usr/local/bin
#   PREFIX=$HOME/.local ./install-host-shim.sh # install to ~/.local/bin
#
# After install:
#   obsidian version
#   obsidian read path=note.md
#
# Override the socket location at call time:
#   OBSIDIAN_SOCK=unix:/tmp/other.sock obsidian version
set -eu

FLING_VERSION="${FLING_VERSION:-0.2.1}"
PREFIX="${PREFIX:-/usr/local}"
SOCK_DEFAULT="${SOCK_DEFAULT:-unix:/run/obsidian/obsidian.sock}"

bin_dir="${PREFIX}/bin"
mkdir -p "${bin_dir}"

uname_s=$(uname -s)
uname_m=$(uname -m)

case "${uname_s}" in
    Linux)  os="unknown-linux-musl" ;;
    Darwin) os="apple-darwin" ;;
    *) echo "unsupported OS: ${uname_s}" >&2; exit 1 ;;
esac

case "${uname_m}" in
    x86_64|amd64)  farch="x86_64" ;;
    aarch64|arm64) farch="aarch64" ;;
    *) echo "unsupported arch: ${uname_m}" >&2; exit 1 ;;
esac

url="https://github.com/wellcaffeinated/fling_rs/releases/download/v${FLING_VERSION}/fling-v${FLING_VERSION}-${farch}-${os}.tar.gz"
tmp=$(mktemp -d)
trap 'rm -rf "${tmp}"' EXIT

echo "downloading fling ${FLING_VERSION} for ${farch}-${os}..."
curl -fSL -o "${tmp}/fling.tar.gz" "${url}"
tar -xzf "${tmp}/fling.tar.gz" -C "${tmp}" fling
install -m 0755 "${tmp}/fling" "${bin_dir}/fling"
echo "installed ${bin_dir}/fling"

cat > "${bin_dir}/obsidian" <<EOF
#!/bin/sh
# Proxies the call to the headless Obsidian container over a Unix socket.
# Override OBSIDIAN_SOCK to target a different socket.
#
# The container takes itself down whenever the Obsidian daemon dies, and the
# socket is recreated only once the daemon answers again -- ~10-15s warm, longer
# on a cold start. fling has no wait or retry of its own, so without this a call
# landing in that window fails outright with "No such file or directory", or
# with "Connection refused" against a socket left behind by a SIGKILL.
#
# Retrying is safe *because* it is gated on a connection failure: if fling could
# not connect, the command never reached Obsidian, so no write can be applied
# twice. Anything else -- a policy denial, a real command error -- is returned
# untouched on the first attempt.
#
# OBSIDIAN_WAIT is the budget in seconds; 0 restores single-shot behaviour.
sock="\${OBSIDIAN_SOCK:-${SOCK_DEFAULT}}"
wait_secs="\${OBSIDIAN_WAIT:-60}"

sock_path=\${sock#unix:}
err=\$(mktemp)
trap 'rm -f "\$err"' EXIT
deadline=\$(( \$(date +%s) + wait_secs ))

while :; do
    # Wait for the socket to appear before spending an attempt on it.
    if [ ! -S "\$sock_path" ] && [ "\$(date +%s)" -lt "\$deadline" ]; then
        sleep 1
        continue
    fi

    "${bin_dir}/fling" --socket "\$sock" obsidian "\$@" 2>"\$err"
    rc=\$?
    [ "\$rc" -eq 0 ] && break
    grep -q 'cannot connect to' "\$err" 2>/dev/null || break
    [ "\$(date +%s)" -lt "\$deadline" ] || break
    sleep 1
done

# stdout streams straight through; only stderr is held back, so that the
# connection errors we retry past are not printed for every failed attempt.
cat "\$err" >&2
exit "\$rc"
EOF
chmod +x "${bin_dir}/obsidian"
echo "installed ${bin_dir}/obsidian (socket default: ${SOCK_DEFAULT})"

cat <<EOF

Done. Test it:
    obsidian version

If the socket lives elsewhere:
    OBSIDIAN_SOCK=unix:/path/to/obsidian.sock obsidian version

EOF
