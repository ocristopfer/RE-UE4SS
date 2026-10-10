#!/usr/bin/env bash
# Runs the candidate release on real Linux dedicated servers, one at a time, and writes a summary.
#
#   tests/linux/integration/run.sh <release-dir> <gate|all|game,game,...> <out-dir>
#
# <release-dir> holds what the release would publish (libUE4SS.so, UE4SS-settings.ini, the
# tarballs, SHA256SUMS). Each game runs in its own container: its volume read-only under an overlay
# (nothing is written to it), UE4SS installed by the game panel's own installer, the CI probe mod.
# Needs: docker, the game volumes (games.json), network access to the panel repository.
# PANEL_REF picks the game-server-deploy commit (default: the one in panel.ref).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
release=$(cd "$1" && pwd)
selection=$2
out=$(mkdir -p "$3" && cd "$3" && pwd)
image=ue4ss-ci-game
panel_ref=${PANEL_REF:-$(tr -d '[:space:]' < "$here/panel.ref")}
panel_raw="https://raw.githubusercontent.com/ocristopfer/game-server-deploy/$panel_ref/src/gamepanel/games/mods"

docker build -q -t "$image" "$here" >/dev/null

panel="$out/panel"
mkdir -p "$panel"
for f in ue4ss_linux_remote.py ue_sym_layout.py ue_linux_layout.py; do
    curl -fsSL "$panel_raw/$f" -o "$panel/$f"
done

games=$(python3 - "$here/games.json" "$selection" <<'PY'
import json, sys
games = json.load(open(sys.argv[1]))["games"]
sel = sys.argv[2]
if sel == "gate":
    names = [n for n, g in games.items() if g.get("gate")]
elif sel == "all":
    names = list(games)
else:
    names = [n.strip() for n in sel.split(",") if n.strip()]
    unknown = [n for n in names if n not in games]
    if unknown:
        sys.exit(f"unknown game(s): {', '.join(unknown)}")
print(" ".join(names))
PY
)

failed=0
for name in $games; do
    echo "::group::$name"
    gdir="$out/$name"
    rm -rf "$gdir"; mkdir -p "$gdir"
    python3 -c 'import json,sys; json.dump(json.load(open(sys.argv[1]))["games"][sys.argv[2]], open(sys.argv[3], "w"))' \
        "$here/games.json" "$name" "$gdir/game.json"
    volume=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["volume"])' "$gdir/game.json")
    if ! docker volume inspect "$volume" >/dev/null 2>&1; then
        echo "volume $volume is missing: $name not tested"
        echo "{\"game\": \"$name\", \"passed\": false, \"error\": \"volume $volume missing\"}" > "$gdir/result.json"
        failed=1; echo "::endgroup::"; continue
    fi
    cid=$(docker create --cap-add SYS_ADMIN --security-opt apparmor=unconfined \
        --tmpfs /ovl:size=8g --mount "type=volume,src=$volume,dst=/lower,readonly" \
        -e GAME_SECONDS="${GAME_SECONDS:-600}" -e DRAGONWILDS_OWNER_ID="${DRAGONWILDS_OWNER_ID:-}" \
        "$image" python3 /ci/run_game.py "$name" /ci/game.json)
    docker cp "$release/." "$cid:/ci/release"
    docker cp "$panel/." "$cid:/ci/panel"
    docker cp "$here/run_game.py" "$cid:/ci/run_game.py"
    docker cp "$here/probe.lua" "$cid:/ci/probe.lua"
    docker cp "$gdir/game.json" "$cid:/ci/game.json"
    docker start -a "$cid" || failed=1
    docker cp "$cid:/ci/out/." "$gdir/" 2>/dev/null || true
    docker rm -f "$cid" >/dev/null
    [ -f "$gdir/result.json" ] || { echo "{\"game\": \"$name\", \"passed\": false, \"error\": \"no result\"}" > "$gdir/result.json"; failed=1; }
    echo "::endgroup::"
done

python3 - "$out" $games > "$out/summary.md" <<'PY'
import json, os, sys
out, names = sys.argv[1], sys.argv[2:]
print("| Game | Engine | Result | Time | Notes |")
print("|---|---|---|---|---|")
for n in names:
    r = json.load(open(os.path.join(out, n, "result.json")))
    notes = r.get("error") or ", ".join(
        [f"missing: {' '.join(r.get('missing', []))}" if r.get("missing") else "",
         f"failed: {' '.join(r.get('failed', []))}" if r.get("failed") else "",
         f"crash: {r['crash']}" if r.get("crash") else "",
         r.get("info", {}).get("hook_calls", "")]).strip(", ")
    print(f"| {n} | {r.get('engine', '')} | {'pass' if r.get('passed') else '**FAIL**'} | {r.get('seconds', '')}s | {notes} |")
PY
cat "$out/summary.md"
exit $failed
