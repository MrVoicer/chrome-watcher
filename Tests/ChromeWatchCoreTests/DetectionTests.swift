import Foundation
import Testing
@testable import ChromeWatchCore

// MARK: Canned processes

private let chromePath = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
private let helpers = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/154.0.8037.98/Helpers"
private let rendererPath = "\(helpers)/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"
private let gpuPath = "\(helpers)/Google Chrome Helper (GPU).app/Contents/MacOS/Google Chrome Helper (GPU)"
private let utilityPath = "\(helpers)/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"
private let claudeCodePath = "/Users/me/Library/Application Support/Claude/claude-code/2.1.293/abc/claude.app/Contents/MacOS/claude"

private let mb: UInt64 = 1_048_576

private func proc(_ pid: Int32, _ ppid: Int32, _ args: [String], path: String? = nil, start: Int = 1_000) -> ProcessRecord {
    ProcessRecord(pid: pid, ppid: ppid, startSeconds: start, executablePath: path ?? args.first, arguments: args)
}

/// A browser main process with a renderer, GPU and utility helper. Helper PIDs are main+1…main+3.
private func browser(_ pid: Int32, parent: Int32, path: String = chromePath, flags: [String] = [], start: Int = 1_000) -> [ProcessRecord] {
    let helperDir = path.hasSuffix("Google Chrome") ? nil : (path as NSString).deletingLastPathComponent
    let renderer = helperDir.map { "\($0)/renderer-helper" } ?? rendererPath
    let gpu = helperDir.map { "\($0)/gpu-helper" } ?? gpuPath
    let utility = helperDir.map { "\($0)/utility-helper" } ?? utilityPath
    return [
        proc(pid, parent, [path] + flags, start: start),
        proc(pid + 1, pid, [renderer, "--type=renderer"], start: start),
        proc(pid + 2, pid, [gpu, "--type=gpu-process"], start: start),
        proc(pid + 3, pid, [utility, "--type=utility", "--utility-sub-type=network.mojom.NetworkService"], start: start),
    ]
}

/// 100 MB for each main, 10 MB for each helper.
private func footprints(_ table: ProcessTable) -> (Int32) -> UInt64? {
    { pid in
        guard let record = table[pid] else { return nil }
        return record.arguments.contains { $0.hasPrefix("--type=") } ? 10 * mb : 100 * mb
    }
}

private func detect(_ list: [ProcessRecord]) -> [ChromeInstance] {
    let table = ProcessTable(list)
    return ChromeDetector.detect(in: table, footprint: footprints(table))
}

// MARK: Scenarios from the spec

@Test func myChromeAlone() {
    // Dock-launched Chrome, plus a native-messaging host it spawned (not a Chrome helper).
    let list = browser(500, parent: 1) + [proc(510, 500, ["/Users/me/.local/bin/claude", "--chrome-native-host"])]
    let found = detect(list)

    #expect(found.count == 1)
    let mine = try! #require(found.first)
    #expect(mine.kind == .mine)
    #expect(mine.flavor == .chrome)
    #expect(mine.launchedBy == "You (Dock/Finder)")
    #expect(mine.automationSignals.isEmpty)
    #expect(mine.helpers.map(\.pid) == [501, 502, 503])
    #expect(mine.memoryFootprint == 130 * mb)
    #expect(mine.processCount == 4)
}

@Test func myChromePlusPlaywrightCLIChrome() {
    // Claude Code → zsh → node cliDaemon.js → Chrome.
    let daemonArgs = [
        "node",
        "/Users/me/.npm/_npx/0a1b2c/node_modules/playwright-core/lib/entry/cliDaemon.js",
        "demo-1a2b3c4-live", "--headed", "--browser=chrome",
    ]
    let list = browser(500, parent: 1)
        + [
            proc(700, 1, [claudeCodePath, "--output-format", "stream-json"]),
            proc(710, 700, ["/bin/zsh", "-c", "playwright-cli open"]),
            proc(720, 710, daemonArgs, path: "/opt/homebrew/Cellar/node/24.1.0/bin/node"),
        ]
        + browser(800, parent: 720, flags: [
            "--disable-field-trial-config", "--enable-automation", "--remote-debugging-pipe",
            "--user-data-dir=/var/folders/x1/abc/T/playwright_chromiumdev_profile-Qk3z", "about:blank",
        ], start: 2_000)
    let found = detect(list)

    #expect(found.count == 2)
    #expect(found.map(\.kind) == [.mine, .automated])
    #expect(found[0].launchedBy == "You (Dock/Finder)")
    let automated = found[1]
    #expect(automated.pid == 800)
    #expect(automated.launchedBy == "Playwright CLI · session demo-1a2b3c4-live")
    #expect(automated.automationSignals.contains("--remote-debugging-pipe"))
    #expect(automated.automationSignals.contains("--enable-automation"))
    #expect(automated.automationSignals.contains { $0.hasPrefix("temporary --user-data-dir") })
    #expect(automated.launcherChain.map(\.pid) == [720, 710, 700])
    #expect(automated.helpers.map(\.pid) == [801, 802, 803])
    #expect(automated.memoryFootprint == 130 * mb)
}

@Test func headlessPuppeteerChrome() {
    // Terminal → login → zsh → node scrape.js → chrome-headless-shell from Puppeteer's cache.
    let shellPath = "/Users/me/.cache/puppeteer/chrome-headless-shell/mac_arm-131.0.6778.204/chrome-headless-shell-mac-arm64/chrome-headless-shell"
    let list = [
        proc(300, 1, ["/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"]),
        proc(310, 300, ["login", "-pf", "me"], path: "/usr/bin/login"),
        proc(320, 310, ["-zsh"], path: "/bin/zsh"),
        proc(330, 320, ["node", "scrape.js"], path: "/opt/homebrew/bin/node"),
    ] + browser(400, parent: 330, path: shellPath, flags: [
        "--headless=new", "--remote-debugging-port=0",
        "--user-data-dir=/var/folders/x1/abc/T/puppeteer_dev_chrome_profile-7hQ2",
    ])
    let found = detect(list)

    #expect(found.count == 1)
    let headless = try! #require(found.first)
    #expect(headless.kind == .automated)
    #expect(headless.flavor == .headlessShell)
    #expect(headless.launchedBy == "Puppeteer")
    #expect(headless.automationSignals.contains("--headless=new"))
    #expect(headless.helpers.count == 3)
}

@Test func playwrightMCPChrome() {
    // Claude Code → npx @playwright/mcp → Chrome with a persistent (non-temp) profile.
    let list = [
        proc(700, 1, [claudeCodePath]),
        proc(750, 700, ["node", "/Users/me/.npm/_npx/9f8e/node_modules/.bin/playwright-mcp"], path: "/opt/homebrew/bin/node"),
    ] + browser(900, parent: 750, flags: [
        "--remote-debugging-pipe", "--no-first-run",
        "--user-data-dir=/Users/me/Library/Caches/ms-playwright/mcp-chrome-profile",
    ])
    let found = detect(list)

    #expect(found.count == 1)
    #expect(found[0].kind == .automated)
    #expect(found[0].launchedBy == "Playwright MCP")
    #expect(found[0].automationSignals == ["--remote-debugging-pipe"])
}

@Test func orphanedDaemonReparentedToLaunchd() {
    // The real incident: the cliDaemon node process was re-parented to PID 1.
    let list = [
        proc(720, 1, [
            "node",
            "/Users/me/.npm/_npx/0a1b2c/node_modules/playwright-core/lib/entry/cliDaemon.js",
            "demo-1a2b3c4-live", "--headed", "--browser=chrome",
        ], path: "/opt/homebrew/bin/node"),
    ] + browser(800, parent: 720, flags: ["--remote-debugging-pipe", "--user-data-dir=/tmp/pw-profile"])
    let found = detect(list)
    let now = Date(timeIntervalSince1970: 1_000 + 7 * 86_400)

    #expect(found.count == 1)
    #expect(found[0].kind == .automated)
    #expect(found[0].launchedBy == "Playwright CLI · session demo-1a2b3c4-live")
    #expect(found[0].launcherChain.map(\.pid) == [720])
    #expect(found[0].isStale(now: now))
    #expect(Format.uptime(found[0].uptime(now: now)) == "7d 0h")
    #expect(Format.details(found[0], now: now).contains("pid 1  launchd"))
}

// MARK: Edge cases

@Test func automatedChromeWhoseParentExited() {
    let found = detect(browser(800, parent: 1, flags: ["--remote-debugging-port=9333"]))
    #expect(found[0].kind == .automated)
    #expect(found[0].launchedBy == "Unknown (parent exited)")
}

@Test func chromeLaunchedByClaudeCodeShell() {
    // What the live check does: a Bash tool shell inside Claude Code starts Chrome.
    let list = [
        proc(700, 1, [claudeCodePath]),
        proc(710, 700, ["/bin/zsh", "-c", "chrome &"]),
    ] + browser(800, parent: 710, flags: ["--user-data-dir=/var/folders/x1/T/tmp.abc", "--remote-debugging-port=9333", "about:blank"])
    let found = detect(list)
    #expect(found[0].kind == .automated)
    #expect(found[0].launchedBy == "Claude Code")
}

@Test func codexLaunchedChrome() {
    let list = [
        proc(600, 1, ["node", "/opt/homebrew/lib/node_modules/@openai/codex/bin/codex.js"], path: "/opt/homebrew/bin/node"),
        proc(610, 600, ["/bin/bash", "-lc", "python3 shot.py"]),
        proc(620, 610, ["python3", "shot.py"], path: "/usr/bin/python3"),
    ] + browser(800, parent: 620, flags: ["--headless", "--remote-debugging-port=9222"])
    #expect(detect(list)[0].launchedBy == "Codex")
}

@Test func terminalCommandLaunchedChrome() {
    let list = [
        proc(300, 1, ["/Applications/iTerm.app/Contents/MacOS/iTerm2"]),
        proc(320, 300, ["-zsh"], path: "/bin/zsh"),
        proc(330, 320, ["python3", "/Users/me/bin/drive.py", "--fast"], path: "/usr/bin/python3"),
    ] + browser(800, parent: 330, flags: ["--remote-debugging-port=9222"])
    #expect(detect(list)[0].launchedBy == "Terminal: python3 drive.py --fast")
}

@Test func myChromeFromTerminal() {
    let list = [
        proc(300, 1, ["/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"]),
        proc(320, 300, ["-zsh"], path: "/bin/zsh"),
    ] + browser(800, parent: 320)
    let found = detect(list)
    #expect(found[0].kind == .mine)
    #expect(found[0].launchedBy == "Terminal: Google Chrome")
}

@Test func chromeForTestingAndChromiumAreAlwaysAutomated() {
    let cft = "/Users/me/Library/Caches/ms-playwright/chromium-1200/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"
    let chromium = "/Users/me/Library/Caches/ms-playwright/chromium-1100/chrome-mac/Chromium.app/Contents/MacOS/Chromium"
    let found = detect(browser(800, parent: 1, path: cft) + browser(900, parent: 1, path: chromium))
    #expect(found.map(\.flavor) == [.chromeForTesting, .chromium])
    #expect(found.allSatisfy { $0.kind == .automated })
    #expect(found.allSatisfy { $0.launchedBy == "Playwright" })
}

@Test func helpersAreNeverMainProcesses() {
    #expect(!ChromeDetector.isMainProcess(proc(1, 1, [chromePath, "--type=renderer"])))
    #expect(!ChromeDetector.isMainProcess(proc(1, 1, [rendererPath, "--type=renderer"])))
    #expect(!ChromeDetector.isMainProcess(proc(1, 1, ["/Applications/Helium.app/Contents/MacOS/Helium"])))
    #expect(ChromeDetector.isMainProcess(proc(1, 1, [chromePath])))
}

@Test func zombieMainIsIgnored() {
    var list = browser(800, parent: 720)
    list[0].isZombie = true
    #expect(detect(list).isEmpty)
}

@Test func freshAutomatedChromeIsNotStale() {
    let found = detect(browser(800, parent: 1, flags: ["--enable-automation"], start: 1_000))
    #expect(!found[0].isStale(now: Date(timeIntervalSince1970: 1_000 + 23 * 3600)))
    #expect(found[0].isStale(now: Date(timeIntervalSince1970: 1_000 + 25 * 3600)))
}

@Test func formatting() {
    #expect(Format.uptime(6 * 86_400 + 22 * 3600 + 5 * 60) == "6d 22h")
    #expect(Format.uptime(3 * 3600 + 12 * 60) == "3h 12m")
    #expect(Format.uptime(4 * 60 + 59) == "4m")
    #expect(Format.uptime(30) == "<1m")
    #expect(Format.memory(130 * mb) == "130.0 MB")
    #expect(Format.memory(1_288_490_189) == "1.20 GB")
    #expect(Format.shellQuote("--user-data-dir=/tmp/x") == "--user-data-dir=/tmp/x")
    #expect(Format.shellQuote("/Applications/Google Chrome.app") == "'/Applications/Google Chrome.app'")
}

@Test func parsesProcArgs2Layout() {
    var bytes: [UInt8] = [3, 0, 0, 0]
    bytes += Array("/bin/exe".utf8) + [0, 0, 0, 0]
    for arg in ["exe", "--flag", "a b"] { bytes += Array(arg.utf8) + [0] }
    bytes += Array("HOME=/Users/me".utf8) + [0]
    #expect(SystemProcessReader.parseProcArgs(bytes[...]) == ["exe", "--flag", "a b"])
}
