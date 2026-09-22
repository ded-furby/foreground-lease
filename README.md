# Lease

Let a computer-use agent borrow your real mouse and keyboard, but only while you're not using them.

macOS has one cursor and one focused window. An agent that posts global input takes both, so you and the agent fight: the pointer jumps and your typing lands in the wrong window. Background injection (cua-driver, Codex, Hermes) covers most of an agent's work, but menus, popovers, drag-and-drop, right-click in Chromium and canvas apps still need the real cursor. Lease is for those last cases.

## How it works

An agent sends a short batch of steps. Lease:

1. waits until your hardware input has been idle for `idle_ms` (default 700 ms),
2. saves your cursor position and focused window,
3. runs the steps with real events, so anything that needs a real pointer works,
4. aborts the instant you touch the mouse or keyboard,
5. puts the cursor and focus back.

Several agents are serialized through one lock. Quit Lease from the menu bar to revoke everything.

## Install

1. Download `Lease.dmg` from [Releases](https://github.com/ded-furby/foreground-lease/releases), drag Lease to Applications, open it.
2. It is not notarized. If macOS refuses to open it: System Settings > Privacy & Security, scroll down, "Open Anyway".
3. Grant Accessibility when prompted: System Settings > Privacy & Security > Accessibility > Lease.

Lease shows a cursor icon in the menu bar. Needs macOS 14 or later on Apple silicon.

## Connect an agent

Lease is an MCP server on a Unix socket at `/tmp/lease.sock`, so `nc` is the whole client.

Claude Code:

    claude mcp add lease -- nc -U /tmp/lease.sock

Codex (`~/.codex/config.toml`):

    [mcp_servers.lease]
    command = "nc"
    args = ["-U", "/tmp/lease.sock"]

Anything else that reads the standard JSON form:

    {"mcpServers": {"lease": {"command": "nc", "args": ["-U", "/tmp/lease.sock"]}}}

## Tools

`status`: Accessibility granted?, seconds since your last input, frontmost app, cursor, displays.

`windows`: on-screen windows with app, pid, id and bounds in global points. Titles are empty unless Lease also has Screen Recording.

`act`: run `steps` under a lease. Options `idle_ms` (700), `max_ms` (2500), `wait_ms` (15000). Returns `ok`, `aborted`, `busy`, `timeout` or `error`, with a `reason`. Coordinates are global screen points, origin at the top-left of the main display.

| step | fields |
|---|---|
| `move` | `x`, `y` |
| `click` | `x`, `y`, `button` (`left` or `right`), `count` (2 = double-click) |
| `drag` | `x`, `y`, `x2`, `y2` |
| `scroll` | `x`, `y`, `dy` (positive = down), `dx` |
| `key` | `combo`, e.g. `cmd+s`, `cmd+shift+z`, `escape`, `down` |
| `type` | `text`, a `\n` presses return |
| `wait` | `ms` |

Any step also takes `pid`. A real click goes to whatever is on top at that point, exactly like yours would, so with `pid` set Lease refuses to act (error, nothing happens) unless the topmost window there belongs to that process, or for `key` and `type` unless that app is frontmost. Get pids from `windows`. Use it on every step.

Example, open a context menu and pick its second item:

    {"steps": [
      {"type": "click", "x": 2600, "y": 400, "button": "right", "pid": 4242},
      {"type": "wait", "ms": 150},
      {"type": "key", "combo": "down", "pid": 4242}, {"type": "key", "combo": "down", "pid": 4242}, {"type": "key", "combo": "return", "pid": 4242}
    ]}

## Limits

- Abort is detected by polling, so a keystroke or two can land in the agent's window before control returns. An event tap would fix that at the cost of an Input Monitoring prompt.
- If you never pause for `idle_ms`, the agent starves and gets `busy`.
- Long foreground jobs, like minutes inside Blender, don't fit a lease. Use a second macOS user over Screen Sharing, or a VM.
- Ad-hoc signed. Rebuilding changes the signature, so re-grant Accessibility after `./build.sh`.

## Build and test

    ./build.sh

Produces `build/Lease.app` and `build/Lease.dmg`. Logic self-check with a fake clock and fake human:

    build/Lease.app/Contents/MacOS/Lease --selftest

End-to-end check with real input (Lease running, Accessibility granted): opens TextEdit on a temp file, drags that window to free screen space, clicks into it, types, saves, checks the pid guard refuses a covered point, closes the window, and verifies your focus and cursor came back.

    python3 e2e.py

MIT.
