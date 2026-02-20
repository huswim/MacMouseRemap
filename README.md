# MouseRemap

> 🤖 이 프로젝트는 AI를 사용하여 생성되었습니다. (Google Antigravity + Claude Opus 4.6)

A macOS command-line tool that remaps mouse side buttons to browser-style
back/forward keyboard shortcuts — no third-party dependencies.

| Mouse Button | Action | Keyboard Shortcut |
|---|---|---|
| Button 4 (Back) | `otherMouseDown`, buttonNumber 3 | ⌘ + `[` |
| Button 5 (Forward) | `otherMouseDown`, buttonNumber 4 | ⌘ + `]` |

## Build

```bash
swiftc main.swift -o MouseRemap
```

## Run

```bash
./MouseRemap
```

Press **Ctrl+C** to stop.

## Granting Accessibility Permission (macOS 14+)

This tool uses `CGEventTap` at the HID layer, which requires **Accessibility**
permission. Without it the tool will print an error and exit.

1. Open **System Settings**.
2. Go to **Privacy & Security → Accessibility**.
3. Click the **"+"** button.
4. Navigate to and add the `MouseRemap` binary.
   - If you run from Terminal.app or iTerm, add the **terminal app** instead.
5. Toggle the switch **ON** next to the entry.
6. Re-run `./MouseRemap`.

> **Tip:** If you recompile the binary, macOS may revoke the permission.
> Toggle it off and back on, or remove and re-add the entry.

## How It Works

1. **Accessibility check** — calls `AXIsProcessTrusted()` on startup.
2. **Event tap** — creates a `CGEventTap` at `.cghidEventTap` (lowest HID level)
   that intercepts `otherMouseDown` and `otherMouseUp` events.
3. **Button filtering** — inspects `mouseEventButtonNumber`; buttons 3 and 4
   (side buttons) are handled, everything else passes through.
4. **Synthetic keypress** — creates a `CGEvent` keyboard event with the
   appropriate key code and sets `.maskCommand`, then posts it back at the
   HID layer.
5. **Suppression** — returns `nil` from the callback to swallow the original
   mouse event.
6. **Timeout recovery** — if macOS disables the tap due to a callback timeout,
   it is automatically re-enabled.
