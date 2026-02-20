// main.swift
// MouseRemap — Remap mouse side buttons (Back/Forward) to ⌘+[ and ⌘+]
//
// Build:  swiftc main.swift -o MouseRemap
// Run:    ./MouseRemap          (silent mode, default)
//         ./MouseRemap -v       (verbose — log button presses to stderr)
//
// Requires Accessibility permission:
//   System Settings → Privacy & Security → Accessibility
//   Add the compiled binary (or Terminal.app if running from terminal).

import Foundation
import CoreGraphics
import ApplicationServices  // AXIsProcessTrusted()

// MARK: - Configuration

/// Virtual key codes (US ANSI keyboard layout).
let kKeyCodeLeftBracket:  CGKeyCode = 33   // '['
let kKeyCodeRightBracket: CGKeyCode = 30   // ']'

// FIX: [LOW] Unconditional logging — gate behind a --verbose / -v flag.
// Logging every button press leaks input-timing metadata when stderr is
// redirected or captured (e.g. by launchd, piped to another process).
let gVerbose: Bool = CommandLine.arguments.contains("-v")
                   || CommandLine.arguments.contains("--verbose")

// FIX: [MEDIUM] Changed from CFMachPort! (implicitly unwrapped optional) to
// CFMachPort? (regular optional).  The IUO was unsafe because it
// communicates "always non-nil" while actually being nil at startup.
// All access paths already use `if let` / `guard let`, so this is a safe
// tightening of the type contract.
var gEventTap: CFMachPort?

// MARK: - Step 1: Check Accessibility permission

// CGEventTap requires the calling process to be trusted for Accessibility.
// Without this, the tap will either fail to create or silently never fire.
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

// MARK: - Step 2: Define the event-tap callback

/// C-convention callback invoked for every matching HID event.
///
/// - Mouse button 4 (buttonNumber 3) → suppress + post ⌘+[
/// - Mouse button 5 (buttonNumber 4) → suppress + post ⌘+]
/// - All other events pass through unmodified.
/// - On `.tapDisabledByTimeout`, re-enable the tap automatically.
/// - On `.tapDisabledByUserInput` (Secure Input), do NOT re-enable.
func eventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {

    // ── Tap disabled by the system ──────────────────────────────────────

    // FIX: [HIGH] tapDisabledByUserInput — do NOT re-enable.
    // macOS sends .tapDisabledByUserInput when Secure Input Mode is active
    // (password fields, sudo prompts, 1Password, etc.).  This is an
    // intentional OS security boundary.  Re-enabling would attempt to
    // bypass Secure Input, potentially intercepting/injecting keystrokes
    // during credential entry.  Only re-enable on .tapDisabledByTimeout,
    // which is a benign "your callback was too slow" signal.
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

    // Button numbering:  0 = Left, 1 = Right, 2 = Middle, 3 = Button4, 4 = Button5
    let buttonNumber = event.getIntegerValueField(.mouseEventButtonNumber)

    let keyCode: CGKeyCode
    switch buttonNumber {
    case 3:   // Mouse button 4 (typically "Back")
        keyCode = kKeyCodeLeftBracket    // ⌘+[
    case 4:   // Mouse button 5 (typically "Forward")
        keyCode = kKeyCodeRightBracket   // ⌘+]
    default:
        // Not a side button (e.g. middle click) — pass through.
        return Unmanaged.passRetained(event)
    }

    // key-down when the mouse button is pressed, key-up when released.
    let keyDown = (type == .otherMouseDown)

    // ── Synthesize keyboard event ───────────────────────────────────────

    // FIX: [MEDIUM] CGEventSource: nil → .combinedSessionState.
    // A nil source produces events with no source identification. Security-
    // sensitive apps inspect the source state and may flag/drop nil-source
    // events as untrusted. Using .combinedSessionState stamps the event
    // with the real hardware+software keyboard state, making it
    // indistinguishable from genuine hardware input at the API level.
    let eventSource = CGEventSource(stateID: .combinedSessionState)

    guard let keyEvent = CGEvent(keyboardEventSource: eventSource,
                                  virtualKey: keyCode,
                                  keyDown: keyDown) else {
        fputs("⚠️  Failed to create synthetic keyboard event.\n", stderr)
        // Can't synthesize — let the original event through as a fallback.
        return Unmanaged.passRetained(event)
    }

    // FIX: [MEDIUM] Flag overwrite — preserve real hardware modifiers.
    // The original code did `keyEvent.flags = .maskCommand`, which
    // discarded any modifiers the user was physically holding (Shift,
    // Option, Control).  This (a) breaks modifier combos like ⌘+Shift+[
    // and (b) creates a mismatch between the event's flags and the real
    // hardware state that apps can detect as synthetic.
    // We read the current hardware modifier state and union it with ⌘.
    let currentFlags = CGEventSource.flagsState(.combinedSessionState)
    keyEvent.flags = currentFlags.union(.maskCommand)

    // Post at the HID layer so the event appears as a real keypress.
    keyEvent.post(tap: .cghidEventTap)

    // FIX: [LOW] Logging gated behind gVerbose flag.
    if gVerbose && keyDown {
        let symbol = (buttonNumber == 3) ? "⌘+[" : "⌘+]"
        fputs("🖱  Button \(buttonNumber + 1) → \(symbol)\n", stderr)
    }

    // Return nil to suppress the original mouse side-button event.
    return nil
}

// MARK: - Step 3: Create the event tap

// We intercept at .cghidEventTap (lowest level, before any app sees the event)
// with .headInsertEventTap (our callback runs first).
// .defaultTap means we can both observe AND modify/suppress events.
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

// Store the tap globally so the callback can re-enable it on timeout.
gEventTap = eventTap

// MARK: - Step 4: Add the tap to the current run loop

// FIX: [LOW] Added nil check for runLoopSource.
// CFMachPortCreateRunLoopSource can return nil on allocation failure or
// if the mach port is invalid.  Passing nil to CFRunLoopAddSource would
// be a null-pointer dereference in CoreFoundation.
guard let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0) else {
    fputs("❌ Failed to create run loop source from event tap.\n", stderr)
    exit(1)
}

CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)

// Explicitly enable the tap (it defaults to enabled, but be safe).
CGEvent.tapEnable(tap: eventTap, enable: true)

// MARK: - Step 5: Graceful shutdown

// FIX: [LOW] Install signal handlers for SIGINT (Ctrl+C) and SIGTERM.
// Without these, the event tap is not explicitly disabled on exit. While
// macOS kernel cleanup will reclaim the resources, explicit teardown
// prevents a brief window where a "dead" tap reference lingers in the
// HID server, and ensures clean shutdown in process-managed environments
// (launchd, supervisord, etc.).
func installSignalHandlers() {
    let handler: @convention(c) (Int32) -> Void = { signal in
        if let tap = gEventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        fputs("\n🛑 MouseRemap stopped (signal \(signal)).\n", stderr)
        _Exit(0)  // _Exit avoids atexit handlers that could deadlock
    }

    signal(SIGINT,  handler)
    signal(SIGTERM, handler)
}

installSignalHandlers()

// MARK: - Step 6: Run

print("✅ MouseRemap is running.")
print("   Button 4 (Back)    → ⌘+[  (Command + Left Bracket)")
print("   Button 5 (Forward) → ⌘+]  (Command + Right Bracket)")
if gVerbose {
    print("   Verbose mode ON (logging button presses to stderr).")
}
print("   Press Ctrl+C to stop.\n")

// CFRunLoopRun() blocks forever, keeping the process alive and dispatching
// HID events to our callback.
CFRunLoopRun()
