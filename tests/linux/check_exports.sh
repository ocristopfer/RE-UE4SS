#!/usr/bin/env bash
# libUE4SS.so exports only UE4SS's API (RC::) and Lua's C API (UE4SS/linux_exports.map). A preloaded
# library comes first in every lookup of the process: anything else exported here (a standard
# template instantiation) is used by the game's own plugins too - Mordhau's mod.io SDK aborted.
set -euo pipefail
lib=$1

leaked=$(nm -D --defined-only "$lib" | awk '{print $3}' | grep -v '^$' | while read -r sym; do
    case $sym in
        lua_*|luaL_*|luaopen_*) continue ;;
    esac
    demangled=$(c++filt "$sym")
    case $demangled in
        *RC::*) continue ;;
    esac
    echo "$demangled"
done)

if [ -n "$leaked" ]; then
    echo "libUE4SS.so exports symbols outside RC:: and Lua:"
    echo "$leaked" | head -50
    exit 1
fi
echo "exports: only RC:: and Lua ($(nm -D --defined-only "$lib" | wc -l) symbols)"
