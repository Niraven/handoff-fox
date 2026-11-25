#!/usr/bin/env python3
"""Build the Handoff Fox documentation site from the repository's own Markdown.

No documentation prose is copied into this script. The landing page is assembled
at build time from README.md, VISION.md, docs/SETUP.md, and docs/SUPPORT.md, and
the support matrix is parsed from the table inside docs/SUPPORT.md, which stays
the single source of truth.

Usage: python3 -B script/build_site.py [--out site]
"""

import argparse
from dataclasses import dataclass
import html
from pathlib import Path
import posixpath
import re
import shutil
from typing import Optional


REPO = Path(__file__).resolve().parents[1]
REPOSITORY = "https://github.com/Niraven/handoff-fox"
DEFAULT_BRANCH = "main"
DEFAULT_OUT = REPO / "site"

PAGES = (
    ("README.md", "readme.html", "Overview"),
    ("VISION.md", "vision.html", "Vision"),
    ("docs/SETUP.md", "setup.html", "Setup"),
    ("docs/SUPPORT.md", "support.html", "Support matrix"),
    ("docs/DEVELOPMENT.md", "development.html", "Development"),
    ("docs/ARCHITECTURE.md", "architecture.html", "Architecture"),
    ("docs/PROTOCOL.md", "protocol.html", "Protocol"),
    ("docs/ROADMAP.md", "roadmap.html", "Roadmap"),
    ("CONTRIBUTING.md", "contributing.html", "Contributing"),
    ("SECURITY.md", "security.html", "Security"),
    ("CHANGELOG.md", "changelog.html", "Changelog"),
    ("AGENTS.md", "agents.html", "Contributor instructions"),
    ("dependencies/licenses/README.md", "third-party-notices.html", "Third-party notices"),
)

ASSET_SUFFIXES = (".png", ".jpg", ".jpeg", ".gif", ".svg", ".webp", ".avif")

FENCE_RE = re.compile(r"^\s*(```|~~~)\s*([\w+-]*)\s*$")
HEADING_RE = re.compile(r"^(#{1,6})\s+(.*?)\s*#*\s*$")
HR_RE = re.compile(r"^(?:-{3,}|\*{3,}|_{3,})$")
QUOTE_RE = re.compile(r"^\s*>\s?(.*)$")
LIST_ITEM_RE = re.compile(r"^(\s*)(?:([-*+])|(\d{1,9})[.)])\s+(.*)$")
TABLE_SEP_RE = re.compile(
    r"^\s*\|?\s*:?-{2,}:?\s*(?:\|\s*:?-{2,}:?\s*)+\|?\s*$"
)
CODE_SPAN_RE = re.compile(r"(?<!`)`([^`]+)`(?!`)")
IMAGE_RE = re.compile(r'!\[([^\]]*)\]\(([^)\s]+)(?:\s+"([^"]*)")?\)')
LINK_RE = re.compile(r'\[([^\]]*)\]\(([^)\s]+)(?:\s+"([^"]*)")?\)')
BOLD_RE = re.compile(r"\*\*(?=\S)(.+?)(?<=\S)\*\*", re.S)
ITALIC_RE = re.compile(r"(?<![\w*])\*(?=\S)(.+?)(?<=\S)\*(?![\w*])", re.S)
UNDERSCORE_RE = re.compile(r"(?<![\w`])_(?=\S)(.+?)(?<=\S)_(?![\w`])", re.S)
SCHEME_RE = re.compile(r"^[a-zA-Z][a-zA-Z0-9+.-]*:")
DEFINITION_RE = re.compile(r"^\[([^\]]+)\]:\s*(\S+)(?:\s+\"([^\"]*)\")?\s*$")
REFERENCE_RE = re.compile(r"\[([^\]]+)\](?![(\[])")
ENTITY_RE = re.compile(r"&(?![a-zA-Z]+;|#\d+;|#x[0-9a-fA-F]+;)")


def escape_text(text):
    text = ENTITY_RE.sub("&amp;", text)
    return text.replace("<", "&lt;").replace(">", "&gt;")


def attribute(value):
    return value.replace('"', "&quot;")


def plain(text):
    """Strip inline Markdown so a heading can be used as a title or an id."""
    text = IMAGE_RE.sub(r"\1", text)
    text = LINK_RE.sub(r"\1", text)
    return text.replace("`", "").replace("*", "").replace("_", "").strip()


def anchor(text):
    slug = re.sub(r"[^a-z0-9]+", "-", plain(text).lower()).strip("-")
    return slug or "section"


@dataclass
class Section:
    level: Optional[int]
    heading: Optional[str]
    body: list


@dataclass
class Document:
    source: str
    dest: str
    label: str
    text: str

    @property
    def title(self):
        for section in sections(self.text):
            if section.level == 1 and section.heading:
                return plain(section.heading)
        return self.label


class BuildError(RuntimeError):
    pass


def sections(text):
    """Split Markdown into (level, heading, body lines); the preamble has no level."""
    found = [Section(None, None, [])]
    fence = None
    for line in text.splitlines():
        match = FENCE_RE.match(line)
        if fence:
            found[-1].body.append(line)
            if match and match.group(1) == fence:
                fence = None
            continue
        if match:
            fence = match.group(1)
            found[-1].body.append(line)
            continue
        heading = HEADING_RE.match(line)
        if heading:
            found.append(Section(len(heading.group(1)), heading.group(2), []))
        else:
            found[-1].body.append(line)
    return found


def paragraphs(lines):
    """Split lines into blank-line-separated paragraphs, keeping fenced code intact."""
    found = []
    current = []
    fence = None
    for line in lines:
        match = FENCE_RE.match(line)
        if fence:
            current.append(line)
            if match and match.group(1) == fence:
                fence = None
            continue
        if match:
            fence = match.group(1)
            current.append(line)
            continue
        if line.strip():
            current.append(line)
        elif current:
            found.append(current)
            current = []
    if current:
        found.append(current)
    return found


def lead(document_sections):
    """The body of a document's H1 section: the text before its first H2."""
    for section in document_sections:
        if section.level == 1:
            return section.body
    raise BuildError("document has no level-1 heading")


def find_section(source, document_sections, prefix, level=2):
    for section in document_sections:
        if section.level == level and section.heading and section.heading.startswith(prefix):
            return section
    raise BuildError(f"{source}: no level-{level} heading starting with {prefix!r}")


def split_row(line):
    row = line.strip()
    if row.startswith("|"):
        row = row[1:]
    if row.endswith("|") and not row.endswith("\\|"):
        row = row[:-1]
    return [cell.strip().replace("\\|", "|") for cell in re.split(r"(?<!\\)\|", row)]


def is_table_start(lines, index):
    if index + 1 >= len(lines):
        return False
    return "|" in lines[index] and bool(TABLE_SEP_RE.match(lines[index + 1]))


def parse_table(lines, index):
    """Read a pipe table starting at `index`; return (header cells, rows) and the next index."""
    header = split_row(lines[index])
    rows = []
    cursor = index + 2
    while cursor < len(lines) and lines[cursor].strip().startswith("|"):
        rows.append(split_row(lines[cursor]))
        cursor += 1
    width = len(header)
    rows = [(row + [""] * width)[:width] for row in rows]
    return header, rows, cursor


def first_table(lines):
    for index in range(len(lines)):
        if is_table_start(lines, index):
            header, rows, _ = parse_table(lines, index)
            return header, rows
    raise BuildError("no pipe table found")


def parse_blocks(lines):
    """Parse a block sequence: heading, paragraph, code, list, table, quote, hr."""
    blocks = []
    index, total = 0, len(lines)
    while index < total:
        line = lines[index]
        if not line.strip():
            index += 1
            continue
        fence = FENCE_RE.match(line)
        if fence:
            marker = fence.group(1)
            language = fence.group(2)
            code = []
            index += 1
            while index < total:
                closing = FENCE_RE.match(lines[index])
                if closing and closing.group(1) == marker:
                    index += 1
                    break
                code.append(lines[index])
                index += 1
            blocks.append(("code", language, "\n".join(code)))
            continue
        heading = HEADING_RE.match(line)
        if heading:
            blocks.append(("heading", len(heading.group(1)), heading.group(2)))
            index += 1
            continue
        if HR_RE.match(line.strip()):
            blocks.append(("hr",))
            index += 1
            continue
        if QUOTE_RE.match(line):
            inner = []
            while index < total and lines[index].strip():
                quoted = QUOTE_RE.match(lines[index])
                inner.append(quoted.group(1) if quoted else lines[index])
                index += 1
            blocks.append(("quote", inner))
            continue
        if DEFINITION_RE.match(line):
            while index < total and DEFINITION_RE.match(lines[index]):
                index += 1
            continue
        if is_table_start(lines, index):
            header, rows, index = parse_table(lines, index)
            blocks.append(("table", header, rows))
            continue
        if LIST_ITEM_RE.match(line):
            items, ordered, index = read_list(lines, index)
            blocks.append(("list", ordered, items))
            continue
        paragraph = []
        while index < total and lines[index].strip() and not starts_block(lines, index):
            paragraph.append(lines[index].strip())
            index += 1
        blocks.append(("paragraph", " ".join(paragraph)))
    return blocks


def starts_block(lines, index):
    line = lines[index]
    return bool(
        FENCE_RE.match(line)
        or HEADING_RE.match(line)
        or HR_RE.match(line.strip())
        or QUOTE_RE.match(line)
        or LIST_ITEM_RE.match(line)
        or is_table_start(lines, index)
    )


def read_list(lines, start):
    first = LIST_ITEM_RE.match(lines[start])
    base = len(first.group(1))
    ordered = first.group(3) is not None
    items = []
    index = start
    while index < len(lines):
        line = lines[index]
        indent = len(line) - len(line.lstrip())
        if not line.strip():
            following = index + 1
            while following < len(lines) and not lines[following].strip():
                following += 1
            if following < len(lines) and len(lines[following]) - len(lines[following].lstrip()) > base:
                items[-1]["extra"].append("")
                index += 1
                continue
            break
        match = LIST_ITEM_RE.match(line)
        if match and indent == base:
            items.append({"text": match.group(4), "extra": []})
            index += 1
            continue
        if match and indent > base:
            items[-1]["extra"].append(line)
            index += 1
            continue
        if indent > base:
            items[-1]["extra"].append(line.strip())
            index += 1
            continue
        break
    return items, ordered, index


def dedent(lines):
    indents = [len(line) - len(line.lstrip()) for line in lines if line.strip()]
    cut = min(indents) if indents else 0
    return [line[cut:] if line.strip() else "" for line in lines]


class Markdown:
    """Render the GitHub-flavored Markdown subset these documents use."""

    def __init__(self, site, source):
        self.site = site
        self.source = source
        self.definitions = site.definitions(source)

    def render(self, lines):
        return "\n".join(self.blocks(parse_blocks(lines)))

    def heading(self, level, text):
        return f'<h{level} id="{anchor(text)}">{self.inline(text)}</h{level}>'

    def blocks(self, parsed):
        rendered = []
        for block in parsed:
            kind = block[0]
            if kind == "heading":
                rendered.append(self.heading(block[1], block[2]))
            elif kind == "paragraph":
                rendered.append(f"<p>{self.inline(block[1])}</p>")
            elif kind == "code":
                language = f' class="language-{html.escape(block[1])}"' if block[1] else ""
                rendered.append(f"<pre><code{language}>{html.escape(block[2], quote=False)}</code></pre>")
            elif kind == "list":
                rendered.append(self.list_block(block[2], block[1]))
            elif kind == "table":
                rendered.append(self.table(block[1], block[2]))
            elif kind == "quote":
                rendered.append("<blockquote>\n" + self.render(block[1]) + "\n</blockquote>")
            elif kind == "hr":
                rendered.append("<hr>")
        return rendered

    def list_block(self, items, ordered, css_class=""):
        tag = "ol" if ordered else "ul"
        classes = f' class="{css_class}"' if css_class else ""
        parts = [f"<{tag}{classes}>"]
        for item in items:
            body = self.inline(item["text"])
            nested = []
            for line in item["extra"]:
                if not line.strip():
                    continue
                if LIST_ITEM_RE.match(line):
                    nested.append(line)
                else:
                    body += " " + self.inline(line.strip())
            if nested:
                body += "\n" + self.render(dedent(nested))
            parts.append(f"<li>{body}</li>")
        parts.append(f"</{tag}>")
        return "\n".join(parts)

    def table(self, header, rows, css_class=""):
        def cells(values, tag):
            return "".join(f"<{tag}>{self.inline(value)}</{tag}>" for value in values)

        classes = f' class="{css_class}"' if css_class else ""
        body = "\n".join(f"<tr>{cells(row, 'td')}</tr>" for row in rows)
        return (
            f'<div class="table"><table{classes}>\n'
            f"<thead><tr>{cells(header, 'th')}</tr></thead>\n"
            f"<tbody>\n{body}\n</tbody>\n</table></div>"
        )

    def inline(self, text):
        text = escape_text(text)
        codes = []

        def stash(match):
            codes.append(match.group(1))
            return f"\x00{len(codes) - 1}\x00"

        text = CODE_SPAN_RE.sub(stash, text)
        text = IMAGE_RE.sub(self.image, text)
        text = LINK_RE.sub(self.link, text)
        text = REFERENCE_RE.sub(self.reference, text)
        text = BOLD_RE.sub(r"<strong>\1</strong>", text)
        text = ITALIC_RE.sub(r"<em>\1</em>", text)
        text = UNDERSCORE_RE.sub(r"<em>\1</em>", text)
        for index, code in enumerate(codes):
            text = text.replace(f"\x00{index}\x00", f"<code>{code}</code>")
        return text

    def reference(self, match):
        name = match.group(1)
        target = self.definitions.get(name.lower())
        if not target:
            return match.group(0)
        return f'<a href="{attribute(self.site.href(self.source, target))}">{name}</a>'

    def image(self, match):
        alt, target = match.group(1), match.group(2)
        title = f' title="{attribute(match.group(3))}"' if match.group(3) else ""
        return f'<img src="{attribute(self.site.href(self.source, target))}" alt="{attribute(alt)}"{title} loading="lazy">'

    def link(self, match):
        label, target = match.group(1), match.group(2)
        title = f' title="{attribute(match.group(3))}"' if match.group(3) else ""
        return f'<a href="{attribute(self.site.href(self.source, target))}"{title}>{label}</a>'


CSS = """
:root {
  color-scheme: light dark;
  --bg: #fdfbf9;
  --surface: #ffffff;
  --sunken: #f6f2ef;
  --text: #1f1714;
  --text-2: #5c4f4a;
  --text-3: #7a6a63;
  --accent: #ba4a24;
  --accent-quiet: rgba(186, 74, 36, 0.09);
  --on-accent: #ffffff;
  --border: rgba(0, 0, 0, 0.08);
  --border-strong: rgba(0, 0, 0, 0.13);
  --shadow: rgba(0, 0, 0, 0.06);
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #16110f;
    --surface: #1e1815;
    --sunken: #231b17;
    --text: #f5ede8;
    --text-2: #c7b8ad;
    --text-3: #94857d;
    --accent: #f08a54;
    --accent-quiet: rgba(240, 138, 84, 0.11);
    --on-accent: #1f1208;
    --border: rgba(255, 255, 255, 0.09);
    --border-strong: rgba(255, 255, 255, 0.16);
    --shadow: rgba(0, 0, 0, 0.34);
  }
}
*, *::before, *::after { box-sizing: border-box; }
html { -webkit-text-size-adjust: 100%; }
body {
  margin: 0;
  background: var(--bg);
  color: var(--text);
  font: 16px/1.65 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
}
.layout {
  display: grid;
  grid-template-columns: 14rem minmax(0, 1fr);
  gap: 2.5rem;
  max-width: 72rem;
  margin: 0 auto;
  padding: 2.5rem 1.5rem 5rem;
}
.sidebar { position: sticky; top: 2.5rem; align-self: start; font-size: 0.9rem; }
.brand {
  display: inline-block;
  font-weight: 700;
  font-size: 1rem;
  letter-spacing: -0.01em;
  color: var(--text);
  text-decoration: none;
}
.brand small { display: block; color: var(--text-3); font-weight: 500; font-size: 0.78rem; letter-spacing: 0; }
.sidebar ul { list-style: none; margin: 1rem 0 0; padding: 0; display: grid; gap: 0.1rem; }
.sidebar a {
  display: block;
  padding: 0.32rem 0.55rem;
  border-radius: 6px;
  border-left: 2px solid transparent;
  color: var(--text-2);
  text-decoration: none;
}
.sidebar a:hover { background: var(--sunken); color: var(--text); }
.sidebar a[aria-current] {
  color: var(--accent);
  border-left-color: var(--accent);
  background: var(--accent-quiet);
  font-weight: 600;
}
main { min-width: 0; max-width: 52rem; }
main > p, main > ul, main > ol, main > blockquote { max-width: 44rem; }
h1, h2, h3, h4 { line-height: 1.25; letter-spacing: -0.01em; }
h1 { font-size: clamp(1.75rem, 1.25rem + 1.6vw, 2.3rem); margin: 0 0 1rem; }
h2 { font-size: 1.32rem; margin: 2.6rem 0 0.6rem; }
h3 { font-size: 1.07rem; margin: 1.9rem 0 0.45rem; }
h4 { font-size: 1rem; margin: 1.5rem 0 0.4rem; }
p, ul, ol { margin: 0.85rem 0; }
a { color: var(--accent); text-underline-offset: 0.15em; }
ul, ol { padding-left: 1.35rem; }
li { margin: 0.3rem 0; }
li p { margin: 0.35rem 0 0; }
code {
  font: 0.875em/1.4 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  background: var(--sunken);
  border: 1px solid var(--border);
  border-radius: 4px;
  padding: 0.1em 0.32em;
}
pre {
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: 8px;
  padding: 0.9rem 1rem;
  overflow-x: auto;
  box-shadow: 0 1px 2px var(--shadow);
}
pre code { background: none; border: 0; padding: 0; font-size: 0.85rem; }
.table {
  overflow-x: auto;
  margin: 1.2rem 0;
  border: 1px solid var(--border);
  border-radius: 8px;
  background: var(--surface);
}
table { border-collapse: collapse; width: 100%; font-size: 0.9rem; }
th, td { text-align: left; vertical-align: top; padding: 0.55rem 0.75rem; border-bottom: 1px solid var(--border); }
th { background: var(--sunken); font-weight: 600; white-space: nowrap; }
tbody tr:last-child td { border-bottom: 0; }
table.matrix { font-size: 0.85rem; min-width: 40rem; }
table.matrix th:first-child, table.matrix td:first-child { min-width: 12rem; }
table.matrix th, table.matrix td { padding: 0.5rem 0.6rem; }
table.matrix th { white-space: normal; }
table.matrix th:not(:first-child), table.matrix td:not(:first-child) { text-align: center; white-space: nowrap; }
blockquote {
  margin: 1.2rem 0;
  padding: 0.1rem 0 0.1rem 1rem;
  border-left: 3px solid var(--border-strong);
  color: var(--text-2);
}
hr { border: 0; border-top: 1px solid var(--border); margin: 2.4rem 0; }
img { max-width: 100%; height: auto; border-radius: 8px; border: 1px solid var(--border); }
figure { margin: 1.4rem 0; }
figure img { display: block; }
figcaption { color: var(--text-3); font-size: 0.85rem; margin-top: 0.45rem; }
.hero .lead { font-size: 1.15rem; color: var(--text-2); }
.hint { color: var(--text-3); font-size: 0.86rem; }
.actions { display: flex; flex-wrap: wrap; gap: 0.5rem; margin: 1.6rem 0 0; padding: 0; list-style: none; }
.actions a {
  display: inline-block;
  padding: 0.42rem 0.8rem;
  border: 1px solid var(--border-strong);
  border-radius: 7px;
  background: var(--surface);
  color: var(--text);
  font-size: 0.92rem;
  font-weight: 600;
  text-decoration: none;
}
.actions a:hover { border-color: var(--accent); color: var(--accent); }
.actions a.primary { background: var(--accent); border-color: var(--accent); color: var(--on-accent); }
.actions a.primary:hover { color: var(--on-accent); opacity: 0.92; }
.index { margin: 1rem 0 0; padding: 0; list-style: none; columns: 2; column-gap: 2rem; }
.index li { margin: 0.3rem 0; break-inside: avoid; }
footer { margin-top: 3.5rem; padding-top: 1rem; border-top: 1px solid var(--border); color: var(--text-3); font-size: 0.82rem; }
@media (max-width: 54rem) {
  .layout { grid-template-columns: 1fr; gap: 1.5rem; padding: 1.5rem 1.15rem 4rem; }
  .sidebar { position: static; border-bottom: 1px solid var(--border); padding-bottom: 1rem; }
  .sidebar ul { display: flex; flex-wrap: wrap; gap: 0.15rem; }
  .sidebar a { border-left: 0; border-bottom: 2px solid transparent; padding: 0.22rem 0.5rem; }
  .sidebar a[aria-current] { border-bottom-color: var(--accent); }
  .index { columns: 1; }
  main { max-width: none; }
}
""".strip()


class Site:
    def __init__(self, root=REPO):
        self.root = Path(root)
        self.dest = {source: dest for source, dest, _ in PAGES}
        self.assets = set()
        self.documents = {}
        for source, dest, label in PAGES:
            path = self.root / source
            if not path.is_file():
                raise BuildError(f"missing documentation source: {source}")
            self.documents[source] = Document(
                source=source, dest=dest, label=label, text=path.read_text(encoding="utf-8")
            )

    def definitions(self, source):
        document = self.documents.get(source)
        if not document:
            return {}
        found = {}
        for line in document.text.splitlines():
            match = DEFINITION_RE.match(line)
            if match:
                found[match.group(1).lower()] = match.group(2)
        return found

    def markdown(self, source):
        return Markdown(self, source)

    def href(self, source, target):
        target = target.strip()
        if not target or target.startswith("#") or SCHEME_RE.match(target) or target.startswith("//"):
            return target
        path, separator, anchor_name = target.partition("#")
        path = path.split("?")[0]
        if not path:
            return target
        resolved = posixpath.normpath(posixpath.join(posixpath.dirname(source), path))
        suffix = f"{separator}{anchor_name}" if separator else ""
        if resolved in self.dest:
            return self.dest[resolved] + suffix
        if resolved.lower().endswith(ASSET_SUFFIXES) and (self.root / resolved).is_file():
            self.assets.add(resolved)
            return resolved + suffix
        return f"{REPOSITORY}/blob/{DEFAULT_BRANCH}/{resolved}{suffix}"

    def shell(self, title, content, current=None):
        items = []
        for source, dest, label in PAGES:
            marker = ' aria-current="page"' if dest == current else ""
            items.append(f'<li><a href="{dest}"{marker}>{escape_text(label)}</a></li>')
        home = ' aria-current="page"' if current == "index.html" else ""
        return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{escape_text(title)} · Handoff Fox</title>
<meta name="color-scheme" content="light dark">
<meta name="description" content="Handoff Fox documentation, built from the repository's own Markdown.">
<style>
{CSS}
</style>
</head>
<body>
<div class="layout">
<nav class="sidebar" aria-label="Documentation">
<a class="brand" href="index.html"{home}>Handoff Fox<small>Documentation</small></a>
<ul>
{"".join(items)}
</ul>
</nav>
<main>
{content}
<footer>
<p>Built from this repository's Markdown by <code>script/build_site.py</code>.
Source, issues, and releases live on <a href="{REPOSITORY}">GitHub</a>.</p>
</footer>
</main>
</div>
</body>
</html>
"""

    def document_page(self, document):
        markdown = self.markdown(document.source)
        body = markdown.render(document.text.splitlines())
        content = f'<article class="doc">\n{body}\n</article>'
        return self.shell(document.title, content, document.dest)

    def landing_page(self):
        readme = self.documents["README.md"]
        vision = self.documents["VISION.md"]
        setup = self.documents["docs/SETUP.md"]
        support = self.documents["docs/SUPPORT.md"]

        readme_paragraphs = paragraphs(lead(sections(readme.text)))
        vision_paragraphs = paragraphs(lead(sections(vision.text)))
        if len(readme_paragraphs) < 2 or not vision_paragraphs:
            raise BuildError("README.md or VISION.md no longer opens with the intro paragraphs")

        readme_markdown = self.markdown(readme.source)
        vision_markdown = self.markdown(vision.source)
        setup_markdown = self.markdown(setup.source)
        support_markdown = self.markdown(support.source)

        hero = [readme_markdown.render(readme_paragraphs[0]), readme_markdown.render(readme_paragraphs[1])]
        figures = [p for p in readme_paragraphs[2:] if any(line.lstrip().startswith("![") for line in p)]
        hero.extend(readme_markdown.render(figure) for figure in figures)
        hero.append(vision_markdown.render(vision_paragraphs[0]))

        setup_sections = sections(setup.text)
        needs = find_section(setup.source, setup_sections, "What you need")
        install = find_section(setup.source, setup_sections, "Build the Mac app from")
        pairing = find_section(setup.source, setup_sections, "Pair and open Linux")
        support_sections = sections(support.text)
        actions = find_section(support.source, support_sections, "Actions")
        legend = lead(support_sections)
        header, rows = first_table(actions.body)

        parts = [
            '<article class="doc landing">',
            '<div class="hero">',
            '<h1>Handoff Fox</h1>',
            *hero,
            "</div>",
            '<ul class="actions">',
            f'<li><a class="primary" href="{self.dest[setup.source]}">Set up Handoff Fox</a></li>',
            f'<li><a href="{self.dest[support.source]}">Support matrix</a></li>',
            f'<li><a href="{self.dest[vision.source]}">Vision</a></li>',
            f'<li><a href="{self.dest["docs/ROADMAP.md"]}">Roadmap</a></li>',
            "</ul>",
            setup_markdown.heading(2, needs.heading),
            setup_markdown.render(needs.body),
            setup_markdown.heading(2, install.heading),
            setup_markdown.render(install.body),
            setup_markdown.heading(2, pairing.heading),
            setup_markdown.render(pairing.body),
            support_markdown.heading(2, "Support matrix"),
            support_markdown.render(legend),
            support_markdown.table(header, rows, css_class="matrix"),
            f'<p><a href="{self.dest[support.source]}">Read the full support matrix</a>, '
            "including the evidence line behind every verified cell.</p>",
        ]
        index = ['<h2 id="all-pages">Every document</h2>', '<ul class="index">']
        for source, dest, label in PAGES:
            index.append(f'<li><a href="{dest}">{escape_text(label)}</a></li>')
        index.append("</ul>")
        parts.append("\n".join(index))
        parts.append("</article>")
        return self.shell("Documentation", "\n".join(parts), "index.html")

    def build(self, out_dir=DEFAULT_OUT):
        out = Path(out_dir).resolve()
        if out == self.root or out == self.root.parent:
            raise BuildError(f"refusing to build over {out}")
        if out.exists():
            if not (out / "index.html").exists() and any(out.iterdir()):
                raise BuildError(f"{out} holds files this build did not write")
            shutil.rmtree(out)
        out.mkdir(parents=True)

        written = []
        for document in self.documents.values():
            target = out / document.dest
            target.write_text(self.document_page(document), encoding="utf-8")
            written.append(target)
        landing = out / "index.html"
        landing.write_text(self.landing_page(), encoding="utf-8")
        written.append(landing)

        for asset in sorted(self.assets):
            target = out / asset
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(self.root / asset, target)
            written.append(target)
        return written


def main(argv=None):
    parser = argparse.ArgumentParser(description="Build the Handoff Fox documentation site.")
    parser.add_argument("--out", default=str(DEFAULT_OUT), help="output directory (default: site)")
    options = parser.parse_args(argv)
    site = Site()
    written = site.build(options.out)
    print(f"Built {len(written)} files in {Path(options.out)}")
    for path in written:
        print(f"  {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
