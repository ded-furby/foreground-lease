#!/usr/bin/env python3
"""End-to-end check with real input. Needs Lease.app running with Accessibility granted.
Opens TextEdit on a temp file, leases a click + typing + cmd+s into it, verifies the file,
verifies your frontmost app and cursor came back, then leases cmd+w to close that window."""
import json, os, socket, subprocess, sys, tempfile, time

SOCK = "/tmp/lease.sock"


class Lease:
    def __init__(self):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.connect(SOCK)
        self.f, self.n = s.makefile("rw"), 0
        self.rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "e2e", "version": "0"}})
        self.send({"jsonrpc": "2.0", "method": "notifications/initialized"})

    def send(self, msg):
        self.f.write(json.dumps(msg) + "\n")
        self.f.flush()

    def rpc(self, method, params):
        self.n += 1
        self.send({"jsonrpc": "2.0", "id": self.n, "method": method, "params": params})
        return json.loads(self.f.readline())["result"]

    def tool(self, name, **args):
        return json.loads(self.rpc("tools/call", {"name": name, "arguments": args})["content"][0]["text"])


def act(L, steps):
    """Run one lease; a human who is actively using the machine just makes us wait and retry."""
    for attempt in range(10):
        r = L.tool("act", wait_ms=60000, steps=steps)
        print("act:", r)
        if r["status"] == "ok":
            return r
        assert r["status"] in ("aborted", "busy"), r
        time.sleep(1.5)
    raise SystemExit("human never paused long enough")


def main():
    L = Lease()
    st = L.tool("status")
    assert st["trusted"], "grant Accessibility to Lease first"
    prev = st["frontmost"]
    path = os.path.join(tempfile.mkdtemp(), "lease-e2e.txt")
    open(path, "w").close()
    was_running = subprocess.run(["pgrep", "-x", "TextEdit"], capture_output=True).returncode == 0
    old_ids = {w["id"] for w in L.tool("windows") if w["app"] == "TextEdit"}  # never type into a pre-existing document
    subprocess.run(["open", "-a", "TextEdit", path], check=True)
    win = None
    for _ in range(50):
        wins = [w for w in L.tool("windows") if w["app"] == "TextEdit" and w["w"] > 200 and w["id"] not in old_ids]
        if wins:
            win = wins[0]
            break
        time.sleep(0.2)
    assert win, "TextEdit window not found"
    if prev and prev.get("bundle"):  # opening TextEdit raised it; give the human's app back first
        subprocess.run(["open", "-b", prev["bundle"]])
    time.sleep(0.8)
    before = L.tool("status")
    cx, cy = win["x"] + win["w"] / 2, win["y"] + win["h"] / 2

    r = act(L, [
        {"type": "click", "x": cx, "y": cy}, {"type": "wait", "ms": 200},
        {"type": "type", "text": "hello from lease"}, {"type": "wait", "ms": 100},
        {"type": "key", "combo": "cmd+s"}])
    time.sleep(0.6)
    text = open(path).read().strip()
    assert text == "hello from lease", repr(text)
    after = L.tool("status")
    assert after["frontmost"]["pid"] == before["frontmost"]["pid"], (before["frontmost"], after["frontmost"])
    dx, dy = after["cursor"]["x"] - before["cursor"]["x"], after["cursor"]["y"] - before["cursor"]["y"]
    assert abs(dx) < 2 and abs(dy) < 2, (before["cursor"], after["cursor"])
    print("typed into TextEdit, file saved, focus back to", after["frontmost"]["name"], "cursor back at", after["cursor"])

    act(L, [{"type": "click", "x": cx, "y": cy}, {"type": "wait", "ms": 150}, {"type": "key", "combo": "cmd+w"}])
    if not was_running:
        subprocess.run(["pkill", "-x", "TextEdit"])
    print("e2e ok")


if __name__ == "__main__":
    main()
