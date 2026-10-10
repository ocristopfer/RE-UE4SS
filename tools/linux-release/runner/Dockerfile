# Self-hosted GitHub Actions runner for the integration tests (label ue4ss-games): it starts the game
# servers as sibling containers through the host's Docker socket, so the game volumes stay on the host.
FROM ghcr.io/actions/actions-runner:2.337.0
USER root
RUN apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*
COPY entrypoint.sh /usr/local/bin/runner-entrypoint
RUN chmod 0755 /usr/local/bin/runner-entrypoint
# Docker socket access is root on the Docker VM anyway; the runner runs as root to reach it.
ENV RUNNER_ALLOW_RUNASROOT=1
ENTRYPOINT ["/usr/local/bin/runner-entrypoint"]
