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
