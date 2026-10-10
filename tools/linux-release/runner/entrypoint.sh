#!/usr/bin/env bash
# Registers the runner once (REPO_URL, RUNNER_TOKEN, RUNNER_NAME) and keeps its registration in
# /state, a volume: a restarted container comes back as the same runner without a new token.
set -euo pipefail
cd /home/runner
files=(.runner .credentials .credentials_rsaparams)
if [ -f /state/.runner ]; then
    for f in "${files[@]}"; do cp "/state/$f" .; done
else
    : "${REPO_URL:?}" "${RUNNER_TOKEN:?}"
    ./config.sh --unattended --replace --url "$REPO_URL" --token "$RUNNER_TOKEN" \
        --name "${RUNNER_NAME:-ue4ss-games}" --labels ue4ss-games --work /home/runner/_work
    for f in "${files[@]}"; do cp "$f" /state/; done
fi
exec ./run.sh
