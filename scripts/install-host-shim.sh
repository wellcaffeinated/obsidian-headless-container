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

FLING_VERSION="${FLING_VERSION:-0.2.0}"
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
sock="\${OBSIDIAN_SOCK:-${SOCK_DEFAULT}}"
exec "${bin_dir}/fling" --socket "\${sock}" obsidian "\$@"
EOF
chmod +x "${bin_dir}/obsidian"
echo "installed ${bin_dir}/obsidian (socket default: ${SOCK_DEFAULT})"

cat <<EOF

Done. Test it:
    obsidian version

If the socket lives elsewhere:
    OBSIDIAN_SOCK=unix:/path/to/obsidian.sock obsidian version

EOF
