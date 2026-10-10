#!/usr/bin/env bash
# Starts the self-hosted runner of the Linux integration tests on this machine:
#
#   tools/linux-release/runner/setup.sh [owner/repo]
#
# Needs Docker with the game volumes (tests/linux/integration/games.json) and an authenticated gh
# with admin rights on the repository (to get a registration token). Run it again to rebuild the
# image; the registration is kept in the volume ue4ss-games-runner-state (delete it to register anew).
set -euo pipefail
repo=${1:-ocristopfer/RE-UE4SS}
here=$(cd "$(dirname "$0")" && pwd)
name=ue4ss-games-runner

docker build -t "$name" "$here"
token=""
if ! docker run --rm -v ue4ss-games-runner-state:/state alpine test -f /state/.runner; then
    token=$(gh api -X POST "repos/$repo/actions/runners/registration-token" --jq .token)
fi
docker rm -f "$name" >/dev/null 2>&1 || true
docker run -d --name "$name" --restart unless-stopped \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v ue4ss-games-runner-state:/state \
    -e REPO_URL="https://github.com/$repo" -e RUNNER_TOKEN="$token" -e RUNNER_NAME="ue4ss-games-$(hostname)" \
    "$name"
echo "runner $name started; it shows up under https://github.com/$repo/settings/actions/runners"
