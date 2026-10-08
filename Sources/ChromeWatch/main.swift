import AppKit
import ChromeWatchCore
import ServiceManagement
import SwiftUI

struct ChromeWatchApp: App {
    @StateObject private var monitor = Monitor()
    @StateObject private var loginItem = LoginItem()

    init() {
        // No Dock icon even when run outside the bundle (the bundle also sets LSUIElement).
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(monitor: monitor, loginItem: loginItem)
        } label: {
            MenuBarLabel(status: monitor.status)
        }
        .menuBarExtraStyle(.window)
    }
}

/// `ChromeWatch --list` prints what the menu would show, then exits. Same detection code.
if CommandLine.arguments.contains("--list") {
    let instances = ChromeDetector.detect(in: SystemProcessReader().snapshot(), footprint: SystemProcessReader.physicalFootprint(pid:))
    let now = Date()
    for instance in instances {
        let stale = instance.isStale(now: now) ? "  [stale]" : ""
        print("\(instance.kind.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0)) pid \(instance.pid)  \(Format.memory(instance.memoryFootprint)) (\(instance.processCount) procs)  up \(Format.uptime(instance.uptime(now: now)))  — \(instance.launchedBy)\(stale)")
        if CommandLine.arguments.contains("--details") {
            print(Format.details(instance, now: now).split(separator: "\n").map { "    " + $0 }.joined(separator: "\n"))
        }
    }
    if instances.isEmpty { print("No Chrome running.") }
    exit(0)
}

/// `ChromeWatch --quit <pid>`: the row's Quit action, for automated instances only.
if let flag = CommandLine.arguments.firstIndex(of: "--quit") {
    guard flag + 1 < CommandLine.arguments.count, let pid = Int32(CommandLine.arguments[flag + 1]) else {
        print("usage: ChromeWatch --quit <pid>")
        exit(2)
    }
    let instances = ChromeDetector.detect(in: SystemProcessReader().snapshot(), footprint: { _ in nil })
    guard let instance = instances.first(where: { $0.pid == pid }) else {
        print("PID \(pid) is not a running Chrome main process. Nothing sent.")
        exit(1)
    }
    guard instance.kind == .automated else {
        print("PID \(pid) is My Chrome. Quit it from the menu, which asks for confirmation.")
        exit(1)
    }
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
        let outcome = await ProcessControl.terminate(ProcessIdentity(instance))
        print("PID \(pid): \(outcome)")
        semaphore.signal()
    }
    semaphore.wait()
    exit(0)
}

/// `ChromeWatch --launch-at-login on|off|status`: the menu's "Launch at login" checkbox.
/// Registers the bundle this binary runs from, so run it from the installed copy.
if let flag = CommandLine.arguments.firstIndex(of: "--launch-at-login") {
    let service = SMAppService.mainApp
    let action = flag + 1 < CommandLine.arguments.count ? CommandLine.arguments[flag + 1] : "status"
    do {
        switch action {
        case "on": try service.register()
        case "off": try service.unregister()
        case "status": break
        default:
            print("usage: ChromeWatch --launch-at-login on|off|status")
            exit(2)
        }
    } catch {
        print("Failed: \(error.localizedDescription)")
        exit(1)
    }
    let names: [SMAppService.Status: String] = [
        .enabled: "enabled", .notRegistered: "not registered",
        .requiresApproval: "requires approval in System Settings › General › Login Items", .notFound: "not found",
    ]
    print("\(Bundle.main.bundlePath): \(names[service.status] ?? "unknown")")
    exit(0)
}

ChromeWatchApp.main()
