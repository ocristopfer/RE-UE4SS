# Runtime of the Linux dedicated servers for the integration tests (tests/linux/integration/run.sh).
# The game files come from a Docker volume; this image only carries what the servers load from the
# system, python3 for the game panel's installer, and the steam user (uid 1000, the volume owner).
FROM debian:13-slim
ENV DEBIAN_FRONTEND=noninteractive
RUN dpkg --add-architecture i386 && apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates python3 procps file util-linux lib32gcc-s1 lib32stdc++6 libx11-6 libgcc-s1 libcurl3t64-gnutls \
    && rm -rf /var/lib/apt/lists/* \
    && useradd -m -u 1000 steam
WORKDIR /ci
