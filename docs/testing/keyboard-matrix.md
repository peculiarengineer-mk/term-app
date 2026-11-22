# Keyboard matrix (manual)

Verify with `cat -v` (or `showkey -a`) in an SSH session: it echoes the bytes each key sends.
Result column: fill in PASS/FAIL per row. Run once on **iPad + Magic Keyboard**, once on the **software keyboard** (with the extra-keys bar).

## A. iPad + Magic Keyboard

| Key | Expected bytes | Result |
|---|---|---|
| Ctrl+A … Ctrl+Z | 0x01 … 0x1A (`^A` … `^Z`) | |
| Ctrl+[ | 0x1B (`^[`) | |
| Alt+B / Alt+F | ESC b / ESC f (`^[b`, `^[f`) | |
| Esc | 0x1B | |
| Tab | 0x09 (`^I`) | |
| Up / Down / Right / Left (normal mode, shell prompt) | `ESC [ A/B/C/D` | |
| Up / Down / Right / Left (app cursor mode, e.g. in `vim`/`less`) | `ESC O A/B/C/D` | |
| Alt+Left / Alt+Right | `ESC b` / `ESC f` (`^[b`, `^[f`) | |
| Ctrl+Right | `ESC [ 1;5 C` | |
| Cmd+T | New tab opens | |
| Cmd+W | Current tab closes | |
| Cmd+1 … Cmd+9 | Switches to tab N (if it exists) | |
| Cmd+K | Screen and scrollback clear locally; no bytes sent | |
| Cmd+= / Cmd+- | Font size grows / shrinks (clamped 8–32) | |
| Caps Lock set to Control (Settings › General › Keyboard › Hardware Keyboard › Modifier Keys); Caps+C | 0x03 (`^C`) |  |
| Caps Lock set to Escape (same setting) | 0x1B |  |
| Caps Lock set to No Action | No bytes; no Caps Lock toggle |  |
| Caps Lock left at default | Normal Caps Lock behaviour |  |

The app does not remap Caps Lock itself; set the Modifier Keys option in iPadOS before testing those rows.

## B. Software keyboard (extra-keys bar)

| Key | Expected bytes | Result |
|---|---|---|
| Esc | 0x1B | |
| Tab | 0x09 | |
| Ctrl (tap, highlights), then `c` | 0x03; Ctrl un-highlights after one key | |
| Alt (tap, highlights), then `b` | ESC b; Alt un-highlights after one key | |
| Ctrl then Esc/Tab/arrow | Ctrl clears; arrow gives `ESC [ 1;5 X` | |
| Alt then Left / Right | `ESC b` / `ESC f`, same as the hardware keyboard | |
| Arrows, normal mode | `ESC [ A/B/C/D` | |
| Arrows, app cursor mode | `ESC O A/B/C/D` | |
| `\|`  `~`  `/` | 0x7C, 0x7E, 0x2F | |
