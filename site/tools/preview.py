#!/usr/bin/env python3
"""preview.py - render site/templates/ with hand-written values into site/preview/.

This is NOT the site generator. `mcsite`, written in mc, is the real one
(docs/specs/M27.md). This throwaway exists so the layout can be looked at
before mcsite is written, and so the substitution contract in site/README.md
has an executable statement of what it means.

    python3 site/tools/preview.py
    cd site && python3 -m http.server 8000   # then open /preview/index.html
"""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
TPL = ROOT / "templates"
OUT = ROOT / "preview"

IF_BLOCK = re.compile(r"[ \t]*<!--if ([a-z_]+)-->\n?(.*?)[ \t]*<!--endif-->\n?", re.S)


def render(template: str, values: dict) -> str:
    """One pass. Conditional blocks first, then placeholders. Values are
    substituted verbatim and are never rescanned for further placeholders."""
    def keep(m):
        return m.group(2) if values.get(m.group(1)) else ""
    out = IF_BLOCK.sub(keep, template)
    return re.sub(r"\{\{([a-z_]+)\}\}",
                  lambda m: values.get(m.group(1), ""), out)


def page(inner_template: str, values: dict) -> str:
    inner = render((TPL / inner_template).read_text(), values)
    return render((TPL / "base.html").read_text(), {**values, "content": inner})


COMMON = {
    "site_title": "mc",
    "base_url": "/",
    "year": "2026",
}

NAV = """<ul class="nav-list">
      <li class="nav-section">
        <span class="nav-section-title">Guide</span>
        <ul class="nav-list">
          <li><a href="/preview/getting-started.html" aria-current="page">Getting started</a></li>
          <li><a href="/preview/404.html">One file, one binary</a></li>
          <li><a href="/preview/404.html">Projects and mc.toml</a></li>
          <li><a href="/preview/404.html">Teaching the compiler</a></li>
          <li><a href="/preview/404.html">Cross-compiling</a></li>
        </ul>
      </li>
      <li class="nav-section">
        <span class="nav-section-title">Reference</span>
        <ul class="nav-list">
          <li><a href="/preview/404.html">Core language</a></li>
          <li><a href="/preview/404.html">Directives</a></li>
          <li><a href="/preview/404.html">Parser and hook API</a></li>
          <li><a href="/preview/404.html">Command line</a></li>
          <li><a href="/preview/404.html">Diagnostics</a></li>
        </ul>
      </li>
    </ul>"""

TOC = """<ul class="toc-list">
      <li><a href="#build-the-seed">Build the seed</a></li>
      <li><a href="#compile-the-compiler">Compile the compiler</a>
        <ul class="toc-list">
          <li><a href="#the-fixed-point">The fixed point</a></li>
          <li><a href="#what-clang-touched">What clang touched</a></li>
        </ul>
      </li>
      <li><a href="#your-first-program">Your first program</a></li>
      <li><a href="#teach-it-something">Teach it something</a></li>
      <li><a href="#where-to-go-next">Where to go next</a></li>
    </ul>"""

BODY = pathlib.Path(__file__).with_name("preview-body.html").read_text()


def main():
    OUT.mkdir(exist_ok=True)

    (OUT / "index.html").write_text(page("home.html", {
        **COMMON,
        "page_title": "mc - a mini compiler that compiles itself",
        "page_url": "/preview/index.html",
        "content": "",
    }))

    (OUT / "getting-started.html").write_text(page("page.html", {
        **COMMON,
        "page_title": "Getting started · mc",
        "page_url": "/preview/getting-started.html",
        "content": BODY,
        "nav": NAV,
        "toc": TOC,
        "prev_url": "",
        "prev_title": "",
        "next_url": "/preview/404.html",
        "next_title": "One file, one binary",
        "edit_url": "https://github.com/schivei/mc/edit/main/docs/guide/getting-started.md",
    }))

    (OUT / "404.html").write_text(page("404.html", {
        **COMMON,
        "page_title": "Page not found · mc",
        "page_url": "/preview/404.html",
        "content": "",
    }))

    for f in sorted(OUT.iterdir()):
        print(f"{f.relative_to(ROOT.parent)}  {f.stat().st_size} bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
