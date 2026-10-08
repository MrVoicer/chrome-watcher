import AppKit
import ChromeWatchCore
import SwiftUI

struct MenuBarLabel: View {
    @ObservedObject var status: MenuBarStatus

    var body: some View {
        let stale = status.hasStaleAutomated
        HStack(spacing: 3) {
            Image(nsImage: Self.icon(stale: stale))
            Text("\(status.count)")
        }
        .accessibilityLabel("\(status.count) Chrome instances\(stale ? ", one automated for over 24 hours" : "")")
    }

    /// Template image normally; orange (non-template, so the menu bar keeps the colour) when stale.
    static func icon(stale: Bool) -> NSImage {
        let base = NSImage(systemSymbolName: "circle.inset.filled", accessibilityDescription: "Chrome instances") ?? NSImage()
        guard stale else {
            base.isTemplate = true
            return base
        }
        let tinted = base.withSymbolConfiguration(.init(paletteColors: [.systemOrange])) ?? base
        tinted.isTemplate = false
        return tinted
    }
}

struct MenuContentView: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject var loginItem: LoginItem

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if monitor.instances.isEmpty {
                Text("No Chrome running.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(monitor.instances) { instance in
                            InstanceRow(instance: instance, now: monitor.lastRefresh, monitor: monitor)
                            if instance.id != monitor.instances.last?.id { Divider().padding(.leading, 12) }
                        }
                    }
                }
                .frame(maxHeight: 420)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let notice = monitor.notice {
                Divider()
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            Divider()
            footer
        }
        .frame(width: 440)
        .onAppear {
            monitor.isPanelVisible = true
            loginItem.reload()
        }
        .onDisappear { monitor.isPanelVisible = false }
    }

    private var header: some View {
        let total = monitor.instances.reduce(UInt64(0)) { $0 + $1.memoryFootprint }
        return HStack {
            Text("Chrome instances").font(.headline)
            Spacer()
            Text("\(monitor.instances.count) · \(Format.memory(total))")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Refresh every", selection: $monitor.interval) {
                    ForEach(Monitor.intervalChoices, id: \.self) { seconds in
                        Text("\(Int(seconds)) s").tag(seconds)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .focusable(false)
                Spacer()
                Toggle("Launch at login", isOn: Binding(get: { loginItem.isEnabled }, set: { loginItem.set($0) }))
                    .toggleStyle(.checkbox)
                    .focusable(false)
            }
            if let message = loginItem.message {
                Button(message) { loginItem.openSettings() }
                    .buttonStyle(.link)
                    .font(.caption)
                    .focusable(false)
            }
            HStack {
                Button {
                    monitor.openMyChrome()
                } label: {
                    Label("Open my Chrome", systemImage: "plus.app")
                }
                .help("Runs open -n -a \"Google Chrome\"")
                .focusable(false)
                Spacer()
                Button("Quit ChromeWatch") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
                    .focusable(false)
            }
        }
        .padding(12)
    }
}

struct InstanceRow: View {
    let instance: ChromeInstance
    let now: Date
    @ObservedObject var monitor: Monitor

    var body: some View {
        let stale = instance.isStale(now: now)
        let busy = monitor.quitting.contains(instance.id)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(instance.kind.rawValue)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(badgeColor.opacity(0.18), in: Capsule())
                    .foregroundStyle(badgeColor)
                Text(instance.launchedBy)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(instance.launchedBy)
            }
            HStack(spacing: 10) {
                Label(Format.memory(instance.memoryFootprint), systemImage: "memorychip")
                    .help("Physical footprint of \(instance.processCount) processes (main + helpers)")
                Label(Format.uptime(instance.uptime(now: now)), systemImage: "clock")
                    .foregroundStyle(stale ? Color.orange : Color.secondary)
                Text("PID \(String(instance.pid))")
                    .foregroundStyle(.secondary)
                Spacer()
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Copy details") { monitor.copyDetails(instance) }
                        .focusable(false)
                    Button("Quit") { monitor.quit(instance) }
                        .accessibilityLabel("Quit PID \(instance.pid)")
                        .focusable(false)
                }
            }
            .font(.caption.monospacedDigit())
            .labelStyle(.titleAndIcon)
            .controlSize(.small)
            if instance.flavor != .chrome {
                Text(instance.flavor.rawValue).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var badgeColor: Color { instance.kind == .mine ? .blue : .purple }
}
