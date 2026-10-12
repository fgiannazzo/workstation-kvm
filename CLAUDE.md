# Switchboard (repo: workstation-kvm)

macOS menu bar utility that switches the LG DualUp's picture-by-picture mode over DDC/CI and
the monitor's USB HID bridge, talks to an ESP32 for HDMI/USB switching, and exposes every
action to a Stream Deck.

Read `docs/BRIEF.md` (the spec and every verified protocol fact) and `docs/DESIGN.md` (names,
package layout, shared interfaces) before changing anything.

## Build and test

```bash
swift build && swift test
```

Swift 6.4. Must build from the Command Line Tools alone (Xcode optional, so no XCTest). Tests use Swift Testing.
`make app` assembles `dist/Switchboard.app`.

## Rules

- Hardware writes are whitelisted: only the `LGDualUpCommand` cases exist. No probing,
  no scanning, no new codes without a verified fact in the brief.
- Never write 0xF4 on DDC source 0x50. Never write 0x60.
- Tests never touch hardware. Do not run `switchboardctl` or any tool against the monitor;
  Felipe runs the manual checklist in `docs/HARDWARE-CHECKLIST.md`.
- Verify after every write with a video-cable read; never report success from the write.
- Swift 6 strict concurrency, deployment target macOS 15, no third-party dependencies in
  the Swift package.
- Conventional commits. One tracer bullet per pull request. Keep `README.md` current.
- If the hardware contradicts the brief, stop and report the raw bytes.
