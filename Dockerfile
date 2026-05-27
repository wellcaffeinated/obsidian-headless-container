FROM ubuntu:24.04

ARG OBSIDIAN_VERSION=1.12.7
ARG FLING_VERSION=0.1.0
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

# fling (multi-arch)
RUN set -eux; \
    case "${TARGETARCH}" in \
        amd64) FARCH="x86_64" ;; \
        arm64) FARCH="aarch64" ;; \
        *) echo "unsupported arch: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fSL -o /tmp/fling.tar.gz \
        "https://github.com/wellcaffeinated/fling_rs/releases/download/v${FLING_VERSION}/fling-v${FLING_VERSION}-${FARCH}-unknown-linux-musl.tar.gz"; \
    tar -xzf /tmp/fling.tar.gz -C /tmp fling; \
    install -m 0755 /tmp/fling /usr/local/bin/fling; \
    rm /tmp/fling.tar.gz /tmp/fling

# fling allowlist: only the obsidian wrapper is permitted
RUN mkdir -p /etc/fling && \
    printf '[commands.obsidian]\nexecutable = "/usr/local/bin/obsidian"\n' \
        > /etc/fling/config.toml

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
