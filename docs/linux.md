# UE4SS on Linux (this fork)

This fork (`linux` branch) builds and runs the official UE4SS inside **native Linux Unreal Engine
games** (dedicated servers built for Linux), loaded with `LD_PRELOAD`. It keeps the official code
and mechanisms - patternsleuth AOB scans, `UE4SS_Signatures`, `VTableLayout.ini`, Lua mods - and
changes only what Linux needs. Windows games running under Proton/Wine use the official Windows
build, not this one.

## Supported and tested games

Tested on the real dedicated server of each game, in Docker, with a probe Lua mod that runs
`FindFirstOf` (it must find the map's GameState), `StaticFindObject`, `RegisterHook` on Blueprint and
native functions, `ExecuteInGameThread` and `NotifyOnNewObject`, with every default hook enabled.

| Game | Engine | Per-game files | Result |
|---|---|---|---|
| RuneScape: Dragonwilds | 5.6.1, modified | from the server's `.sym` | works |
| Palworld | 5.1.1 | none (built-in layout) | works (10 min, hooks from worker threads) |
| Pavlov VR | 5.1 | none (built-in layout) | works |
| Soulmask | 4.27 | reference pack (62 extra virtuals in AGameModeBase) | works |
| The Front | 4.27 | reference pack (FUObjectArray +0x18, `UE4SS_TARGET_EXE`) | works; crashed once at startup in four runs (not explained) |
| Smalland: Survive the Wilds | 4.27 | reference pack | works |
| Insurgency: Sandstorm | 4.27 | reference pack | works |
| Astro Colony | 4.27 | reference pack (`UE4SS_TARGET_EXE`) | works |
| Squad 44 | 4.27 | from its `.sym` (it is the 4.27 reference) | works |
| MORDHAU | 4.26 | from its `.sym` (the 4.26 reference) | works |
| HYPERCHARGE: Unboxed | 4.26 | reference pack | works |
| The Bus | 5.6 | reference pack (`UE4SS_TARGET_EXE`) | works |
| VEIN | 5.6 | from its `.sym` (the 5.6 reference) | works |
| Squad | 5.7 | reference pack (`UE4SS_TARGET_EXE`) | works |
| QANGA | 5.7 | from its `.sym` (the 5.7 reference) | works |

Not working yet: Citadel: Forged with Fire (4.21: the probe runs, then the server crashes).
No reference game with symbols for 4.18, 4.22, 4.25, 5.2 and 5.4, so StickyBots, Tower Unite,
Operation: Harsh Doorstop, Modiverse, Day of Dragons and Nightingale are not supported.
Not tested: Linux game **clients** (the GUI and hotkeys are not built on Linux), C++ mods.

### Why a game needs its own files

Every studio changes engine classes. Measured on the 4.27 servers above: Soulmask adds 62 virtuals
to `AGameModeBase`, The Front adds 0x18 bytes to `FUObjectArray` before the listener arrays, and
Squad 44 adds one virtual to `AActor`. A layout per engine version is not enough - with it, more
than half of these servers crashed. What carries over between two games of one version is the code
of each engine function (same compiler, same source), and the target's own vtables, which Unreal
servers export in `.dynsym` (`_ZTV*`).

`tools/linux-layouts/ue_reference_pack.py` turns one game that ships symbols (`.sym` and `.debug`)
into a **reference pack** for its engine version: the complete vtable layout from the DWARF, a
fingerprint of each slot, masked code for each signature, and how often the code touches each
`FUObjectArray` member. From a pack and a target executable, the game panel's generator
(`ue_linux_layout.py`, plain stdlib) writes that game's `VTableLayout.ini` (slots aligned by
code), `UE4SS_Signatures/` (the shortest prefix of the reference's code unique in the target, never
shorter than unique in the reference), `GMalloc.lua`/`ConsoleManager.lua` checked at run time
against the allocator's / `FConsoleManager`'s exported vtable, and `MemberVariableLayout.ini` when
the `FUObjectArray` access histogram is shifted. The release ships the packs in
`LinuxReferencePacks.tar.gz`.

## Installing

From a release of this fork (`linux-*` tags): `libUE4SS.so`, `UE4SS-settings.ini` and
`ue4ss-mods-shared.tar.gz` (the Lua libraries of `Mods/shared`), with `SHA256SUMS`.

```
<Game>/Binaries/Linux/<Game>-Linux-Shipping      the game
<Game>/Binaries/Linux/ue4ss/libUE4SS.so
<Game>/Binaries/Linux/ue4ss/UE4SS-settings.ini
<Game>/Binaries/Linux/ue4ss/Mods/shared/...      from ue4ss-mods-shared.tar.gz
<Game>/Binaries/Linux/ue4ss/Mods/mods.txt
```

Start the game with `LD_PRELOAD=<...>/ue4ss/libUE4SS.so` (for a systemd service, an
`Environment=LD_PRELOAD=...` drop-in). The library starts only in a process whose executable name
contains `-Linux-` (or is `UE4SS_TARGET_EXE`), so the launcher script and the tools it runs are
left alone. `UE4SS.log` is written next to the library.

For a game with a modified engine (Dragonwilds), generate its files from the `.sym` the server
ships and put them in the same `ue4ss/` folder:

```bash
python3 tools/linux-layouts/ue_vtable_layout.py <executable> assets/VTableLayoutTemplates/VTableLayout_5_06_Template.ini > ue4ss/VTableLayout.ini
```

## What changed for Linux, and why

- **Build**: Linux platform type and Clang; GUI and input optional; Windows-only libraries behind
  `WIN32`; POSIX ports of the file, mutex and scanner layers; `LD_PRELOAD` constructor entry.
- **Running inside the game**: libstdc++ and the unwinder are linked in and bound locally (the game
  exports its own libc++abi/libunwind, and every `throw` inside UE4SS died in them).
- **patternsleuth** reads the ELF image (`image-elf`).
- **Itanium ABI**: the FName constructor takes `this` first; `ProcessLocalScriptFunction` is the
  tail jump of `ProcessInternal` under Clang; `ULocalPlayer::Exec` comes from the primary vtable.
- **Layouts**: vtable and member offsets of each engine version generated from Epic's source with
  clang (`tools/linux-layouts`, see its README): Itanium orders vtables differently and reuses tail
  padding, and platform types change size (`FRWLock`).
- **Lua**: `RegisterHook` callbacks take the Lua state lock (a hooked function can run on a worker
  thread; not Linux-specific).
- **`VTableLayout.ini` reader**: it asked `Version::IsBelow(4, 25)` before the engine version is known
  (still -1), so every `FProperty` offset was stacked on the UObject chain; an `[FField]` section now
  says the inheritance (FField only exists from 4.25 on). Not Linux-specific.
- **patternsleuth image on Linux** (`patternsleuth_bind/src/linux_image.rs`): the ELF was parsed from
  memory, where the section header table falls in `.bss` - garbage once the game wrote there, past
  the image, or in the holes between 2 MiB-aligned segments. The headers now come from
  `/proc/self/exe`, and only mapped segments are read.
- **Exports** (`UE4SS/linux_exports.map`): a preloaded library comes first in every lookup of the
  process, so its standard template instantiations were used by the game's own plugins (Mordhau's
  mod.io SDK aborted, Sandstorm's allocator saw foreign blocks). Only `RC::` and Lua are exported.
- **Layouts from DWARF** (`tools/linux-layouts/ue_layout_from_dwarf.py`): the same bodies as the
  source tools, read from a server's `.debug` - no Unreal source or UnrealBuildTool needed.

## Upstream sync, tests and releases

The fork follows upstream on its own; what runs where:

- **Sync** (`.github/workflows/linux-sync.yml`, daily, GitHub): `main` of this fork and of
  `ocristopfer/UEPseudo` fast-forward to `UE4SS-RE/RE-UE4SS` and `Re-UE4SS/UEPseudo`; upstream
  `main` is merged into `linux` on the branch `sync/upstream` (`tools/linux-release/sync_upstream.sh`)
  and a pull request is opened. When upstream moved the UEPseudo pin, the pin becomes our UEPseudo
  merge, which must contain upstream's. A conflict opens an issue (label `upstream-sync`) instead.
- **CI** (`.github/workflows/linux-ci.yml`, every pull request into `linux`, GitHub): the Clang
  build and the tests of `tests/linux`, none of which needs a game: the Itanium vtable shift and the
  ProcessLocalScriptFunction tail jump, the scanner over a real ELF image, the exported symbols, the
  library staying inert outside a game, and a **simulated server startup** (the library preloaded
  into a process named `*-Linux-Shipping`: it must start, scan the image, find no engine and leave
  the process to end normally).
- **Release** (`.github/workflows/linux-release.yml`, every push to `linux`, GitHub): when anything
  users install changed since the last `linux-v*` tag, the CI build and tests run and those exact
  files become `linux-vN`. The game panel pins a tag per game profile, so a new release reaches a
  server only when its profile is moved.
- **Real servers** (`tests/linux/integration`, by hand, on the machine of whoever wants them - usually
  before moving a game profile): each server of `games.json` starts in Docker from a volume where it
  is installed (read-only, under an overlay), UE4SS installed by the game panel's own installer
  (`ue4ss_linux_remote.py`, pinned in `panel.ref`), and a probe mod must find the GameState, hook
  native and Blueprint functions, run code on the game thread and leave the server alive. Only
  Docker is needed; nothing stays running afterwards:

```bash
tests/linux/integration/local.sh <libUE4SS.so> gate results/     # or: all, or palworld,squad
```

Secret: `FORK_SYNC_TOKEN`, a classic token with the `repo` and `workflow` scopes from an account that
can read `Re-UE4SS/UEPseudo` (private, like our fork of it).
