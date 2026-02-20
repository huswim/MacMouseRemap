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
./MouseRemap              # 포그라운드 실행 (기본)
./MouseRemap -v           # Verbose 모드 (stderr에 로그 출력)
./MouseRemap --install    # 백그라운드 서비스로 설치
./MouseRemap --uninstall  # 백그라운드 서비스 제거
./MouseRemap --help       # 도움말 표시
```

포그라운드 실행 시 **Ctrl+C**로 중지합니다.

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

## 백그라운드 프로세스로 등록 (launchd)

로그인 시 자동으로 실행되도록 `launchd`에 등록할 수 있습니다.

### 자동 설치

```bash
sudo ./MouseRemap --install
```

바이너리를 `/usr/local/bin/MouseRemap`에 복사하고, LaunchAgent plist를 생성한 뒤,
`launchctl load`까지 자동으로 실행합니다.

### 제거

```bash
sudo ./MouseRemap --uninstall
```

서비스 해제, plist 삭제, 바이너리 삭제를 모두 자동 처리합니다.

### 상태 확인 및 로그

```bash
launchctl list | grep mouseremap           # 서비스 상태 확인
cat ~/Library/Logs/mouseremap.out.log      # 표준 출력 로그
cat ~/Library/Logs/mouseremap.err.log      # 에러 로그
```

> ⚠️ **중요:** Accessibility 권한은 `/usr/local/bin/MouseRemap` 바이너리에 직접
> 부여해야 합니다. 바이너리를 다시 빌드하여 복사한 경우 권한을 다시 부여해야 할 수
> 있습니다.

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
