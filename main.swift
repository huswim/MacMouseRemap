// main.swift
// MouseRemap — Remap mouse side buttons (Back/Forward) to ⌘+[ and ⌘+]
//
// Build:  swiftc main.swift -o MouseRemap
// Run:    ./MouseRemap
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

/// Global reference to the event tap, used by the callback for re-enabling
/// after a system timeout.  Set once, immediately after tap creation.
var gEventTap: CFMachPort!

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
func eventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {

    // ── Tap timeout recovery ────────────────────────────────────────────
    // macOS disables a tap if the callback takes too long.  We simply
    // re-enable it using the global tap reference.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = gEventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
            fputs("⏎  Event tap re-enabled after timeout.\n", stderr)
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
    guard let keyEvent = CGEvent(keyboardEventSource: nil,
                                  virtualKey: keyCode,
                                  keyDown: keyDown) else {
        fputs("⚠️  Failed to create synthetic keyboard event.\n", stderr)
        // Can't synthesize — let the original event through as a fallback.
        return Unmanaged.passRetained(event)
    }

    // Apply ⌘ (Command) modifier.
    keyEvent.flags = .maskCommand

    // Post at the HID layer so the event appears as a real keypress.
    keyEvent.post(tap: .cghidEventTap)

    // Log key-down only (avoid double-logging on key-up).
    if keyDown {
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

let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)

// Explicitly enable the tap (it defaults to enabled, but be safe).
CGEvent.tapEnable(tap: eventTap, enable: true)

// MARK: - Step 5: Run

print("✅ MouseRemap is running.")
print("   Button 4 (Back)    → ⌘+[  (Command + Left Bracket)")
print("   Button 5 (Forward) → ⌘+]  (Command + Right Bracket)")
print("   Press Ctrl+C to stop.\n")

// CFRunLoopRun() blocks forever, keeping the process alive and dispatching
// HID events to our callback.
CFRunLoopRun()
