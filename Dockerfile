FROM ubuntu:24.04

ARG OBSIDIAN_VERSION=1.12.7
ARG SSRV_VERSION=0.3.4
ARG SSRV_BUILD=r0.g85a1f7f
ARG TARGETARCH

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        wget \
        jq \
        tini \
        gosu \
        dbus \
        xvfb \
        xdg-utils \
        zstd \
        libgtk-3-0 \
        libnotify4 \
        libnss3 \
        libxss1 \
        libasound2t64 \
        libgbm1 \
        libsecret-1-0 \
        libdrm2 \
    && rm -rf /var/lib/apt/lists/*

# Obsidian (multi-arch). The .tar.gz is used rather than the AppImage:
# extracting an AppImage requires executing its FUSE runtime, which fails
# under QEMU emulation during multi-arch builds.
RUN set -eux; \
    case "${TARGETARCH}" in \
        amd64) TARBALL="obsidian-${OBSIDIAN_VERSION}.tar.gz" ;; \
        arm64) TARBALL="obsidian-${OBSIDIAN_VERSION}-arm64.tar.gz" ;; \
        *) echo "unsupported arch: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    mkdir -p /opt/obsidian; \
    curl -fSL -o /tmp/obsidian.tar.gz \
        "https://github.com/obsidianmd/obsidian-releases/releases/download/v${OBSIDIAN_VERSION}/${TARBALL}"; \
    tar -xzf /tmp/obsidian.tar.gz -C /opt/obsidian; \
    rm /tmp/obsidian.tar.gz; \
    extracted="$(find /opt/obsidian -mindepth 1 -maxdepth 1 -type d -name 'obsidian-*')"; \
    chmod -R go+rX "${extracted}"; \
    ln -s "${extracted}/obsidian" /opt/obsidian/obsidian; \
    printf '#!/bin/sh\nexec /opt/obsidian/obsidian --no-sandbox --disable-gpu "$@"\n' > /usr/local/bin/obsidian; \
    chmod +x /usr/local/bin/obsidian

# ssrv (multi-arch)
RUN set -eux; \
    case "${TARGETARCH}" in \
        amd64) SARCH="x86_64" ;; \
        arm64) SARCH="aarch64" ;; \
        *) echo "unsupported arch: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    cd /tmp; \
    curl -fSL -o ssrv.tar.zst \
        "https://github.com/VHSgunzo/ssrv/releases/download/v${SSRV_VERSION}/ssrv-${SARCH}-v${SSRV_VERSION}.${SSRV_BUILD}.tar.zst"; \
    mkdir -p ssrv-extract; \
    tar --use-compress-program=unzstd -xf ssrv.tar.zst -C ssrv-extract; \
    install -m 0755 "$(find ssrv-extract -type f -name ssrv | head -n1)" /usr/local/bin/ssrv; \
    rm -rf ssrv.tar.zst ssrv-extract

RUN userdel -r ubuntu 2>/dev/null || true \
    && groupadd -g 1000 obsidian \
    && useradd -m -u 1000 -g 1000 -s /bin/bash obsidian \
    && mkdir -p /vaults /run/obsidian /home/obsidian/.config/obsidian \
    && install -d -m 1777 /tmp/.X11-unix \
    && chown -R obsidian:obsidian /vaults /run/obsidian /home/obsidian

COPY entrypoint.sh /opt/entrypoint.sh
COPY entrypoint-user.sh /opt/entrypoint-user.sh
COPY config/obsidian.json.template /opt/obsidian.json.template
COPY scripts/wait-for-obsidian.sh /opt/wait-for-obsidian.sh
RUN chmod +x /opt/entrypoint.sh /opt/entrypoint-user.sh /opt/wait-for-obsidian.sh

ENV DISPLAY=:99 \
    OBSIDIAN_BIN=/opt/obsidian/obsidian \
    OBSIDIAN_SOCK_PATH=/run/obsidian/obsidian.sock \
    HOME=/home/obsidian

WORKDIR /home/obsidian

VOLUME ["/vaults", "/run/obsidian"]

ENTRYPOINT ["/usr/bin/tini", "--", "/opt/entrypoint.sh"]
