#!/usr/bin/env bash
# libUE4SS.so goes into a game's environment with LD_PRELOAD, so every process the startup script
# runs gets it too. It must load (every symbol resolved: LD_BIND_NOW) and stay inert in a process
# that is not the game: no output, no log file, the same exit code.
set -euo pipefail
lib=$1

dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
cp "$lib" "$dir/libUE4SS.so"

out=$(LD_BIND_NOW=1 LD_PRELOAD="$dir/libUE4SS.so" /bin/sh -c 'echo ok; exit 3' 2>&1) && code=0 || code=$?
if [ "$code" != 3 ] || [ "$out" != ok ]; then
    echo "a shell with libUE4SS.so preloaded changed: exit $code, output:"
    echo "$out"
    exit 1
fi

LD_BIND_NOW=1 LD_PRELOAD="$dir/libUE4SS.so" /bin/true
if [ "$(ls -A "$dir")" != libUE4SS.so ]; then
    echo "libUE4SS.so wrote files outside a game process:"
    ls -A "$dir"
    exit 1
fi
echo "preload: loads with every symbol bound and stays inert outside the game"
