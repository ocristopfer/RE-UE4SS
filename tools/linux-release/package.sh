#!/usr/bin/env bash
# Assembles the files of a Linux release, the set the game panel installs (ue4ss_linux_remote.py):
#
#   tools/linux-release/package.sh <libUE4SS.so> <LinuxReferencePacks.tar.gz> <out-dir>
#
# libUE4SS.so, UE4SS-settings.ini (the default one with the console off: a server has no window),
# ue4ss-mods-shared.tar.gz (assets/Mods/shared), VTableLayoutTemplates.tar.gz, the reference packs
# and SHA256SUMS. Tarballs are reproducible: sorted names, fixed owner and time.
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
lib=$1
packs=$2
out=$3
mkdir -p "$out"

tarball() { # <archive> <dir> <member>
    tar --sort=name --owner=0 --group=0 --numeric-owner --mtime='2000-01-01 00:00Z' \
        --mode='u=rwX,go=rX' -C "$2" -cf - "$3" | gzip -n -9 > "$1"
}

install -m 0755 "$lib" "$out/libUE4SS.so"
sed -E 's/^(ConsoleEnabled|GuiConsoleEnabled|GuiConsoleVisible) = 1/\1 = 0/' "$repo/assets/UE4SS-settings.ini" > "$out/UE4SS-settings.ini"
grep -q '^ConsoleEnabled = 0' "$out/UE4SS-settings.ini"
tarball "$out/ue4ss-mods-shared.tar.gz" "$repo/assets/Mods" shared
tarball "$out/VTableLayoutTemplates.tar.gz" "$repo/assets" VTableLayoutTemplates
cp "$packs" "$out/LinuxReferencePacks.tar.gz"
tar -tzf "$out/LinuxReferencePacks.tar.gz" | grep '^LinuxReferencePacks/pack-' > /dev/null

(cd "$out" && sha256sum --binary libUE4SS.so UE4SS-settings.ini ue4ss-mods-shared.tar.gz \
    VTableLayoutTemplates.tar.gz LinuxReferencePacks.tar.gz > SHA256SUMS)
cat "$out/SHA256SUMS"
