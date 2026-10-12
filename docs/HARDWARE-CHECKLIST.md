# Hardware checklist

Manual checks Felipe runs against the real desk after each tracer bullet lands. Agents never run
these (`CLAUDE.md`); `swift test` is hardware-free.

When something differs from the expected output: copy the command, its complete output (raw
bytes included) and what the OSD shows at that moment into the pull request or issue. If the
hardware contradicts `docs/BRIEF.md`, stop there; nothing gets worked around silently.

## Check 1: read the DualUp's state (tracer bullet 1)

Reads only. Nothing in this check writes to the monitor.

Preconditions:

- The DualUp is on HDMI 1 through the plain USB-C-to-HDMI dongle and its OREI switch, with the
  Studio as the main input.
- PBP is **off** in the OSD.
- Fresh build: `swift build`.

Steps:

1. `swift run switchboardctl monitor list`

   Expected: one line per external display. One of them is the DualUp, named `LG SDQHD`, with a
   non-zero serial and a `GSM` manufacturer id, for example:

   ```
   LG SDQHD  serial 0x0001E240  serial string 312NTXXXXXXX  GSM 0x7708
   ```

   The LG HDR 4K appears too. The Samsung may or may not; it refuses DDC but its EDID should
   still enumerate.

2. `swift run switchboardctl monitor read`

   Expected, exit code 0:

   ```
   display: LG SDQHD  serial 0x...
   0xD7 PBP: 1 (off)
   0xF5 main input: 1 (HDMI 1)
   ```

3. Optional: `swift run switchboardctl monitor read --json` prints the same as JSON with
   `"pbp": "off"` and `"mainInput": "hdmi1"`.

What to report if it is not that:

- `no external display matches "SDQHD"` (exit 2): paste the `monitor list` output. If the DualUp
  is listed under another name, re-run with `--display <part of that name>` and report the name.
  If it is missing, note which cable path it is on (dongle vs Cable Matters, which OREI input).
- `unknown (unreadable)` for either code: wait 5 s and run `monitor read` once more (the link
  re-trains after any mode change). If it is still unreadable, paste both outputs.
- `0xD7` reads anything other than `1 (off)` while PBP is off, or `0xF5` anything other than
  `1 (HDMI 1)` while the Studio is on HDMI 1: paste the output verbatim. This contradicts the
  brief and blocks tracer bullet 2 until understood.
- Exit 1 with an IOKit error: paste the full message; it names the failing call and the
  `IOReturn` code.

Record the result (date, pass/fail, pasted output) in the pull request that introduced the check.

Result 2026-10-11, pass (run by the orchestrating agent with Felipe's authorisation, Xcode 27
toolchain, PBP off in the OSD):

```
$ switchboardctl monitor list
LG SDQHD  serial 0x0007DB2C  serial string 301NTQDF4860  GSM 0x5C5A
LG HDR 4K  serial 0x0000F233  serial string 302NTCZ1U003  GSM 0x774F
Odyssey G80SD  serial 0x01000E00  serial string H1AK500000  SAM 0xE031
$ switchboardctl monitor read
display: LG SDQHD  serial 0x0007DB2C
0xD7 PBP: 1 (off)
0xF5 main input: 1 (HDMI 1)
```

The read took 0.9 s end to end (two passes 0.5 s apart).

## Check 2: PBP on over the USB bridge, PBP off over the video cable (tracer bullet 2)

This check **writes to the monitor**: exactly two writes, `0xD7 = 0` over the USB HID bridge and
`0xD7 = 1` over the video cable, each followed by a video-cable read-back. Nothing else is sent.

Preconditions:

- Check 1 passed on this build.
- PBP is **off** in the OSD.
- The Studio is the main input on HDMI 1 (through the plain USB-C-to-HDMI dongle and its OREI
  switch), and `monitor read` says `0xD7 PBP: 1 (off)` and `0xF5 main input: 1 (HDMI 1)`.
- The DualUp's USB upstream cable is on the Studio and that upstream is selected in the OSD.
- Fresh build: `swift build`.

Steps:

A. `swift run switchboardctl monitor bridge list`

   Expected, exit code 0: one LG HID interface, product id 0x9A39, "LG Monitor Controls", usage
   page 0xFF00, max output report 64 (or 63), and a serial that equals the DualUp's serial string
   from `monitor list` (or its numeric serial in decimal or hex), for example:

   ```
   pid 0x9A39  LG Monitor Controls  usage page 0xFF00  max output report 64  serial 312NTXXXXXXX
   ```

   More than one line is fine as long as every line carries the same serial (one physical bridge
   with several interfaces); the tool picks the one with the 64-byte output report.

B. `swift run switchboardctl monitor pbp on --dry-run`

   Expected, exit code 0, no hardware touched. The two report lines must start with:

   ```
   report 1: 08 01 55 03 07 00 03 37 51 84 03 D7 00 00 6F 00 ...
   report 2: 08 02 55 04 0B 00 0B 37 51 84 03 D7 00 00 6F 00 ...
   ```

   each 64 bytes long. `monitor pbp off --dry-run` must show `packet: 84 03 D7 00 01 6E` on
   source 0x51. If either differs from `docs/DESIGN.md`, stop: do not run step C.

C. `swift run switchboardctl monitor pbp on`

   Expected, exit code 0, after about 5 s:

   ```
   transport: USB bridge (SDQHD)
   writing 0xD7 = 0, then waiting 4.0 seconds for the link to settle
   verified: 0xD7 = 0 (on)
   ```

   The OSD now shows PBP on (stacked split) and the Studio's half appears at 1920 x 1080. That
   resolution is expected and BetterDisplay fixes it; this tool does not try to. Then
   `monitor read` should say `0xD7 PBP: 0 (on)`.

D. `swift run switchboardctl monitor pbp off`

   Expected, exit code 0:

   ```
   transport: video cable (SDQHD)
   writing 0xD7 = 1, then waiting 4.0 seconds for the link to settle
   verified: 0xD7 = 1 (off)
   ```

   The OSD shows PBP off and the Studio is back to full 2560 x 2880. `monitor read` should say
   `0xD7 PBP: 1 (off)` and `0xF5 main input: 1 (HDMI 1)`.

E. Optional: `swift run switchboardctl monitor pbp on --json` and `... off --json` print the
   `WriteOutcome` object (`"verified": true`, `"observed": 0` / `1`, and the full `reading`).

What to report if it is not that:

- **Bridge not found** (exit 4, `LG USB bridge not found: ...`): paste `monitor bridge list` and
  `monitor list`. Check the USB upstream cable and the OSD upstream selection, then
  `monitor bridge reset` (expected: `re-enumerated 1 LG USB device`), wait 5 s and retry step A.
  If `bridge list` shows a bridge whose serial does not match the DualUp, paste both outputs: the
  pairing rule (`BridgePairing.matches`) may need another rendering of the serial.
- **Exclusive access** (exit 5, `LG USB bridge is busy: ...`): another client holds the bridge
  open exclusively. Quit Arc (or any browser with a WebUSB session on the monitor) and LG OnScreen
  Control, retry. If it persists, `monitor bridge reset`, wait 5 s, retry. Report which app it was.
- **Display not found** (exit 2) during `pbp off`: the video cable path is gone; see Check 1.
- **Unverified** (exit 3, `UNVERIFIED: 0xD7 read back 1 (off)` after step C, or `read back 0 (on)`
  after step D): the write went out but the monitor did not change, or changed back. Paste the
  full output and what the OSD shows. For step C, confirm the USB upstream is the Studio's (the
  bridge accepts writes from any upstream but the OSD decides which one it listens to). Do not
  retry more than once: the write is fire-and-forget and the brief says the opposite value on each
  transport is ignored, so a second identical write is harmless but tells us nothing new.
- **Unverified, unreadable** (exit 3, `UNVERIFIED: 0xD7 unreadable`): the link was still
  re-training. Wait 5 s and run `monitor read`; if it now reads the expected value the write did
  take effect and the settle time (`Timing.settleAfterModeChange`, 4 s) is too short on this desk.
  Paste both outputs.
- **Contradiction with the brief**: PBP changes on the *other* transport (for example the OSD
  shows PBP on after step D, or a `pbp off` through the bridge if you ran one by hand), 0xD7 reads
  a value other than 0 or 1, or the Studio half comes up at anything but 1920 x 1080. Stop there
  and paste the complete output, raw bytes included, plus the OSD state. Nothing gets worked
  around silently.
- Exit 1 with an IOKit error: paste the full message; it names the failing call
  (`IOHIDManagerOpen`, `IOHIDDeviceOpen`, `IOHIDDeviceSetReport(first report)`, ...) and the
  `IOReturn` code.

Record the result (date, pass/fail, pasted output) in the pull request that introduced the check.

Result 2026-10-11, **partial fail** (run by the orchestrating agent with Felipe's authorisation):

- Step A pass: `monitor bridge list` → `pid 0x9A39  LG Monitor Controls  usage page 0xFF00  max output report 64  serial 301NTQDF4860` (matches the EDID serial string from `monitor list`).
- Step B pass: `monitor pbp on --dry-run` printed report 1 `08 01 55 03 07 00 03 37 51 84 03 D7 00 00 6F` and report 2 `08 02 55 04 0B 00 0B 37 51 84 03 D7 00 00 6F`, both zero padded to 64 bytes, report id 8.
- Step C **fail**: `monitor pbp on` → both `IOHIDDeviceSetReport` calls returned success, then `UNVERIFIED: 0xD7 read back 1 (off)` (exit 3). The read-back was stable, so the monitor never started switching.
- Differential check, **inconclusive**: seconds later the prototype `~/Code/dualup/lgusb uset 0xD7 0`
  sent the byte-identical first report and the following reads of 0xD7 and 0xF5 were unreadable.
  `pmset -g log` later showed that macOS turned the displays off at 22:48:04 (idle display sleep),
  between step D and this check, so the unreadable reads are explained by the sleeping display and
  it is not established whether the prototype's write switched the monitor. Repeat with the display
  awake. Known differences from `lgusb.m` to try if the prototype does switch and this app does not:
  it registers an input-report callback, schedules the device on a run loop and keeps the device
  open about 300 ms after the second report. Tracked in GitHub issue #5.
- Step D pass (before the differential check): `monitor pbp off` → `verified: 0xD7 = 1 (off)`.
- Everything after 22:48:04 (the restore `monitor pbp off`, reported `UNVERIFIED: 0xD7 unreadable`,
  and one `pbp on` experiment with a 300 ms linger before closing the HID device) went to a sleeping
  display, so the monitor's physical PBP state is uncertain. **Before anything else in the morning:**
  wake the Mac, run `switchboardctl monitor read`; if 0xD7 reads 0, run `switchboardctl monitor pbp off`.
  Lesson for every future check: a DDC/CI null reply (`err -3`, reply byte 2 not 0x02) from an idle
  Mac means the display is asleep; check `pmset -g log | grep "Display is turned"` first.
