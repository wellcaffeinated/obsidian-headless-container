#!/bin/sh
# Installs the ssrv client binary and an `obsidian` wrapper that proxies
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

SSRV_VERSION="${SSRV_VERSION:-0.3.4}"
SSRV_BUILD="${SSRV_BUILD:-r0.g85a1f7f}"
PREFIX="${PREFIX:-/usr/local}"
SOCK_DEFAULT="${SOCK_DEFAULT:-unix:/run/obsidian/obsidian.sock}"

bin_dir="${PREFIX}/bin"
mkdir -p "${bin_dir}"

uname_m=$(uname -m)
case "${uname_m}" in
    x86_64|amd64)   sarch="x86_64" ;;
    aarch64|arm64)  sarch="aarch64" ;;
    armv7l)         sarch="armv7" ;;
    i386|i686)      sarch="i386" ;;
    *) echo "unsupported arch: ${uname_m}" >&2; exit 1 ;;
esac

url="https://github.com/VHSgunzo/ssrv/releases/download/v${SSRV_VERSION}/ssrv-${sarch}-v${SSRV_VERSION}.${SSRV_BUILD}.tar.zst"
tmp=$(mktemp -d)
trap 'rm -rf "${tmp}"' EXIT

echo "downloading ssrv ${SSRV_VERSION} for ${sarch}..."
curl -fSL -o "${tmp}/ssrv.tar.zst" "${url}"

if ! command -v zstd >/dev/null 2>&1; then
    echo "ERROR: zstd is required to extract the ssrv release archive" >&2
    echo "  Debian/Ubuntu: sudo apt-get install zstd" >&2
    echo "  macOS:         brew install zstd" >&2
    echo "  Arch:          sudo pacman -S zstd" >&2
    exit 1
fi

tar --use-compress-program=unzstd -xf "${tmp}/ssrv.tar.zst" -C "${tmp}"
ssrv_bin=$(find "${tmp}" -type f -name ssrv | head -n1)
install -m 0755 "${ssrv_bin}" "${bin_dir}/ssrv"
echo "installed ${bin_dir}/ssrv"

cat > "${bin_dir}/obsidian" <<EOF
#!/bin/sh
# Proxies the call to the headless Obsidian container over a Unix socket.
# Override OBSIDIAN_SOCK to target a different socket.
sock="\${OBSIDIAN_SOCK:-${SOCK_DEFAULT}}"
# ssrv lowercases the -sock path; an uppercase path silently misses the socket.
case "\${sock}" in
    *[A-Z]*) echo "obsidian: socket path contains uppercase characters, which ssrv cannot dial: \${sock}" >&2; exit 1 ;;
esac
exec "${bin_dir}/ssrv" -sock "\${sock}" obsidian "\$@"
EOF
chmod +x "${bin_dir}/obsidian"
echo "installed ${bin_dir}/obsidian (socket default: ${SOCK_DEFAULT})"

cat <<EOF

Done. Test it:
    obsidian version

If the socket lives elsewhere:
    OBSIDIAN_SOCK=unix:/path/to/obsidian.sock obsidian version

EOF
