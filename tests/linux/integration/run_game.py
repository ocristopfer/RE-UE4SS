"""Runs ONE dedicated server with the candidate release and the CI probe mod, inside the test container.

UE4SS is installed exactly as users get it: by the game panel's own installer
(ue4ss_linux_remote.install_loader, from ocristopfer/game-server-deploy), which checks every file
against SHA256SUMS and generates this game's VTableLayout.ini / UE4SS_Signatures from its .sym or
from the release's reference pack. Only the systemd part is skipped: the environment the drop-in
would get (LD_PRELOAD, UE4SS_TARGET_EXE) is given to the server directly.

The game volume is mounted read-only at /lower; everything is written to an overlay on a tmpfs, so
the volume is never changed.

Usage: run_game.py <name> <game.json> -> writes /ci/out/result.json, exit 0 = passed.
"""
from __future__ import annotations

import importlib.util
import json
import os
import shutil
import signal
import subprocess
import sys
import time

CI = "/ci"
GAME_ROOT = "/opt/game"
TAG = "ci"
REQUIRED = ("lua_started", "find_gamestate", "static_find_object", "register_hook_native",
            "execute_in_game_thread", "notify_on_new_object", "done")
MARK = "[ue4ss-ci] "
CRASH_PATTERNS = ("Segmentation fault", "Signal 11", "signal 11", "CommonUnixCrashHandler", "Fatal error!")


def log(msg: str) -> None:
    print(f"[run_game] {msg}", flush=True)


def mount_overlay() -> None:
    os.makedirs("/ovl/upper", exist_ok=True)
    os.makedirs("/ovl/work", exist_ok=True)
    os.makedirs(GAME_ROOT, exist_ok=True)
    subprocess.run(["mount", "-t", "overlay", "overlay", "-o",
                    f"lowerdir=/lower,upperdir=/ovl/upper,workdir=/ovl/work", GAME_ROOT], check=True)
    os.chown("/ovl/upper", 1000, 1000)


def load_installer():
    spec = importlib.util.spec_from_file_location("ue4ss_linux_remote", f"{CI}/panel/ue4ss_linux_remote.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module._daemon_reload = lambda: None  # no systemd in the test container
    return module


def local_fetcher(module):
    """The panel downloads the release from GitHub; here the candidate files come from /ci/release."""
    release_dir = f"{CI}/release"
    api = module.RELEASE.format(tag=TAG)

    def fetch(url: str) -> bytes:
        if url == api:
            assets = [{"name": n, "browser_download_url": f"https://github.com/ci/{n}"} for n in sorted(os.listdir(release_dir))]
            return json.dumps({"assets": assets}).encode()
        name = url.rsplit("/", 1)[-1]
        with open(os.path.join(release_dir, name), "rb") as f:
            return f.read()

    return fetch


def probe_lines(path: str) -> list[tuple[str, str, str]]:
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            text = f.read()
    except OSError:
        return []
    lines = []
    for raw in text.splitlines():
        at = raw.find(MARK)
        if at < 0:
            continue
        parts = raw[at + len(MARK):].strip().split(" ", 2)
        if len(parts) >= 2:
            lines.append((parts[0], parts[1], parts[2] if len(parts) > 2 else ""))
    return lines


def tail(path: str, n: int = 40) -> str:
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return "".join(f.readlines()[-n:])
    except OSError:
        return ""


def main(name: str, game_path: str) -> int:
    with open(game_path, encoding="utf-8") as f:
        game = json.load(f)
    seconds = int(os.environ.get("GAME_SECONDS", "600"))
    result: dict = {"game": name, "engine": game["engine"], "passed": False, "steps": {}, "info": {}}
    os.makedirs(f"{CI}/out", exist_ok=True)
    started = time.monotonic()
    try:
        mount_overlay()
        exe_dir = os.path.join(GAME_ROOT, game["project"], "Binaries", "Linux")
        # A clean install: leftovers of earlier manual tests in the volume are hidden by the overlay.
        shutil.rmtree(os.path.join(exe_dir, "ue4ss"), ignore_errors=True)

        installer = load_installer()
        release = installer.Release(TAG, game["engine"], open(f"{CI}/panel/ue_sym_layout.py", encoding="utf-8").read(),
                                    open(f"{CI}/panel/ue_linux_layout.py", encoding="utf-8").read())
        log(f"installing with the panel installer into {exe_dir}")
        installer.install_loader(exe_dir, "ue4ss-ci.service", release, fetcher=local_fetcher(installer))
        env_vars = installer.loader_env(exe_dir)
        ue4ss_dir = os.path.join(exe_dir, "ue4ss")
        mark = json.load(open(os.path.join(ue4ss_dir, installer.MARK), encoding="utf-8"))
        result["info"]["generated_files"] = mark.get("sym_files", [])
        result["info"]["env"] = env_vars

        mod_dir = os.path.join(ue4ss_dir, "Mods", "UE4SSCIProbe", "scripts")
        os.makedirs(mod_dir, exist_ok=True)
        shutil.copy(f"{CI}/probe.lua", os.path.join(mod_dir, "main.lua"))
        with open(os.path.join(ue4ss_dir, "Mods", "mods.txt"), "a", encoding="utf-8") as f:
            f.write("\nUE4SSCIProbe : 1\n")
        subprocess.run(["chown", "-R", "steam:steam", ue4ss_dir], check=True)

        # Steam servers load the Steam client from ~/.steam/sdk64 (steamcmd ships it with the game).
        for candidate in (os.path.join(GAME_ROOT, "linux64", "steamclient.so"), os.path.join(GAME_ROOT, "steamclient.so"),
                          os.path.join(exe_dir, "steamclient.so")):
            if os.path.isfile(candidate):
                os.makedirs("/home/steam/.steam/sdk64", exist_ok=True)
                link = "/home/steam/.steam/sdk64/steamclient.so"
                if not os.path.lexists(link):
                    os.symlink(candidate, link)
                subprocess.run(["chown", "-R", "-h", "steam:steam", "/home/steam/.steam"], check=True)
                break

        if game.get("prepare"):
            subprocess.run(["bash", "-c", game["prepare"]], check=True)

        ue4ss_log = os.path.join(ue4ss_dir, "UE4SS.log")
        server_log = f"{CI}/out/server.log"
        command = f"cd {GAME_ROOT} && exec ./{game['start']} {game.get('args', '')}"
        env = {"HOME": "/home/steam", "PATH": "/usr/local/bin:/usr/bin:/bin", **env_vars}
        log(f"starting {game['start']} with {env_vars} for up to {seconds}s")
        with open(server_log, "wb") as out:
            proc = subprocess.Popen(["setpriv", "--reuid=1000", "--regid=1000", "--init-groups", "bash", "-c", command],
                                    env=env, stdout=out, stderr=subprocess.STDOUT, start_new_session=True)
            deadline = time.monotonic() + seconds
            done = False
            while time.monotonic() < deadline and proc.poll() is None:
                if any(step == "done" for step, _, _ in probe_lines(ue4ss_log)):
                    done = True
                    break
                time.sleep(3)
            result["info"]["alive_at_end"] = proc.poll() is None
            result["info"]["exit_code"] = proc.returncode
            if proc.poll() is None:
                os.killpg(proc.pid, signal.SIGTERM)
                try:
                    proc.wait(30)
                except subprocess.TimeoutExpired:
                    os.killpg(proc.pid, signal.SIGKILL)
                    proc.wait()

        for step, status, detail in probe_lines(ue4ss_log):
            if status == "INFO":
                result["info"][step] = detail
            else:
                # The first FAIL of a step wins over a later PASS.
                if result["steps"].get(step, {}).get("status") != "FAIL":
                    result["steps"][step] = {"status": status, "detail": detail}
        server_text = tail(server_log, 400)
        crash = next((p for p in CRASH_PATTERNS if p in server_text), "")
        missing = [s for s in REQUIRED if result["steps"].get(s, {}).get("status") != "PASS"]
        failed = [s for s, v in result["steps"].items() if v["status"] == "FAIL"]
        result["missing"], result["failed"], result["crash"] = missing, failed, crash
        result["passed"] = done and result["info"]["alive_at_end"] and not missing and not failed and not crash
        if not result["passed"]:
            result["ue4ss_log_tail"] = tail(ue4ss_log)
            result["server_log_tail"] = tail(server_log)
    except Exception as e:  # noqa: BLE001 - every error is a failed test with its reason
        result["error"] = f"{type(e).__name__}: {e}"
    result["seconds"] = round(time.monotonic() - started)
    with open(f"{CI}/out/result.json", "w", encoding="utf-8") as f:
        json.dump(result, f, indent=1)
    log(f"{name}: {'PASSED' if result['passed'] else 'FAILED'} in {result['seconds']}s")
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2]))
