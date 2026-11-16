"""
Simple AH for friends: one exe, no setup.

First run (double-click):
  - finds WoW Forever (the SimpleAH addon folder must already be in Interface/AddOns)
  - copies itself to %LOCALAPPDATA%\\SimpleAH and starts with Windows
  - downloads the latest prices
Afterwards it runs quietly in the background. Blizzard publishes a new auction
snapshot about once an hour, so the client sleeps until the next snapshot is due,
then downloads it once. Prices show up in game after /reload or a relog.

Flags: --background (used by autostart), --uninstall
"""

import ctypes
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
import winreg

DATA_URL = "https://raw.githubusercontent.com/mkborik-cloud/forever-prices/data/prices.lua"
STATUS_URL = "https://raw.githubusercontent.com/mkborik-cloud/forever-prices/data/status.json"
APP_NAME = "SimpleAH"
SNAPSHOT_EVERY = 60 * 60  # Blizzard publishes auction data hourly
PUBLISH_LAG = 15 * 60     # time for the cloud job to pick it up and GitHub's cache to refresh
LATE_POLL = 5 * 60        # when a snapshot is overdue, look again this often (status.json is ~2 KB)
RETRY_AFTER = 2 * 60      # network not up yet, GitHub hiccup
USER_AGENT = "SimpleAH-Client/1.0"

LOCAL_DIR = os.path.join(os.environ.get("LOCALAPPDATA", os.path.expanduser("~")), APP_NAME)
INSTALLED_EXE = os.path.join(LOCAL_DIR, "SimpleAH.exe")
LOG_PATH = os.path.join(LOCAL_DIR, "log.txt")
STATE_PATH = os.path.join(LOCAL_DIR, "state.txt")
RUN_KEY = r"Software\Microsoft\Windows\CurrentVersion\Run"

MB_OK, MB_ICONINFO, MB_ICONWARN = 0x0, 0x40, 0x30


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def message(text, icon=MB_ICONINFO):
    ctypes.windll.user32.MessageBoxW(None, text, "Simple AH", MB_OK | icon)


def log(msg):
    os.makedirs(LOCAL_DIR, exist_ok=True)
    try:
        if os.path.exists(LOG_PATH) and os.path.getsize(LOG_PATH) > 200_000:
            os.remove(LOG_PATH)
        with open(LOG_PATH, "a", encoding="utf-8") as f:
            f.write(time.strftime("%Y-%m-%d %H:%M:%S ") + msg + "\n")
    except OSError:
        pass


_kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
_kernel32.CreateMutexW.restype = ctypes.c_void_p
_kernel32.CreateMutexW.argtypes = (ctypes.c_void_p, ctypes.c_int, ctypes.c_wchar_p)


def single_instance():
    """Returns a handle while this is the only background copy, else None."""
    ctypes.set_last_error(0)
    handle = _kernel32.CreateMutexW(None, False, "Local\\SimpleAHClient")
    if ctypes.get_last_error() == 183:  # ERROR_ALREADY_EXISTS
        return None
    return handle


def startup_shortcut_path():
    appdata = os.environ.get("APPDATA", os.path.expanduser("~"))
    return os.path.join(appdata, "Microsoft", "Windows", "Start Menu", "Programs", "Startup", "Simple AH.lnk")


def make_startup_shortcut():
    """A shortcut in the Startup folder; more reliable than the Run key on some PCs."""
    lnk = startup_shortcut_path()
    script = (
        "$s=(New-Object -ComObject WScript.Shell).CreateShortcut($env:SAH_LNK);"
        "$s.TargetPath=$env:SAH_EXE;$s.Arguments='--background';"
        "$s.WorkingDirectory=$env:SAH_DIR;$s.Save()"
    )
    env = dict(os.environ, SAH_LNK=lnk, SAH_EXE=INSTALLED_EXE, SAH_DIR=LOCAL_DIR)
    subprocess.run(["powershell", "-NoProfile", "-NonInteractive", "-Command", script],
                   env=env, capture_output=True, creationflags=0x08000000)  # CREATE_NO_WINDOW
    return os.path.exists(lnk)


# ---------------------------------------------------------------------------
# Finding WoW Forever
# ---------------------------------------------------------------------------

def candidate_roots():
    roots = []
    for hive, key in ((winreg.HKEY_LOCAL_MACHINE, r"SOFTWARE\WOW6432Node\Blizzard Entertainment\World of Warcraft"),
                      (winreg.HKEY_LOCAL_MACHINE, r"SOFTWARE\Blizzard Entertainment\World of Warcraft")):
        try:
            with winreg.OpenKey(hive, key) as k:
                path, _ = winreg.QueryValueEx(k, "InstallPath")
                path = path.rstrip("\\/")
                roots.append(os.path.dirname(path) if os.path.basename(path).startswith("_") else path)
        except OSError:
            pass
    for drive in "CDEFGH":
        for sub in (r"Program Files (x86)\World of Warcraft", r"Program Files\World of Warcraft",
                    r"World of Warcraft", r"Games\World of Warcraft", r"Battle.net\World of Warcraft"):
            roots.append(f"{drive}:\\{sub}")
    return roots


def find_forever():
    saved = read_state().get("wow")
    if saved and os.path.isdir(saved):
        return saved
    for root in candidate_roots():
        path = os.path.join(root, "_forever_")
        if os.path.isdir(path):
            return path
    return None


def ask_for_folder():
    try:
        import tkinter
        from tkinter import filedialog
        tk = tkinter.Tk()
        tk.withdraw()
        path = filedialog.askdirectory(title="Select your World of Warcraft folder (the one that contains _forever_)")
        tk.destroy()
    except Exception:
        return None
    if not path:
        return None
    path = os.path.normpath(path)
    if os.path.basename(path).lower() == "_forever_":
        return path
    if os.path.isdir(os.path.join(path, "_forever_")):
        return os.path.join(path, "_forever_")
    return None


# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

def read_state():
    state = {}
    try:
        with open(STATE_PATH, encoding="utf-8") as f:
            for line in f:
                if "=" in line:
                    k, v = line.rstrip("\n").split("=", 1)
                    state[k] = v
    except OSError:
        pass
    return state


def write_state(**updates):
    state = read_state()
    state.update({k: str(v) for k, v in updates.items()})
    os.makedirs(LOCAL_DIR, exist_ok=True)
    with open(STATE_PATH, "w", encoding="utf-8") as f:
        for k, v in state.items():
            f.write(f"{k}={v}\n")


# ---------------------------------------------------------------------------
# Addon + prices
# ---------------------------------------------------------------------------

def addon_dir(forever):
    return os.path.join(forever, "Interface", "AddOns", "SimpleAH")


def addon_installed(forever):
    return os.path.isfile(os.path.join(addon_dir(forever), "SimpleAH.toc"))


def has_live_prices(forever):
    try:
        with open(os.path.join(addon_dir(forever), "PriceData.lua"), "rb") as f:
            return f.read(64).startswith(b"-- Generated by Simple AH")
    except OSError:
        return False


def download_prices(forever):
    if not addon_installed(forever):
        raise FileNotFoundError("the SimpleAH addon is not in Interface\\AddOns")
    state = read_state()
    req = urllib.request.Request(DATA_URL, headers={"User-Agent": USER_AGENT})
    # a freshly copied addon only has the placeholder, so always download then
    if state.get("etag") and has_live_prices(forever):
        req.add_header("If-None-Match", state["etag"])
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            body = resp.read()
            etag = resp.headers.get("ETag", "")
    except urllib.error.HTTPError as e:
        if e.code == 304:
            return False
        raise
    if not body.startswith(b"-- Generated by Simple AH"):
        raise ValueError("downloaded file is not a price file")
    path = os.path.join(addon_dir(forever), "PriceData.lua")
    tmp = path + ".tmp"
    with open(tmp, "wb") as f:
        f.write(body)
    os.replace(tmp, path)
    write_state(etag=etag, updated=int(time.time()))
    log(f"prices updated ({len(body) // 1024} KB)")
    return True


# ---------------------------------------------------------------------------
# Install / autostart
# ---------------------------------------------------------------------------

def set_autostart(enabled):
    # Both a Run entry and a Startup-folder shortcut: some PCs skip one of them.
    # The single-instance check keeps it to one running copy.
    with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN_KEY, 0, winreg.KEY_SET_VALUE) as k:
        if enabled:
            winreg.SetValueEx(k, APP_NAME, 0, winreg.REG_SZ, f'"{INSTALLED_EXE}" --background')
        else:
            try:
                winreg.DeleteValue(k, APP_NAME)
            except OSError:
                pass
    if enabled:
        if not make_startup_shortcut():
            log("could not create the Startup shortcut")
    else:
        try:
            os.remove(startup_shortcut_path())
        except OSError:
            pass


def copy_self():
    if not getattr(sys, "frozen", False):
        return False
    me = os.path.abspath(sys.executable)
    if os.path.normcase(me) == os.path.normcase(INSTALLED_EXE):
        return False
    os.makedirs(LOCAL_DIR, exist_ok=True)
    try:
        shutil.copy2(me, INSTALLED_EXE)
    except PermissionError:
        # an older copy is running; stop it and retry
        subprocess.run(["taskkill", "/f", "/im", "SimpleAH.exe", "/fi", f"PID ne {os.getpid()}"],
                       capture_output=True)
        time.sleep(1)
        shutil.copy2(me, INSTALLED_EXE)
    return True


def start_background():
    if getattr(sys, "frozen", False) and os.path.exists(INSTALLED_EXE):
        subprocess.Popen([INSTALLED_EXE, "--background"], close_fds=True,
                         creationflags=0x00000008 | 0x00000200)  # DETACHED_PROCESS | NEW_PROCESS_GROUP


def uninstall():
    set_autostart(False)
    subprocess.run(["taskkill", "/f", "/im", "SimpleAH.exe", "/fi", f"PID ne {os.getpid()}"],
                   capture_output=True)
    forever = read_state().get("wow")
    message("Simple AH was removed from startup and stopped.\n\n"
            "To remove the addon too, delete this folder:\n"
            + (addon_dir(forever) if forever else "Interface\\AddOns\\SimpleAH"))


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def background():
    if not single_instance():
        log("background updater already running")
        return
    forever = find_forever()
    if not forever:
        log("WoW Forever not found")
        return
    log("background updater started")
    while True:
        try:
            wait = check_for_snapshot(forever)
        except Exception as e:  # network not up yet after boot, GitHub hiccup, ...
            log(f"update failed: {e}")
            wait = RETRY_AFTER
        # sleep by the wall clock in short steps, so waking the PC from sleep doesn't add delay
        deadline = time.time() + wait
        while time.time() < deadline:
            time.sleep(min(60, max(1, deadline - time.time())))


def latest_snapshot():
    """Newest Blizzard snapshot time (unix seconds) the cloud has published."""
    req = urllib.request.Request(STATUS_URL, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=30) as resp:
        status = json.loads(resp.read())
    return max(int(m.get("scanned", 0)) for m in status.get("markets", [])) or int(status.get("updated", 0))


def next_wait(snapshot, now=None):
    """Seconds to sleep: until the next snapshot should be online, or a short poll if it is late."""
    now = time.time() if now is None else now
    due = snapshot + SNAPSHOT_EVERY + PUBLISH_LAG
    return int(min(max(due - now, LATE_POLL), SNAPSHOT_EVERY + PUBLISH_LAG))


def check_for_snapshot(forever):
    """Downloads prices only when the cloud has a newer snapshot. Returns seconds to wait."""
    snapshot = latest_snapshot()
    have = int(read_state().get("snapshot", "0") or 0)
    if snapshot > have or not has_live_prices(forever):
        download_prices(forever)
        write_state(snapshot=snapshot)
        log(f"new snapshot from {time.strftime('%H:%M', time.localtime(snapshot))}")
    wait = next_wait(snapshot)
    log(f"next check in {wait // 60} min")
    return wait


def remove_old_version(forever):
    """Cleans up the earlier "ForeverPrices" build of this tool, if present."""
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN_KEY, 0, winreg.KEY_SET_VALUE) as k:
            winreg.DeleteValue(k, "ForeverPrices")
    except OSError:
        pass
    subprocess.run(["taskkill", "/f", "/im", "ForeverPrices.exe"], capture_output=True)
    old_local = os.path.join(os.path.dirname(LOCAL_DIR), "ForeverPrices")
    if os.path.isfile(os.path.join(old_local, "ForeverPrices.exe")):
        shutil.rmtree(old_local, ignore_errors=True)
    old_addon = os.path.join(forever, "Interface", "AddOns", "ForeverPrices")
    if os.path.isfile(os.path.join(old_addon, "ForeverPrices.toc")):
        shutil.rmtree(old_addon, ignore_errors=True)
        log("removed the old ForeverPrices addon")


def first_run():
    forever = find_forever() or ask_for_folder()
    if not forever:
        message("World of Warcraft Forever was not found.\n\n"
                "Run this again and pick the World of Warcraft folder that contains _forever_.", MB_ICONWARN)
        return
    write_state(wow=forever)
    remove_old_version(forever)
    if not addon_installed(forever):
        message("Copy the SimpleAH addon folder first.\n\n"
                "Put the SimpleAH folder from the zip into:\n"
                f"{os.path.join(forever, 'Interface', 'AddOns')}\n\n"
                "Then run SimpleAH.exe again.", MB_ICONWARN)
        return
    try:
        write_state(snapshot=0)  # always fetch on a fresh install
        check_for_snapshot(forever)
        got = "Prices are downloaded."
    except Exception as e:
        log(f"first download failed: {e}")
        got = "Prices could not be downloaded right now; it will retry in the background."
    copy_self()
    set_autostart(True)
    start_background()
    message("The Simple AH updater is running.\n\n"
            f"{got}\n"
            "It starts with Windows and downloads each new hourly auction snapshot.\n\n"
            "In game: type /reload, then /ah to search. Shift-click any item while the window is open.")


def main():
    args = sys.argv[1:]
    if "--uninstall" in args:
        uninstall()
    elif "--background" in args:
        background()
    else:
        first_run()


if __name__ == "__main__":
    try:
        main()
    except Exception:
        import traceback
        log("crash: " + traceback.format_exc().replace("\n", " | "))
        raise
