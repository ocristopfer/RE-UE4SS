#!/usr/bin/env bash
# Decides the next linux-v* release from what changed since the last one, in the GITHUB_OUTPUT format
# (release=, previous=, next=, bump=, reason=). Usage: next_version.sh [auto|patch|minor|major] [force]
#
# Only commits that touch what users install count (PATHS below; docs, CI and tests never bump):
#   major  a commit marked breaking: `type!:` / `type(scope)!:` subject, `BREAKING CHANGE` in the body,
#          or a `Release: major` trailer
#   minor  a feature: `feat:` / `feat(scope):` subject (upstream uses Conventional Commits), a new mod
#          in cppmods or assets/Mods/shared, or a `Release: minor` trailer
#   patch  anything else (fixes, refactors, upstream syncs without features, UEPseudo pin moves)
# A `Release: patch` trailer caps that commit at patch. The old tags linux-v1..linux-v4 count as N.0.0.
set -euo pipefail

bump_override=${1:-auto}
force=${2:-false}
PATHS=(UE4SS deps cmake CMakeLists.txt cppmods assets/UE4SS-settings.ini assets/Mods/shared assets/VTableLayoutTemplates)

previous=$(git tag -l 'linux-v*' | grep -E '^linux-v[0-9]+(\.[0-9]+){0,2}$' | sort -V | tail -1 || true)
echo "previous=$previous"

if [ -z "$previous" ]; then
    echo "release=true"; echo "next=linux-v1.0.0"; echo "bump=major"; echo "reason=first release"
    exit 0
fi

IFS=. read -r major minor patch <<< "${previous#linux-v}"
minor=${minor:-0}; patch=${patch:-0}

rank() { case $1 in major) echo 3 ;; minor) echo 2 ;; patch) echo 1 ;; *) echo 0 ;; esac; }
level=none
reason=""
raise() { # raise <level> <why>
    if [ "$(rank "$1")" -gt "$(rank "$level")" ]; then level=$1; reason=$2; fi
}

while read -r sha; do
    [ -n "$sha" ] || continue
    subject=$(git log -1 --format=%s "$sha")
    body=$(git log -1 --format=%b "$sha")
    trailer=$(git log -1 --format='%(trailers:key=Release,valueonly)' "$sha" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
    short=$(git rev-parse --short "$sha")
    case $trailer in
        major|minor|patch) raise "$trailer" "Release: $trailer trailer in $short ($subject)"; continue ;;
    esac
    if [[ $subject =~ ^[A-Za-z]+(\([^\)]*\))?!: ]] || grep -q '^BREAKING[ -]CHANGE' <<< "$body"; then
        raise major "breaking change in $short ($subject)"
    elif [[ $subject =~ ^feat(\([^\)]*\))?: ]]; then
        raise minor "feature in $short ($subject)"
    else
        raise patch "fixes and changes, e.g. $short ($subject)"
    fi
done < <(git log --no-merges --format=%H "$previous..HEAD" -- "${PATHS[@]}")

new_mods=$(git diff --name-only --diff-filter=A "$previous" HEAD -- cppmods assets/Mods/shared \
    | awk -F/ '$1 == "cppmods" { print $1 "/" $2 } $1 == "assets" { print $1 "/" $2 "/" $3 "/" $4 }' | sort -u)
for m in $new_mods; do
    git cat-file -e "$previous:$m" 2>/dev/null || raise minor "new mod $m"
done

# Commits outside PATHS can still move what users install through the UEPseudo pin of a merge.
if [ "$level" = none ] && [ -n "$(git diff --name-only "$previous" HEAD -- "${PATHS[@]}")" ]; then
    raise patch "files users install changed"
fi

if [ "$bump_override" != auto ]; then
    level=$bump_override; reason="chosen by hand (workflow_dispatch)"
elif [ "$level" = none ]; then
    if [ "$force" != true ]; then
        echo "release=false"; echo "next="; echo "bump=none"; echo "reason=nothing users install changed since $previous"
        exit 0
    fi
    level=patch; reason="forced release without changes users install"
fi

case $level in
    major) major=$((major + 1)); minor=0; patch=0 ;;
    minor) minor=$((minor + 1)); patch=0 ;;
    patch) patch=$((patch + 1)) ;;
    *) echo "unknown bump '$level'" >&2; exit 1 ;;
esac
echo "release=true"
echo "next=linux-v$major.$minor.$patch"
echo "bump=$level"
echo "reason=${reason//$'\n'/ }"
