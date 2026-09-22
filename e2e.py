#!/usr/bin/env python3
"""End-to-end check with real input. Needs Lease.app running with Accessibility granted.
Opens TextEdit on a temp file, drags that window to free screen space, gives your app the
front back, leases a click + typing + cmd+s into TextEdit, verifies the file, verifies your
frontmost app and cursor came back, checks the pid guard refuses a covered point, then
leases cmd+w to close the window it opened."""
import json, os, socket, subprocess, tempfile, time

SOCK = "/tmp/lease.sock"
TITLE = 28  # title bar height; the drag grabs the window there


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
    for _ in range(10):
        r = L.tool("act", wait_ms=60000, steps=steps)
        print("act:", r)
        if r["status"] == "ok":
            return r
        assert r["status"] in ("aborted", "busy"), r
        time.sleep(1.5)
    raise SystemExit("human never paused long enough")


def intersects(a, b):
    return a[0] < b[0] + b[2] and b[0] < a[0] + a[2] and a[1] < b[1] + b[3] and b[1] < a[1] + a[3]


def free_spot(L, size, win_id, cover_pid):
    """Top-left corner of a rect of `size` on some display that nothing above our window will cover:
    windows currently in front of it, plus every window of the app we are about to bring back in front."""
    wins = L.tool("windows")  # front to back
    above = wins[:next((i for i, w in enumerate(wins) if w["id"] == win_id), 0)]
    others = [(w["x"], w["y"], w["w"], w["h"]) for w in wins if w["pid"] == cover_pid or w in above]
    W, H = size
    for d in L.tool("status")["displays"]:
        for y in range(int(d["y"]) + 30, int(d["y"] + d["h"] - H), 40):
            for x in range(int(d["x"]), int(d["x"] + d["w"] - W), 40):
                if not any(intersects((x, y, W, H), o) for o in others):
                    return x, y
    return None


def top_at(L, x, y):
    return next((w for w in L.tool("windows") if w["x"] <= x <= w["x"] + w["w"] and w["y"] <= y <= w["y"] + w["h"]), None)


def main():
    L = Lease()
    st = L.tool("status")
    assert st["trusted"], "grant Accessibility to Lease first"
    prev = st["frontmost"]
    path = os.path.join(tempfile.mkdtemp(), "lease-e2e.txt")
    open(path, "w").close()
    was_running = subprocess.run(["pgrep", "-x", "TextEdit"], capture_output=True).returncode == 0
    old_ids = {w["id"] for w in L.tool("windows") if w["app"] == "TextEdit"}  # never touch a pre-existing document
    subprocess.run(["open", "-a", "TextEdit", path], check=True)
    win = None
    for _ in range(50):
        wins = [w for w in L.tool("windows") if w["app"] == "TextEdit" and w["w"] > 200 and w["id"] not in old_ids]
        if wins:
            win = wins[0]
            break
        time.sleep(0.2)
    assert win, "TextEdit window not found"
    pid = win["pid"]

    # Your app goes back in front before the real test, so park the TextEdit window where nothing covers it.
    spot = free_spot(L, (win["w"], win["h"]), win["id"], prev["pid"] if prev else -1)
    assert spot, "no free screen space for the TextEdit window; close or move something and rerun"
    act(L, [{"type": "drag", "x": win["x"] + win["w"] / 2, "y": win["y"] + TITLE / 2,
             "x2": spot[0] + win["w"] / 2, "y2": spot[1] + TITLE / 2, "pid": pid}])
    time.sleep(0.5)
    win = next(w for w in L.tool("windows") if w["id"] == win["id"])
    if prev and prev.get("bundle"):
        subprocess.run(["open", "-b", prev["bundle"]])
        time.sleep(0.8)
    cx, cy = win["x"] + win["w"] / 2, win["y"] + win["h"] / 2
    top = top_at(L, cx, cy)
    assert top and top["pid"] == pid, ("TextEdit window is covered by", top)
    before = L.tool("status")

    t0 = time.time()
    act(L, [{"type": "click", "x": cx, "y": cy, "pid": pid}, {"type": "wait", "ms": 200},
            {"type": "type", "text": "hello from lease", "pid": pid}, {"type": "wait", "ms": 100},
            {"type": "key", "combo": "cmd+s", "pid": pid}])
    time.sleep(0.6)
    text = open(path).read().strip()
    assert text == "hello from lease", repr(text)
    after = L.tool("status")
    assert after["frontmost"]["pid"] == before["frontmost"]["pid"], (before["frontmost"], after["frontmost"])
    print("typed into TextEdit, file saved, focus back to", after["frontmost"]["name"])
    if after["human_idle_s"] > time.time() - t0:  # you did not touch anything since, so the cursor must be back too
        dx, dy = after["cursor"]["x"] - before["cursor"]["x"], after["cursor"]["y"] - before["cursor"]["y"]
        assert abs(dx) < 2 and abs(dy) < 2, (before["cursor"], after["cursor"])
        print("cursor back at", after["cursor"])
    else:
        print("you moved the mouse after the lease, cursor check skipped")

    # pid guard: the center of your window, claimed as TextEdit, must be refused without a click
    yours = next((w for w in L.tool("windows") if w["pid"] == before["frontmost"]["pid"]), None)
    if yours and yours["pid"] != pid:
        r = L.tool("act", wait_ms=60000, steps=[{"type": "click", "x": yours["x"] + yours["w"] / 2, "y": yours["y"] + yours["h"] / 2, "pid": pid}])
        assert r["status"] == "error" and "covered" in r["reason"], r
        print("pid guard refused a covered point:", r["reason"])

    act(L, [{"type": "click", "x": cx, "y": cy, "pid": pid}, {"type": "wait", "ms": 150}, {"type": "key", "combo": "cmd+w", "pid": pid}])
    if not was_running:
        subprocess.run(["pkill", "-x", "TextEdit"])
    print("e2e ok")


if __name__ == "__main__":
    main()
