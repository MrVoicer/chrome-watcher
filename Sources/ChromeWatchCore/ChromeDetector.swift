import Foundation

public enum BrowserFlavor: String, Sendable, Equatable {
    case chrome = "Google Chrome"
    case chromeForTesting = "Chrome for Testing"
    case chromium = "Chromium"
    case headlessShell = "Chrome Headless Shell"

    /// Test and bare builds are never somebody's everyday browser.
    public var isAlwaysAutomated: Bool { self != .chrome }
}

public enum ChromeKind: String, Sendable, Equatable {
    case mine = "My Chrome"
    case automated = "Automated"
}

/// One running browser: its main process plus its helpers.
public struct ChromeInstance: Identifiable, Sendable, Equatable {
    public var id: String { "\(main.pid)-\(main.startSeconds)-\(main.startMicroseconds)" }

    public var main: ProcessRecord
    public var flavor: BrowserFlavor
    public var kind: ChromeKind
    /// Why it counts as automated, e.g. "--remote-debugging-port=9333".
    public var automationSignals: [String]
    /// "Playwright CLI · session x", "Claude Code", "You (Dock/Finder)", …
    public var launchedBy: String
    /// Parent chain from the direct parent upwards.
    public var launcherChain: [ProcessRecord]
    /// Renderer, GPU, utility, … processes counted in `memoryFootprint`.
    public var helpers: [ProcessRecord]
    /// Sum of physical footprint of the main process and its helpers, in bytes.
    public var memoryFootprint: UInt64

    public var pid: Int32 { main.pid }
    public var processCount: Int { helpers.count + 1 }

    public func uptime(now: Date) -> TimeInterval { max(0, now.timeIntervalSince(main.startDate)) }

    /// Automated and running for over a day: probably forgotten.
    public func isStale(now: Date, threshold: TimeInterval = 24 * 3600) -> Bool {
        kind == .automated && uptime(now: now) > threshold
    }
}

public enum ChromeDetector {
    public static let defaultTempRoots = ["/var/folders/", "/private/var/folders/", "/tmp/", "/private/tmp/"]

    // MARK: Main process

    public static func browserFlavor(executablePath path: String) -> BrowserFlavor? {
        let macOSDir = ".app/Contents/MacOS/"
        if let range = path.range(of: macOSDir, options: .backwards) {
            let binary = String(path[range.upperBound...])
            let bundle = (String(path[..<range.lowerBound]) as NSString).lastPathComponent
            // The binary name and bundle name agree for the real browser; helpers live elsewhere.
            switch binary {
            case "Google Chrome", "Google Chrome Beta", "Google Chrome Dev", "Google Chrome Canary":
                return bundle == binary ? .chrome : nil
            case "Google Chrome for Testing":
                return .chromeForTesting
            case "Chromium":
                return .chromium
            default:
                return nil
            }
        }
        switch (path as NSString).lastPathComponent {
        case "headless_shell", "chrome-headless-shell": return .headlessShell
        default: return nil
        }
    }

    /// A browser main process: a known browser executable without `--type=`.
    public static func isMainProcess(_ record: ProcessRecord) -> Bool {
        guard browserFlavor(executablePath: record.path) != nil else { return false }
        return !record.arguments.dropFirst().contains { $0.hasPrefix("--type=") }
    }

    // MARK: Automated or mine

    public static func automationSignals(
        for record: ProcessRecord,
        flavor: BrowserFlavor,
        tempRoots: [String] = defaultTempRoots
    ) -> [String] {
        var signals: [String] = []
        let args = Array(record.arguments.dropFirst())
        for (index, arg) in args.enumerated() {
            let flag = arg.split(separator: "=", maxSplits: 1).first.map(String.init) ?? arg
            switch flag {
            case "--remote-debugging-pipe", "--remote-debugging-port", "--enable-automation", "--headless":
                signals.append(arg)
            case "--user-data-dir":
                var dir = arg.contains("=") ? String(arg.drop { $0 != "=" }.dropFirst()) : (index + 1 < args.count ? args[index + 1] : "")
                dir = dir.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if tempRoots.contains(where: { dir.hasPrefix($0) }) {
                    signals.append("temporary --user-data-dir (\(dir))")
                }
            default:
                break
            }
        }
        if flavor.isAlwaysAutomated {
            signals.append("\(flavor.rawValue) build")
        }
        if record.path.contains("/ms-playwright/") {
            signals.append("Playwright browser build")
        } else if record.path.contains("/puppeteer/") {
            signals.append("Puppeteer browser build")
        }
        return signals
    }

    // MARK: Launched by

    private static let shells: Set<String> = [
        "login", "zsh", "bash", "sh", "fish", "dash", "tcsh", "csh", "ksh", "nu", "xonsh",
        "tmux", "screen", "sudo", "env", "disclaimer",
    ]

    private static let interpreters: Set<String> = ["node", "bun", "deno", "python", "python3"]

    private static let terminalBundles = [
        "Terminal.app", "iTerm.app", "iTerm2.app", "Ghostty.app", "WezTerm.app", "Alacritty.app",
        "kitty.app", "Warp.app", "Hyper.app", "Tabby.app", "Rio.app",
    ]

    private static func basename(_ s: String) -> String { (s as NSString).lastPathComponent }

    /// The program name as a user would say it: argv[0]'s basename without a login-shell dash.
    private static func programName(_ record: ProcessRecord) -> String {
        var name = basename(record.arguments.first ?? record.path)
        if name.hasPrefix("-") { name.removeFirst() }
        return name
    }

    private static func isShell(_ record: ProcessRecord) -> Bool {
        shells.contains(programName(record)) || shells.contains(basename(record.path))
    }

    /// Specific automation tools, recognised from an ancestor's command line.
    private static func toolLabel(for record: ProcessRecord) -> String? {
        let args = record.arguments
        if let index = args.firstIndex(where: { $0.hasSuffix("cliDaemon.js") && $0.contains("playwright") }) {
            let next = args.index(after: index)
            if next < args.endIndex, !args[next].hasPrefix("-") {
                return "Playwright CLI · session \(args[next])"
            }
            return "Playwright CLI"
        }
        let haystack = ([record.path] + args).joined(separator: " ").lowercased()
        if haystack.contains("@playwright/mcp") || haystack.contains("playwright-mcp")
            || haystack.contains("mcp-server-playwright") {
            return "Playwright MCP"
        }
        if haystack.contains("puppeteer") { return "Puppeteer" }
        if haystack.contains("playwright") { return "Playwright" }
        return nil
    }

    /// Tool hints carried by the browser's own arguments, for scripts like `node scrape.js`.
    private static func toolHint(fromBrowser record: ProcessRecord) -> String? {
        let haystack = ([record.path] + record.arguments).joined(separator: " ")
        if haystack.contains("puppeteer") { return "Puppeteer" }
        if haystack.contains("playwright") { return "Playwright" }
        return nil
    }

    /// Coding agents and terminals: recognisable, but less specific than a tool.
    private static func hostLabel(for record: ProcessRecord, below: ArraySlice<ProcessRecord>, browser: ProcessRecord) -> String? {
        var names = [programName(record), basename(record.path)]
        // `node …/codex.js`: the script names the tool. Only for interpreters, not `sh -c "…"`.
        if interpreters.contains(programName(record)), let script = record.arguments.dropFirst().first,
           !script.contains(where: \.isWhitespace) {
            names.append(basename(script))
        }
        let lowered = names.map { $0.lowercased() }
        let haystack = ([record.path] + record.arguments).joined(separator: " ")
        if lowered.contains(where: { $0 == "codex" || $0.hasPrefix("codex-") || $0 == "codex.js" })
            || haystack.contains("@openai/codex") {
            return "Codex"
        }
        if lowered.contains("claude") || haystack.contains("@anthropic-ai/claude-code") {
            return "Claude Code"
        }
        if terminalBundles.contains(where: { record.path.contains("/\($0)/") }) {
            // The command the user typed: the first non-shell process below the terminal.
            let command = below.reversed().first { !isShell($0) } ?? browser
            return "Terminal: \(shortCommand(command))"
        }
        return nil
    }

    /// "node cliDaemon.js demo-1a2b3c4-live --headed", path arguments shortened to their basenames.
    public static func shortCommand(_ record: ProcessRecord, limit: Int = 48) -> String {
        let parts = [programName(record)] + record.arguments.dropFirst().prefix(3).map { arg in
            arg.hasPrefix("/") || arg.hasPrefix("~") ? basename(arg) : arg
        }
        let text = parts.joined(separator: " ")
        return text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }

    public static func launchedBy(_ browser: ProcessRecord, kind: ChromeKind, in table: ProcessTable) -> (label: String, chain: [ProcessRecord]) {
        let chain = table.ancestors(of: browser)
        if let label = chain.lazy.compactMap(toolLabel(for:)).first {
            return (label, chain)
        }
        if kind == .automated, let hint = toolHint(fromBrowser: browser) {
            return (hint, chain)
        }
        for (index, ancestor) in chain.enumerated() {
            if let label = hostLabel(for: ancestor, below: chain[..<index], browser: browser) {
                return (label, chain)
            }
        }
        if browser.ppid <= 1 || chain.isEmpty {
            return (kind == .mine ? "You (Dock/Finder)" : "Unknown (parent exited)", chain)
        }
        let nearest = chain.first { !isShell($0) } ?? chain[0]
        return (shortCommand(nearest), chain)
    }

    // MARK: Whole snapshot

    /// The directory a browser's helper executables live under.
    private static func bundleRoot(of path: String) -> String {
        if let range = path.range(of: ".app/", options: .backwards) {
            return String(path[..<range.upperBound])
        }
        return (path as NSString).deletingLastPathComponent + "/"
    }

    public static func detect(
        in table: ProcessTable,
        tempRoots: [String] = defaultTempRoots,
        footprint: (Int32) -> UInt64?
    ) -> [ChromeInstance] {
        var instances: [ChromeInstance] = []
        for record in table.records.values where !record.isZombie && isMainProcess(record) {
            guard let flavor = browserFlavor(executablePath: record.path) else { continue }
            let signals = automationSignals(for: record, flavor: flavor, tempRoots: tempRoots)
            let kind: ChromeKind = signals.isEmpty ? .mine : .automated
            let launcher = launchedBy(record, kind: kind, in: table)
            // Only count Chrome's own helpers, not e.g. native-messaging hosts it spawned.
            let root = bundleRoot(of: record.path)
            let helpers = table.descendants(of: record.pid).filter {
                !$0.isZombie && $0.path.hasPrefix(root) && !isMainProcess($0)
            }
            let memory = ([record] + helpers).reduce(UInt64(0)) { $0 + (footprint($1.pid) ?? 0) }
            instances.append(ChromeInstance(
                main: record, flavor: flavor, kind: kind, automationSignals: signals,
                launchedBy: launcher.label, launcherChain: launcher.chain,
                helpers: helpers, memoryFootprint: memory
            ))
        }
        return instances.sorted {
            if $0.kind != $1.kind { return $0.kind == .mine }
            return ($0.main.startSeconds, $0.pid) < ($1.main.startSeconds, $1.pid)
        }
    }
}
