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

Result 2026-10-12 08:5x, **fail, both tools** (display awake since 08:43:48 per `pmset -g log`,
PBP off, Studio main on HDMI 1, bridge listed with serial 301NTQDF4860):

- `monitor pbp on` → `UNVERIFIED: 0xD7 read back 1 (off)`, exit 3.
- Prototype `lgusb uset 0xD7 0` (`08 01 55 03 07 00 03 37 51 84 03 d7 00 00 6f` + follow-up) → 0xD7 still
  1 after 6 s. The prototype does not switch the monitor today either.
- `monitor bridge reset` (1 device re-enumerated, same serial afterwards) → prototype `uset` → 0xD7 = 1;
  `monitor pbp on` → `UNVERIFIED`, 0xD7 = 1.
- `monitor pbp off` → `verified: 0xD7 = 1 (off)` every time; reads stable throughout.

Conclusion: not a difference between the two senders. The bridge accepts the reports and the monitor
ignores the command in today's state. Open questions for Felipe in GitHub issue #5 (active signal on
the PBP sub input, OSD USB upstream selection, LG OnScreen Control or WebUSB clients, bridge traffic
that preceded the working run). No further writes until that is understood.

## Check 3: macros and `switchboardctl run` against the controller mock (tracer bullet 3)

This check **writes to the monitor**, with the same two writes as Check 2 (`0xD7 = 0` over the USB
bridge, `0xD7 = 1` over the video cable), now driven by a macro. Everything on the controller side
goes to a mock on this Mac; the real ESP32 is not involved.

Known problem, GitHub issue #5: the USB bridge write does not take effect yet (Check 2, step C
failed with `UNVERIFIED: 0xD7 read back 1 (off)`; the differential check against the prototype was
inconclusive, so the cause is still open). Step 1 of `guest` is that same write, so until #5 is
fixed `run guest` is **expected to fail at step 1 with `unverified`** (step D below says what that
looks like, and it is a useful result: it shows the macro aborting before `usb.select`).
`run solo` finishes either way, because PBP is already off.

Preconditions:

- Check 2 step D passed on a recent build: `monitor read` says `0xD7 PBP: 1 (off)` and
  `0xF5 main input: 1 (HDMI 1)`.
- The display is awake (a sleeping display answers DDC/CI with a null reply and every read looks
  `unreadable`): wake the Mac, then `pmset -g log | grep "Display is turned"` should end with a
  "turned on" line, and `monitor read` works.
- Fresh build: `swift build`.
- Two terminals. Terminal 1 is for the mock.

Steps:

A. No hardware: `swift run switchboardctl actions` lists the eight actions with their parameters
   (`usb.select  USB to port  [port:int(1-4)]` and so on); `swift run switchboardctl macros` lists
   `guest` and `solo` and creates `~/Library/Application Support/Switchboard/macros.json` on the
   first call:

   ```
   guest  Guest  monitor.pbp.on -> usb.select port=2  (verify pbp=on usbPort=2)
   solo   Solo  usb.select port=1 -> monitor.pbp.off  (verify pbp=off usbPort=1)
   ```

B. Terminal 1: `swift run switchboardctl controller mock --port 48700` (prints
   `mock ESP32 listening on http://127.0.0.1:48700`, then one line per request). Terminal 2:

   ```
   swift run switchboardctl settings set controllerURL http://127.0.0.1:48700
   swift run switchboardctl settings show
   ```

   Expected: `controllerURL = http://127.0.0.1:48700`, then the settings with that URL, the defaults
   `displayNameContains: SDQHD`, `pollingIntervalSeconds: 30`, `localAPIPort: 48600`,
   `launchAtLogin: false`, and the path of `settings.json`.

C. Controller only, no monitor write: `swift run switchboardctl run usb.select port=2`.

   Expected, exit code 0:

   ```
   started usb.select (1 step)
   step 1/1: usb.select: port 2
   finished usb.select: ok
   ```

   Terminal 1 shows `POST /usb/select {"port":2} -> 200`. Then `run usb.select port=1` to put the
   mock back.

D. `swift run switchboardctl run guest`.

   Expected once #5 is fixed, exit code 0 after about 5 s (the 4 s settle is inside step 1):

   ```
   started guest (2 steps)
   step 1/2: monitor.pbp.on: verified 0xD7 = 0
   step 2/2: usb.select: port 2
   finished guest: ok
   ```

   The OSD shows PBP on, terminal 1 shows `POST /usb/select {"port":2} -> 200`, and
   `swift run switchboardctl controller state --url http://127.0.0.1:48700` says `usb: port 2`.

   Expected while #5 is open, exit code 3:

   ```
   started guest (2 steps)
   failed guest at step 1/2: monitor.pbp.on: unverified: 0xD7 read back 1 (off), expected 0 (on)
   ```

   and terminal 1 shows **no** request: the macro stopped at the first failing step, so `usb.select`
   did not run. Paste this output into the pull request or into #5; it is the same failure as Check 2
   step C seen through the macro runner.

E. `swift run switchboardctl run solo`.

   Expected, exit code 0, also while PBP is already off:

   ```
   started solo (2 steps)
   step 1/2: usb.select: port 1
   step 2/2: monitor.pbp.off: verified 0xD7 = 1
   finished solo: ok
   ```

   Terminal 1 shows `POST /usb/select {"port":1} -> 200`. The write in step 2 is `0xD7 = 1` over the
   video cable; with PBP already off nothing visibly changes. If #5 is fixed and step D left PBP on,
   the OSD now shows PBP off and the Studio back at 2560 x 2880.

F. The exit codes: stop the mock (Ctrl-C in terminal 1), then `swift run switchboardctl run usb.select
   port=2; echo $?`.

   Expected: `failed usb.select at step 1/1: usb.select: controller unreachable at 127.0.0.1:48700: ...`
   and `6`. Do not run `guest` with the controller down: it checks that a controller is
   configured, not that it answers, so step 1 would still switch PBP on before step 2 fails.
   `swift run switchboardctl settings set controllerURL none` puts the setting back for the real board.

G. Optional: `swift run switchboardctl run guest --json` (with the mock running) prints one JSON object
   per event, in the shape of the `run` events in `docs/API.md`.

What to report if it is not that:

- `no controller is configured` (exit 6): step B was skipped, or `SWITCHBOARD_CONTROLLER_URL` is set
  to something else in this shell (`settings show` prints `controller in effect` when it is).
- `controller unreachable at 127.0.0.1:48700` (exit 6) with the mock running: paste terminal 1 and
  `lsof -i :48700`.
- `UNVERIFIED`-style failure in step E (`monitor.pbp.off: unverified`): paste the output and what the
  OSD shows; this is the Check 2 step D write.
- `verify failed: ...` after both steps finished: paste the line; it names the field and both values.
- Exit 1 with `macros.json is not a valid macro file` or `settings.json is not a valid settings
  file`: the message names the file, the macro and the step; paste it.
- Anything that contradicts `docs/BRIEF.md`: stop and paste the complete output.

Record the result (date, pass/fail, pasted output) in the pull request that introduced the check.

## Check 4: the menu bar app (tracer bullet 4)

Starting the app **reads** the monitor (DDC reads on the video cable, then every 30 s) and nothing
else. Steps A to F and the unknown-URL part of step G write nothing. The only monitor writes are in
step G (`solo`: `0xD7 = 1` over the video cable, which changes nothing while PBP is already off) and
in the optional step H (`PBP on`: `0xD7 = 0` over the USB bridge, the same write as Check 2 step C).
The controller side goes to the mock from Check 3; the real ESP32 is not involved.

Known problem, GitHub issue #5: the USB bridge write does not take effect yet. **PBP on depends on
it**: the `PBP on` button and the `guest` macro are expected to end `unverified` (step H says what
that looks like in the app) until #5 is fixed. Nothing in this check needs PBP on to work.

Preconditions:

- Check 2 step D and Check 3 passed on a recent build: `swift run switchboardctl monitor read` says
  `0xD7 PBP: 1 (off)` and `0xF5 main input: 1 (HDMI 1)`.
- The display is awake (a sleeping display answers DDC/CI with a null reply and every read looks
  `unreadable`); PBP is off in the OSD.
- `settings.json` has no `controllerURL` (`swift run switchboardctl settings set controllerURL none`)
  and `SWITCHBOARD_CONTROLLER_URL` is not set in the shell that launches the app, so step B starts from
  "no controller". Back up `~/Library/Application Support/Switchboard/` first if its macros matter.
- Two terminals: terminal 1 stays free for the mock (step D).

Steps:

A. Build and launch: `make app`, then `make run-app` (or `open dist/Switchboard.app`).

   Expected: `make app` ends by printing `.../dist/Switchboard.app`. A glyph appears in the menu bar
   within a couple of seconds; no Dock icon and no window. It starts as the dashed question mark, dimmed,
   and settles to the plain `rectangle` (PBP off) after the first poll, about a second later. If the
   glyph is missing, check `pgrep -x SwitchboardApp` and paste the output of
   `log show --last 2m --predicate 'subsystem == "io.github.fgiannazzo.switchboard"' --info`.

B. Click the glyph. The State section shows:

   ```
   PBP          Off
   Main input   HDMI 1
   USB port     Unknown
   DualUp       Unknown      (no controller, so no assumed input)
   LG 4K        Unknown
   Samsung      Unknown
   ```

   a green dot for DualUp, a grey one for "Controller (not set)", no error, and `Updated just now`
   (then `5 s ago`, ... as time passes). The USB and HDMI controls are greyed out with a line saying to
   set the controller address in Settings.

   Press **Read monitor**. Expected: the Run row says `Finished monitor.read`, `Updated just now`
   resets, nothing else changes. A red `monitor.read: the monitor did not answer on the video cable`
   means the display is asleep or not found: wake it and press the button again.

C. **Settings...** opens a window. Set `Polling interval` to `10` and press **Save**.

   Expected: `Saved`, and `swift run switchboardctl settings show` prints `pollingIntervalSeconds: 10`.
   Close and reopen the window: the value is still there. Try `0` as the interval: Save refuses with
   `pollingIntervalSeconds must be a number from 1 to 3600, got "0"` and the file keeps `10`. Put it back
   to `30` and Save. **Reveal in Finder** shows the folder with `settings.json` and `macros.json`;
   **Discover** with no controller on the network says `No controller answered over mDNS` after about 3 s
   (macOS asks for Local Network access the first time: allow it).

D. Start the mock in terminal 1: `swift run switchboardctl controller mock --port 48700`. In Settings set
   the controller address to `http://127.0.0.1:48700` and Save.

   Expected: within a second the Controller dot turns green and its note disappears; USB port shows
   `Port 1`; each display shows `HDMI 1 (assumed)`; the USB and HDMI segmented controls light up with the
   current values selected. `settings show` prints the address. Then in the HDMI row of the LG 4K open
   **Actually on...** and choose `Actually on HDMI 2`: terminal 1 shows `POST /hdmi/lg4k/resync
   {"input":2} -> 200`, the row now says `HDMI 2 (assumed)`, and nothing was pulsed (there is no
   `/hdmi/lg4k/select` line). Choose `Actually on HDMI 1` to put it back.

E. **Macros...**: press `+`, set the id to `check4` and the name to `Check 4`, press **Add step** and
   choose `Wait` (set `ms` to `100`), then press **Save**.

   Expected: `Saved to macros.json`. In a terminal, `swift run switchboardctl macros` lists
   `check4  Check 4  delay ms=100` below `guest` and `solo`. In the popover a **Check 4** button
   appeared; press it: the Run row says `Finished check4`. Back in the editor, try an empty id, a
   duplicate id and a `Wait` of `70000`: each is listed in red and Save stays disabled. Select `check4`,
   press `-`, Save: `switchboardctl macros` no longer lists it.

F. Launch at login. In Settings turn **Launch at login** on.

   Expected: **System Settings > General > Login Items & Extensions** lists **Switchboard** (macOS may show
   a "Switchboard added items that can run in the background" notification). If the Settings window says to
   approve Switchboard, approve it there; the toggle stays on. `swift run switchboardctl settings show`
   prints `launchAtLogin: true`. Turn it off again: the entry is gone and the file says `false`. (If the
   toggle says `launch at login only works from the app bundle`, the app was started from `swift run`
   instead of `dist/Switchboard.app`.)

G. The URL scheme. With the mock running and the controller set (step D):

   ```
   open "switchboard://run/solo"
   ```

   Expected: no window opens; within about 1 s the Run row says `Finished solo`; terminal 1 shows
   `POST /usb/select {"port":1} -> 200`; PBP stays Off in the State section and the OSD (step 2 of `solo`
   writes `0xD7 = 1` over the video cable, which changes nothing while PBP is off). Then
   `open "switchboard://run/nope"` and `open "switchboard://state"`: each posts a notification
   (`nope did not run: unknown action or macro "nope"` and `Cannot open switchboard://state: ...`) and
   nothing else happens (macOS asks for notification permission the first time; if you decline, the same
   lines appear in the Log window instead). Finally stop the mock (Ctrl-C), set the controller address to
   empty in Settings (Save) and `open "switchboard://run/solo"` again: the run fails before its first step,
   so the monitor is untouched. Expected: the Run row says `Failed solo: usb.select: no controller is
   configured: ...`, the glyph turns red, and a notification repeats it (`solo did not run: ...`).

H. Optional, **writes to the monitor** (the Check 2 step C write). With the mock running and the controller
   set, press **PBP on**. Expected while #5 is open: after about 5 s the Run row turns red with
   `Failed monitor.pbp.on: monitor.pbp.on: unverified: 0xD7 read back 1 (off), expected 0 (on)`, the glyph
   turns red, `PBP` still reads Off. Press **Solo** (or any run that finishes) to clear the red. Once #5 is
   fixed the same press ends `Finished monitor.pbp.on`, the glyph is `rectangle.split.1x2` and the OSD
   shows PBP on; **PBP off** puts it back.

I. **Log...** shows the lines of the steps above, newest first; `Warning and above` filters; **Copy all**
   puts the whole log on the pasteboard (paste it somewhere to check). **Quit** removes the glyph:
   `pgrep -x SwitchboardApp` prints nothing.

What to report if it is not that:

- No glyph, or the process exits: the output of the `log show` command in step A and anything in
  `~/Library/Logs/DiagnosticReports/` named `SwitchboardApp*`.
- The State section stays at `Unknown` with the DualUp dot grey while `monitor read` in a terminal works:
  paste both; the display name substring in Settings (`SDQHD`) may not match.
- A window opens when a `switchboard://` URL arrives: paste the URL and which window it was.
- The glyph looks wrong in the menu bar (invisible on a dark wallpaper, or red does not show): say which
  tint (dimmed or red), the wallpaper and the menu bar's appearance.
- Launch at login stays off with no message, or the entry never appears in System Settings: paste the
  Log window's `launch at login` lines.

## Check 5: the local API, `switchboardctl state`, Stream Deck wrappers and the plugin (tracer bullet 5)

Steps A to G write **nothing to the monitor**: the only runs are `usb.select` against a controller
mock on this Mac, and the API is served by `switchboardctl serve` (the menu bar app does not start the
API yet; once it does, every call below works against it unchanged). Step H is optional and does write to the monitor, with the same `0xD7 = 1`
write as Check 3 step E. Step I needs the Stream Deck app.

Preconditions:

- The Switchboard app is **not** running (it would hold port 48600; `lsof -nP -iTCP:48600
  -sTCP:LISTEN` prints nothing). If it must run, add `--port 48601` to `serve` here and to every
  `switchboardctl` command below.
- Fresh build: `swift build`.
- Three terminals: 1 for the mock controller, 2 for `serve`, 3 for everything else.

Steps:

A. The token. Terminal 3: `swift run switchboardctl token`.

   Expected: one line of 43 characters from `A-Z a-z 0-9 - _` (base64url, no `=`). On the very first
   call there is also `switchboardctl: created a new API token` on stderr, and no keychain prompt
   (the tool made the item itself). `security find-generic-password -s io.github.fgiannazzo.switchboard
   -a local-api-token` (no `-w`) now prints the item's attributes, and a second `swift run
   switchboardctl token` prints the same token. Keep it: `TOKEN=$(swift run switchboardctl token)`.

   If a keychain prompt does appear ("wants to use your confidential information"), choose
   **Always Allow**; after a rebuild it can ask again, because the allowance belongs to that exact
   binary.

B. Terminal 1: `swift run switchboardctl controller mock --port 48700`. Terminal 3:
   `swift run switchboardctl settings set controllerURL http://127.0.0.1:48700`. Terminal 2:
   `swift run switchboardctl serve`.

   Expected in terminal 2:

   ```
   Switchboard 0.1.0 API listening on http://127.0.0.1:48600
   token: `switchboardctl token` (Authorization: Bearer <token>)
   controller: http://127.0.0.1:48700
   not polling: state stays unknown until a run or `--poll` (reads only) fills it
   press Ctrl-C to stop
   ```

   `lsof -nP -iTCP:48600 -sTCP:LISTEN` shows `TCP 127.0.0.1:48600 (LISTEN)`: loopback only, not `*`.

C. With curl, terminal 3:

   ```
   curl -s -i http://127.0.0.1:48600/health
   curl -s -i http://127.0.0.1:48600/state
   curl -s -o /dev/null -w "%{http_code}\n" "http://127.0.0.1:48600/state?token=$TOKEN"
   curl -s -H "Authorization: Bearer $TOKEN" http://127.0.0.1:48600/state
   ```

   Expected: `/health` is `200` with `{"name":"Switchboard","ok":true,"version":"0.1.0"}`; `/state`
   without a token is `401` with `{"error":"unauthorized"}`; the token in the query string is `401`
   (it is never accepted); with the header the state is one JSON line, on a fresh `serve`:

   ```
   {"controllerReachable":false,"dualUpReachable":false,"hdmiInput":{},"lastError":null,"mainInput":"unknown","pbp":"unknown","updatedAt":"0001-01-01T00:00:00.000Z","usbPort":null}
   ```

D. `swift run switchboardctl state`, then `swift run switchboardctl state --json`.

   Expected, exit code 0 (everything unknown, nothing has been read yet):

   ```
   pbp: unknown
   main input: unknown
   usb: unknown
   hdmi: dualup unknown  lg4k unknown  samsung unknown
   controller: not reachable
   monitor: not reachable
   last error: none
   updated: never
   ```

   Then, in a second window of terminal 3, `swift run switchboardctl events`: it prints
   `state  pbp=unknown main=unknown usb=? ...` at once and then waits. Leave it running.

E. A run through the API. Terminal 3:

   ```
   swift run switchboardctl run usb.select port=2
   swift run switchboardctl state
   swift run switchboardctl run usb.select port=1
   ```

   Expected, exit code 0:

   ```
   started usb.select (1 step)
   step 1/1: usb.select: port 2
   finished usb.select: ok
   ```

   Terminal 1 shows `POST /usb/select {"port":2} -> 200`. `state` now says `usb: port 2`,
   `hdmi: dualup 1  lg4k 1  samsung 1`, `controller: reachable`, and `updated:` has a time with
   milliseconds and a `Z`. The `events` window printed `run    started usb.select (1 step)`,
   `run    step 1/1: ...`, `run    finished usb.select: ok` and several `state  ...` lines (a `state`
   line can come just before or after the `run` line it belongs to). The same for `port=1`.

   Error paths, each with its exit code: `run usb.select` prints `missing parameter "port"` (1),
   `run usb.select port=9` prints `invalid parameter "port": must be 1 to 4, got 9` (1), `run nope`
   prints `unknown action or macro "nope"` (1). For 7, run `swift run switchboardctl run delay
   ms=5000` in one window and `swift run switchboardctl run usb.select port=2` in another within
   those 5 s: `another run is in progress (run ...)` and exit 7.

F. Stop `serve` (Ctrl-C in terminal 2) and ask again, terminal 3:

   ```
   swift run switchboardctl state; echo $?
   swift run switchboardctl run usb.select port=2; echo $?
   ```

   Expected: `state` prints `Switchboard app is not running (no API at http://127.0.0.1:48600); start
   it, or use "switchboardctl run" which works offline` and `8`. The `run` works anyway, in process,
   and exits `0` (the mock is still up): `run` falls back when the API does not answer. `events`
   exits 8 the same way. Start `serve` again for steps G to I.

G. Stream Deck wrappers, no Stream Deck needed yet. Terminal 3: `swift run switchboardctl streamdeck
   export`.

   Expected: `wrote 5 wrappers and README.txt to ~/Library/Application Support/Switchboard/StreamDeck/`
   and the names `guest.command`, `monitor.pbp.off.command`, `monitor.pbp.on.command`,
   `monitor.read.command`, `solo.command`. `ls -l` shows `-rwxr-xr-x` on each, and
   `cat ~/Library/Application\ Support/Switchboard/StreamDeck/solo.command` is exactly:

   ```
   #!/bin/bash
   # Generated by `switchboardctl streamdeck export`. Regenerate instead of editing.
   exec "<path to switchboardctl>" run solo
   ```

   Run the command again: same output, and `ls -l` shows unchanged modification times.
   **Do not run `guest.command`, `solo.command` or the `monitor.*` wrappers in this step**: they
   write to the monitor (step H).

H. Optional, **writes to the monitor** (`0xD7 = 1` over the video cable, a no-op with PBP already
   off). In Finder, double-click `solo.command`.

   Expected: Terminal opens and prints `started solo (2 steps)`, `step 1/2: usb.select: port 1`,
   `step 2/2: monitor.pbp.off: verified 0xD7 = 1`, `finished solo: ok`, then the window closes or
   says `[Process completed]`. If `serve` is still running this ran through it, otherwise in
   process; either way terminal 1 shows `POST /usb/select {"port":1} -> 200`. The first run may
   raise the keychain prompt of step A.

I. The Stream Deck, with the app and the plugin (phase 2; `serve` on port 48600, step B):

   1. `cd StreamDeckPlugin && npm ci && npm run build`, then `npx streamdeck dev` once and
      `npx streamdeck link io.github.fgiannazzo.switchboard.sdPlugin`.
   2. In the Stream Deck app drag **Switchboard → State** onto a key, set Field to `usbPort`, open
      **Connection**, keep host `127.0.0.1` and port `48600`, paste `$TOKEN`, press **Test
      connection**.

      Expected: `Switchboard 0.1.0: token accepted. PBP unknown, USB port 1, controller reachable`.
      `PBP unknown` because `serve` has not read the monitor (`serve --poll` would, reads only);
      `USB port 1, controller reachable` because step E's last run asked the mock. A `serve` that
      has run nothing yet says `USB port ?, controller unreachable`.
   3. The tile shows `1`. Terminal 3: `swift run switchboardctl run usb.select port=2`. Expected: the
      tile changes to `2` within a second, with no press. Run `port=1` and it goes back.
   4. Drag **Switchboard → Run** onto another key, id `usb.select`, Parameters `{"port": 2}`, press
      it. Expected: the green check, terminal 1 shows `POST /usb/select {"port":2} -> 200`, and the
      tile shows `2`. With the id `nope` the key shows the yellow triangle.
   5. A phase 1 key: **System → Open**, choose `solo.command`, press it (this is step H's write).
      `switchboard://run/solo` goes to the app, not to the API (Check 4: `open "switchboard://run/solo"`).

What to report if it is not that:

- `cannot listen on 127.0.0.1:48600 ... Address already in use`: something holds the port, usually
  the app; `lsof -nP -iTCP:48600 -sTCP:LISTEN`. Paste it.
- A keychain error from `token` (`keychain error -25308` and similar): paste the full line. To
  proceed without the keychain, `export SWITCHBOARD_TOKEN_FILE=/tmp/switchboard-token` in every
  terminal that runs `switchboardctl`, and paste that token into the plugin; say that you did.
- `rejected the API token (401)` from `state` or `run`: `serve` and the CLI disagree about the token
  (one of them has `SWITCHBOARD_TOKEN_FILE` set). Paste `env | grep SWITCHBOARD`.
- `state` says the app is not running while `serve` is up: wrong port. `settings show` prints
  `localAPIPort`; paste it and the `serve` banner.
- A `run` that hangs or ends without `finished`/`failed`: paste the `events` window and terminal 2.
- A State tile stuck on `?` after a green Test connection: paste the plugin log
  (`StreamDeckPlugin/io.github.fgiannazzo.switchboard.sdPlugin/logs/`) and the output of
  `curl -s -N -H "Authorization: Bearer $TOKEN" http://127.0.0.1:48600/events` for 20 s: it should
  print one `state` event at once and `: keepalive` after 15 s.
- Anything that contradicts `docs/BRIEF.md`: stop and paste the complete output.

Record the result (date, pass/fail, pasted output) in the pull request that introduced the check.

## Check 6: the app hosts the local API (integration)

No monitor writes. Needs the app from Check 4 and the plugin or `curl`.

Preconditions:

- Nothing else listens on the API port: `lsof -nP -iTCP:48600 -sTCP:LISTEN` prints nothing
  (quit any `switchboardctl serve`).
- `make app` is fresh.

Steps:

1. `open dist/Switchboard.app`. Open **Settings…** from the popover. Expected, in the Local API
   section: Status `listening on http://127.0.0.1:48600`, and a 43-character Token with a Copy button.
   Wrong: Status `failed: …` (paste it; `Address already in use` means something else holds the port).
2. `swift run switchboardctl state`. Expected: the same state the popover shows, exit 0. The first
   run may show a keychain prompt because `switchboardctl` is a different binary from the app;
   allow it (Always Allow keeps it from coming back). Wrong: exit 8 "app is not running" (the app
   is not listening; see step 1) or `401` (the CLI and the app disagree about the token: paste
   `env | grep SWITCHBOARD`).
3. `swift run switchboardctl run usb.select port=2` with the controller mock from Check 3 configured.
   Expected: the run goes through the app (the popover's Run row animates, the log shows the step)
   and finishes with exit 0.
4. Change the port in Settings to `48601`, Save. Expected: Status shows `listening on
   http://127.0.0.1:48601` within a second; `swift run switchboardctl state --port 48601` works and
   `--port 48600` exits 8. Change it back to `48600`, Save.
5. Plugin smoke test (Check 5, step I) against the app instead of `serve`: the State tile shows the
   PBP state, the Run key with `usb.select` and `{"port": 2}` gets the green check.
6. Quit the app. Expected: `swift run switchboardctl state` exits 8 at once.

Record the result (date, pass/fail, pasted output) in the pull request that introduced the check.
