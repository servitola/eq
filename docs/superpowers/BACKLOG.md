# eq backlog

## Next round (v5): colour everywhere
- `eq --help` / `eq help` / usage on errors painted: command names bold, flags cyan,
  placeholders (`<band>`, `Q`) yellow, descriptions plain, section headings dim; aligned
  columns that fit the terminal width (no wrapping like `…1kh\nz -3`), grouped: look
  (`eq`, `devices`, `status`, `watch`, `zones`, `stream`), tune (`set`, `preamp`, `flat`,
  `copy`, `import`, `on/off`), setup (`init`, `doctor`, `daemon`).
- Every text output painted by the same sixteen-colour rules: `status` (already), `devices`
  (already), `doctor` (already), `import` summaries, `copy`, `init`, `on/off`, error lines
  (`error:` red, the hint after it yellow), `zones` (names dim, spans in band inks).
- `--json` on a terminal is pretty and coloured like `jq`: keys blue, strings green,
  numbers yellow, `true/false` cyan, `null` dim, punctuation dim. Piped or `NO_COLOR` →
  plain JSON exactly as today (scripts and the tests parse it).
- Pipes and `NO_COLOR` stay plain.

## Follow-ups from the v4 review
- The one-line hint drops whole segments instead of being cut mid-word.
- Hide zones with no visible band at narrow widths.
- `eq zones` without a config/device; fit it to the terminal width.
- ≤ 8 rows: shrink the meter below 4 rows or drop the footer so nothing scrolls.
- Option C of watch was done as keyboard tuning; arrows for band select + fine steps later.
- Ctrl‑Z in `eq watch` leaves the alternate screen up.

## Follow-ups from the v7 review
- A stray UTF-8 lead byte delays the next ASCII key until enough bytes arrive.
- A same-user connect flood keeps the accept loop busy (accept-and-close until EAGAIN).
- Listening to wide instruments (kick, voice) isolates little: consider soloing each range, not the outer span.
