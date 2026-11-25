#!/usr/bin/env python3
"""Check that the generated documentation site matches the repository's Markdown."""

import importlib.util
from html.parser import HTMLParser
from pathlib import Path
import re
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]
BUILDER = REPO / "script/build_site.py"
SUPPORT = "docs/SUPPORT.md"

BLOCK_TAGS = {
    "p", "li", "tr", "div", "br", "blockquote", "h1", "h2", "h3", "h4", "h5", "h6",
}
MARKDOWN_LEFTOVERS = (
    (re.compile(r"\*\*"), "bold markers"),
    (re.compile(r"\]\("), "raw link target"),
    (re.compile(r"^\s{0,3}#+ "), "raw heading marker"),
    (re.compile(r"^\s*\|"), "raw table row"),
    (re.compile(r"::: "), "directive marker"),
    (re.compile(r"^\[[^\]]+\]:\s*\S+$"), "link definition line"),
)


def load_builder():
    spec = importlib.util.spec_from_file_location("handoff_fox_build_site", BUILDER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class PageReader(HTMLParser):
    """Collect visible text, link targets, and table cells from one built page."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.text = []
        self.links = []
        self.tables = []
        self.literal = 0
        self.table = None
        self.row = None
        self.cell = None

    def handle_starttag(self, tag, attrs):
        attributes = dict(attrs)
        if tag in ("pre", "code", "style"):
            self.literal += 1
        if tag in ("a", "img"):
            self.links.append(attributes.get("href") or attributes.get("src") or "")
        if tag == "table":
            self.table = {"class": attributes.get("class") or "", "rows": []}
        elif tag == "tr" and self.table is not None:
            self.row = []
        elif tag in ("td", "th") and self.row is not None:
            self.cell = []
        if tag in BLOCK_TAGS:
            self.text.append("\n")

    def handle_endtag(self, tag):
        if tag in ("pre", "code", "style") and self.literal:
            self.literal -= 1
        if tag in ("td", "th") and self.cell is not None:
            self.row.append(" ".join("".join(self.cell).split()))
            self.cell = None
        elif tag == "tr" and self.row is not None:
            self.table["rows"].append(self.row)
            self.row = None
        elif tag == "table" and self.table is not None:
            self.tables.append(self.table)
            self.table = None
        if tag in BLOCK_TAGS:
            self.text.append("\n")

    def handle_data(self, data):
        if self.literal:
            return
        if self.cell is not None:
            self.cell.append(data)
        self.text.append(data)


class SiteBuildTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.builder = load_builder()
        cls.out = tempfile.TemporaryDirectory(prefix="handoff-fox-site-")
        cls.site = cls.builder.Site(REPO)
        cls.written = cls.site.build(cls.out.name)
        cls.pages = {}
        for path in sorted(Path(cls.out.name).glob("*.html")):
            reader = PageReader()
            reader.feed(path.read_text(encoding="utf-8"))
            cls.pages[path.name] = reader

    @classmethod
    def tearDownClass(cls):
        cls.out.cleanup()

    def read(self, name):
        return (Path(self.out.name) / name).read_text(encoding="utf-8")

    def test_every_document_becomes_a_page(self):
        expected = {dest for _, dest, _ in self.builder.PAGES} | {"index.html"}
        self.assertEqual(set(self.pages), expected)
        for name in expected:
            self.assertIn("<h1", self.read(name), f"{name} has no heading")

    def test_landing_matrix_matches_support_markdown(self):
        source = (REPO / SUPPORT).read_text(encoding="utf-8")
        actions = self.builder.find_section(SUPPORT, self.builder.sections(source), "Actions")
        header, rows = self.builder.first_table(actions.body)
        self.assertGreater(len(rows), 20, "the support matrix lost its rows")

        matrices = [table for table in self.pages["index.html"].tables if table["class"] == "matrix"]
        self.assertEqual(len(matrices), 1, "the landing page needs exactly one generated matrix")
        self.assertEqual(matrices[0]["rows"], [header] + rows)

    def test_no_raw_markdown_survives(self):
        for name, page in self.pages.items():
            for line in "".join(page.text).splitlines():
                for pattern, description in MARKDOWN_LEFTOVERS:
                    self.assertIsNone(
                        pattern.search(line), f"{name} kept a {description}: {line.strip()[:80]}"
                    )

    def test_internal_links_point_at_built_files(self):
        for name, page in self.pages.items():
            for link in page.links:
                if not link or link.startswith(("http://", "https://", "mailto:", "#")):
                    continue
                target = link.split("#")[0]
                self.assertTrue(target, f"{name} has an empty link")
                self.assertTrue(
                    (Path(self.out.name) / target).is_file(), f"{name} links to missing {link}"
                )

    def test_no_repository_markdown_links_remain(self):
        for name, page in self.pages.items():
            for link in page.links:
                if link.startswith(("http://", "https://", "mailto:", "#")):
                    continue
                self.assertFalse(
                    link.split("#")[0].endswith(".md"), f"{name} still links to {link}"
                )


if __name__ == "__main__":
    unittest.main()


class InlineRenderingTests(unittest.TestCase):
    """The renderer is hand-written, so the forms it claims to support are pinned here."""

    @classmethod
    def setUpClass(cls):
        cls.builder = load_builder()
        cls.site = cls.builder.Site(REPO)

    def render(self, markdown):
        page = self.builder.Markdown(self.site, SUPPORT)
        return page.render(markdown.splitlines())

    def test_link_and_image_titles_survive_escaping(self):
        page = self.render('[x](SETUP.md "the title")')
        self.assertIn('title="the title"', page)
        self.assertIn('href="setup.html"', page)
        self.assertNotIn("[x](", page)
        image = self.render('![fox](assets/TrayFox.png "a fox")')
        self.assertIn('title="a fox"', image)
        self.assertIn('alt="fox"', image)

    def test_quotes_in_prose_stay_readable(self):
        page = self.render('He pressed "Pair" and it worked.')
        self.assertIn('"Pair"', page)
        self.assertNotIn("&quot;", page)

    def test_unknown_citation_stays_text(self):
        page = self.render("Verified [3][7] on Omarchy.")
        self.assertIn("[3][7]", page)
        self.assertNotIn("<a href", page)
