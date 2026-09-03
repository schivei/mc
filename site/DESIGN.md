# site/DESIGN.md — the look of the mc documentation site

The compiler's values are *small, deterministic, teachable, honest*. The site is built the same
way: no framework, no build step, no web font, no JavaScript needed to read a page. One
stylesheet of 689 lines, four templates, one SVG mark. Everything here is checkable — the
contrast numbers come from a script in this directory, not from an eyeball.

---

## The mark

![the mc mark](static/icon.svg)

A square bracket that contains a smaller copy of itself, and a solid square at the centre.

- **Why a bracket.** It is the letter **c** drawn square, and it is the shape of a container:
  something goes inside it. The wordmark next to it supplies the **m**; the icon does not try to
  spell two letters in sixteen pixels.
- **Why it contains itself.** mc compiles its own source. The middle ring is not a second drawing
  — in `icon.svg` it is literally the same `<path>`, referenced again through `<use>` at half
  scale. The file has one shape in it, used twice.
- **Why the centre is solid.** The third generation would be identical to the second, so there is
  nothing left to draw. `make bootstrap` compiles the source three times and `cmp mc2.o mc3.o`
  reports no difference; the filled square is that fixed point.
- **Why it is on a 4-unit grid.** AArch64 instructions are four bytes wide, always. The canvas is
  64 units with a 4-unit module, and reading outward from the centre every measurement is a
  multiple of it: core 8, gap 4, ring 4, gap 4, ring 8, margin 8. No stroke, gap or coordinate in
  the file is off the grid.

| File | What it is | Where it is used |
|---|---|---|
| `static/icon.svg` | 3 generations, transparent, follows `prefers-color-scheme` | docs, README, anywhere at 32px or larger |
| `static/favicon.svg` | 2 generations on a solid copper tile, fixed colours | browser tab, the PNG exports |
| `static/icon-16/32/180/512.png` | rasterised from `favicon.svg` | legacy favicon, `apple-touch-icon`, manifest |
| `static/social.svg`, `social.png` | 1200×630 preview card | `og:image` |

One generation is dropped in the tab-bar variant so that nothing is thinner than two device
pixels at 16px, and the tile is opaque so the mark reads on a light and on a dark tab strip
alike. In the page header and on the home page the mark is **inlined** in the template with
`stroke="currentColor"`, so it takes the theme exactly and costs no request.

Known nit: `icon-180.png` (the `apple-touch-icon`) already has rounded corners, and iOS rounds
again. The tile radius is 12/64 ≈ 19%, inside the iOS mask of ~22.5%, so the double rounding is
not visible — but a full-bleed square export would be strictly more correct.

### Regenerating the raster set

```sh
cd site/static
for s in 16 32 180 512; do rsvg-convert -w $s -h $s favicon.svg -o icon-$s.png; done
rsvg-convert -w 1200 -h 630 social.svg -o social.png
```

`rsvg-convert` comes from `librsvg` (`brew install librsvg`). Without it, open the SVG in a
browser and export, or use `qlmanage -t -s 512 -o . favicon.svg`; `sips` alone cannot rasterise
SVG. `rsvg-convert` ignores `prefers-color-scheme`, so it always renders the light variant —
which is what the tile wants anyway.

---

## Colour

Warm greys rather than blue-greys, and a single accent: **copper**, the colour of a soldered
joint. It is not the default documentation blue, it survives both themes, and it leaves blue free
to mean exactly one thing — focus.

### Light

| Token | Hex | Role |
|---|---|---|
| `--bg` | `#fbfaf8` | page |
| `--bg-elev` | `#f2eee8` | cards, inline code, nav hover |
| `--code-bg` | `#f4f1eb` | code blocks |
| `--text` | `#191817` | body |
| `--text-muted` | `#5c564e` | secondary text, nav, footer, captions |
| `--border` | `#ddd7ce` | separators (decorative) |
| `--border-strong` | `#918878` | control boundaries (must clear 3:1) |
| `--accent` | `#8f3d0d` | links, active nav, primary button, the mark |
| `--accent-hover` | `#6f2f09` | link and button hover |
| `--accent-soft` | `#f4e6da` | active nav background |
| `--focus` | `#0a5fbd` | focus ring, and nothing else |

### Dark

| Token | Hex | Role |
|---|---|---|
| `--bg` | `#131211` | page |
| `--bg-elev` | `#1e1c1a` | cards, inline code, nav hover |
| `--code-bg` | `#1a1917` | code blocks |
| `--text` | `#ece8e2` | body |
| `--text-muted` | `#a49d94` | secondary text |
| `--border` | `#302d2a` | separators |
| `--border-strong` | `#716b62` | control boundaries |
| `--accent` | `#f0a568` | links, active nav, primary button, the mark |
| `--accent-hover` | `#f8c093` | hover |
| `--accent-soft` | `#2b2018` | active nav background |
| `--focus` | `#7cb7f5` | focus ring |

Dark is not an inversion: the page is near-black rather than pure black, the accent moves from a
dark copper to a light one so that it stays the *lighter* element against its background, and the
neutrals keep the same warmth.

### Code tokens

The lexer's token classes get one colour each, and the two that matter most get a second,
non-colour cue as well — a reader who cannot separate the hues still gets the information.

| Class | Light | Dark | What it marks | Extra cue |
|---|---|---|---|---|
| `tok-keyword` | `#8c2461` | `#ee8dc0` | core words: `if`, `loop`, `break`, the 7 types | bold |
| `tok-taught` | `#8f3d0d` | `#f0a568` | words that came from the surface, not the core | bold + dotted underline |
| `tok-dir` | `#1a5482` | `#82b9ec` | `#include`, `#rule`, `#token`, and their grammar words | bold |
| `tok-hole` | `#6a34a3` | `#c3a4f2` | `$c`, `$$t` — rule holes and gensyms | italic |
| `tok-str` | `#256128` | `#8ecb8a` | string and char literals | — |
| `tok-num` | `#0a615f` | `#55c9c1` | integer literals | — |
| `tok-ident` | `#191817` | `#ece8e2` | ordinary names | — |
| `tok-op` | `#5c564e` | `#b0a99f` | operators and punctuation | — |
| `tok-comment` | `#67615a` | `#9a938a` | `//` comments | italic |

**`tok-taught` is the point of the whole palette.** In every other language's documentation, the
highlighted words are the language. Here, half of them are not: `while`, `for` and `+=` are 37
lines of `lib/prelude.mc`. The dotted underline says so on every page, without a caption.

---

## Contrast

Measured with `python3 site/tools/contrast.py`, which parses the custom properties straight out of
`static/site.css` — so the table cannot drift from the stylesheet. WCAG 2.1 AA: 4.5:1 for text,
3:1 for the boundary of a control and for the focus indicator. Every pair the stylesheet actually
puts on screen is listed; the lowest is 3.03:1 and it is a border, the lowest text pair is 5.42:1.

| What | Foreground / background | Light | Dark | Min |
|---|---|---:|---:|---:|
| body text | `--text` on `--bg` | 17.00:1 | 15.33:1 | 4.5 |
| text on a card | `--text` on `--bg-elev` | 15.34:1 | 13.92:1 | 4.5 |
| text on a code block | `--text` on `--code-bg` | 15.73:1 | 14.40:1 | 4.5 |
| muted text, nav link, footer | `--text-muted` on `--bg` | 6.95:1 | 6.98:1 | 4.5 |
| muted text on a card | `--text-muted` on `--bg-elev` | 6.27:1 | 6.33:1 | 4.5 |
| link | `--accent` on `--bg` | 7.09:1 | 9.17:1 | 4.5 |
| link on a card | `--accent` on `--bg-elev` | 6.40:1 | 8.32:1 | 4.5 |
| active nav item | `--accent` on `--accent-soft` | 6.05:1 | 7.78:1 | 4.5 |
| link, hovered | `--accent-hover` on `--bg` | 9.65:1 | 11.54:1 | 4.5 |
| primary button label | `--bg` on `--accent` | 7.09:1 | 9.17:1 | 4.5 |
| `tok-keyword` | `--tok-keyword` on `--code-bg` | 7.33:1 | 7.70:1 | 4.5 |
| `tok-taught` | `--tok-taught` on `--code-bg` | 6.56:1 | 8.61:1 | 4.5 |
| `tok-op` | `--tok-op` on `--code-bg` | 6.43:1 | 7.55:1 | 4.5 |
| `tok-ident` | `--tok-ident` on `--code-bg` | 15.73:1 | 14.40:1 | 4.5 |
| `tok-num` | `--tok-num` on `--code-bg` | 6.45:1 | 8.79:1 | 4.5 |
| `tok-str` | `--tok-str` on `--code-bg` | 6.61:1 | 9.25:1 | 4.5 |
| `tok-dir` | `--tok-dir` on `--code-bg` | 7.07:1 | 8.45:1 | 4.5 |
| `tok-hole` | `--tok-hole` on `--code-bg` | 7.08:1 | 8.29:1 | 4.5 |
| `tok-comment` | `--tok-comment` on `--code-bg` | 5.42:1 | 5.78:1 | 4.5 |
| focus ring on the page | `--focus` on `--bg` | 5.95:1 | 8.86:1 | 3.0 |
| focus ring on a card | `--focus` on `--bg-elev` | 5.37:1 | 8.05:1 | 3.0 |
| focus ring on a code block | `--focus` on `--code-bg` | 5.50:1 | 8.32:1 | 3.0 |
| control border (ghost button) | `--border-strong` on `--bg` | 3.36:1 | 3.55:1 | 3.0 |
| control border on a card | `--border-strong` on `--bg-elev` | 3.03:1 | 3.22:1 | 3.0 |
| `tok-taught` underline | `--accent` on `--code-bg` | 6.56:1 | 8.61:1 | 3.0 |

`--border` (`#ddd7ce` / `#302d2a`) is deliberately below 3:1. It draws separators — table rules,
the line under an `h2`, the edge of a code block — none of which identify a control or convey
information the text does not. Anything that *does* bound a control uses `--border-strong`.

---

## Type

System fonts only. Nothing is downloaded, so nothing reflows on a slow connection, and the site
looks native on the machine it is read on.

```css
--font-sans: ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto,
             "Helvetica Neue", Arial, "Noto Sans", sans-serif;
--font-mono: ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas,
             "DejaVu Sans Mono", "Liberation Mono", monospace;
```

**Every heading is monospaced.** Headings, the wordmark, the nav section labels, table headers,
buttons and the "fact" line on each home card are all in the mono stack; only running prose is
sans. It costs nothing, it is unmistakably a compiler's site, and it echoes the thing the whole
project is built on — a word that is always the same width.

Scale: ratio 1.2 (minor third), rounded to whole pixels at a 16px root.

| Token | Size | Used for |
|---|---|---|
| `--fs-micro` | 12px | copy button |
| `--fs-small` | 13px | outline, nav section labels, `.fact` |
| `--fs-ui` | 14px | nav, footer, tables, code blocks |
| `--fs-body` | 16px | body |
| `--fs-lead` | 18px | lead paragraph, home pitch, brand |
| `--fs-h3` | 20px | h3, card titles |
| `--fs-h2` | 24px | h2 |
| `--fs-h1` | 32px | h1 |
| `--fs-display` | 40px | home headline, the 404 number |

Line height 1.65 for prose, 1.55 in code, 1.25 for headings. Measure capped at **72ch** — about
80 characters at this size, the top of the comfortable range, chosen because the pages are dense
with `inline code` that eats width.

## Spacing

One module: **4px**, again the width of an instruction word. `--s1` through `--s9` are
4, 8, 12, 16, 24, 32, 48, 64, 96. Nothing in the stylesheet uses a spacing value that is not one
of those nine.

---

## Layout

```
                     < 900px          900-1199px            >= 1200px
  header             one line         one line              one line
  sidebar            behind "Menu"    15rem, sticky         15rem, sticky
  content            full width       max 72ch              max 72ch
  outline            hidden           hidden                14rem, sticky
```

**The sidebar toggle is a checkbox, not a script.** `<input type="checkbox" id="nav-toggle">` sits
at the very top of `<body>` so the CSS can reach the sidebar with a sibling combinator
(`.nav-toggle:checked ~ .layout .site-nav`), and the visible control is its `<label>` in the
header. Above 900px both are `display: none`, which also removes the invisible tab stop — the
sidebar is simply always open there. The checkbox stays keyboard-operable (Tab, then Space) and
the focus ring is drawn on the label through
`.nav-toggle:focus-visible ~ .site-header .nav-button`.

A `<details>` element would have been the tidier markup, but current browsers hide the contents of
a closed `<details>` through `::details-content` / `content-visibility`, which CSS in the page
cannot reliably override to force it open on wide screens. The checkbox works everywhere.

Two deliberate trade-offs, both visible above:

- **The outline is hidden below 1200px.** Below that the grid has no third column, so it would
  land *after* the content, where a page outline helps nobody. Moving it above the content with
  grid `order` would put its links out of tab order. The honest options were "hide it" or "let the
  generator emit it twice"; hiding it is the smaller lie. Revisit if the doc pages get long.
- **The header links stand down below 700px, but only when the "Menu" button is there.**
  `.nav-button ~ .header-nav { display: none }` — on a doc page the same sections are inside the
  menu, and on the home page and the 404 page (where the generator drops the toggle entirely,
  through `<!--if nav-->`) they stay visible. This keeps the header on one line at 320px.

Other layout notes: code blocks scroll horizontally inside themselves and carry `tabindex="0"` so
a keyboard user can scroll them; tables are wrapped in `.table-wrap` for the same reason; headings
carry `scroll-margin-top` so a fragment link does not park them under the sticky header; the copy
button on code blocks is optional and progressive — the page is complete without it and without
any script.

## Accessibility

- `<html lang="en">`, one `<h1>` per page, heading levels never skip.
- Skip link first in `<body>`, visible on focus.
- Landmarks on every page: `header`, `nav` (named), `main#content`, `footer`, plus `aside`
  (named) on doc pages. Both `<nav>`s and the `<aside>` carry `aria-label`.
- The active page is `aria-current="page"`, and is marked three ways: colour, a 2px leading bar,
  and bold — never colour alone.
- `:focus-visible` everywhere: 2px `--focus` ring, 2px offset.
- `prefers-reduced-motion`, `forced-colors` and `print` blocks are all present.
- No empty links: the pager's previous/next anchors are removed by the generator when there is no
  neighbour, rather than rendered with an empty name (see `site/README.md`).

Checked with `python3 site/tools/checkhtml.py`, which verifies tag balance, unique ids, heading
order, landmark presence, `label for` targets, fragment targets, accessible names on every link,
and that every `/static/...` reference exists on disk. It is not a conformance validator — see the
open questions in the M27 report.

---

## Files

| Path | What |
|---|---|
| `templates/base.html` | the shell: head, header, `{{content}}`, footer |
| `templates/page.html` | doc page: sidebar, content, pager, outline |
| `templates/home.html` | landing: pitch, three cards, code sample |
| `templates/404.html` | not found |
| `static/site.css` | the whole stylesheet |
| `static/icon.svg`, `favicon.svg`, `social.svg` | the mark |
| `static/icon-*.png`, `social.png` | raster exports |
| `tools/contrast.py` | the contrast table above |
| `tools/checkhtml.py` | structural and a11y checks |
| `tools/preview.py` | renders the templates into `preview/` before `mcsite` exists |
| `preview/*.html` | the three layouts, filled in by hand |

The template contract — every placeholder, who substitutes it, and the conditional-block rule —
is in `site/README.md`.
