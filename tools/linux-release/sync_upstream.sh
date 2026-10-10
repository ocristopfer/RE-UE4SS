#!/usr/bin/env bash
# Brings the upstream work into the Linux fork, for .github/workflows/linux-sync.yml.
#
#   tools/linux-release/sync_upstream.sh <out-dir>
#
# Run from a checkout of the fork's `linux` branch whose `origin` can push (both forks).
#   1. `main` of both forks (ocristopfer/RE-UE4SS, ocristopfer/UEPseudo) fast-forwards to upstream.
#   2. UEPseudo: upstream/main is merged into its `linux` on the branch `sync/upstream`.
#   3. RE-UE4SS: upstream/main is merged into `linux` on `sync/upstream`. The UEPseudo gitlink
#      conflicts whenever upstream bumped its submodule: it takes our UEPseudo merge, which contains
#      the commit upstream pinned (checked).
#   4. Both sync branches are pushed; the workflow opens the pull request into `linux`, where CI
#      and the integration tests run. Nothing reaches `linux` without them.
# Writes <out-dir>/status (up-to-date|merged|conflict), <out-dir>/summary.md and, on a conflict,
# <out-dir>/conflicts.txt. Nothing is pushed on a conflict.
set -euo pipefail
out=$(mkdir -p "$1" && cd "$1" && pwd)
repo=$(git rev-parse --show-toplevel)
sub=deps/first/Unreal
branch=sync/upstream
cd "$repo"
# Without the submodule checked out, `git -C $sub` would act on this repository instead.
if [ "$(git -C "$sub" rev-parse --show-toplevel 2>/dev/null)" != "$(cd "$sub" 2>/dev/null && pwd -P)" ]; then
    echo "$sub is not checked out (git submodule update --init $sub)" >&2
    exit 1
fi

git config user.name >/dev/null || git config user.name "ue4ss-linux-sync"
git config user.email >/dev/null || git config user.email "ue4ss-linux-sync@users.noreply.github.com"

remote() { # <dir> <name> <url>
    git -C "$1" remote get-url "$2" >/dev/null 2>&1 && git -C "$1" remote set-url "$2" "$3" || git -C "$1" remote add "$2" "$3"
}
remote . upstream "${UPSTREAM_RE_UE4SS:-https://github.com/UE4SS-RE/RE-UE4SS.git}"
remote "$sub" upstream "${UPSTREAM_UEPSEUDO:-https://github.com/Re-UE4SS/UEPseudo.git}"
# --no-recurse-submodules: upstream pins UEPseudo commits that our fork does not have yet.
git fetch -q --no-recurse-submodules origin main linux
git fetch -q --no-recurse-submodules upstream main
git -C "$sub" fetch -q origin main linux
git -C "$sub" fetch -q upstream main

conflict() { # <repo label> <files...>
    local label=$1; shift
    echo conflict > "$out/status"
    printf '%s\n' "$@" > "$out/conflicts.txt"
    {
        echo "Merging upstream/main into \`linux\` of **$label** stopped on conflicts:"
        echo
        printf -- '- `%s`\n' "$@"
        echo
        echo "Resolve locally (\`git merge upstream/main\` on \`linux\`), run the Linux build and tests, and push."
    } > "$out/summary.md"
    cat "$out/summary.md"
    exit 0
}

# 1. main of both forks mirrors upstream (fast-forward only: the forks keep nothing of their own there).
ff_main() { # <dir> <label>
    if git -C "$1" merge-base --is-ancestor origin/main upstream/main; then
        if [ "$(git -C "$1" rev-parse origin/main)" != "$(git -C "$1" rev-parse upstream/main)" ]; then
            git -C "$1" push -q origin upstream/main:refs/heads/main
            echo "$2: main fast-forwarded to $(git -C "$1" rev-parse --short upstream/main)"
        fi
    else
        echo "::warning::$2: main has commits that are not upstream; left as it is"
    fi
}
ff_main . RE-UE4SS
ff_main "$sub" UEPseudo

# 2. UEPseudo.
pinned_linux=$(git rev-parse origin/linux:$sub)
git -C "$sub" checkout -q -B "$branch" "$pinned_linux"
sub_changed=0
if ! git -C "$sub" merge-base --is-ancestor upstream/main HEAD; then
    if ! git -C "$sub" merge -q --no-ff --no-edit -m "Merge upstream/main ($(git -C "$sub" rev-parse --short upstream/main))" upstream/main; then
        mapfile -t files < <(git -C "$sub" diff --name-only --diff-filter=U)
        git -C "$sub" merge --abort
        conflict UEPseudo "${files[@]}"
    fi
    sub_changed=1
fi
sub_head=$(git -C "$sub" rev-parse HEAD)

# 3. RE-UE4SS.
git checkout -q -B "$branch" origin/linux
main_changed=0
if ! git merge-base --is-ancestor upstream/main HEAD; then
    if ! git merge -q --no-ff --no-commit upstream/main >/dev/null 2>&1; then
        mapfile -t files < <(git diff --name-only --diff-filter=U)
        others=()
        for f in "${files[@]}"; do [ "$f" = "$sub" ] || others+=("$f"); done
        if [ ${#others[@]} -gt 0 ]; then
            git merge --abort
            conflict RE-UE4SS "${others[@]}"
        fi
    fi
    main_changed=1
fi
if [ $main_changed = 1 ] || [ $sub_changed = 1 ]; then
    # Upstream's pin of UEPseudo (when it moved it) must be inside ours.
    upstream_pin=$(git rev-parse upstream/main:$sub)
    if ! git -C "$sub" merge-base --is-ancestor "$upstream_pin" "$sub_head"; then
        git merge --abort 2>/dev/null || true
        conflict "RE-UE4SS (upstream pins UEPseudo $upstream_pin, which is not in UEPseudo upstream/main)" "$sub"
    fi
    git -C "$sub" checkout -q "$sub_head"
    git add "$sub"
fi
if [ $main_changed = 1 ]; then
    git commit -q --no-edit -m "Merge upstream/main ($(git rev-parse --short upstream/main))"
elif [ $sub_changed = 1 ]; then
    git commit -q -m "UEPseudo: merge upstream/main ($(git -C "$sub" rev-parse --short upstream/main))"
else
    echo up-to-date > "$out/status"
    echo "linux already has upstream/main of both projects." | tee "$out/summary.md"
    exit 0
fi

# 4. Push the sync branches (the UEPseudo one first: the RE-UE4SS commit points into it).
[ $sub_changed = 1 ] && git -C "$sub" push -q -f origin "HEAD:refs/heads/$branch"
git push -q -f origin "HEAD:refs/heads/$branch"
echo merged > "$out/status"
{
    echo "Upstream work merged into \`linux\`. CI and the integration tests on real servers run on this pull request;"
    echo "merging it releases nothing by itself - the Linux release workflow decides after its own tests."
    echo
    if [ $main_changed = 1 ]; then
        echo "### RE-UE4SS (UE4SS-RE/RE-UE4SS main)"
        git log --no-merges --format='- %s (%h)' "origin/linux..upstream/main" | head -100
        echo
    fi
    if [ $sub_changed = 1 ]; then
        echo "### UEPseudo (Re-UE4SS/UEPseudo main)"
        git -C "$sub" log --no-merges --format='- %s (%h)' "$pinned_linux..upstream/main" | head -100
    fi
} > "$out/summary.md"
cat "$out/summary.md"
