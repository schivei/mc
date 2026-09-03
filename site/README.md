# site/ — the mc documentation website

`docs/` is the source. This directory holds everything that turns it into a website: the
generator, the templates, the stylesheet, the mark, and the small tools used to check them.

```sh
build/mc1 build site         # site/mc.toml: compiles site/gen/*.mc into build/mcsite
build/mcsite site            # renders docs/ into site/public
build/mcsite site --check    # the same, then validates links, structure and contrast
cd site/public && python3 -m http.server 8000
```

Two consecutive runs write byte-identical files: nothing in the output comes from a clock, a
directory order or an address (`docs/determinism.md`). The generator rebuilds `site/public` from
scratch on every run, so a page deleted from `docs/` cannot survive there.

The design rationale (palette, type scale, icon, contrast measurements, the reasoning behind the
responsive decisions) is in [`DESIGN.md`](DESIGN.md).

```
site/
  site.toml    the site: title, base URL, sections, search              (M27)
  mc.toml      how `mc build` turns site/gen into build/mcsite          (M27)
  gen/         mcsite, written in mc: util md hl tmpl site check main   (M27)
  templates/   base.html  page.html  home.html  404.html
  static/      site.css  icon.svg  favicon.svg  social.svg  icon-*.png  social.png
  tools/       contrast.py  checkhtml.py  preview.py   (checks, not the generator)
  public/      the built site                          (generated, not committed)
```

---

## `site.toml`

Every path in it is relative to **the directory of `site.toml`**, never to the working directory —
the same rule `mc.toml` follows in `mc build` (`docs/build.md`).

| `[site]` key | meaning |
|---|---|
| `title`, `tagline` | the site name and the one-line description that follows it in the home page's `<title>` |
| `description` | the home page's `<meta name=description>` and `og:description`; every other page uses its own first paragraph |
| `base_url` | URL prefix of every asset and internal link, always ending in `/`. `/` at a domain root, `/mc/` under a GitHub Pages project path |
| `origin` | scheme and host, for `<link rel=canonical>`, `og:url` and `sitemap.xml` |
| `title_separator` | between a page title and the site title: `Getting started - mc` |
| `year` | the footer's year. **Data, not the system clock** — a build must not depend on the day it runs |
| `edit_url` | prefix of "Edit this page"; the page's path in the repository is appended |
| `search` | `true` writes `search.json` and fills `{{search}}` with the header form and its script |
| `docs`, `out`, `templates`, `static`, `repo` | the four directories and the repository root |
| `home` | optional Markdown rendered into the home page's `.home-extra` (its `# ` headings are demoted: `home.html` already has the `h1`) |
| `highlight` | fence languages that go through the bundled lexer. Default `["mc"]` |
| `nav` | the section ids, in sidebar and reading order |

A section is `[section.<id>]` with `title`, `dir` (under `docs`, `.` for the root), `url` (under
`base_url`) and an optional `order` — the file names or slugs that come first, everything else
following sorted by file name. **A section whose directory does not exist still gets its index
page**, so the links in the header never land on the 404 page; the index says the section has no
pages yet. A section directory's `index.md` or `README.md` becomes its index page; without one the
index is generated from the section's pages and their first paragraphs.

`docs/guide/00-getting-started.md` is `/guide/getting-started/`: the numeric prefix is what puts a
sorted listing in reading order, and it is not part of the address.

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
| `{{edit_url}}` | link to this page's Markdown source in the repository, empty for a generated page | `page.html` |
| `{{page_description}}` | the page's first paragraph as plain text, for `<meta name=description>` and `og:description` | `base.html` |
| `{{search}}` | the header search form and its inline script; empty when `[site] search` is off | `base.html` |
| `{{year}}` | four digits, from `[site] year` — never from the clock | `base.html` |

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
page — in which case use an `<a>` in the same position, which is what `mcsite` always emits: every
section gets an index page. A section with no pages gets no inner `<ul>` at all.

```html
<ul class="nav-list">
  <li class="nav-section">
    <a class="nav-section-title" href="/guide/">Guide</a>
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

The copy button is **not** emitted (M27 decision, following the designer's own preview): it is
optional in this contract, it needs a second script on every page, and `pre.code` is already
selectable and keyboard-reachable. `.code-copy` stays in the stylesheet, so adding it later is a
change in one function of `site/gen/hl.mc` and nothing else. Its place, if it comes, is **inside**
the `<pre>`, before the `<code>`.

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
block's frame and horizontal scrolling. `[site] highlight` is the list of languages that do go
through the lexer, and it defaults to `["mc"]`.

How `site/gen/hl.mc` decides what is *taught*, given that it parses nothing and runs no `user_init`:

- the fence itself is scanned for `#token`, `#rule` (the first literal after `stmt:`), `#infix`,
  `#prefix` and `syntax("word", …)`, which is where a lexeme is always named;
- `#include <name>` inside the fence brings the vocabulary of the file the bundle serves under that
  name — `#include <prelude>` is what makes `while`, `for` and `+=` come out taught;
- ```` ```mc taught=lib/mc_syntax_demo.mc ```` names one more file, resolved against the repository
  root; when it is not readable the fence falls back to the core classes and says so on stderr.

Those lexemes are also registered with `tok_add` before the fence is lexed, so a taught operator
comes out as one token. The table is rebuilt from `tok_init` for **every** fence, so one page can
never colour another's code.

A fence the lexer would refuse — an unterminated string, a character no punctuation table knows,
the deliberate errors half of `docs/` is about — is emitted with no spans at all, and the run's
last line counts them. That check (`hl_scan_ok`) mirrors `lex_next`'s error paths one by one; it is
what keeps a documentation site from dying on a documented diagnostic.

### What the generator must copy

Everything in `static/` goes to `public/static/` byte for byte. The templates reference
`{{base_url}}static/site.css`, `favicon.svg`, `icon-32.png`, `icon-180.png` and `social.png`; the
run should fail loudly if any of them is missing.

### Assumed URL layout

The templates link to `{{base_url}}guide/`, `{{base_url}}reference/` and `{{base_url}}examples/`,
and `site.toml` maps three sections onto exactly those paths. The two "Getting started" buttons
used to point at `{{base_url}}guide/getting-started/`, a page that does not exist until the guide
is written; they now point at the guide's index, which always exists and lists it first.

---

## What ends up in `public/`

```
public/
  index.html                 home.html
  404.html                   404.html, where GitHub Pages looks for it
  guide/index.html           one directory per page, so the URL ends in '/'
  guide/getting-started/index.html
  sitemap.xml                every page, <loc> only: no lastmod, nothing dated
  search.json                [{u, t, s, d, h:[{i, t}]}] - url, title, section,
                             first paragraph, and every h2/h3 with its id
  static/...                 site/static copied byte for byte
```

`search.json` is fetched by the header form's script on the first keystroke, never on load, and the
form stays hidden until that script runs — a reader without JavaScript is not shown a box that
cannot search. The whole search feature disappears from every page when `[site] search` is off.

## The Markdown subset

ATX headings (`#` … `######`) with ids and an anchor, paragraphs, `**strong**`, `*em*`, `_em_` (only
at a word boundary, so `snake_case` survives), `` `code` ``, links, images, autolinks, ordered and
unordered lists with nesting, blockquotes, pipe tables (`\|` inside a cell is a literal bar),
thematic breaks and fenced code. Written-out entities (`&mdash;`) pass through; everything else is
escaped.

Deliberately absent, because `docs/` does not need them: reference links (`[x][1]`), setext
headings (a `---` line is always a thematic break), indented 4-space code blocks, raw HTML (it is
escaped), footnotes.

Four rules keep every page valid whatever the Markdown does:

- **exactly one `h1` per page.** The first `# ` is the page title; a second one — `docs/plan.md`
  opens each phase with `# ` — is rendered as an `h2`, and a page with none gets an `h1` built from
  its title. Both are reported on stderr.
- **a link is rewritten, not trusted.** `[x](build.md)` becomes the URL of the page that file maps
  to; `[the prelude](../lib/prelude.mc)` becomes a link to the source in the repository
  (`[site] edit_url`); a link to neither is left as written and `--check` reports it.
- **only `http:`, `https:` and `mailto:` may be absolute.** The test is the URL's scheme
  (`u_scheme` in `util.mc`), never the substring `://` — `javascript://%0aalert(1)//` carries that
  substring exactly like a real URL. A link, image or autolink whose scheme is refused is not a
  link at all: its source is written out as escaped text and the page is named on stderr. `--check`
  applies the same list to every `href`/`src` it reads back, so a scheme written by a template or
  by `site.toml` is reported as a link problem.
- **nesting past 8 levels degrades, it does not disappear.** Blockquotes and list items recurse
  down to `MD_MAXDEPTH`; deeper than that the remaining text is written escaped inside a `<p>`
  instead of being dropped, and the page is named on stderr.

## Looking at a page

```sh
build/mcsite site && cd site/public && python3 -m http.server 8000
```

`site/public` is generated and not committed; `.claude/launch.json`'s `site-preview` serves it on
port 8765.

`tools/preview.py` is the throwaway Python implementation of the template contract that existed
before `mcsite` did — the two stages, the conditional blocks, nothing else. It still runs
(`python3 site/tools/preview.py` writes `site/preview/{index,getting-started,404}.html` from
`tools/preview-body.html`) and is useful for judging a template change with no compiler and no
`docs/`, but `site/preview/` is now generated on demand and gitignored: the site itself is the
preview.

Things worth checking by hand after a template change: resize below 900px and open the "Menu"
button (it must work with the keyboard too — Tab to it, then Space); switch the system appearance
to dark; press Tab from the top of the page and confirm the skip link appears first; type two
letters in the search box and press Escape.

## Checks

`mcsite --check` is the whole gate. It rebuilds the site, then

- resolves every `href`/`src` of every page it wrote: a fragment has to have its id on that page, a
  URL under `base_url` has to name a file that exists in `site/public`, and anything else is
  reported;
- spawns `python3 site/tools/checkhtml.py` on every page and `python3 site/tools/contrast.py`,
  exactly the way `mc build` spawns the linker. **Without `python3` those two are reported as
  skipped and the link check still runs**; with it, a non-zero exit from either fails the run.

```sh
build/mcsite site --check                      # everything above; exit 1 on a problem
python3 site/tools/contrast.py                 # WCAG ratios, parsed out of site.css
python3 site/tools/contrast.py --markdown      # the table in DESIGN.md
python3 site/tools/checkhtml.py site/public/index.html
```

`checkhtml.py` verifies tag balance and nesting, unique ids, exactly one `h1`, no skipped heading
levels, the four landmarks, accessible names on every link, `<label for>` targets, `<img alt>`,
`aria-current` values, fragment links that have a target, and that every `/static/…` reference
exists on disk.

It is **not** a conformance validator, and the machine has none: `/usr/bin/tidy` is the HTML 4.01
build from 2006 and `xmllint --html` uses libxml2's HTML 4.01 parser, so both reject `<header>`,
`<main>` and `<svg>` as unknown elements and are useless for HTML5. Run the W3C Nu validator if you
have it (`vnu site/public/index.html`, or `brew install vnu`).
