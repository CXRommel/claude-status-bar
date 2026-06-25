import Cocoa

final class StatusController: NSObject, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let statusbarDir = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/statusbar")
    let instancesDir = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/statusbar/instances")
    let registryPath = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/statusbar/instances.json")
    // Legacy single-instance paths (pre multi-instance) — used only as a fallback so the bar
    // isn't blank during the upgrade window before the new hooks write to instances/.
    let legacyStatePath = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/statusbar/state.json")
    let legacySessionsDir = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/statusbar/sessions.d")
    let claudeDesktopBundleID = "com.anthropic.claudefordesktop"

    var pollTimer: Timer?
    var animTimer: Timer?
    var frameIdx = 0

    let launchedAt = Date()
    var notNeededSince: Date?
    let launchGrace: TimeInterval = 5   // settle time after launch before we may quit
    let idleQuitDelay: TimeInterval = 3 // "not needed" must persist this long before quitting

    // Multi-instance state. One Claude config dir = one instance, keyed by its label
    // (the subdir name under instances/). The menu bar renders a single "combined" item
    // for the busiest instance; the dropdown lists them all.
    var instances: [String: [String: Any]] = [:] // label -> raw state.json contents
    var instanceOrder: [String] = []             // registry order first, then discovered
    var instanceNames: [String: String] = [:]    // label -> friendly display name
    var prevEffByLabel: [String: String] = [:]   // last effective state per instance (completion-sound edge)
    var lastTurnStartByLabel: [String: Double] = [:] // active turn start per instance (1-min gate)

    var activeBase = ""        // label without the elapsed clock
    var startedAt: Double = 0  // unix seconds the current turn began (0 = no clock)
    var activeColor: NSColor? = nil

    let brand = NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1) // #d97757, Anthropic's official "Orange" accent
    let amber = NSColor(srgbRed: 0.95, green: 0.73, blue: 0.18, alpha: 1) // "awaiting permission" yellow dot
    let frames: [NSImage] = StatusController.loadFrames()
    let spriteFPS: Double = 9 // tune: 8 frames per loop -> ~0.9s/cycle

    enum AnimStyle: String { case web, code, crab }
    var animStyle: AnimStyle = .web
    var showTimer = false
    var iconSystem = false // false = brand Orange; true = adaptive black/white (template image)
    var playCompletionSound = false // chime when a turn longer than ~1 min finishes
    lazy var completionSound: NSSound? = {
        guard let p = Bundle.main.path(forResource: "completion", ofType: "mp3"),
              let s = NSSound(contentsOfFile: p, byReference: true) else { return nil }
        s.volume = 0.7 // the clip is loud at full system volume; play it a bit softer
        return s
    }()
    var iconColor: NSColor? { iconSystem ? nil : brand } // nil => render as an adaptive template
    let codeGlyphs = ["✻", "✽", "✶", "✳", "✢"]
    let codePeaks: [CGFloat] = [1.0, 1.0, 1.0, 1.0, 1.0]
    let codeDip: CGFloat = 0.14 // glyph shrinks to this at each swap
    let codeSub = 18            // sub-frames per glyph (tween smoothness)
    let codeCycle: Double = 3.8 // seconds for the full loop (lower = faster)
    lazy var codeGlyphMasks: [NSImage] = codeGlyphs.map { StatusController.glyphMask($0) }
    let crabFPS: Double = 12.5 // matches the source GIF's 0.08s frame delay
    lazy var crabFrames: [NSImage] = StatusController.decodePNGs(clawdCrabFramePNGs)
    var fps: Double {
        switch animStyle {
        case .web: return spriteFPS
        case .code: return Double(codeGlyphs.count * codeSub) / codeCycle
        case .crab: return crabFPS
        }
    }
    var frameCount: Int {
        switch animStyle {
        case .web: return max(1, frames.count)
        case .code: return codeGlyphs.count * codeSub
        case .crab: return max(1, crabFrames.count)
        }
    }

    override init() {
        super.init()
        let d = UserDefaults.standard
        if d.object(forKey: "showTimer") != nil { showTimer = d.bool(forKey: "showTimer") }
        if d.object(forKey: "iconSystem") != nil { iconSystem = d.bool(forKey: "iconSystem") }
        if d.object(forKey: "completionSound") != nil { playCompletionSound = d.bool(forKey: "completionSound") }
        if let s = d.string(forKey: "animStyle"), let st = AnimStyle(rawValue: s) { animStyle = st }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        render(label: "", color: iconColor, animate: false, startedAt: 0)
        let t = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
        tick()
        ensureHooksInstalled()
        checkForUpdate()
    }

    // Re-runs on first install AND on every version change, so upgrades pick up hook
    // changes and retire old artifacts. See CLAUDE.md "ensureHooksInstalled" for why.
    func ensureHooksInstalled() {
        let d = UserDefaults.standard
        let current = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""
        guard d.string(forKey: "installedVersion") != current,
              let installer = Bundle.main.path(forResource: "install", ofType: "js") else { return }
        DispatchQueue.global().async {
            guard let node = Self.locateNode() else {
                NSLog("ClaudeStatusBar: could not find node; hooks not installed (will retry next launch)")
                return
            }
            let task = Process()
            task.executableURL = URL(fileURLWithPath: node)
            task.arguments = [installer]
            try? task.run()
            task.waitUntilExit()
            if task.terminationStatus == 0 { UserDefaults.standard.set(current, forKey: "installedVersion") }
        }
    }

    // `/bin/zsh -lc node` saw only the login PATH, missing nvm/fnm set in .zshrc.
    static func locateNode() -> String? {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        var candidates = [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node",
            "\(home)/.volta/bin/node",
            "\(home)/.asdf/shims/node",
        ]
        let nvmDir = "\(home)/.nvm/versions/node"
        if let versions = try? fm.contentsOfDirectory(atPath: nvmDir) {
            for v in versions.sorted(by: >) { candidates.append("\(nvmDir)/\(v)/bin/node") }
        }
        for path in candidates where fm.isExecutableFile(atPath: path) { return path }

        for args in [["-ilc", "command -v node"], ["-lc", "command -v node"]] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { continue }
            p.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = (String(data: data, encoding: .utf8) ?? "")
                .split(separator: "\n").last.map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            if !path.isEmpty, fm.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    // MARK: update check

    var currentVersion: String { (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0" }
    let releaseAPIURL = "https://api.github.com/repos/m1ckc3s/claude-status-bar/releases/latest"
    let releasePageURL = "https://github.com/m1ckc3s/claude-status-bar/releases/latest"

    // Once/day: cache GitHub's latest release tag in UserDefaults. Nothing sent to us.
    // See CLAUDE.md "Update check" for the privacy/behavior notes.
    func checkForUpdate() {
        let d = UserDefaults.standard
        let now = Date().timeIntervalSince1970
        if now - d.double(forKey: "lastUpdateCheck") < 86400 { return }
        guard let url = URL(string: releaseAPIURL) else { return }
        var req = URLRequest(url: url)
        req.setValue("ClaudeStatusBar", forHTTPHeaderField: "User-Agent") // GitHub API requires a UA
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = obj["tag_name"] as? String else { return }
            let ver = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            UserDefaults.standard.set(ver, forKey: "latestVersion")
            UserDefaults.standard.set(now, forKey: "lastUpdateCheck")
        }.resume()
    }

    // Numeric component-wise compare so "0.0.10" > "0.0.9".
    func versionIsNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    @objc func openLatestRelease() {
        if let url = URL(string: releasePageURL) { NSWorkspace.shared.open(url) }
    }

    // MARK: menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        checkForUpdate() // refreshes the update cache for next open (gated to once a day)

        let openItem = NSMenuItem(title: "Open Claude", action: #selector(openClaude), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)
        menu.addItem(.separator())
        menu.addItem(header("Options"))

        let timerItem = NSMenuItem(title: "Show timer", action: #selector(toggleTimer), keyEquivalent: "")
        timerItem.target = self
        timerItem.state = showTimer ? .on : .off
        menu.addItem(timerItem)

        let soundItem = NSMenuItem(title: "Play Completion Sound", action: #selector(toggleSound), keyEquivalent: "")
        soundItem.target = self
        soundItem.state = playCompletionSound ? .on : .off
        if #available(macOS 14.0, *) { soundItem.badge = NSMenuItemBadge(string: "1m+") }
        menu.addItem(soundItem)

        menu.addItem(.separator())
        menu.addItem(header("Animation"))
        for (style, name) in [(AnimStyle.web, "Claude Spark"), (AnimStyle.code, "Claude Code"), (AnimStyle.crab, "Crab Walking")] {
            let it = NSMenuItem(title: name, action: #selector(chooseStyle(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = style.rawValue
            it.state = animStyle == style ? .on : .off
            menu.addItem(it)
        }

        menu.addItem(.separator())
        menu.addItem(header("Color"))
        for (sys, name) in [(false, "Orange"), (true, "System")] {
            let it = NSMenuItem(title: name, action: #selector(chooseColor(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = sys
            it.state = iconSystem == sys ? .on : .off
            menu.addItem(it)
        }

        menu.addItem(.separator())
        menu.addItem(header("Instances"))
        let live = instanceOrder.filter { instances[$0] != nil }
        if live.isEmpty {
            let none = NSMenuItem(title: "No active instances", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        } else {
            for label in live {
                let e = effective(instances[label]!)
                let it = NSMenuItem(title: "\(shortName(label)) — \(rowStatus(e))", action: nil, keyEquivalent: "")
                it.isEnabled = false
                menu.addItem(it)
            }
        }
        let edit = NSMenuItem(title: "Edit instances…", action: #selector(editInstances), keyEquivalent: "")
        edit.target = self
        menu.addItem(edit)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Version \(currentVersion)", action: nil, keyEquivalent: ""))
        if let latest = UserDefaults.standard.string(forKey: "latestVersion"), versionIsNewer(latest, than: currentVersion) {
            let up = NSMenuItem(title: "Update available", action: #selector(openLatestRelease), keyEquivalent: "")
            up.target = self
            menu.addItem(up)
        }
        let q = NSMenuItem(title: "Quit Claude Status Bar", action: #selector(quit), keyEquivalent: "q")
        q.target = self
        menu.addItem(q)
    }

    func header(_ title: String) -> NSMenuItem {
        if #available(macOS 14.0, *) { return NSMenuItem.sectionHeader(title: title) }
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.isEnabled = false
        return it
    }

    @objc func quit() { NSApp.terminate(nil) }

    @objc func openClaude() {
        let ws = NSWorkspace.shared
        if let url = ws.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") {
            ws.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    // Open the instance registry in the user's default editor, seeding a single-instance
    // template (just the default ~/.claude) if it doesn't exist yet. Users duplicate the entry
    // to track extra CLAUDE_CONFIG_DIR aliases. The "_comment" key is ignored by the parsers.
    @objc func editInstances() {
        if !FileManager.default.fileExists(atPath: registryPath) {
            let template = """
            {
              "_comment": "One entry per Claude instance — each a distinct CLAUDE_CONFIG_DIR. Duplicate the Default line to track an alias, e.g. { \\"name\\": \\"Work\\", \\"configDir\\": \\"~/.claude-work\\", \\"label\\": \\"claude-work\\" }. configDir accepts ~ and $ENV. Re-run the installer (or update the app) after editing so hooks reach the new dir.",
              "instances": [
                { "name": "Default", "configDir": "~/.claude", "label": "default" }
              ]
            }

            """
            try? FileManager.default.createDirectory(atPath: statusbarDir, withIntermediateDirectories: true)
            try? template.write(toFile: registryPath, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: registryPath))
    }

    @objc func toggleTimer() {
        showTimer.toggle()
        UserDefaults.standard.set(showTimer, forKey: "showTimer")
        applyTitle()
    }

    @objc func toggleSound() {
        playCompletionSound.toggle()
        UserDefaults.standard.set(playCompletionSound, forKey: "completionSound")
    }

    @objc func chooseColor(_ sender: NSMenuItem) {
        guard let sys = sender.representedObject as? Bool else { return }
        iconSystem = sys
        UserDefaults.standard.set(iconSystem, forKey: "iconSystem")
        evaluate() // re-render the current state in the new color
    }

    @objc func chooseStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let st = AnimStyle(rawValue: raw) else { return }
        animStyle = st
        UserDefaults.standard.set(raw, forKey: "animStyle")
        animTimer?.invalidate(); animTimer = nil // recreate at the new style's fps
        frameIdx = 0
        evaluate()
    }

    // MARK: state polling

    func tick() {
        checkLifecycle()
        loadRegistry()
        loadInstances()
        evaluate()
    }

    // Read instances.json (friendly names + ordering). Tolerant of a missing/invalid file.
    func loadRegistry() {
        guard let data = FileManager.default.contents(atPath: registryPath),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["instances"] as? [[String: Any]] else { return }
        var names: [String: String] = [:]
        var order: [String] = []
        for it in arr {
            guard let label = it["label"] as? String, !label.isEmpty else { continue }
            names[label] = (it["name"] as? String) ?? label
            order.append(label)
        }
        instanceNames = names
        // Stash the registry order so evaluate()/the menu list instances predictably.
        registryOrder = order
    }
    var registryOrder: [String] = []

    // Load every instance's state.json under instances/. Falls back to the legacy top-level
    // state.json (as a synthetic "default") so the bar isn't blank right after an upgrade.
    func loadInstances() {
        let fm = FileManager.default
        var found: [String: [String: Any]] = [:]
        var discovered: [String] = []
        if let labels = try? fm.contentsOfDirectory(atPath: instancesDir) {
            for label in labels.sorted() {
                let sp = (instancesDir as NSString).appendingPathComponent("\(label)/state.json")
                if let data = fm.contents(atPath: sp),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    found[label] = obj
                    discovered.append(label)
                }
            }
        }
        if found.isEmpty,
           let data = fm.contents(atPath: legacyStatePath),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            found["default"] = obj
            discovered = ["default"]
        }
        instances = found
        // Registry order first (only labels we actually found), then any extras discovered.
        instanceOrder = registryOrder.filter { found[$0] != nil }
            + discovered.filter { !registryOrder.contains($0) }
    }

    struct Eff { let state: String; let label: String; let started: Double; let ts: Double }

    // Resolve one instance's raw state into its effective state, applying the same recovery
    // rules the single-instance path used (Esc-interrupt marker + a 900s safety net).
    func effective(_ s: [String: Any]) -> Eff {
        let state = s["state"] as? String ?? "idle"
        var label = s["label"] as? String ?? ""
        let ts = (s["ts"] as? NSNumber)?.doubleValue ?? 0
        let started = (s["startedAt"] as? NSNumber)?.doubleValue ?? 0
        let age = Date().timeIntervalSince1970 - ts
        var eff = state
        // Stop fires on normal completion but NOT on an Esc interrupt or a denied permission
        // prompt: Claude Code writes "[Request interrupted by user]" to the transcript and ends
        // with no hook, freezing state.json. Recover off that marker. (Force-quit writes no
        // marker; lifecycle.js handles that case.) Full rationale in CLAUDE.md.
        if state == "thinking" || state == "tool" || state == "permission" {
            if age > 900 { eff = "idle"; label = "" } // absolute safety net
            else if let tr = s["transcript"] as? String,
                    let last = lastLine(ofFileAt: tr),
                    last.contains("interrupted by user") {
                eff = "idle"; label = ""
            }
        }
        return Eff(state: eff, label: label, started: started, ts: ts)
    }

    // Higher wins the single menu-bar slot: an instance awaiting you outranks one merely
    // working, which outranks one that just finished, which outranks idle.
    func priority(_ state: String) -> Int {
        switch state {
        case "permission": return 3
        case "tool", "thinking": return 2
        case "done": return 1
        default: return 0
        }
    }

    func shortName(_ label: String) -> String { instanceNames[label] ?? label }

    // One-line status used in the dropdown's Instances section.
    func rowStatus(_ e: Eff) -> String {
        switch e.state {
        case "permission": return "Awaiting permission"
        case "tool": return e.label.isEmpty ? "Working…" : e.label
        case "thinking": return e.label.isEmpty ? "Thinking…" : e.label
        case "done": return "Done"
        default: return "Idle"
        }
    }

    func evaluate() {
        // Per-instance completion-sound bookkeeping: chime once when any instance's turn that
        // ran >= 1 min transitions to "done".
        for (label, raw) in instances {
            let e = effective(raw)
            if (e.state == "thinking" || e.state == "tool"), e.started > 0 { lastTurnStartByLabel[label] = e.started }
            if e.state == "done", (prevEffByLabel[label] ?? "") != "done", playCompletionSound,
               let lts = lastTurnStartByLabel[label], lts > 0,
               Date().timeIntervalSince1970 - lts >= 60 {
                completionSound?.play()
            }
            if e.state == "done" { lastTurnStartByLabel[label] = 0 }
            prevEffByLabel[label] = e.state
        }
        // Drop bookkeeping for instances that vanished.
        for label in Array(prevEffByLabel.keys) where instances[label] == nil {
            prevEffByLabel[label] = nil; lastTurnStartByLabel[label] = nil
        }

        // Pick the "combined" winner: highest priority, ties broken by most recent activity.
        var winnerLabel: String?
        var winner: Eff?
        for label in instanceOrder {
            guard let raw = instances[label] else { continue }
            let e = effective(raw)
            if let w = winner {
                let p = priority(e.state), wp = priority(w.state)
                if p > wp || (p == wp && e.ts > w.ts) { winner = e; winnerLabel = label }
            } else {
                winner = e; winnerLabel = label
            }
        }

        guard let e = winner, let wl = winnerLabel else {
            render(label: "", color: iconColor, animate: false, startedAt: 0)
            return
        }
        // Prefix the winner's short name only when more than one instance exists and it's
        // doing something worth attributing.
        let prefix = (instances.count > 1 && priority(e.state) > 0) ? "\(shortName(wl)) " : ""

        switch e.state {
        case "thinking":  render(label: prefix + (e.label.isEmpty ? "Thinking…" : e.label), color: iconColor, animate: true,  startedAt: e.started)
        case "tool":      render(label: prefix + (e.label.isEmpty ? "Working…"  : e.label), color: iconColor, animate: true,  startedAt: e.started)
        case "permission":render(label: prefix + "Awaiting permission", color: amber, animate: false, startedAt: 0, dot: true)
        default:          render(label: "", color: iconColor, animate: false, startedAt: 0) // done + idle: just the orange spark
        }
    }

    // MARK: self-quit lifecycle (rationale + warmup-churn history in CLAUDE.md)

    func claudeDesktopRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == claudeDesktopBundleID }
    }

    // Total live sessions across every instance (each is one file in its sessions.d/),
    // plus the legacy top-level sessions.d as a fallback during the upgrade window.
    func sessionCount() -> Int {
        let fm = FileManager.default
        var n = 0
        if let labels = try? fm.contentsOfDirectory(atPath: instancesDir) {
            for label in labels {
                let sd = (instancesDir as NSString).appendingPathComponent("\(label)/sessions.d")
                n += (try? fm.contentsOfDirectory(atPath: sd).count) ?? 0
            }
        }
        n += (try? fm.contentsOfDirectory(atPath: legacySessionsDir).count) ?? 0
        return n
    }

    // Stay while Claude desktop is open OR a session is active; otherwise quit after a
    // short debounced grace (warmup-session churn must not kill us).
    func checkLifecycle() {
        let now = Date()
        if now.timeIntervalSince(launchedAt) < launchGrace { return }
        if claudeDesktopRunning() || sessionCount() > 0 {
            notNeededSince = nil
            return
        }
        if let since = notNeededSince {
            if now.timeIntervalSince(since) >= idleQuitDelay { NSApp.terminate(nil) }
        } else {
            notNeededSince = now
        }
    }

    // Read the last non-empty line of a (possibly large) file by tailing ~8KB.
    func lastLine(ofFileAt path: String) -> String? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let chunk: UInt64 = 8192
        try? fh.seek(toOffset: size > chunk ? size - chunk : 0)
        guard let data = try? fh.readToEnd(), let s = String(data: data, encoding: .utf8) else { return nil }
        return s.split(separator: "\n").last { !$0.isEmpty }.map(String.init)
    }

    // MARK: render

    func render(label: String, color: NSColor?, animate: Bool, startedAt: Double, dot: Bool = false) {
        guard let button = statusItem.button else { return }
        button.contentTintColor = nil // we paint the icon color ourselves; template-tint is unreliable
        activeBase = label
        activeColor = color
        self.startedAt = startedAt

        if animate {
            if animTimer == nil {
                let t = Timer(timeInterval: 1.0 / fps, repeats: true) { [weak self] _ in self?.animStep() }
                RunLoop.main.add(t, forMode: .common)
                animTimer = t
            }
        } else {
            animTimer?.invalidate(); animTimer = nil
            frameIdx = 0
            button.image = dot ? dotIcon(color: color) : restingIcon(color: color)
        }
        applyTitle()
        if button.image == nil { button.image = dot ? dotIcon(color: color) : restingIcon(color: color) }
    }

    func animStep() {
        frameIdx = (frameIdx + 1) % frameCount
        statusItem.button?.image = iconImage(color: activeColor, frame: frameIdx)
        applyTitle() // refresh the elapsed clock
    }

    func applyTitle() {
        guard let button = statusItem.button else { return }
        var text = activeBase
        if showTimer, startedAt > 0 {
            let secs = max(0, Int(Date().timeIntervalSince1970 - startedAt))
            let m = secs / 60, s = secs % 60
            text += "  " + (m > 0 ? "\(m)m \(s)s" : "\(s)s") // Claude Code style: "1m 1s" / "43s"
        }
        if text.isEmpty {
            button.imagePosition = .imageOnly
            button.attributedTitle = NSAttributedString(string: "")
            return
        }
        button.imagePosition = .imageLeading
        // labelColor adapts: white on a dark menu bar, black on a light one. Monospaced
        // digits keep the elapsed clock from nudging neighboring menu bar icons.
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.labelColor,
            .font: NSFont.monospacedDigitSystemFont(ofSize: 0, weight: .regular),
        ]
        button.attributedTitle = NSAttributedString(string: " \(text)", attributes: attrs)
    }

    // MARK: icon

    static func loadFrames() -> [NSImage] { decodePNGs(claudeSparkFramePNGs) }
    static func decodePNGs(_ list: [String]) -> [NSImage] {
        list.compactMap { Data(base64Encoded: $0).flatMap(NSImage.init(data:)) }
    }

    func iconImage(color: NSColor?, frame: Int) -> NSImage {
        if animStyle == .web { return tint(frames, color: color, frame: frame) }
        if animStyle == .crab { return crabIcon(frame: frame) }
        let i = (frame / codeSub) % codeGlyphs.count
        let local = (CGFloat(frame % codeSub) + 0.5) / CGFloat(codeSub) // 0…1 within this glyph
        // Scale envelope per glyph: rise, hold at peak, fall, so each lands before the swap.
        let env: CGFloat
        if local < 0.30 { let u = local / 0.30; env = u * u * (3 - 2 * u) }
        else if local > 0.70 { let u = (1 - local) / 0.30; env = u * u * (3 - 2 * u) }
        else { env = 1 }
        let scale = codeDip + (codePeaks[i] - codeDip) * env
        return codeIcon(color: color, glyph: i, scale: scale)
    }

    // nil color => adaptive template image (system draws it black/white per the menu bar).
    func codeIcon(color: NSColor?, glyph: Int, scale: CGFloat) -> NSImage {
        let s: CGFloat = 18
        guard glyph < codeGlyphMasks.count else { return NSImage(size: NSSize(width: s, height: s)) }
        let mask = codeGlyphMasks[glyph]
        let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
            let dw = s * scale
            let r = NSRect(x: (s - dw) / 2, y: (s - dw) / 2, width: dw, height: dw)
            if let c = color {
                c.setFill(); r.fill()
                mask.draw(in: r, from: .zero, operation: .destinationIn, fraction: 1.0)
            } else {
                mask.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1.0)
            }
            return true
        }
        img.isTemplate = (color == nil)
        return img
    }

    // Rasterize a single glyph into a centered 60x60 alpha mask filling ~92%.
    static func glyphMask(_ g: String) -> NSImage {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 180), .foregroundColor: NSColor.black,
        ]
        let str = NSAttributedString(string: g, attributes: attrs)
        let sz = str.size()
        let big = NSImage(size: sz, flipped: false) { _ in str.draw(at: .zero); return true }
        guard let rep = big.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)) else {
            return NSImage(size: NSSize(width: 60, height: 60))
        }
        let w = rep.pixelsWide, h = rep.pixelsHigh, data = rep.bitmapData!
        var minx = w, miny = h, maxx = -1, maxy = -1
        for y in 0..<h { for x in 0..<w where data[(y*w+x)*4+3] > 20 {
            minx = min(minx, x); maxx = max(maxx, x); miny = min(miny, y); maxy = max(maxy, y)
        }}
        guard maxx >= 0 else { return NSImage(size: NSSize(width: 60, height: 60)) }
        let bw = CGFloat(maxx - minx + 1), bh = CGFloat(maxy - miny + 1)
        let out: CGFloat = 60, fill = out * 0.92
        let scale = fill / max(bw, bh)
        let dw = bw * scale, dh = bh * scale
        // NSBitmapImageRep origin is top-left; convert the bbox to bottom-left for drawing.
        let srcRect = NSRect(x: CGFloat(minx), y: CGFloat(h - maxy - 1), width: bw, height: bh)
        return NSImage(size: NSSize(width: out, height: out), flipped: false) { _ in
            big.draw(in: NSRect(x: (out - dw)/2, y: (out - dh)/2, width: dw, height: dh),
                     from: srcRect, operation: .sourceOver, fraction: 1.0)
            return true
        }
    }

    let logoSet: [NSImage] = Data(base64Encoded: claudeLogoPNG).flatMap(NSImage.init(data:)).map { [$0] } ?? []
    func restingIcon(color: NSColor?) -> NSImage {
        if animStyle == .crab { return crabIcon(frame: 0) }
        return tint(logoSet.isEmpty ? frames : logoSet, color: color, frame: 0)
    }

    // Full color (isTemplate=false), so the Orange/System color setting does NOT apply here.
    func crabIcon(frame: Int) -> NSImage {
        guard !crabFrames.isEmpty else { return NSImage(size: NSSize(width: 18, height: 18)) }
        let src = crabFrames[frame % crabFrames.count]
        let rep = src.representations.first
        let pw = CGFloat(rep?.pixelsWide ?? Int(src.size.width))
        let ph = CGFloat(rep?.pixelsHigh ?? Int(src.size.height))
        let h: CGFloat = 18, w = (ph > 0 ? h * (pw / ph) : h)
        let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { rect in
            src.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
            return true
        }
        img.isTemplate = false
        return img
    }

    func dotIcon(color: NSColor?) -> NSImage {
        let s: CGFloat = 18, d: CGFloat = 9
        let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
            (color ?? .systemYellow).setFill()
            NSBezierPath(ovalIn: NSRect(x: (s - d) / 2, y: (s - d) / 2, width: d, height: d)).fill()
            return true
        }
        img.isTemplate = (color == nil)
        return img
    }

    // Paint `color` through a frame mask's alpha (destinationIn) so frames recolor.
    func tint(_ set: [NSImage], color: NSColor?, frame: Int) -> NSImage {
        let s: CGFloat = 18
        guard !set.isEmpty else { return NSImage(size: NSSize(width: s, height: s)) }
        let mask = set[frame % set.count]
        let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { rect in
            if let c = color {
                c.setFill()
                rect.fill()
                mask.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1.0)
            } else {
                mask.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
            }
            return true
        }
        img.isTemplate = (color == nil) // nil => adaptive black/white in the menu bar
        return img
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = StatusController()
app.run()
