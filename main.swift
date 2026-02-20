// main.swift
// MouseRemap — Remap mouse side buttons (Back/Forward) to ⌘+[ and ⌘+]
//
// Build:  swiftc main.swift -o MouseRemap
//
// Usage:
//   ./MouseRemap              Run the remapper (foreground)
//   ./MouseRemap -v           Run with verbose logging
//   ./MouseRemap --install    Install as a background service (launchd)
//   ./MouseRemap --uninstall  Remove the background service
//   ./MouseRemap --help       Show usage information
//
// Requires Accessibility permission:
//   System Settings → Privacy & Security → Accessibility

import Foundation
import CoreGraphics
import ApplicationServices  // AXIsProcessTrusted()

// MARK: - Constants

/// Virtual key codes (US ANSI keyboard layout).
let kKeyCodeLeftBracket:  CGKeyCode = 33   // '['
let kKeyCodeRightBracket: CGKeyCode = 30   // ']'

/// launchd service configuration.
let kServiceLabel = "com.user.mouseremap"
let kInstallPath  = (NSString("~/.local/bin/MouseRemap").expandingTildeInPath)
let kPlistPath    = (NSString("~/Library/LaunchAgents/com.user.mouseremap.plist")
                        .expandingTildeInPath)

// MARK: - CLI Argument Parsing

let gVerbose: Bool = CommandLine.arguments.contains("-v")
                   || CommandLine.arguments.contains("--verbose")

// MARK: - Install / Uninstall / Help Handlers

// FIX: [MEDIUM] Log paths moved from /tmp to ~/Library/Logs/.
// /tmp is world-writable — an attacker could place a symlink at
// /tmp/mouseremap.err.log pointing to a sensitive file (e.g. ~/.zshrc),
// causing the launchd service to overwrite it on startup.
// ~/Library/Logs/ is user-owned and not world-writable.
let kLogDir = (NSString("~/Library/Logs").expandingTildeInPath)
let kStdoutLog = "\(kLogDir)/mouseremap.out.log"
let kStderrLog = "\(kLogDir)/mouseremap.err.log"

/// Generate the LaunchAgent plist XML content.
func launchAgentPlist() -> String {
    return """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
      "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>Label</key>
        <string>\(kServiceLabel)</string>

        <key>ProgramArguments</key>
        <array>
            <string>\(kInstallPath)</string>
        </array>

        <key>RunAtLoad</key>
        <true/>

        <key>KeepAlive</key>
        <true/>

        <key>StandardErrorPath</key>
        <string>\(kStderrLog)</string>

        <key>StandardOutPath</key>
        <string>\(kStdoutLog)</string>
    </dict>
    </plist>
    """
}

// FIX: [HIGH] Removed shell() function that used string interpolation to
// build shell commands. Passing user-controlled strings (e.g. binaryPath
// from argv[0]) through "/bin/sh -c" creates a command injection vector:
// a malicious binary path containing shell metacharacters (;, |, $(), etc.)
// could execute arbitrary commands, especially dangerous under sudo.
// Replaced with runProcess() that calls executables directly with argument
// arrays, completely bypassing shell interpretation.

/// Run a process directly (no shell). Returns (exitCode, stdout+stderr).
@discardableResult
func runProcess(_ executable: String, _ arguments: [String] = []) -> (Int32, String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError  = pipe

    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return (1, "Failed to run \(executable): \(error.localizedDescription)")
    }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""
    return (process.terminationStatus, output)
}

/// Resolve the path of the currently running binary to an absolute path.
func currentBinaryPath() -> String {
    let arg0 = CommandLine.arguments[0]

    // If arg0 is already absolute, use it directly.
    if arg0.hasPrefix("/") {
        return arg0
    }

    // Otherwise, resolve relative to the current working directory.
    let cwd = FileManager.default.currentDirectoryPath
    let resolved = (cwd as NSString).appendingPathComponent(arg0)
    return (resolved as NSString).standardizingPath
}

/// Install MouseRemap as a launchd background service.
func performInstall() {
    print("📦 Installing MouseRemap as a background service...\n")

    let binaryPath = currentBinaryPath()
    let fm = FileManager.default

    // Verify source binary actually exists
    guard fm.fileExists(atPath: binaryPath) else {
        fputs("❌ Source binary not found at: \(binaryPath)\n", stderr)
        exit(1)
    }

    // Step 1: Copy binary to /usr/local/bin
    print("1️⃣  Copying binary to \(kInstallPath)...")

    // Ensure /usr/local/bin exists (use FileManager, not shell)
    let installDir = (kInstallPath as NSString).deletingLastPathComponent
    if !fm.fileExists(atPath: installDir) {
        do {
            try fm.createDirectory(atPath: installDir, withIntermediateDirectories: true)
        } catch {
            fputs("❌ Failed to create \(installDir): \(error.localizedDescription)\n", stderr)
            fputs("\n💡 Check directory permissions and try again.\n", stderr)
            exit(1)
        }
    }

    // Copy binary (use FileManager, not shell cp)
    do {
        if fm.fileExists(atPath: kInstallPath) {
            try fm.removeItem(atPath: kInstallPath)
        }
        try fm.copyItem(atPath: binaryPath, toPath: kInstallPath)
    } catch {
        fputs("❌ Failed to copy binary: \(error.localizedDescription)\n", stderr)
        fputs("\n💡 Check directory permissions and try again.\n", stderr)
        exit(1)
    }

    // Set executable permission (use chmod directly, no shell)
    let (chmodCode, chmodOut) = runProcess("/bin/chmod", ["+x", kInstallPath])
    if chmodCode != 0 {
        fputs("⚠️  chmod +x failed: \(chmodOut)", stderr)
    }
    print("   ✅ Binary installed at \(kInstallPath)")

    // Step 2: Ensure log directory exists
    if !fm.fileExists(atPath: kLogDir) {
        do {
            try fm.createDirectory(atPath: kLogDir, withIntermediateDirectories: true)
        } catch {
            fputs("⚠️  Could not create log directory \(kLogDir): \(error.localizedDescription)\n", stderr)
        }
    }

    // Step 3: Create LaunchAgent plist
    print("2️⃣  Creating LaunchAgent plist...")

    let plistDir = (kPlistPath as NSString).deletingLastPathComponent
    if !fm.fileExists(atPath: plistDir) {
        do {
            try fm.createDirectory(atPath: plistDir, withIntermediateDirectories: true)
        } catch {
            fputs("❌ Failed to create \(plistDir): \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    do {
        try launchAgentPlist().write(toFile: kPlistPath, atomically: true, encoding: .utf8)
    } catch {
        fputs("❌ Failed to write plist: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
    print("   ✅ Plist created at \(kPlistPath)")

    // Step 4: Unload if already loaded (ignore errors), then load
    print("3️⃣  Loading service via launchctl...")
    runProcess("/bin/launchctl", ["unload", kPlistPath])

    let (loadCode, loadOut) = runProcess("/bin/launchctl", ["load", kPlistPath])
    if loadCode != 0 {
        fputs("⚠️  launchctl load returned an error:\n\(loadOut)", stderr)
        fputs("   The plist was still created — you can load it manually:\n", stderr)
        fputs("   launchctl load \"\(kPlistPath)\"\n", stderr)
    } else {
        print("   ✅ Service loaded and running")
    }

    print("""

    ✅ Installation complete!

    ⚠️  Don't forget to grant Accessibility permission:
       System Settings → Privacy & Security → Accessibility
       Add: \(kInstallPath)

    Useful commands:
       Check status:  launchctl list | grep mouseremap
       View logs:     cat \(kStdoutLog)
                      cat \(kStderrLog)
       Uninstall:     ./MouseRemap --uninstall
    """)
    exit(0)
}

/// Uninstall MouseRemap background service.
func performUninstall() {
    print("🗑  Uninstalling MouseRemap background service...\n")

    let fm = FileManager.default

    // Step 1: Unload the service (use direct args, no shell)
    print("1️⃣  Unloading service via launchctl...")
    if fm.fileExists(atPath: kPlistPath) {
        let (code, out) = runProcess("/bin/launchctl", ["unload", kPlistPath])
        if code != 0 {
            fputs("⚠️  launchctl unload: \(out)", stderr)
        } else {
            print("   ✅ Service unloaded")
        }
    } else {
        print("   ⏭  Plist not found, skipping launchctl unload")
    }

    // Step 2: Remove plist (use FileManager, no shell)
    print("2️⃣  Removing plist...")
    if fm.fileExists(atPath: kPlistPath) {
        do {
            try fm.removeItem(atPath: kPlistPath)
            print("   ✅ Removed \(kPlistPath)")
        } catch {
            fputs("❌ Failed to remove plist: \(error.localizedDescription)\n", stderr)
        }
    } else {
        print("   ⏭  Plist not found, skipping")
    }

    // Step 3: Remove binary (use FileManager, no shell)
    print("3️⃣  Removing binary...")
    if fm.fileExists(atPath: kInstallPath) {
        do {
            try fm.removeItem(atPath: kInstallPath)
            print("   ✅ Removed \(kInstallPath)")
        } catch {
            fputs("❌ Failed to remove binary: \(error.localizedDescription)\n", stderr)
            fputs("💡 Check file permissions and try again.\n", stderr)
        }
    } else {
        print("   ⏭  Binary not found at \(kInstallPath), skipping")
    }

    print("\n✅ Uninstall complete.")
    exit(0)
}

/// Print usage information.
func printHelp() {
    print("""
    MouseRemap — Remap mouse side buttons to ⌘+[ / ⌘+]

    USAGE:
      MouseRemap [OPTIONS]

    OPTIONS:
      (none)          Run the remapper in the foreground
      -v, --verbose   Enable verbose logging to stderr
      --install       Install as a launchd background service
      --uninstall     Remove the launchd background service
      --help          Show this help message

    BACKGROUND SERVICE:
      --install copies the binary to \(kInstallPath),
      creates a LaunchAgent plist, and loads it via launchctl.
      The service will start automatically on login.

      --uninstall reverses all of the above.

    ACCESSIBILITY:
      This tool requires Accessibility permission.
      System Settings → Privacy & Security → Accessibility
    """)
    exit(0)
}

// MARK: - Handle CLI subcommands (before any event-tap work)

if CommandLine.arguments.contains("--help") {
    printHelp()
}

if CommandLine.arguments.contains("--install") {
    performInstall()
}

if CommandLine.arguments.contains("--uninstall") {
    performUninstall()
}

// MARK: - Event Tap Mode (default)

var gEventTap: CFMachPort?

// Check Accessibility permission.
guard AXIsProcessTrusted() else {
    fputs("""
    ⚠️  Accessibility permission is required.

    Grant permission to this binary in:
      System Settings → Privacy & Security → Accessibility

    Steps (macOS 14 Sonoma and later):
      1. Open System Settings.
      2. Navigate to Privacy & Security → Accessibility.
      3. Click the "+" button.
      4. Locate and add this binary (MouseRemap), or add Terminal.app
         / iTerm.app if you are running from a terminal emulator.
      5. Toggle the switch ON.
      6. Re-run this tool.

    """, stderr)
    exit(1)
}

// MARK: - Event-tap callback

func eventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {

    // ── Tap disabled by the system ──────────────────────────────────────

    // FIX: [HIGH] tapDisabledByUserInput — do NOT re-enable.
    if type == .tapDisabledByUserInput {
        if gVerbose {
            fputs("🔒 Tap disabled by Secure Input — respecting OS boundary.\n", stderr)
        }
        return Unmanaged.passRetained(event)
    }

    if type == .tapDisabledByTimeout {
        if let tap = gEventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
            if gVerbose {
                fputs("⏎  Event tap re-enabled after timeout.\n", stderr)
            }
        }
        return Unmanaged.passRetained(event)
    }

    // ── Only process otherMouseDown / otherMouseUp ──────────────────────
    guard type == .otherMouseDown || type == .otherMouseUp else {
        return Unmanaged.passRetained(event)
    }

    let buttonNumber = event.getIntegerValueField(.mouseEventButtonNumber)

    let keyCode: CGKeyCode
    switch buttonNumber {
    case 3:   // Mouse button 4 (Back)
        keyCode = kKeyCodeLeftBracket    // ⌘+[
    case 4:   // Mouse button 5 (Forward)
        keyCode = kKeyCodeRightBracket   // ⌘+]
    default:
        return Unmanaged.passRetained(event)
    }

    let keyDown = (type == .otherMouseDown)

    // ── Synthesize keyboard event ───────────────────────────────────────

    // FIX: [MEDIUM] Use .combinedSessionState instead of nil source.
    let eventSource = CGEventSource(stateID: .combinedSessionState)

    guard let keyEvent = CGEvent(keyboardEventSource: eventSource,
                                  virtualKey: keyCode,
                                  keyDown: keyDown) else {
        fputs("⚠️  Failed to create synthetic keyboard event.\n", stderr)
        return Unmanaged.passRetained(event)
    }

    // FIX: [MEDIUM] Preserve real hardware modifiers, union with ⌘.
    let currentFlags = CGEventSource.flagsState(.combinedSessionState)
    keyEvent.flags = currentFlags.union(.maskCommand)

    keyEvent.post(tap: .cghidEventTap)

    if gVerbose && keyDown {
        let symbol = (buttonNumber == 3) ? "⌘+[" : "⌘+]"
        fputs("🖱  Button \(buttonNumber + 1) → \(symbol)\n", stderr)
    }

    return nil
}

// MARK: - Create the event tap

let eventMask: CGEventMask =
    (1 << CGEventType.otherMouseDown.rawValue) |
    (1 << CGEventType.otherMouseUp.rawValue)

guard let eventTap = CGEvent.tapCreate(
    tap: .cghidEventTap,
    place: .headInsertEventTap,
    options: .defaultTap,
    eventsOfInterest: eventMask,
    callback: eventTapCallback,
    userInfo: nil
) else {
    fputs("""
    ❌ Failed to create event tap.

    Possible causes:
    • Accessibility permission not granted (check System Settings).
    • Running as root — run as your normal user instead.
    • Another process holds a conflicting tap.

    """, stderr)
    exit(1)
}

gEventTap = eventTap

// Add to run loop.
guard let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0) else {
    fputs("❌ Failed to create run loop source from event tap.\n", stderr)
    exit(1)
}

CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
CGEvent.tapEnable(tap: eventTap, enable: true)

// MARK: - Graceful shutdown

func installSignalHandlers() {
    let handler: @convention(c) (Int32) -> Void = { sig in
        if let tap = gEventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        fputs("\n🛑 MouseRemap stopped (signal \(sig)).\n", stderr)
        _Exit(0)
    }

    signal(SIGINT,  handler)
    signal(SIGTERM, handler)
}

installSignalHandlers()

// MARK: - Run

print("✅ MouseRemap is running.")
print("   Button 4 (Back)    → ⌘+[  (Command + Left Bracket)")
print("   Button 5 (Forward) → ⌘+]  (Command + Right Bracket)")
if gVerbose {
    print("   Verbose mode ON (logging button presses to stderr).")
}
print("   Press Ctrl+C to stop.\n")

CFRunLoopRun()
