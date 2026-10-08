# ChromeWatch

A macOS menu bar app that lists every running Google Chrome instance, says whether it is
yours or automated (Playwright, Puppeteer, MCP browser servers, coding agents), shows
who launched it and how much RAM it uses, and lets you quit stale ones.

The menu bar shows `◉ N`, the number of Chrome instances. The icon turns orange when an
automated instance has been running for more than 24 hours.

## Requirements

- macOS 14 or later
- Swift 6 toolchain. The Command Line Tools are enough; Xcode is not required.

## Build

```bash
scripts/build-app.sh
```

This builds a release binary and wraps it in `build/ChromeWatch.app` (ad-hoc signed,
`LSUIElement`, so no Dock icon).

## Run

```bash
open build/ChromeWatch.app
```

For "Launch at login", install it first:

```bash
cp -R build/ChromeWatch.app /Applications/
```

```bash
open /Applications/ChromeWatch.app
```

The same binary has two command-line modes:

```bash
build/ChromeWatch.app/Contents/MacOS/ChromeWatch --list --details
```

`--list` prints what the menu would show. `--quit <pid>` runs the row's Quit action on an
automated instance. It refuses "My Chrome", which you can only quit from the menu after a
confirmation.

## Launch at login

1. Copy `ChromeWatch.app` to `/Applications` and open it from there.
2. Open the menu and tick **Launch at login**. This uses `SMAppService.mainApp`.
3. If macOS asks for approval, click the hint shown under the checkbox. It opens
   System Settings › General › Login Items, where you allow ChromeWatch.

Once enabled, ChromeWatch appears under "Open at Login" in System Settings › General ›
Login Items. Unticking the checkbox removes it.

The same switch is available from the command line. Run it from the installed copy,
because it registers the bundle the binary runs from:

```bash
/Applications/ChromeWatch.app/Contents/MacOS/ChromeWatch --launch-at-login on
```

`off` and `status` work the same way. After you rebuild and copy a new version over the
installed app, run `--launch-at-login status` and re-enable it if it is no longer
"enabled".

## Test

```bash
scripts/test.sh
```

The tests use swift-testing. The script adds the macro plugin path the Command Line Tools
need. With Xcode installed, a plain `swift test` works too.

The detection tests run on canned process tables:

- your Chrome alone
- your Chrome plus a Playwright CLI Chrome
- a headless Puppeteer Chrome
- a Playwright MCP Chrome
- an orphaned `cliDaemon.js` re-parented to PID 1
- Chrome launched by Codex, by a Claude Code shell, or from a terminal
- Chrome for Testing and Chromium builds
- zombie processes and the stale threshold

Two tests also read the live process table through the native APIs.

## How it works

- **Process list:** one `sysctl(KERN_PROC_ALL)` per refresh gives the PID, parent PID,
  UID, start time and state of every process.
- **Command lines:** `KERN_PROCARGS2` and `proc_pidpath` give each process's arguments and
  executable path. They are read only for your own processes, and cached by
  (PID, start time), so steady-state polling reads only new processes.
- **RAM:** `proc_pid_rusage(...).ri_phys_footprint`. This is the "Memory" figure Activity
  Monitor shows. A row adds up the main process and its helpers (renderer, GPU, utility),
  meaning descendants whose executable lives inside the same browser bundle. Other
  programs Chrome starts, such as native-messaging hosts, are not counted.
- **Main process:** a `Google Chrome` (or Chrome for Testing, Chromium, or headless shell)
  executable started without a `--type=` argument.
- **Automated:** any of `--remote-debugging-pipe`, `--remote-debugging-port`,
  `--enable-automation`, `--headless`, or a `--user-data-dir` under `/var/folders` or
  `/tmp`. Chrome for Testing, Chromium, headless shell, and builds from the Playwright or
  Puppeteer caches always count as automated.
- **Launched by:** the app walks up from Chrome's parent, nearest first, and stops at the
  first match:
  1. A known tool: `cliDaemon.js <session>` (Playwright CLI), Playwright MCP, Puppeteer, Playwright.
  2. Tool hints in Chrome's own arguments, such as a Puppeteer profile directory.
  3. A host: Codex, Claude Code, or a terminal app, shown as "Terminal: <command>".
  4. Parent PID 1: "You (Dock/Finder)" for your Chrome, "Unknown (parent exited)" for an
     automated one.
- **Quit:** sends SIGTERM to that exact PID, waits up to 5 s, then sends SIGKILL if the
  process is still there. Before each signal it re-checks with `proc_pidinfo`,
  `proc_pidpath` and `KERN_PROCARGS2` that the PID is still the same process (same start
  time to the microsecond, not a zombie) and still a Chrome main process. It never uses
  `pkill` or `killall`.
- **Polling:** a `DispatchSourceTimer` with leeway, every 5 s by default (2–60 s can be
  chosen in the menu). Row data is published only while the panel is open. The menu bar
  label re-renders only when the count or the stale tint changes.
- **No App Sandbox:** the app has to read other processes' arguments. Your own processes
  need no root.

## Why "Open my Chrome" uses `open -n`

While an automated Chrome is running, macOS treats Chrome as already open. Clicking the
Dock icon raises that hidden copy. `open -n -a "Google Chrome"` starts a new instance
instead. If your own Chrome is already running, the new process hands off to it.

## License

MIT. See [LICENSE](LICENSE).
