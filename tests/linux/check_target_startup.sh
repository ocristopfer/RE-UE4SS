#!/usr/bin/env bash
# A simulated game startup: libUE4SS.so preloaded into a process named like an Unreal server
# (<Name>-Linux-Shipping, here a copy of sleep). There is no engine to find, so the scans fail, but
# UE4SS must start in it (UE4SS.log next to the library, patternsleuth reading the ELF image) and the
# "game" must run to its normal end with its own exit code: a UE4SS that cannot find what it needs
# must never take the server down.
set -euo pipefail
lib=$1
settings=$2
seconds=${3:-10}

dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
game="$dir/Fake/Binaries/Linux"
mkdir -p "$game/ue4ss/Mods"
cp "$(command -v sleep)" "$game/FakeServer-Linux-Shipping"
cp "$lib" "$game/ue4ss/libUE4SS.so"
cp "$settings" "$game/ue4ss/UE4SS-settings.ini"

code=0
(cd "$game" && LD_PRELOAD="$game/ue4ss/libUE4SS.so" ./FakeServer-Linux-Shipping "$seconds") > "$dir/out.log" 2>&1 || code=$?
log="$game/ue4ss/UE4SS.log"

fail() {
    echo "$1"
    echo "--- process output"; tail -20 "$dir/out.log"
    echo "--- UE4SS.log"; tail -20 "$log" 2>/dev/null || true
    exit 1
}
[ "$code" = 0 ] || fail "the fake server ended with exit $code instead of 0"
[ -s "$log" ] || fail "UE4SS did not start in a process named *-Linux-Shipping (no UE4SS.log)"
grep -q "Reading image" "$log" || fail "UE4SS started but patternsleuth never read the image"
if grep -qE "Segmentation|signal 11|Caught|terminate called" "$dir/out.log" "$log"; then
    fail "UE4SS reported a crash in the fake server"
fi
echo "target startup: UE4SS started, scanned the image and left the process to end normally (exit 0 after ${seconds}s)"
