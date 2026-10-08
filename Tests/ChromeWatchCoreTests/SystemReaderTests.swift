import Darwin
import Foundation
import Testing
@testable import ChromeWatchCore

/// Reads this test process itself through the native APIs.
@Test func readsOwnProcessNatively() throws {
    let table = SystemProcessReader().snapshot()
    let me = try #require(table[getpid()])
    #expect(me.ppid == getppid())
    #expect(me.uid == getuid())
    #expect(me.executablePath?.isEmpty == false)
    #expect(me.arguments == CommandLine.arguments)
    #expect(abs(me.startDate.timeIntervalSinceNow) < 3600)

    let footprint = try #require(SystemProcessReader.physicalFootprint(pid: getpid()))
    #expect(footprint > 1_000_000)

    let bsd = try #require(SystemProcessReader.bsdInfo(pid: getpid()))
    #expect(bsd.ppid == getppid())
    #expect(bsd.startSeconds == me.startSeconds && bsd.startMicroseconds == me.startMicroseconds)
}

@Test func identityCheckRejectsReusedStartTime() {
    let me = ProcessRecord(pid: getpid(), ppid: getppid(), executablePath: "/x", arguments: [])
    let bsd = SystemProcessReader.bsdInfo(pid: getpid())!
    var record = me
    record.startSeconds = bsd.startSeconds
    record.startMicroseconds = bsd.startMicroseconds
    let instance = ChromeInstance(main: record, flavor: .chrome, kind: .automated, automationSignals: [],
                                  launchedBy: "", launcherChain: [], helpers: [], memoryFootprint: 0)
    #expect(ProcessControl.isAlive(ProcessIdentity(instance)))
    // Not a Chrome main process, so it must never be signalled.
    #expect(!ProcessControl.isSameBrowserMain(ProcessIdentity(instance)))

    record.startMicroseconds += 1
    let other = ChromeInstance(main: record, flavor: .chrome, kind: .automated, automationSignals: [],
                               launchedBy: "", launcherChain: [], helpers: [], memoryFootprint: 0)
    #expect(!ProcessControl.isAlive(ProcessIdentity(other)))
}
