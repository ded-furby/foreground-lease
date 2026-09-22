// Lease: a computer-use agent borrows the real mouse and keyboard only while the human is idle.
//
// macOS has one cursor and one focused window. Agents that post global input steal both.
// Lease waits for a pause in the human's hardware input, snapshots cursor + focused window,
// runs a short burst of REAL input (so menus, drags, right-clicks and canvas apps work),
// aborts the instant the human touches anything, then puts cursor and focus back.
//
// Menu bar app + MCP server (newline-delimited JSON-RPC) on a Unix socket.
// Connect any MCP client with: nc -U /tmp/lease.sock
// Public APIs only. Needs Accessibility permission (macOS prompts on first launch).

import AppKit
import ApplicationServices

let sockPath = "/tmp/lease.sock"
let version = "0.1.0"

// MARK: - Engine

struct Step {
    let type: String
    let d: [String: Any]
    func num(_ k: String) -> Double? { (d[k] as? NSNumber)?.doubleValue }
    func str(_ k: String) -> String? { d[k] as? String }
}
struct Opts { var idleMs = 700.0; var maxMs = 2500.0; var waitMs = 15000.0 }
struct Snapshot { let cursor: CGPoint; let pid: pid_t; let window: AXUIElement? }
enum LeaseEnd: Error { case aborted, timeout, bad(String) }

// Everything the engine touches in the outside world goes through here so --selftest can fake it.
struct Env {
    var now: () -> Double = { Date().timeIntervalSince1970 }
    var sleepMs: (Int) -> Void = { usleep(useconds_t($0) * 1000) }
    // Seconds since the last HARDWARE event. We post at the session tap, which leaves this table alone;
    // posting at the HID tap would reset it and the lease would abort on its own events.
    var idle: () -> Double = {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: UInt32.max)!)
    }
    var perform: (Step) throws -> Void = performReal
    var snapshot: () -> Snapshot? = takeSnapshot
    var restore: (Snapshot, _ cursor: Bool) -> Void = restoreReal   // cursor false = human took the mouse, leave it
}
var env = Env()
let leaseLock = NSLock() // ponytail: one global lock; agents are serialized on purpose, there is one seat
var lease: (start: Double, maxMs: Double)? = nil

func guardLease() throws {
    guard let l = lease else { return }
    let elapsed = env.now() - l.start
    if env.idle() < elapsed { throw LeaseEnd.aborted } // a hardware event arrived after the lease began
    if elapsed * 1000 > l.maxMs { throw LeaseEnd.timeout }
}

func runLease(_ steps: [Step], _ o: Opts) -> [String: Any] {
    leaseLock.lock(); defer { leaseLock.unlock() }
    let t0 = env.now()
    while env.idle() * 1000 < o.idleMs {
        if (env.now() - t0) * 1000 > o.waitMs {
            return ["status": "busy", "done": 0, "reason": "human kept using the computer for \(Int(o.waitMs)) ms; retry later"]
        }
        env.sleepMs(50)
    }
    let snap = env.snapshot()
    let start = env.now()
    lease = (start, o.maxMs)
    setLeasing(true)
    var humanTookOver = false
    defer { lease = nil; if let s = snap { env.restore(s, !humanTookOver) }; setLeasing(false) }
    var done = 0
    do {
        for s in steps { try guardLease(); try env.perform(s); done += 1 }
    } catch LeaseEnd.aborted {
        humanTookOver = true
        return ["status": "aborted", "done": done, "reason": "human touched mouse or keyboard; cursor and focus restored, retry later"]
    } catch LeaseEnd.timeout {
        return ["status": "timeout", "done": done, "reason": "max_ms exceeded; keep bursts short"]
    } catch LeaseEnd.bad(let m) {
        return ["status": "error", "done": done, "reason": m]
    } catch {
        return ["status": "error", "done": done, "reason": "\(error)"]
    }
    return ["status": "ok", "done": done, "elapsed_ms": Int((env.now() - start) * 1000)]
}

// MARK: - Real input

let src: CGEventSource? = {
    let s = CGEventSource(stateID: .privateState)
    s?.localEventsSuppressionInterval = 0 // default 0.25 s would mute the human's hardware input after every post
    return s
}()

func post(_ e: CGEvent?, _ ms: Int = 25) throws {
    try guardLease()
    e?.post(tap: .cgSessionEventTap)
    env.sleepMs(ms)
}
func mouse(_ t: CGEventType, _ p: CGPoint, _ b: CGMouseButton = .left, clicks: Int = 1) -> CGEvent? {
    let e = CGEvent(mouseEventSource: src, mouseType: t, mouseCursorPosition: p, mouseButton: b)
    e?.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))
    return e
}

let keyCodes: [String: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14,
    "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27,
    "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "return": 36, "enter": 36, "l": 37, "j": 38,
    "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49, "`": 50,
    "delete": 51, "backspace": 51, "escape": 53, "esc": 53, "home": 115, "pageup": 116, "forwarddelete": 117,
    "end": 119, "pagedown": 121, "left": 123, "right": 124, "down": 125, "up": 126,
    "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109,
    "f11": 103, "f12": 111,
]
let modFlags: [String: CGEventFlags] = [
    "cmd": .maskCommand, "command": .maskCommand, "shift": .maskShift, "alt": .maskAlternate,
    "option": .maskAlternate, "ctrl": .maskControl, "control": .maskControl, "fn": .maskSecondaryFn,
]

func pressCombo(_ combo: String) throws {
    var flags = CGEventFlags()
    var key: CGKeyCode? = nil
    for part in combo.lowercased().split(separator: "+").map(String.init) {
        if let f = modFlags[part] { flags.insert(f) }
        else if let k = keyCodes[part] { key = k }
        else { throw LeaseEnd.bad("unknown key '\(part)' in '\(combo)'") }
    }
    guard let k = key else { throw LeaseEnd.bad("combo needs a key: '\(combo)'") }
    let down = CGEvent(keyboardEventSource: src, virtualKey: k, keyDown: true); down?.flags = flags
    let up = CGEvent(keyboardEventSource: src, virtualKey: k, keyDown: false); up?.flags = flags
    try post(down, 30); try post(up, 30)
}

func typeText(_ text: String) throws {
    for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        if i > 0 { try pressCombo("return") }
        var units = Array(String(line).utf16)
        while !units.isEmpty {
            let chunk = Array(units.prefix(20)); units.removeFirst(chunk.count)
            let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true)
            let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
            down?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            up?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            try post(down, 15); try post(up, 15)
        }
    }
}

// Safety rail: with "pid" on a step, refuse to act unless the topmost window at the point belongs to
// that process (mouse steps) or that app is frontmost (key/type). A real click goes to whatever is on
// top, so this is what stops an agent from typing into the human's window when its target is covered.
func topWindowOwner(at p: CGPoint) -> (pid: Int, app: String)? {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    for w in list { // front to back; app windows only (the Dock owns an invisible full-screen window at layer 20)
        guard (w[kCGWindowLayer as String] as? Int ?? 0) < 20,
              ((w[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0,
              let b = w[kCGWindowBounds as String] as? [String: Any] else { continue }
        func n(_ k: String) -> Double { (b[k] as? NSNumber)?.doubleValue ?? 0 }
        if CGRect(x: n("X"), y: n("Y"), width: n("Width"), height: n("Height")).contains(p) {
            return (w[kCGWindowOwnerPID as String] as? Int ?? 0, w[kCGWindowOwnerName as String] as? String ?? "?")
        }
    }
    return nil
}

func expectTarget(_ s: Step, at p: CGPoint?) throws {
    guard let want = s.num("pid").map({ Int($0) }) else { return }
    if let p = p {
        let at = "(\(Int(p.x)),\(Int(p.y)))"
        guard let top = topWindowOwner(at: p) else { throw LeaseEnd.bad("no window at \(at); nothing was clicked") }
        if top.pid != want {
            throw LeaseEnd.bad("\(at) is covered by \(top.app) (pid \(top.pid)), not pid \(want); nothing was clicked")
        }
    } else {
        let front = onMain { NSWorkspace.shared.frontmostApplication?.processIdentifier }.map { Int($0) }
        if front != want {
            throw LeaseEnd.bad("frontmost app is pid \(front ?? 0), not pid \(want); click its window and wait first, nothing was typed")
        }
    }
}

func performReal(_ s: Step) throws {
    let p = CGPoint(x: s.num("x") ?? 0, y: s.num("y") ?? 0)
    try expectTarget(s, at: ["key", "type", "wait"].contains(s.type) ? nil : p)
    switch s.type {
    case "move":
        try post(mouse(.mouseMoved, p))
    case "click":
        let right = s.str("button") == "right"
        let b: CGMouseButton = right ? .right : .left
        try post(mouse(.mouseMoved, p))
        for i in 1...max(1, Int(s.num("count") ?? 1)) {
            try post(mouse(right ? .rightMouseDown : .leftMouseDown, p, b, clicks: i))
            try post(mouse(right ? .rightMouseUp : .leftMouseUp, p, b, clicks: i))
        }
    case "drag":
        let q = CGPoint(x: s.num("x2") ?? p.x, y: s.num("y2") ?? p.y)
        try post(mouse(.mouseMoved, p))
        try post(mouse(.leftMouseDown, p), 60)
        for i in 1...12 {
            let t = Double(i) / 12
            try post(mouse(.leftMouseDragged, CGPoint(x: p.x + (q.x - p.x) * t, y: p.y + (q.y - p.y) * t)), 20)
        }
        try post(mouse(.leftMouseUp, q), 40)
    case "scroll":
        try post(mouse(.mouseMoved, p))
        let dy = Int32(max(-5000, min(5000, s.num("dy") ?? 0)))
        let dx = Int32(max(-5000, min(5000, s.num("dx") ?? 0)))
        try post(CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 2, wheel1: -dy, wheel2: -dx, wheel3: 0))
    case "key":
        try pressCombo(s.str("combo") ?? "")
    case "type":
        try typeText(s.str("text") ?? "")
    case "wait":
        let end = env.now() + (s.num("ms") ?? 100) / 1000
        while env.now() < end { try guardLease(); env.sleepMs(20) }
    default:
        throw LeaseEnd.bad("unknown step type '\(s.type)'")
    }
}

// MARK: - Snapshot / restore of the human's cursor and focus

func onMain<T>(_ f: () -> T) -> T { Thread.isMainThread ? f() : DispatchQueue.main.sync(execute: f) }

func takeSnapshot() -> Snapshot? {
    guard let app = onMain({ NSWorkspace.shared.frontmostApplication }) else { return nil }
    var win: CFTypeRef?
    AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute as CFString, &win)
    return Snapshot(cursor: CGEvent(source: nil)?.location ?? .zero, pid: app.processIdentifier,
                    window: win.map { $0 as! AXUIElement })
}

func restoreReal(_ s: Snapshot, cursor: Bool) {
    if cursor { _ = CGWarpMouseCursorPosition(s.cursor) }
    AXUIElementSetAttributeValue(AXUIElementCreateApplication(s.pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    if let w = s.window { AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue) }
    onMain { _ = NSRunningApplication(processIdentifier: s.pid)?.activate() }
}

// MARK: - Menu bar

var statusItem: NSStatusItem?
var stateItem: NSMenuItem?
var accessItem: NSMenuItem?

func setLeasing(_ on: Bool) {
    guard statusItem != nil else { return }
    onMain {
        statusItem?.button?.image = NSImage(systemSymbolName: on ? "cursorarrow.motionlines" : "cursorarrow",
                                            accessibilityDescription: "Lease")
        stateItem?.title = on ? "Agent has the cursor" : "Idle"
    }
}

final class MenuController: NSObject, NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        accessItem?.title = AXIsProcessTrusted() ? "Accessibility: granted" : "Accessibility: not granted, click to open Settings"
    }
    @objc func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc func quit() { NSApp.terminate(nil) }
}
let menuController = MenuController()

func buildMenu() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    item.button?.image = NSImage(systemSymbolName: "cursorarrow", accessibilityDescription: "Lease")
    let menu = NSMenu()
    menu.delegate = menuController
    stateItem = menu.addItem(withTitle: "Idle", action: nil, keyEquivalent: "")
    accessItem = menu.addItem(withTitle: "Accessibility", action: #selector(MenuController.openAccessibility), keyEquivalent: "")
    accessItem?.target = menuController
    menu.addItem(.separator())
    menu.addItem(withTitle: "Socket: \(sockPath)", action: nil, keyEquivalent: "")
    let q = menu.addItem(withTitle: "Quit Lease", action: #selector(MenuController.quit), keyEquivalent: "q")
    q.target = menuController
    item.menu = menu
    statusItem = item
}

// MARK: - MCP

let stepSchema: [String: Any] = [
    "type": "object",
    "properties": [
        "type": ["type": "string", "enum": ["move", "click", "drag", "scroll", "key", "type", "wait"]],
        "x": ["type": "number"], "y": ["type": "number"],
        "x2": ["type": "number", "description": "drag end x"], "y2": ["type": "number", "description": "drag end y"],
        "button": ["type": "string", "enum": ["left", "right"]],
        "count": ["type": "integer", "description": "clicks; 2 = double-click"],
        "dx": ["type": "number"], "dy": ["type": "number", "description": "scroll pixels, positive = down"],
        "combo": ["type": "string", "description": "e.g. cmd+s, cmd+shift+z, escape, return, down"],
        "text": ["type": "string", "description": "text to type; \\n presses return"],
        "ms": ["type": "number", "description": "wait duration"],
        "pid": ["type": "integer", "description": "safety rail: only act if the topmost window at (x,y) belongs to this pid, or for key/type if this app is frontmost; otherwise an error and nothing happens"],
    ],
    "required": ["type"],
]
let toolSpecs: [[String: Any]] = [
    ["name": "status",
     "description": "Lease status: whether Accessibility is granted, seconds since the human's last input, frontmost app, cursor and displays (global points, origin top-left of the main display).",
     "inputSchema": ["type": "object", "properties": [String: Any]()]],
    ["name": "windows",
     "description": "On-screen windows: app, pid, id and bounds in global points (title is empty unless Lease also has Screen Recording). Use it to find where to act, especially on another display.",
     "inputSchema": ["type": "object", "properties": [String: Any]()]],
    ["name": "act",
     "description": "Borrow the REAL mouse and keyboard for one short burst. Waits until the human has been idle for idle_ms, saves their cursor and focused window, runs the steps with real input (menus, popovers, drags, right-click and canvas apps all work), aborts instantly if the human touches mouse or keyboard, then restores cursor and focus. Coordinates are global screen points, origin top-left of the main display. Keep bursts under a couple of seconds. On 'aborted' or 'busy' just retry later.",
     "inputSchema": ["type": "object",
                     "properties": ["steps": ["type": "array", "items": stepSchema],
                                    "idle_ms": ["type": "number", "description": "human must be idle this long before the lease starts (default 700)"],
                                    "max_ms": ["type": "number", "description": "hard cap on the lease (default 2500)"],
                                    "wait_ms": ["type": "number", "description": "give up waiting for idle after this (default 15000)"]],
                     "required": ["steps"]]],
]

func statusJSON() -> [String: Any] {
    let (front, displays): (NSRunningApplication?, [[String: Any]]) = onMain {
        let screens = NSScreen.screens
        let h0 = screens.first?.frame.height ?? 0
        return (NSWorkspace.shared.frontmostApplication, screens.map { s in
            ["x": s.frame.origin.x, "y": h0 - s.frame.origin.y - s.frame.height,
             "w": s.frame.width, "h": s.frame.height, "main": s == screens.first]
        })
    }
    let c = CGEvent(source: nil)?.location ?? .zero
    return ["trusted": AXIsProcessTrusted(), "human_idle_s": (env.idle() * 100).rounded() / 100, "leasing": lease != nil,
            "frontmost": front.map { ["name": $0.localizedName ?? "", "pid": Int($0.processIdentifier), "bundle": $0.bundleIdentifier ?? ""] as [String: Any] } ?? NSNull(),
            "cursor": ["x": c.x, "y": c.y], "displays": displays]
}

func windowsJSON() -> [[String: Any]] {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    return list.compactMap { w in
        guard (w[kCGWindowLayer as String] as? Int) == 0, let b = w[kCGWindowBounds as String] as? [String: Any] else { return nil }
        func n(_ k: String) -> Double { (b[k] as? NSNumber)?.doubleValue ?? 0 }
        return ["app": w[kCGWindowOwnerName as String] as? String ?? "", "pid": w[kCGWindowOwnerPID as String] as? Int ?? 0,
                "title": w[kCGWindowName as String] as? String ?? "", "id": w[kCGWindowNumber as String] as? Int ?? 0,
                "x": n("X"), "y": n("Y"), "w": n("Width"), "h": n("Height")]
    }
}

func toolResult(_ obj: Any, isError: Bool = false) -> [String: Any] {
    let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
    return ["content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]], "isError": isError]
}

func mcpHandle(_ req: [String: Any]) -> [String: Any]? {
    let id = req["id"]
    let method = req["method"] as? String ?? ""
    let params = req["params"] as? [String: Any] ?? [:]
    func reply(_ result: Any) -> [String: Any]? { id.map { ["jsonrpc": "2.0", "id": $0, "result": result] } }
    func fail(_ code: Int, _ msg: String) -> [String: Any]? { id.map { ["jsonrpc": "2.0", "id": $0, "error": ["code": code, "message": msg]] } }
    switch method {
    case "initialize":
        return reply(["protocolVersion": params["protocolVersion"] ?? "2025-06-18",
                      "capabilities": ["tools": [String: Any]()],
                      "serverInfo": ["name": "lease", "version": version]])
    case "ping":
        return reply([String: Any]())
    case "tools/list":
        return reply(["tools": toolSpecs])
    case "tools/call":
        let args = params["arguments"] as? [String: Any] ?? [:]
        switch params["name"] as? String ?? "" {
        case "status":
            return reply(toolResult(statusJSON()))
        case "windows":
            return reply(toolResult(windowsJSON()))
        case "act":
            guard AXIsProcessTrusted() else {
                return reply(toolResult(["status": "error", "reason": "Accessibility not granted: System Settings > Privacy & Security > Accessibility > Lease"], isError: true))
            }
            let raw = args["steps"] as? [[String: Any]] ?? []
            let steps = raw.compactMap { d in (d["type"] as? String).map { Step(type: $0, d: d) } }
            guard steps.count == raw.count, (args["steps"] as? [Any]) != nil else {
                return reply(toolResult(["status": "error", "reason": "steps must be an array of objects with a 'type'"], isError: true))
            }
            var o = Opts()
            if let v = (args["idle_ms"] as? NSNumber)?.doubleValue { o.idleMs = v }
            if let v = (args["max_ms"] as? NSNumber)?.doubleValue { o.maxMs = v }
            if let v = (args["wait_ms"] as? NSNumber)?.doubleValue { o.waitMs = v }
            return reply(toolResult(runLease(steps, o)))
        case let name:
            return fail(-32602, "unknown tool '\(name)'")
        }
    default:
        return method.hasPrefix("notifications/") ? nil : fail(-32601, "method not found: \(method)")
    }
}

// MARK: - Unix socket server, one thread per client, newline-delimited JSON

func handleClient(_ fd: Int32) {
    defer { close(fd) }
    var buf = Data()
    var chunk = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = read(fd, &chunk, chunk.count)
        if n <= 0 { return }
        buf.append(chunk, count: n)
        while let nl = buf.firstIndex(of: 10) {
            let line = buf.subdata(in: buf.startIndex..<nl)
            buf.removeSubrange(buf.startIndex...nl)
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            guard let resp = mcpHandle(obj), var out = try? JSONSerialization.data(withJSONObject: resp) else { continue }
            out.append(10)
            out.withUnsafeBytes { _ = write(fd, $0.baseAddress, out.count) }
        }
    }
}

func serve() {
    unlink(sockPath)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutablePointer(to: &addr.sun_path) {
        $0.withMemoryRebound(to: CChar.self, capacity: 104) { _ = strncpy($0, sockPath, 103) }
    }
    let ok = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard ok == 0, listen(fd, 8) == 0 else { fputs("lease: cannot listen on \(sockPath)\n", stderr); exit(1) }
    chmod(sockPath, 0o600)
    while true {
        let c = accept(fd, nil, nil)
        if c >= 0 { Thread { handleClient(c) }.start() }
    }
}

// MARK: - Self-check of the lease logic with a fake clock and fake human

func selfTest() {
    var clock = 0.0, lastHuman = -10.0, performed = 0, restored = 0, cursorBack = false
    env.now = { clock }
    env.sleepMs = { clock += Double($0) / 1000 }
    env.idle = { clock - lastHuman }
    env.snapshot = { Snapshot(cursor: .zero, pid: 0, window: nil) }
    env.restore = { _, c in restored += 1; cursorBack = c }
    env.perform = { _ in performed += 1; clock += 0.05 }
    func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL:", what); exit(1) } }
    let steps = (0..<5).map { _ in Step(type: "move", d: [:]) }

    var r = runLease(steps, Opts())
    check(r["status"] as? String == "ok" && performed == 5 && restored == 1 && cursorBack, "idle human: all steps run, restored once \(r)")

    performed = 0; lastHuman = clock
    env.idle = { 0.1 }
    r = runLease(steps, Opts(waitMs: 1000))
    check(r["status"] as? String == "busy" && performed == 0 && restored == 1, "busy human: nothing runs, no restore \(r)")

    env.idle = { clock - lastHuman }; lastHuman = clock - 5; performed = 0
    env.perform = { _ in performed += 1; clock += 0.05; if performed == 2 { lastHuman = clock } }
    r = runLease(steps, Opts())
    check(r["status"] as? String == "aborted" && performed == 2 && restored == 2 && !cursorBack, "human touches mouse after step 2: aborted, restored \(r)")

    lastHuman = clock - 5; performed = 0
    env.perform = { _ in performed += 1; clock += 1.0 }
    r = runLease(steps, Opts())
    check(r["status"] as? String == "timeout" && performed == 3 && restored == 3 && cursorBack, "slow steps: timeout at max_ms, restored \(r)")

    let init_ = mcpHandle(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18"]])
    check((init_?["result"] as? [String: Any])?["protocolVersion"] as? String == "2025-06-18", "initialize echoes protocol version")
    check(mcpHandle(["jsonrpc": "2.0", "method": "notifications/initialized"]) == nil, "notifications get no reply")
    let tools = (mcpHandle(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])?["result"] as? [String: Any])?["tools"] as? [[String: Any]]
    check(tools?.count == 3, "tools/list lists three tools")
    print("selftest ok")
}

// MARK: - Main

signal(SIGPIPE, SIG_IGN)
if CommandLine.arguments.contains("--selftest") { selfTest(); exit(0) }
atexit { _ = unlink(sockPath) }
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
buildMenu()
Thread { serve() }.start()
app.run()
