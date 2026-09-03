# site/ — the mc documentation website

`docs/` is the source. This directory holds everything that turns it into a website: the
templates, the stylesheet, the mark, and the small tools used to check them. The generator itself
— `mcsite`, an mc program under `site/gen/` — is specified in `docs/specs/M27.md` and **does not
exist yet**. This file is the contract it has to satisfy.

The design rationale (palette, type scale, icon, contrast measurements, the reasoning behind the
responsive decisions) is in [`DESIGN.md`](DESIGN.md).

```
site/
  templates/   base.html  page.html  home.html  404.html
  static/      site.css  icon.svg  favicon.svg  social.svg  icon-*.png  social.png
  preview/     three pages with the placeholders filled in by hand
  tools/       contrast.py  checkhtml.py  preview.py   (checks, not the generator)
  gen/         mcsite, written in mc                    (M27, not written yet)
  public/      the built site                           (generated, not committed)
```

---

## The template contract

### Substitution

A placeholder is `{{name}}`, lowercase with underscores. The generator replaces it with the
value, **verbatim**, and **never rescans the result**: a value that happens to contain `{{`
is not substituted again. One pass per template, left to right.

A page is rendered in **two stages**:

1. Render the page-level template — `page.html`, `home.html` or `404.html` — substituting every
   placeholder with its value. `{{content}}` here receives the HTML rendered from the Markdown
   page.
2. Render `base.html`, substituting `{{content}}` with **the output of stage 1** and the remaining
   placeholders with their values.

`{{content}}` therefore appears in both stages. That is deliberate and safe, because stage 1
finishes before stage 2 begins and neither pass rescans what it produced. Rendering `base.html`
first would be wrong.

### Placeholders

| Placeholder | Value | Used by |
|---|---|---|
| `{{site_title}}` | the site name, e.g. `mc` | `base.html` |
| `{{base_url}}` | URL prefix for every asset and internal link, **ending in `/`** — `/` for a site at the domain root, `/mc/` under a GitHub Pages project path | `base.html`, `home.html`, `404.html` |
| `{{page_title}}` | the **complete** `<title>`, already composed — e.g. `Getting started · mc`. The templates do not append the site name | `base.html` |
| `{{page_url}}` | absolute URL of this page, for `<link rel=canonical>` and `og:url` | `base.html` |
| `{{content}}` | stage 1: the page body rendered from Markdown. stage 2: the whole page-level template's output | all |
| `{{nav}}` | the site navigation, a nested `<ul>` (shape below) | `page.html` |
| `{{toc}}` | this page's outline from its `h2`/`h3`, a nested `<ul>` (shape below) | `page.html` |
| `{{prev_url}}`, `{{prev_title}}` | the previous page in reading order, or empty | `page.html` |
| `{{next_url}}`, `{{next_title}}` | the next page in reading order, or empty | `page.html` |
| `{{edit_url}}` | link to this page's Markdown source in the repository | `page.html` |
| `{{year}}` | four digits, for the footer | `base.html` |

Values are substituted into HTML, so the generator escapes `&`, `<` and `>` in every value that
is not already markup (`{{page_title}}`, `{{prev_title}}`, `{{next_title}}`, `{{site_title}}`),
and in URLs it also escapes `"`. `{{content}}`, `{{nav}}` and `{{toc}}` are markup and are
inserted as-is.

### Conditional blocks

```html
<!--if prev_url-->
  ...markup...
<!--endif-->
```

If the named placeholder's value is empty or absent, the generator removes the block **and its
markers**. Otherwise it removes only the two marker comments and keeps the markup. Blocks do not
nest. This is pure string work — no HTML parsing — and it is the only extension beyond plain
`{{name}}` substitution.

It is used twice, and both uses matter:

- `page.html` wraps each pager link, so a first or last page does not get an `<a href="">` with
  no accessible name.
- `base.html` wraps the sidebar toggle in `<!--if nav-->`, so the "Menu" button does not appear on
  the home page and the 404 page, which have no sidebar. `base.html` may test any placeholder,
  including ones only a page-level template substitutes — the generator passes the same values to
  both stages.

### The shape of `{{nav}}`

Sections and pages, nested. `aria-current="page"` goes on the link to the page being rendered,
and on nothing else. A section title is a `<span>`, not a link, unless the section has an index
page — in which case use an `<a>` in the same position.

```html
<ul class="nav-list">
  <li class="nav-section">
    <span class="nav-section-title">Guide</span>
    <ul class="nav-list">
      <li><a href="/guide/getting-started/" aria-current="page">Getting started</a></li>
      <li><a href="/guide/one-file/">One file, one binary</a></li>
    </ul>
  </li>
</ul>
```

### The shape of `{{toc}}`

`h2` at the top level, `h3` nested one deeper. Nothing deeper than `h3`. Emit an empty string
when the page has no `h2` — the surrounding `<aside>` then shows only its own heading, and is
hidden below 1200px anyway.

```html
<ul class="toc-list">
  <li><a href="#build-the-seed">Build the seed</a>
    <ul class="toc-list">
      <li><a href="#the-fixed-point">The fixed point</a></li>
    </ul>
  </li>
</ul>
```

### The shape of `{{content}}`

Ordinary HTML from the Markdown subset, with four requirements the stylesheet depends on:

1. **Headings carry an `id`** and an anchor link, which is revealed on hover and on focus:
   `<h2 id="build-the-seed">Build the seed <a class="anchor" href="#build-the-seed" aria-label="Link to this section">#</a></h2>`.
   Ids are unique within a page.
2. **Tables are wrapped**: `<div class="table-wrap"><table>…</table></div>`, so a wide table
   scrolls inside its own box instead of widening the page.
3. **Code blocks** are `<pre class="code" tabindex="0"><code class="lang-XX">…</code></pre>`.
   `tabindex="0"` is required: the block scrolls horizontally, and a scrollable region has to be
   reachable by keyboard.
4. **Images** always have an `alt`.

If the generator adds the optional copy button, it goes **inside** the `<pre>`, before the
`<code>`: `<pre class="code" tabindex="0"><button class="code-copy" type="button">Copy</button><code …>`.
It is absolutely positioned, so it does not disturb the preformatted text, and the page is
complete and readable when it and its script are absent.

### Code highlighting

Inside a `lang-mc` block the bundled lexer wraps each token in a `<span>` with one of nine
classes. All nine are styled in both themes.

| Class | What it marks |
|---|---|
| `tok-keyword` | core keywords: the 7 types, `if`, `else`, `loop`, `break`, `continue`, `return`, `extern` |
| `tok-taught` | words that came from the surface: `#rule` literals, `#token` lexemes, `syntax*` registrations. Rendered bold **and dotted-underlined** — the one distinction the site is built to show |
| `tok-dir` | `#include`, `#define`, `#rule`, `#token`, `#infix`, `#section`, `#opcode`, and the grammar words inside them (`stmt`, `expr`, `block`, `ident`) |
| `tok-hole` | `$c`, `$$t` — rule holes and gensyms |
| `tok-str` | string and char literals, and an `#include <name>` target |
| `tok-num` | integer literals |
| `tok-ident` | every other name |
| `tok-op` | operators and punctuation |
| `tok-comment` | `//` comments |

A fence in another language (`sh`, `c`, `toml`) is emitted without spans; it still gets the code
block's frame and horizontal scrolling.

### What the generator must copy

Everything in `static/` goes to `public/static/` byte for byte. The templates reference
`{{base_url}}static/site.css`, `favicon.svg`, `icon-32.png`, `icon-180.png` and `social.png`; the
run should fail loudly if any of them is missing.

### Assumed URL layout

The templates link to `{{base_url}}guide/`, `{{base_url}}reference/`, `{{base_url}}examples/` and
`{{base_url}}guide/getting-started/`. Change the templates, or map `site.toml`'s sections onto
these paths.

---

## Looking at a page before `mcsite` exists

`tools/preview.py` is a throwaway Python implementation of the contract above — the two stages,
the conditional blocks, nothing else. It exists so the layout can be judged now, and so the rules
on this page have an executable statement of what they mean. It is **not** the generator.

```sh
python3 site/tools/preview.py     # writes site/preview/{index,getting-started,404}.html
cd site && python3 -m http.server 8000
```

Then open <http://localhost:8000/preview/index.html>. The pages use `base_url = /`, so the server
has to be started from `site/`, not from the repository root.

- `preview/index.html` — the landing page: pitch, three cards, the highlighted sample.
- `preview/getting-started.html` — a documentation page: sidebar, outline, tables, blockquote,
  code blocks, pager, edit link. The sidebar's unwritten pages point at the 404 page, so clicking
  around shows all three templates.
- `preview/404.html` — not found.

Things worth checking by hand: resize below 900px and open the "Menu" button (it must work with
the keyboard too — Tab to it, then Space); switch the system appearance to dark; press Tab from
the top of the page and confirm the skip link appears first.

The page content in `tools/preview-body.html` is hand-written sample prose, not generated from
`docs/`.

## Checks

```sh
python3 site/tools/contrast.py                 # WCAG ratios, parsed out of site.css
python3 site/tools/contrast.py --markdown      # the table in DESIGN.md
python3 site/tools/checkhtml.py                # structure and accessibility, on preview/
python3 site/tools/checkhtml.py site/public/*.html
```

Both exit non-zero on a problem, so they can be wired into `make check` alongside `mcsite --check`
when the generator lands.

`checkhtml.py` verifies tag balance and nesting, unique ids, exactly one `h1`, no skipped heading
levels, the four landmarks, accessible names on every link, `<label for>` targets, `<img alt>`,
`aria-current` values, fragment links that have a target, and that every `/static/…` reference
exists on disk.

It is **not** a conformance validator, and the machine has none: `/usr/bin/tidy` is the HTML 4.01
build from 2006 and `xmllint --html` uses libxml2's HTML 4.01 parser, so both reject `<header>`,
`<main>` and `<svg>` as unknown elements and are useless for HTML5. Run the W3C Nu validator if
you have it (`vnu site/preview/*.html`, or `brew install vnu`) before accepting M27.
