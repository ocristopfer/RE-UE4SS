#!/usr/bin/env bash
# Runs the real-server tests on this machine, for whoever wants them before a release or before moving
# a game profile of the panel: only Docker and the game volumes of games.json are needed (Linux, or
# Windows with Docker Desktop from Git Bash). Nothing stays running afterwards.
#
#   tests/linux/integration/local.sh <libUE4SS.so> [gate|all|game,game,...] [out-dir]
#
# The release files are assembled with tools/linux-release/package.sh, the reference packs coming
# from the latest linux-v* release; the results land in <out-dir> (default: integration-results).
set -euo pipefail
lib=$1
selection=${2:-gate}
out=${3:-integration-results}
repo=$(cd "$(dirname "$0")/../../.." && pwd)
mkdir -p "$out"
lib_dir=$(cd "$(dirname "$lib")" && pwd)
lib_name=$(basename "$lib")
out=$(cd "$out" && pwd)
if command -v cygpath >/dev/null; then
    repo=$(cygpath -m "$repo"); lib_dir=$(cygpath -m "$lib_dir"); out=$(cygpath -m "$out")
    export MSYS_NO_PATHCONV=1
fi

docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
    -v "$repo:/src:ro" -v "$lib_dir:/lib-in:ro" -v "$out:/out" \
    -e LIB="/lib-in/$lib_name" -e SELECTION="$selection" \
    -e GAME_SECONDS="${GAME_SECONDS:-600}" -e DRAGONWILDS_OWNER_ID="${DRAGONWILDS_OWNER_ID:-}" \
    docker:27-cli sh -c '
        set -e
        apk add -q bash python3 curl tar gzip coreutils sed grep
        api=https://api.github.com/repos/ocristopfer/RE-UE4SS/releases
        url=$(curl -fsSL "$api?per_page=50" | python3 -c "
import json, sys
rels = [r for r in json.load(sys.stdin) if r[\"tag_name\"].startswith(\"linux-v\")]
rel = max(rels, key=lambda r: tuple(int(x) for x in r[\"tag_name\"][7:].split(\".\")))
print(next(a[\"browser_download_url\"] for a in rel[\"assets\"] if a[\"name\"] == \"LinuxReferencePacks.tar.gz\"))")
        mkdir -p /tmp/packs && curl -fsSL "$url" -o /tmp/packs/LinuxReferencePacks.tar.gz
        bash /src/tools/linux-release/package.sh "$LIB" /tmp/packs/LinuxReferencePacks.tar.gz /tmp/release
        bash /src/tests/linux/integration/run.sh /tmp/release "$SELECTION" /out
    '
