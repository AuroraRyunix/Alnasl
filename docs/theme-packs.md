# Theme packs

A theme pack is a colour theme that is not part of the program: a folder the
box finds at run time and offers in the theme pickers (the rail's half-moon,
and Setup's grid) after the built-in themes. The user-facing description is
on the Help page, under *Colours*. This page is for whoever writes a pack or
touches the code that loads one.

The format is OpenPairings' (its `docs/theme-packs.md`), with the same
scanner, so one pack folder can serve both programs as far as the format
goes. The tokens differ: a pack styles one program's class names and fills
one program's palette, and a pack written for OpenPairings has nothing to say
to Alnasl's rail.

## Where packs are read from

`Alnasl.ThemePacks.dir/0`:

1. `ALNASL_THEMES_DIR` (`config :alnasl, :themes_dir`, set in
   `config/runtime.exs`) if set and non-empty;
2. otherwise `<data dir>/themes` - next to `alnasl.db`, wherever
   `ALNASL_DATA` or `Alnasl.DataHome` put that (Windows
   `%LOCALAPPDATA%\AlnaslData\themes`, Linux installed
   `/var/lib/alnasl/themes`, Mac
   `~/Library/Application Support/AlnaslData/themes`, `./data/themes` from
   `mix phx.server`).

Each subfolder is a candidate. Nothing is installed by default, and the
folder is never created: no folder, no packs, and the site is the site.

A pack is read on the next page load, without a restart, and changing its
files changes the version on its stylesheet's URL, so browsers fetch it
again. Removing the folder removes the pack; a browser that had chosen it
falls back to *Match device*, as it does for any stored theme it no longer
knows.

## The format

```
<id>/
  theme.json
  theme.css
  fonts/*.woff2     optional
  LICENSE, README   optional, never served
```

`theme.json`:

| key | required | rule |
|---|---|---|
| `id` | yes | `[a-z0-9][a-z0-9-]{0,39}`, equal to the folder name, not a built-in theme (`system`, `paper`, `night`, `board`, `slate`, `contrast`, nor `light` / `dark`, which the first light/dark switch stored and `theme.js` still reads as paper and night) |
| `name` | yes | at most 40 characters, shown in the picker |
| `name_nl` | no | the name in Dutch |
| `author` | no | shown as the picker item's tooltip |
| `version` | no | free text |
| `dark` | yes | boolean; `true` sets `data-theme-dark` on `<html>`, which makes `color-scheme: dark` (the browser's own scrollbars and form controls) |
| `swatch` | yes | 3 or 4 `#rrggbb` colours, the strip shown in the picker |
| `users` | ignored | OpenPairings keeps such a pack for the listed accounts. The box has no accounts, so here the key is read past - not refused, so the same folder works in both programs - and the pack is everybody's |

Limits: `theme.css` at most 200 KB, each font at most 1 MB, font names
`[a-z0-9_-]+\.woff2`.

## What the scanner refuses

`Alnasl.ThemePacks.Scanner.scan/2` tokenises the stylesheet (comments become
whitespace, strings stay whole, so neither can hide or fake a brace) and
refuses:

- `@import`, and any at-rule other than `@font-face`, `@keyframes` (also
  `-webkit-`), `@media`, `@supports`;
- `url()` pointing anywhere but `fonts/<name>.woff2`; `image-set()`,
  `-webkit-image-set()`, `image()`, `src()`, `element()`;
- `expression(`, `javascript:`, `vbscript:`, `behavior:`, `-moz-binding`,
  anywhere, strings included;
- a backslash outside a string (CSS escapes would let `@\69mport` past any
  text match);
- nested rules, unbalanced braces, unterminated strings or comments, invalid
  UTF-8;
- any selector whose first compound does not contain `[data-theme="<id>"]`
  (any quoting) or `:where(...)` / `:is(...)` of exactly that. So
  `:root[data-theme="x"]`, `html[data-theme="x"] body` and
  `[data-theme="x"] .rail` pass; `body`, `.x [data-theme="x"]` and
  `[data-theme*="x"]` do not.

A refused pack is logged, left out of the picker and of the themes the
script will apply, and named under the built-in themes in grey with the
reason. Pack CSS and fonts are files served by the box itself
(`AlnaslWeb.ThemePackController`, `/themes/:id/theme.css` and
`/themes/:id/fonts/:file`), checked against the loaded pack and answering
404 with an empty body to everything else - so a page never loads anything
from anywhere but the box. Those two routes sit outside the PIN gate: the
PIN page wears the theme too.

## How the page uses it

The root layout carries `<meta name="alnasl-theme-packs">` with
`[{id, dark, css}]` as JSON, placed before `assets/js/theme.js`, which reads
it with `JSON.parse` (data in an attribute, never spliced into a script).
The script adds the pack ids to the themes it accepts and, only while a pack
is the chosen theme, inserts `<link id="alnasl-theme-pack">` to its
stylesheet and sets `data-theme-dark` if the pack says `"dark": true`.
Choose anything else and both go again.

## The tokens

A pack is mostly one token block, and it must define the whole palette:
every built-in theme does, and a token left out would quietly be Paper's,
which is how a dark theme gets dark text on it. Write it on `:root`, which
puts it level with the built-in blocks it has to beat:

```css
:root[data-theme="mytheme"] {
  --bg: ...;        /* the page */
  --panel: ...;     /* panels, the rail, tiles, the theme picker */
  --sunken: ...;    /* hovered rows and buttons, the current place in the rail */
  --ink: ...;       /* text */
  --quiet: ...;     /* secondary text, the edges of fields */
  --rule: ...;      /* hairlines */
  --accent: ...;    /* links, the focus ring, primary buttons */
  --on-accent: ...; /* text on the accent */
  --ok: ...;   --ok-bg: ...;     /* Live, Connected, a board found */
  --warn: ...; --warn-bg: ...;   /* Settling, Offline, the banner */
  --bad: ...;  --bad-bg: ...;    /* Out of sync, No signal, refusals */
  --idle: ...; --idle-bg: ...;   /* Waiting, Not set up */
  --reconstructed: ...; --reconstructed-bg: ...; /* a move worked out (orange) */
  --guessed: ...;       --guessed-bg: ...;       /* a move assumed (red) */
  --sq-light: ...;  /* the board's light squares */
  --sq-dark: ...;   /* and dark ones */
  --sq-mark: ...;   /* the last move, translucent */
  --sq-diff: ...;   /* a square where board and game disagree */
  --shadow: ...;    /* a box-shadow, not a colour */
  color-scheme: light; /* or dark */
}
```

`--radius`, `--font` and `--mono` may be set as well (not part of the
palette). Anything beyond tokens is ordinary CSS scoped as above; the class
names to know are `.rail`, `.brand`, `.nav a[aria-current="page"]` (the
current place), `.rail-foot`, `.bar`, `main.page`, `.panel`, `.btn`
(`.primary`, `.danger`, `.ghost`, `.small`), `.state`, `.tile`, `.board`,
`.moves`, `.clock`, `.field`, `.input`, `table`, `.banner`, `.flash`,
`.callout`, `.theme-picker-panel`, `.theme-grid`, `.door` (the PIN page) and
`.walk-*` (the phone pages).

Animation is allowed, with two limits. Switch it off under
`@media (prefers-reduced-motion: reduce)` (the site's own rule does too, for
everything). And leave the things that show live data alone - tiles,
boards, clocks, move lists, the live pill: an arbiter reads those across a
hall, and a moving one reads as something happening.

## Checking one

```
mix alnasl.theme_check path/to/mytheme
```

Loads the pack exactly as the program does (so every refusal above shows),
then runs `AlnaslWeb.ThemeContrast.pack_failures/3` against
`assets/css/app.css` plus the pack: the whole palette is there, every text
pairing `test/alnasl_web/accessibility_test.exs` holds the built-in themes
to reaches 4.5:1, and so does every rule of the pack's own that sets a text
colour and a background together. It lists each failure and exits non-zero
if there is one. A pack that fails the contrast still loads; the check is
for its author.

## The first pack

`jorian`, the cartoon theme, lives in the separate `openpairings_themes`
repository, under `alnasl/jorian/`, with its fonts (Bangers and Nunito, OFL)
vendored so it works in a hall without internet.
