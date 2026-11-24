"""Exercise the installed app's Finder entry point twice using an isolated Codex profile."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

app = Path(sys.argv[1]).resolve()
binary = app / "Contents/MacOS/rainbow"
base = Path(sys.argv[2]).resolve()
root = Path(tempfile.mkdtemp(dir=base, prefix="launcher-test-"))
state, index = root / "rainbow", root / "codex" / "session_index.jsonl"
index.parent.mkdir()
profile = root / "profile"
profile.mkdir()
env = {key: os.environ[key] for key in ("HOME", "USER", "LOGNAME", "TMPDIR", "LANG") if key in os.environ}
env.update(PATH="/usr/bin:/bin:/usr/sbin:/sbin", CODEX_HOME=str(index.parent),
           CODEX_ELECTRON_USER_DATA_PATH=str(profile), CODEX_RAINBOW_STATE_DIR=str(state))
receipt = state / "launcher-status.json"
first = "018f0000-0000-7000-8000-000000000001"
second = "018f0000-0001-7000-8000-000000000002"
original_pid = None

def record():
    return json.loads(receipt.read_text()) if receipt.exists() else {}

def wait_for(predicate, timeout=40):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(.15)
    raise AssertionError("Timed out waiting for the installed launcher: " + str(record()))

def append(chat_id):
    with index.open("a") as handle:
        handle.write(json.dumps({"id": chat_id, "thread_name": "Sample chat"}) + "\n")

def process_field(pid, field):
    result = subprocess.run(["/bin/ps", "-p", str(pid), "-o", field + "="], capture_output=True, text=True)
    return result.stdout.strip()

def owned_child(pid):
    if not pid:
        return False
    controller = process_field(pid, "ppid")
    if not controller:
        return False
    launcher = process_field(controller, "ppid")
    return launcher and process_field(launcher, "comm") == str(binary)

for attempt in (1, 2):
    args = ["/usr/bin/open", "-n", "-g", "-j", "-W"]
    for key in ("CODEX_HOME", "CODEX_ELECTRON_USER_DATA_PATH", "CODEX_RAINBOW_STATE_DIR"):
        args.extend(["--env", key + "=" + env[key]])
    process = subprocess.Popen([*args, "-a", app], env=env, stdout=subprocess.DEVNULL)
    try:
        def current():
            if process.poll() is not None:
                raise AssertionError("Launcher exited early: " + str(record()))
            item = record()
            pid = item.get("pid")
            return item if pid and pid != original_pid and owned_child(pid) else None

        started = wait_for(current)
        if attempt == 1:
            assert started["status"] == "waiting-for-palette"
            append(first)
        wait_for(lambda: record().get("status") == "applied" and record().get("windows", 0) > 0)
        if attempt == 1:
            subprocess.run([binary, "set", "turquoise", first], env=env, check=True, stdout=subprocess.DEVNULL)
            append(second)
            wait_for(lambda: second.upper() in json.loads((state / "colors.json").read_text())["rainbow"])
        colors = json.loads((state / "colors.json").read_text())
        assert colors["overrides"][first.upper()] == "turquoise"
        assert colors["rainbow"][second.upper()] == "orange"
        if attempt == 1:
            saved = (state / "colors.json").read_bytes()
        else:
            assert saved == (state / "colors.json").read_bytes()
        print(f"Launch {attempt}: installed bundle opened stock Codex, applied a stylesheet, and retained assignments.", flush=True)
    finally:
        # Only terminate the Codex child belonging to this test's own launcher and profile.
        child = record().get("pid")
        if owned_child(child):
            original_pid = child
            os.kill(child, signal.SIGTERM)
        process.wait(timeout=15)
    assert record()["status"] == "closed"
print("Cold start and reopen passed. Both isolated Codex processes exited.")
