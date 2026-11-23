"""Builds the two small test libraries Kiwix (PrepareMe)'s reopen test swaps between (kiwix-mac/build.sh --tsan).

Both carry the same fixed ID, as a rebuilt PrepareMe volume does (FINDINGS F-003), and differ in their version letter,
so the test can tell which copy Kiwix is reading. B also carries extra pages, so its search indexes sit at other
offsets in the file than A's: a search index reopened by file name from the wrong copy then reads garbage, as it would
after a real rebuild (FINDINGS F-044). A and B have a full-text and a title index; titles-A and titles-B have only the
title index, so a search's results come from the title index alone (libzim's full-text index also holds titles, and is
opened with the archive, so it would hide a broken title index). other-id is A under another ID, as a stray copy of
another library at the same path would be.

A and B also carry media/clip.mp4, 300000 bytes stored uncompressed (so libzim can hand out its place in the file and
Kiwix can read it by path and offset), all "A" in A and all "B" in B, so the app's test can tell which copy it read
after a swap.

The PrepareMe phone app's tests read two more libraries. app-links is a front page with a link to a page in app-maps
(by its ID) and one to a library no phone has (ABSENT_ID); a page found by search and a page kept out of full-text
search the way the packer keeps the front page out (the packer's own _FrontEntry), both holding the made-up word
quokka; and the same kind of uncompressed media/clip.mp4, with a repeating byte pattern. app-maps is a front page
and a "Find a map" page. app-search holds made-up guides named for a word (floodwater) and guides whose bodies say that
word more often, and three water guides made up in the real ones' shape (titles, bodies, search words), for the search order
test (beta run 2, B2-31, B2-18); and, found by title only, the real walk-throughs' titles and a crowd of made-up titles
with c and co words, and full-text pages whose titles start with co (a guide, map pages), so a title typed from "The
c" has to be found, and lead, as typed (2026-10-22). app-encyclopedia is a second library beside it, with an article
holding every word of a search no guide holds whole (2026-10-28).

--check-home DIR fills DIR as the Mac app's check build reads it (kiwix-mac/build.sh --app-mac-check DIR, opened with
`open -n --env PREPAREME_CHECK_HOME=DIR`; Mac sidebar plan, Task 9): Library › Application Support › PrepareMe with a
delivery folder (a made-up daily library, topo overview and street map, and the manifest.json naming them; the daily
library also holds a made-up guide with a walk-through, step 10, and meaning search's numbers when the model is made) and an
inventory folder (copies of the made-up rehearsal inventory and lists fixture), and Household Private › Plans ›
card.toml, the made-up card (paper/tests/fixtures/card-sample.toml). The daily library holds a Today front
page, guides.html, news.html, news-board.html (the rebuilt News page, from dashboard/tests' made-up page.json), new-guides.html, inventory.html, a topic-<slug>.html for each topic and household/guide-topics.json, the shared
fixture app/Service's GuideTopics reads, so every sidebar row loads a page; --no-topics leaves the JSON out (the
sidebar then shows no Categories row). --games FOLDER adds a made-up games file, prepareme-games.zim, built from that
folder's files as they are, its index.html the Games list (full-screen play's checks, games 3b). --dc-conditions adds the phone's conditions settings for the DC test area
(app/Service's Fixtures/conditions/settings-dc.json, and area-dc.json beside it, a made-up state file whose feeds
addresses lead nowhere), which only a simulator's build reads (owner, 2026-10-21), so a
session's simulator reads the live feeds for Washington, DC; the real packer refuses that file. Made-up words only. DIR must be a scratch folder under /private/tmp or the
temporary folder, as build.sh's check requires, so a slip can never write over the real delivery folder.
"""

import hashlib
import json
import mimetypes
import shutil
import sys
from datetime import datetime, timedelta
from pathlib import Path

from libzim.writer import Creator, Hint, Item, StringProvider

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from packer.build import (BASE, GUIDES_PAGE, INVENTORY_PAGE, NEWS_BOARD_PAGE, NEWS_PAGE, READING, SIDE_STYLE,  # noqa: E402
                          STYLE, STYLE_MARKER, _FrontEntry, _head)
from packer.news_style import BOARD_STYLE  # noqa: E402
from packer.guide_topics import NEW_HEADING, NEW_PAGE, TOPICS_PATH  # noqa: E402
from packer.guide_links import LINKS_PATH, links_json  # noqa: E402
from packer.map_pages import FURNITURE, MAP_PAGES  # noqa: E402
from packer import calculator_links  # noqa: E402
from packer.config import CALCULATOR_LINKS_FILE, CONTENT_DIR, load_calculator_links  # noqa: E402
from packer.pages import Page as GuidePage, render_page  # noqa: E402
from packer import guide_list, home_calls, library_card, meaning, spelling, steps, walkthroughs  # noqa: E402
from packer.phone_settings import AREA_PATH, SETTINGS_PATH  # noqa: E402
from packer.zimid import pin_uuid  # noqa: E402

FIXTURE_ID = "0f1e2d3c-4b5a-4968-8776-655443322110"  # the test's own ID, never a live volume's
OTHER_ID = "0f1e2d3c-4b5a-4968-8776-655443322111"  # another made-up ID
LINKS_ID = "0f1e2d3c-4b5a-4968-8776-6554433221a1"  # the app's links library
MAPS_ID = "0f1e2d3c-4b5a-4968-8776-6554433221a2"  # the library the links library points at
ABSENT_ID = "0f1e2d3c-4b5a-4968-8776-6554433221a3"  # carried by no fixture
SEARCH_ID = "0f1e2d3c-4b5a-4968-8776-6554433221a4"  # the search order test's library (B2-31)
ENCYCLOPEDIA_ID = "0f1e2d3c-4b5a-4968-8776-6554433221a5"  # the search test's second library (app-encyclopedia)
LONG_TITLE_ID = "0f1e2d3c-4b5a-4968-8776-6554433221a6"  # a title too long for Kiwix's spelling help (app-long-title)
DAILY_ID = "0f1e2d3c-4b5a-4968-8776-6554433221b1"  # the check home's daily library (both variants: a rebuild keeps it)
OVERVIEW_ID = "0f1e2d3c-4b5a-4968-8776-6554433221b2"  # the check home's topo overview (Find a map)
GONE_ID = "0f1e2d3c-4b5a-4968-8776-6554433221ff"  # no fixture ships it: Today's link to a library this device lacks

REPO = Path(__file__).resolve().parents[1]
TOPICS_FIXTURE = REPO / "app/Service/Tests/PrepareMeSharedTests/Fixtures/guide-topics.json"
REHEARSAL = REPO / "readiness/tests/fixtures/rehearsal.grist"
NEWS_FIXTURE = REPO / "dashboard/tests/fixtures/news/page-full.json"  # made-up stories and marks
CARD_SAMPLE = REPO / "paper/tests/fixtures/card-sample.toml"  # the made-up Family Emergency Card
LISTS_FIXTURE = REPO / "app/Service/Tests/PrepareMeSharedTests/Fixtures/lists.json"
SUPPLY_FIXTURE = REPO / "app/Service/Tests/PrepareMeSharedTests/Fixtures/supply.json"
DC_SETTINGS = REPO / "app/Service/Tests/PrepareMeSharedTests/Fixtures/conditions/settings-dc.json"  # the DC test area
DC_AREA = REPO / "app/Service/Tests/PrepareMeSharedTests/Fixtures/conditions/area-dc.json"  # its made-up state file
STREET_MAP = REPO / "app/Service/Tests/PrepareMeSharedTests/Fixtures/street-map-with-places.pmtiles"  # made-up area
STREET_MAP_ID = "0f1e2d3c-4b5a-4968-8776-6554433221b3"
MEDIA_ID = "0f1e2d3c-4b5a-4968-8776-6554433221b4"  # the check home's video library (phase C), with --video only
REFERENCE_ID = "0f1e2d3c-4b5a-4968-8776-6554433221b5"  # the check home's made-up reference library (Library)
KNOTS_ID = "0f1e2d3c-4b5a-4968-8776-6554433221c7"  # a made-up download the starting shelf places in Skills (Library plan)
KNOTS_TITLE = "Made-up knots"
DOWNLOAD_ID = "0f1e2d3c-4b5a-4968-8776-6554433221b6"  # its made-up Get More Libraries download
DOWNLOAD_TITLE = "Made-up Wikipedia sample"
GAMES_ID = "0f1e2d3c-4b5a-4968-8776-6554433221c9"  # the check home's made-up games file, with --games only (games 3b)
VIDEO_PAGE, VIDEO_PATH = "made-up-video.html", "made-up-step.mp4"  # its manifest entry's (a street map has no ZIM ID to match)


class Page(Item):
    def __init__(self, path, title, html):
        super().__init__()
        self.path, self.title, self.html = path, title, html

    def get_path(self):
        return self.path

    def get_title(self):
        return self.title

    def get_mimetype(self):
        return "text/html"

    def get_contentprovider(self):
        return StringProvider(self.html)

    def get_hints(self):
        return {Hint.FRONT_ARTICLE: True}


class Json(Item):
    """A JSON file, kept out of the title list as the packer keeps TOPICS_PATH."""

    def __init__(self, path, data: bytes):
        super().__init__()
        self.path, self.data = path, data

    def get_path(self):
        return self.path

    def get_title(self):
        return ""

    def get_mimetype(self):
        return "application/json"

    def get_contentprovider(self):
        return StringProvider(self.data)

    def get_hints(self):
        return {Hint.FRONT_ARTICLE: False}


class Video(Item):
    """A real video file for the check home's video library (phase C), stored uncompressed, as Clip."""

    def __init__(self, path: str, data: bytes):
        super().__init__()
        self.path, self.data = path, data

    def get_path(self):
        return self.path

    def get_title(self):
        return ""

    def get_mimetype(self):
        return "video/mp4"

    def get_contentprovider(self):
        return StringProvider(self.data)

    def get_hints(self):
        return {Hint.COMPRESS: False, Hint.FRONT_ARTICLE: False}


class Media(Item):
    """A made-up photo beside a page (phase C)."""

    def __init__(self, path: str, mimetype: str, data: bytes):
        super().__init__()
        self.path, self.mimetype, self.data = path, mimetype, data

    def get_path(self):
        return self.path

    def get_title(self):
        return ""

    def get_mimetype(self):
        return self.mimetype

    def get_contentprovider(self):
        return StringProvider(self.data)

    def get_hints(self):
        return {Hint.FRONT_ARTICLE: False}


class Clip(Item):
    """A video, stored uncompressed: libzim gives a path and offset only for an item that isn't compressed."""

    def __init__(self, data: bytes):
        super().__init__()
        self.data = data

    def get_path(self):
        return "media/clip.mp4"

    def get_title(self):
        return "Clip"

    def get_mimetype(self):
        return "video/mp4"

    def get_contentprovider(self):
        return StringProvider(self.data)

    def get_hints(self):
        return {Hint.COMPRESS: False, Hint.FRONT_ARTICLE: False}


def metadata(creator, name: str, title: str, description: str) -> None:
    for key, value in (("Name", name), ("Title", title), ("Language", "eng"), ("Creator", "PrepareMe"),
                       ("Publisher", "PrepareMe"), ("Date", "2026-10-13"), ("Description", description)):
        creator.add_metadata(key, value)


def build(out: Path, version: str, fulltext: bool = True, uuid: str = FIXTURE_ID,
          media: bool = False) -> None:
    with Creator(str(out)).config_indexing(fulltext, "eng") as creator:
        creator.set_mainpath("index.html")
        for name, value in (("Name", "prepareme_reopen_test"), ("Title", "PrepareMe reopen test"), ("Language", "eng"),
                            ("Creator", "PrepareMe"), ("Publisher", "PrepareMe"), ("Date", "2026-10-07"),
                            ("Description", f"Reopen test library, version {version}")):
            creator.add_metadata(name, value)
        creator.add_item(Page("index.html", "Front page", f"<html><body><h1>Version {version}</h1></body></html>"))
        creator.add_item(Page("water.html", "Water test", "<html><body><p>The zebrafish water test page.</p></body></html>"))
        if version == "B":
            for n in range(200):
                words = " ".join(f"word{n}x{k} reading{k * n} chapter{n}" for k in range(40))
                creator.add_item(Page(f"extra/{n}.html", f"Extra page {n} about storms {n}",
                                      f"<html><body><p>{words}</p></body></html>"))
        if media:
            creator.add_item(Clip(ord(version).to_bytes(1, "big") * 300000))
    pin_uuid(out, uuid)


def build_links(out: Path) -> None:
    with Creator(str(out)).config_indexing(True, "eng") as creator:
        creator.set_mainpath("index.html")
        metadata(creator, "prepareme_app_links_test", "PrepareMe app links test", "App links test library")
        front = (f'<html><body><p><a href="zim://{MAPS_ID}/maps.html">Find a map</a></p>'
                 f'<p><a href="zim://{ABSENT_ID}/absent.html">A map not on this phone</a></p></body></html>')
        creator.add_item(_FrontEntry("index.html", "Links front page", "text/html", front, True))
        creator.add_item(Page("found.html", "Found page", "<html><body><p>The quokka page.</p></body></html>"))
        creator.add_item(_FrontEntry("kept.html", "Kept page", "text/html",
                                     "<html><body><p>The quokka page, kept out of search.</p></body></html>", True))
        creator.add_item(Clip(bytes((i * 7) % 256 for i in range(300000))))
    pin_uuid(out, LINKS_ID)


def build_maps(out: Path) -> None:
    with Creator(str(out)).config_indexing(True, "eng") as creator:
        creator.set_mainpath("index.html")
        metadata(creator, "prepareme_app_maps_test", "PrepareMe app maps test", "App maps test library")
        creator.add_item(Page("index.html", "Maps front page", "<html><body><p>Maps test.</p></body></html>"))
        creator.add_item(Page("maps.html", "Find a map", "<html><body><p>Find a map test page</p></body></html>"))
    pin_uuid(out, MAPS_ID)


# The search order test's guides (beta run 2, B2-31 and B2-18): path, title, body. Made-up bodies; the titles are the
# kind the library has. Several bodies say floodwater more often than the Floodwater guide's, so the library's own
# full-text order alone doesn't put the right guide first: the title rule has to.
SEARCH_GUIDES = (
    ("floodwater.html", "Floodwater: turn around, don't drive in",
     "Never walk or drive into floodwater; turn back and find another road."),
    ("medicines.html", "Medicines in an emergency: supplies, storage and floodwater",
     "Keep a made-up supply of medicines. Throw out any medicine that floodwater touched; floodwater carries germs, "
     "and floodwater gets into bottles. Ask the made-up pharmacy about floodwater damage."),
    ("flood-food.html", "Food that floodwater may have touched: what to throw out and what to keep",
     "Floodwater spoils food. Throw out food floodwater touched. Floodwater gets under lids. Cans that floodwater "
     "covered can be kept after cleaning. Floodwater, floodwater, floodwater."),
    ("pantry.html", "Rotating pantry stock",
     "Rotate the made-up cans. Keep the pantry shelves above floodwater; floodwater ruins boxes and floodwater rusts "
     "cans. After floodwater, check every can. Floodwater, floodwater."),
    ("road-maps.html", "Paper maps and road reports",
     "Mark the roads that floodwater closes. Floodwater hides washed-out roads; floodwater over a road is a reason to "
     "turn back. Floodwater, floodwater, floodwater."),
    ("flash-floods.html", "Flash floods at home: get to high ground",
     "Flash floods rise fast. Get to high ground before floodwater reaches the house."),
    ("drying-out.html", "Drying out a flooded house",
     "After the floodwater goes down, open the made-up windows and dry the walls. Floodwater leaves mud and mold."),
    ("generator.html", "Running a generator safely",
     "Run the made-up generator outdoors, far from windows."),
)

# Made-up titles that each hold a word starting with c, most with co, found by title only, as the real library has
# dozens (cold, cooking, coolers…): so "c" or "co" alone matches more titles than search keeps (25 a library), and a
# page typed by its title has to be found by more than its first letters (2026-10-22)
CROWD_TITLES = tuple(f"{word.capitalize()} {kind}" for word in (
    "cold", "cooking", "coolers", "cough", "compass", "coal", "cord", "cots", "coyotes", "copper", "coats", "corn",
    "coffee", "condiments", "containers", "cooling", "comfort", "contacts", "cords", "corners", "candles", "canning",
    "chainsaws", "chlorine", "clothing", "cabins", "cards", "cats",
) for kind in ("basics", "checklist"))

# Full-text pages that "co" finds by their text and whose titles start with a co word, as the owner's iPhone showed
# above the walk-through (2026-10-22): the real "Cooking without power" guide's title and map pages' kind of title (the
# DC test area's names, never home), with made-up bodies that say CO
TITLE_RIVALS = (
    ("cooking.html", "Cooking without power: grills and camp stoves outdoors, and safe temperatures",
     "Cook on the made-up grill outdoors: carbon monoxide (CO) builds up indoors. CO has no smell. Keep CO out."),
    ("map-congress-heights.html", "Congress Heights topo map",
     "Made-up map text: CO marker, CO line, Congress Heights, CO 12."),
    ("map-columbia-road.html", "Columbia Road map",
     "Made-up map text: CO route, CO bridge, Columbia Road, CO 3."),
)


def build_search(out: Path) -> None:
    """The search order test's library (B2-31): a front page, SEARCH_GUIDES and the water guides' titles and search
    words (water_guides), with a full-text and a title index and the packer's hidden spelling words; TITLE_RIVALS; and,
    found only by their titles as the packer adds them, the real walk-throughs' titles (packer/walkthroughs.toml, made-up
    pages) and CROWD_TITLES."""
    with Creator(str(out)).config_indexing(True, "eng") as creator:
        creator.set_mainpath("index.html")
        metadata(creator, "prepareme_app_search_test", "PrepareMe app search test", "Search order test library")
        creator.add_item(_FrontEntry("index.html", "Search front page", "text/html",
                                     "<html><body><p>Search test.</p></body></html>", True))
        for path, title, body in SEARCH_GUIDES:
            creator.add_item(Page(path, title, html(title, f"<h1>{title}</h1><p>{body}</p>")))
        water, keywords = water_guides()
        for path, title, body in water:  # made by the packer's own page maker, its search words in the head
            page = GuidePage(path=path, title=title, life_safety=False, approved=None, sources=(), body_md=body)
            creator.add_item(Page(path, title, render_page(page, "PrepareMe app search test", "check",
                                                           keywords=keywords[path])))
        import tomllib
        walks = tomllib.loads((REPO / "packer/walkthroughs.toml").read_text())["walkthrough"]
        for walk in walks:  # out of full-text search, as packer/build.py adds a walk-through's page
            creator.add_item(_FrontEntry(walkthroughs.PAGE.format(id=walk["id"]), walk["title"], "text/html",
                                         html(walk["title"], "<p>A made-up walk-through.</p>"), True))
        for path, title, body in TITLE_RIVALS:
            creator.add_item(Page(path, title, html(title, f"<h1>{title}</h1><p>{body}</p>")))
        for n, title in enumerate(CROWD_TITLES):
            creator.add_item(_FrontEntry(f"crowd-{n}.html", title, "text/html", html(title, "<p>Made up.</p>"), True))
        # the hidden words for Kiwix's "Did you mean", as the packer adds them to the guides volume (packer/build.py)
        pages = [(p, t) for p, t, _ in SEARCH_GUIDES + water]
        for word, path in sorted(spelling.words(pages, keywords).items()):
            creator.add_redirection(spelling.PREFIX + word, word, path, {Hint.FRONT_ARTICLE: False})
    pin_uuid(out, SEARCH_ID)


def build_encyclopedia(out: Path) -> None:
    """The search test's second library, as Wikipedia 100 is beside the guides on a phone (owner's iPhone, 2026-10-28:
    "my brother is choking" found only its Charlie Chaplin page): one made-up article holding every word of a search no
    guide holds whole, and one only "bicycle" finds."""
    with Creator(str(out)).config_indexing(True, "eng") as creator:
        creator.set_mainpath("index.html")
        metadata(creator, "prepareme_app_encyclopedia_test", "PrepareMe app encyclopedia test", "Second search library")
        creator.add_item(_FrontEntry("index.html", "Encyclopedia front page", "text/html",
                                     "<html><body><p>Encyclopedia test.</p></body></html>", True))
        for path, title, body in (
            ("silent-film.html", "A made-up silent film star",
             "In one made-up scene a bicycle rolls through floodwater past a pantry door."),
            ("wheels.html", "Made-up wheels", "A bicycle has two made-up wheels."),
        ):
            creator.add_item(Page(path, title, html(title, f"<h1>{title}</h1><p>{body}</p>")))
    pin_uuid(out, ENCYCLOPEDIA_ID)


def build_long_title(out: Path) -> None:
    """A library Kiwix can't build its spelling help for (2026-11-12: PrepareMe on the Mac aborted at every launch): one
    page title longer than the 255 bytes Xapian allows a key, which libkiwix adds whole as one spelling word."""
    long_title = "A made-up page about floodwater " + " ".join(["with a very long title"] * 12)
    assert len(long_title.encode()) > 255
    with Creator(str(out)).config_indexing(True, "eng") as creator:
        creator.set_mainpath("index.html")
        metadata(creator, "prepareme_app_long_title_test", "PrepareMe app long title test", "Spelling failure library")
        creator.add_item(_FrontEntry("index.html", "Long title front page", "text/html",
                                     "<html><body><p>Long title test.</p></body></html>", True))
        creator.add_item(Page("long.html", long_title, html(long_title, "<p>A made-up floodwater page.</p>")))
        creator.add_item(Page("short.html", "Floodwater short page", html("Floodwater", "<p>Made-up floodwater.</p>")))
    pin_uuid(out, LONG_TITLE_ID)


# The water guides "purify water" should find (B2-18), made up in the real guides' shape (the published source holds no
# library text: the lead's review, 2026-11-23): path, title, body and search words. Storing says water more often than
# the other two, and once says purified; each says how and to (how much, how long), so a question ("how to purify
# water") can match them; the bleach and boiling guides' search words carry "purify water", Storing's don't.
WATER_GUIDES = (
    ("water-bleach.html", "Disinfecting water with plain bleach",
     "Which made-up bleach to use, how much to add to clear water, and how long to wait before you drink it.",
     ("chlorine", "purify water", "disinfect water", "drinking water", "bleach amount", "drops of bleach per gallon",
      "cloudy water and bleach", "make water drinkable", "germs in water", "bleach smell in water",
      "wait after adding bleach", "can i drink this water")),
    ("water-boil.html", "Boiling water so it's safe to drink",
     "How long to boil made-up water, then how to let it cool in a clean pot with a lid.",
     ("boil order", "boil water notice", "safe drinking water", "purify water", "how long to boil", "flooded well",
      "boiling at altitude", "well water safety", "well after a flood", "cloudy water drinkable", "bad smelling water",
      "boil one minute")),
    ("water-storage.html", "Storing drinking water: how much, what containers, and keeping it clean",
     "How much made-up drinking water to store. Keep it in clean water containers and label each water jug with the "
     "date. Keep stored water cool and dark, away from fuel. Well water that hasn't been tested is purified before you "
     "store the water. Replace stored water on a schedule, and take water out with a clean scoop.",
     ("water storage", "store water", "storing water", "water containers", "water jugs", "how much water",
      "emergency water", "food safe water container", "how long stored water keeps", "old water in a jug",
      "stored water smell", "out of drinking water")),
)


def water_guides() -> tuple[tuple[tuple[str, str, str], ...], dict[str, tuple[str, ...]]]:
    """WATER_GUIDES as (path, title, body), and each page's search words: {path: words}."""
    return (tuple((path, title, body) for path, title, body, _ in WATER_GUIDES),
            {path: words for path, _, _, words in WATER_GUIDES})


def html(title: str, body: str) -> str:
    return f"<html><head><title>{title}</title></head><body>{body}</body></html>"


def news_board_page() -> str:
    """news-board.html as the packer styles it, from dashboard/tests' made-up page.json, half an hour after it was
    made, so the stories show as fresh."""
    from dashboard import news_board  # noqa: PLC0415 (only the check home needs the dashboard)
    data = json.loads(NEWS_FIXTURE.read_text(encoding="utf-8"))
    now = datetime.fromisoformat(data["made"]) + timedelta(minutes=30)
    body = news_board.page(data, now).html
    return (f'{_head("News", f"<style>{STYLE}</style>{SIDE_STYLE}{BOARD_STYLE}")}<body class="guides-page side-page '
            f'wide"><div class="page-band"><h1>News</h1></div>{body}</body></html>')


def guide_pages(topics: dict) -> dict:
    """Made-up guides for the fixture's topics, as many as each sub-category (or topic) counts: path -> title."""
    return {path: title for path, (title, _) in _guides_with_topics(topics).items()}


def _guides_with_topics(topics: dict) -> dict:
    """path -> (title, topic): each made-up guide under its topic, for the guides list the editor's picker reads."""
    pages = {}
    for topic in topics["topics"]:
        for sub in topic["subs"] or [{"name": topic["name"], "count": topic["count"]}]:
            for n in range(1, sub["count"] + 1):
                pages[f"made-up-{len(pages) + 1}.html"] = (f"Made-up guide {n}: {sub['name']}", topic["name"])
    return pages



def guide_list_pages(topics: dict, guides: dict) -> dict[str, tuple[str, str]]:
    """The guide list, New guides and each topic page, {path: (title, html)}, made by the packer's own page builders
    from a made-up Volume, so the check build shows the real guide list's look (Library matches Guides plan, Task 1.1).
    The fixture's topics become the Volume's: a topic with subs a group of topics, Our Home's guides the
    household pages (in no topic and not the library's own), EXTRA_LISTED's pages in their topic's last sub. The walk
    guide is life-safety, so the band shows the legend as the real list's does."""
    from packer.build import _category_page, _guides_page, _new_page
    from packer.config import Volume
    from packer.guide_topics import HOUSEHOLD_TOPIC, sections

    order, done = list(guides), 0
    titles = {**guides, **{p: t for extra in EXTRA_LISTED.values() for p, t in extra}}
    household, topic_paths, groups = [], [], []
    for topic in topics["topics"]:
        subs = topic["subs"] or [{"name": topic["name"], "count": topic["count"]}]
        for sub in subs:
            chosen = order[done:done + sub["count"]]
            done += sub["count"]
            if sub is subs[-1]:
                chosen += [p for p, _ in EXTRA_LISTED.get(topic["name"], ())]
            if topic["name"] == HOUSEHOLD_TOPIC:
                household += chosen
            else:
                topic_paths.append((sub["name"], tuple(chosen)))
        if topic["subs"]:
            groups.append((topic["name"], tuple(sub["name"] for sub in subs)))
    volume = Volume("prepareme-daily", "PrepareMe check daily", "check", 168, (), topics=tuple(topic_paths),
                    topic_groups=tuple(groups), library_pages=tuple(sorted(set(titles) - set(household))))
    pages = [(p, t, "emergency" if p == f"{WALK_GUIDE}.html" else False) for p, t in titles.items()]
    built = datetime.now().isoformat(timespec="minutes")
    new_count = topics["new"]["count"]
    listed_new = [(*pages[i], f"2026-10-1{i}") for i in range(new_count)]
    out = {GUIDES_PAGE: ("Guides", _guides_page(volume, built, pages, new=new_count)),
           NEW_PAGE: (NEW_HEADING, _new_page(volume, built, listed_new))}
    found, notes = sections(volume, pages)
    assert not notes and [g.page for g in found] == [t["page"] for t in topics["topics"]], (notes, found)
    for group in found:
        out[group.page] = (group.name, _category_page(volume, built, group))
    return out

STEPS_PAGE, STEPS_PHOTO = "made-up-steps.html", "made-up-steps-1.png"  # phase C: a household page, one step per screen
STEPS_TEXT = f"""---
title: Made-up shut-offs
kind: steps
when: A made-up gas smell or a burst pipe.
guides: made-up-linked
keywords: made-up shut off
---
- step: Turn the made-up valve a quarter turn, so the handle lies across the pipe.
  name: Water main
  photo: {STEPS_PHOTO}
  caution: Don't force a stuck valve: a cracked valve floods the room.
- step: Push the made-up main breaker to Off.
  name: Breaker panel
- step: Watch the made-up video of the next step.
  photo: {STEPS_PHOTO}
  video: made-up-step.mp4
- step: Open a faucet; the made-up water should stop within a minute.
"""


# An Our Home page (Our Home plan, phase 2), the shared fixture with its items' words swapped for two the rehearsal
# inventory holds ("Dual fuel generator" in a made-up place, "Test flashlight" in none), its photo, its number to call,
# a made-up manual for the generator and two made-up meeting places, so a check build shows each slot filled
OUR_HOME_PAGE = "house-check.html"  # a house-… name, so prepareme://home/house-check opens it (Task 2.6)
# the editor's picks (the editor plan, Task 7) as the rehearsal inventory holds them: place 2 is Garage, item 1 the
# generator with its manual, item 3 the water jugs in the Pantry; place 1 picked as "SAMPLE Old pantry" is a renamed
# place, so it fills with its new name (owner, 2026-11-20: a renamed place is followed)
OUR_HOME_TEXT = ((REPO / "app/Service/Tests/PrepareMeSharedTests/Fixtures/our-home-page.md").read_text(encoding="utf-8")
                 .replace("sample pipe wrench", "generator").replace("sample flashlight", "flashlight")
                 .replace("#14 SAMPLE Garage › Utility shelf", "#2 Garage")
                 .replace("#7 SAMPLE Generator", "#1 Dual fuel generator")
                 .replace("#7 SAMPLE wrench", "#3 Drinking water jugs")
                 .replace("  checked: e4f2e76f\n", "  checked: e4f2e76f\n  place: #1 SAMPLE Old pantry\n")
                 # a short number beside the ten-digit one: both dial on the new app, the ten-digit one on today's
                 .replace("  calculator: calc-outage-load\n", "  calculator: calc-outage-load\n  call: 411; SAMPLE information\n"))
MANUALS_ID = "22a5a8ba-c510-4af3-a781-5f93fd1acddd"  # ItemManuals.volumeID, pinned in packer/volumes.toml
GENERATOR_ROW = 1  # the rehearsal inventory's "Dual fuel generator"
CHECK_RALLY = (("SAMPLE corner park", "near-home", [-77.0365, 38.8977]),  # Washington, DC: never a home area
               ("SAMPLE library lot", "outside-neighborhood", [-77.0091, 38.8899]))


def sample_pdf() -> bytes:
    """A one-page made-up PDF: "SAMPLE generator manual"."""
    stream = b"BT /F1 24 Tf 72 700 Td (SAMPLE generator manual: made up) Tj ET"
    objs = [b"<< /Type /Catalog /Pages 2 0 R >>", b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R "
            b"/Resources << /Font << /F1 5 0 R >> >> >>",
            b"<< /Length %d >>\nstream\n" % len(stream) + stream + b"\nendstream",
            b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"]
    out, offsets = bytearray(b"%PDF-1.4\n"), []
    for i, body in enumerate(objs, 1):
        offsets.append(len(out))
        out += b"%d 0 obj\n" % i + body + b"\nendobj\n"
    xref = len(out)
    out += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1)
    out += b"".join(b"%010d 00000 n \n" % o for o in offsets)
    out += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objs) + 1, xref)
    return bytes(out)


def build_manuals(out: Path) -> None:
    """A made-up equipment manuals library: the made-up PDF at the generator's path (ItemManuals.contentPath)."""
    with Creator(str(out)).config_indexing(False, "eng") as creator:
        creator.set_mainpath("index.html")
        metadata(creator, "prepareme_check_manuals", "PrepareMe check manuals", "Made-up manuals library")
        creator.add_item(Page("index.html", "Manuals", html("Manuals", "<h1>Made-up manuals</h1>")))
        creator.add_item(Media(f"item-{GENERATOR_ROW}.pdf", "application/pdf", sample_pdf()))
    pin_uuid(out, MANUALS_ID)


def add_check_marks(grist: Path) -> None:
    """The made-up meeting places, in the table and columns MapMarks writes (app/Service's MapMarks.marksTable)."""
    import sqlite3

    with sqlite3.connect(grist) as db:
        db.execute('CREATE TABLE IF NOT EXISTS "PrepareMe_MapMarks" (id INTEGER PRIMARY KEY, kind TEXT NOT NULL, '
                   "name TEXT NOT NULL, note TEXT NOT NULL, points TEXT NOT NULL, role TEXT NOT NULL DEFAULT '', "
                   "extra TEXT NOT NULL DEFAULT '')")
        for i, (name, role, point) in enumerate(CHECK_RALLY, 1):
            db.execute('INSERT OR REPLACE INTO "PrepareMe_MapMarks" (id, kind, name, note, points, role) '
                       "VALUES (?, 'rally', ?, '', ?, ?)", (i, name, json.dumps([point]), role))


def made_up_png(width: int = 400, height: int = 260) -> bytes:
    """A made-up photo: grey with a pipe and a red handle across it, written as a PNG with the standard library."""
    import struct
    import zlib

    rows = []
    for y in range(height):
        row = bytearray()
        for x in range(width):
            pipe = 118 <= y < 152
            handle = 128 <= y < 142 and 150 <= x < 250
            row += bytes((185, 28, 28) if handle else (91, 102, 114) if pipe else (141, 153, 166))
        rows.append(b"\0" + bytes(row))

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(b"".join(rows))) + chunk(b"IEND", b""))


LINKED_PAGE, LINKED_TITLE = "made-up-linked.html", "Made-up outage guide"
LINKED_WORDS = ("generator", "flashlight", "water jug")
# A guide with a walk-through (step 10), and the kids' guide its kids' version uses: made-up words only, built by the
# packer's own walk-through code (packer.walkthroughs) from this made-up spec
WALK_GUIDE, WALK_GUIDE_TITLE = "made-up-alarm", "Made-up alarm guide"
WALK_KIDS, WALK_KIDS_TITLE = "made-up-kids-alarm", "Made-up alarms, for kids"
WALK_GUIDE_TEXT = """A made-up guide for the check build, so the Walk me through it button and its screens can be seen.

## When the made-up alarm sounds

1. Get everyone out of the made-up house to fresh air at once.
2. From outside, call the made-up emergency number and say the alarm is sounding and someone feels sick.
3. Leave the made-up doors and windows as they are, and wait outside for the made-up responders.
4. Don't go back in until the made-up responders say it is safe.

## After the alarm

Have the made-up heater checked by a made-up technician before you use it again.
"""
WALK_KIDS_TEXT = """## If an alarm goes off

- Go outside right away with your made-up grown-up.
- Don't hide under a made-up bed or in a made-up closet.
"""
WALK_SPEC = f"""volume = "prepareme-daily"

[[walkthrough]]
id = "made-up-alarm"
title = "The made-up alarm is going off"
guides = ["{WALK_GUIDE}"]
kids = "{WALK_KIDS}"

[[walkthrough.screen]]
id = "out"
heading = "When the made-up alarm sounds"
item = 1
next = "sick"

[[walkthrough.screen]]
id = "sick"
question = "Does anyone feel dizzy, sick or sleepy?"
yes = "call"
no = "wait"

[[walkthrough.screen]]
id = "call"
heading = "When the made-up alarm sounds"
item = 2
next = "wait"

[[walkthrough.screen]]
id = "wait"
heading = "When the made-up alarm sounds"
item = 3
next = "back-in"

[[walkthrough.screen]]
id = "back-in"
heading = "When the made-up alarm sounds"
item = 4

[[walkthrough.kids_screen]]
id = "out"
guide = "{WALK_KIDS}"
heading = "If an alarm goes off"
item = 1
next = "hide"

[[walkthrough.kids_screen]]
id = "hide"
guide = "{WALK_KIDS}"
heading = "If an alarm goes off"
item = 2
next = "tell"

[[walkthrough.kids_screen]]
id = "tell"
end = "tell-adult"
"""


VIDEO_BYTES: list[bytes] = []  # the made-up clip (--video), which must keep its index at the front (phase C)


def build_media(out: Path, video: Path) -> None:
    """The check home's video library: one made-up video (phase C), as a step's video lives in PrepareMe: video."""
    with Creator(str(out)).config_indexing(False, "eng") as creator:
        creator.set_mainpath("index.html")
        metadata(creator, "prepareme_check_media", "PrepareMe check video", "Made-up video library for the check build")
        creator.add_item(Page("index.html", "Video", html("Video", "<h1>Video</h1>")))
        creator.add_item(Video(VIDEO_PATH, VIDEO_BYTES[0]))
    pin_uuid(out, MEDIA_ID)


def build_daily(out: Path, with_topics: bool = True, video: bool = False, dc_conditions: bool = False) -> None:
    """The check home's daily library: Today (index.html), the guide list, New guides and a page per topic with an
    anchor per sub-category (the packer's own pages: guide_list_pages), the made-up guides, and the topics list unless
    left out."""
    raw = TOPICS_FIXTURE.read_bytes()
    topics = json.loads(raw)
    guides = guide_pages(topics)
    with Creator(str(out)).config_indexing(True, "eng") as creator:
        creator.set_mainpath("index.html")
        metadata(creator, "prepareme_check_daily", "PrepareMe check daily", "Made-up daily library for the check build")
        front = html("Today", f"<h1>Today</h1><p>A made-up front page for the check build.</p>"
                              f'<p><a href="{GUIDES_PAGE}">Go to the guides</a></p>'
                              f'<p><a href="{LINKED_PAGE}">{LINKED_TITLE}</a></p>'
                              f'<p><a href="{STEPS_PAGE}">Made-up shut-offs</a></p>'
                              f'<p><a href="{OUR_HOME_PAGE}">SAMPLE Our Home page</a></p>'
                              f'<p><a href="{OUR_HOME_PAGE}#step-2">SAMPLE Our Home page, step 2</a></p>'
                              f'<p><a href="{OUR_HOME_PAGE}#step-3">SAMPLE Our Home page, step 3</a></p>'
                              f'<p><a href="{OUR_HOME_PAGE}#step-4">SAMPLE Our Home page, step 4</a></p>'
                              f'<p><a href="{OUR_HOME_PAGE}#done">SAMPLE Our Home page, end</a></p>'
                              f'<p><a href="{WALK_GUIDE}.html">{WALK_GUIDE_TITLE}</a></p>'
                              + (f'<p><a href="{VIDEO_PAGE}">Made-up video step</a></p>' if video else "") +
                              f'<p><a href="zim://{OVERVIEW_ID}/index.html">Maps</a></p>'
                              f'<p><a href="zim://{GONE_ID}/index.html">A library not on this device</a></p>'
                              f'<p><a href="{INVENTORY_PAGE}">Inventory</a></p>')
        creator.add_item(_FrontEntry("index.html", "Today", "text/html", front, True))
        # the library's phone-width Inventory page, which a click on Today's button skips for the Mac's own screen
        creator.add_item(_FrontEntry(INVENTORY_PAGE, "Inventory", "text/html", html("Inventory", "<h1>Inventory</h1>"
                                     "<p>A made-up Inventory page: the Mac shows its own screen instead.</p>"), True))
        # the News page (step 7), so the Mac sidebar's News row loads a page: made-up words only
        creator.add_item(_FrontEntry(NEWS_PAGE, "News", "text/html", html("News", "<h1>News</h1>"
                                     "<p>A made-up News page for the check build.</p>"), True))
        # the rebuilt News page (news plan phase 3), from the tests' made-up page.json, with its marks (Task 3.4)
        creator.add_item(_FrontEntry(NEWS_BOARD_PAGE, "News", "text/html", news_board_page(), True))
        for path, (title, page) in guide_list_pages(topics, guides).items():
            creator.add_item(_FrontEntry(path, title, "text/html", page, True))
        for path, title in guides.items():
            creator.add_item(Page(path, title, html(title, f"<h1>{title}</h1><p>The made-up wombat guide.</p>")))
        # A guide built by the packer's own page maker, with its links (phase 14, F57): On the map, and In the house for
        # words that match the rehearsal inventory's made-up items; and the list the apps read for How to use it
        linked = GuidePage(path=LINKED_PAGE, title=LINKED_TITLE, life_safety=False, approved=None, sources=(),
                           body_md="A made-up guide for the check build. Its links are at its foot.")
        creator.add_item(Page(LINKED_PAGE, LINKED_TITLE, render_page(linked, "PrepareMe check daily", "check",
                                                                     links=(True, LINKED_WORDS))))
        creator.add_item(Json(LINKS_PATH, links_json([(LINKED_PAGE, LINKED_TITLE, LINKED_WORDS)])))
        # the guides list the Mac's editor picks from, as main writes it, and each guide's topic beside it (the editor
        # plan, Task 3); the library's own guides only, as the packer lists them: never the Our Home section's pages
        from packer.guide_topics import HOUSEHOLD_TOPIC
        made_up = {p: g for p, g in _guides_with_topics(topics).items() if g[1] != HOUSEHOLD_TOPIC}
        listed = [(path, title) for path, (title, _) in made_up.items()] + [(LINKED_PAGE, LINKED_TITLE)]
        creator.add_item(Json(guide_list.LIST_PATH, guide_list.list_json(listed)))
        creator.add_item(Json(guide_list.TOPICS_PATH, guide_list.topics_json(
            listed, {path: topic for path, (_, topic) in made_up.items()})))
        # a household page, one step per screen (phase C), made by the packer's own steps renderer
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "made-up-steps.md"
            source.write_text(STEPS_TEXT, encoding="utf-8")
            page = steps.parse(source, STEPS_PAGE)
        creator.add_item(Page(STEPS_PAGE, page.title, steps.render(page, "PrepareMe check daily", "check",
                                                                   MEDIA_ID if video else "",
                                                                   {LINKED_PAGE: LINKED_TITLE})))
        creator.add_item(Media(STEPS_PHOTO, "image/png", made_up_png()))
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "house-check.md"
            source.write_text(OUR_HOME_TEXT, encoding="utf-8")
            home = steps.parse(source, OUR_HOME_PAGE)
        creator.add_item(Page(OUR_HOME_PAGE, home.title, steps.render(home, "PrepareMe check daily", "check", "", {})))
        creator.add_item(Media("sample-shutoffs-4.jpg", "image/png", made_up_png()))
        called = [s.call[0] for s in home.steps if s.call]
        creator.add_item(Json(home_calls.CALLS_PATH, home_calls.calls_json(called)))
        creator.add_item(Json(home_calls.OTHER_PATH, home_calls.other_json(called)))
        # a guide with a walk-through and its kids' guide (step 10), each page made by the packer's own code
        for page, kids_page in walk_pages().items():
            creator.add_item(Page(page, kids_page[0], kids_page[1]))
        if video:  # a page playing a video from the other library (phase C's first check)
            creator.add_item(Page(VIDEO_PAGE, "Made-up video step", html("Made-up video step",
                f'<h1>Made-up video step</h1><video controls playsinline preload="metadata" style="width:100%" '
                f'src="zim://{MEDIA_ID}/{VIDEO_PATH}"></video><p>The video is in the video library.</p>')))
        # meaning search's numbers for the made-up guides and household page (2026-10-28 plan, phase 3), made by the
        # real model, as the packer makes them; left out, with a note, where its folder isn't made
        texts = {path: meaning.page_texts(title, (), "The made-up wombat guide.", None) for path, title in guides.items()}
        texts[LINKED_PAGE] = meaning.page_texts(LINKED_TITLE, LINKED_WORDS, linked.body_md, None)
        texts[STEPS_PAGE] = meaning.page_texts("Made-up shut-offs", (), STEPS_TEXT.split("---")[2], None)
        try:
            vectors = meaning.numbers([text for many in texts.values() for text in many], "pages")
            creator.add_item(Json(meaning.MEANING_PATH, meaning.meaning_json([(path, [vectors.pop(0) for _ in many])
                                                                              for path, many in texts.items()])))
        except meaning.Unavailable as problem:
            print(f"no meaning search numbers in the check daily library: {problem}", file=sys.stderr)
        # the hidden words for "Did you mean", as the packer adds them (a misspelled title word, "houshold", shows it)
        for word, path in sorted(spelling.words(list(guides.items()), {}).items()):
            creator.add_redirection(spelling.PREFIX + word, word, path, {Hint.FRONT_ARTICLE: False})
        if with_topics:
            creator.add_item(Json(TOPICS_PATH, raw))
        if dc_conditions:
            creator.add_item(Json(SETTINGS_PATH, DC_SETTINGS.read_bytes()))
            creator.add_item(Json(AREA_PATH, DC_AREA.read_bytes()))  # beside it, as the packer packs it (phase 4)
        # the calculators and the committed table of which inventory group links which (step 8b): the calculators
        # are the project's own pages, no household words; the figures come from the check home's supply.json
        for page in sorted((CONTENT_DIR / "daily").glob("calc-*.html")):
            styled = page.read_text(encoding="utf-8").replace(STYLE_MARKER, f"<style>{BASE}{READING}</style>", 1)
            creator.add_item(Page(page.name, page.stem, styled))  # styled as the build styles them
            creator.add_item(Media(page.with_suffix(".js").name, "text/javascript",
                                   page.with_suffix(".js").read_bytes()))
        table, _ = load_calculator_links(CALCULATOR_LINKS_FILE)
        creator.add_item(Json(calculator_links.LINKS_PATH, calculator_links.links_json(table)))
    pin_uuid(out, DAILY_ID)


# The check home's other pages, each listed on its group's category page as the real library lists them, so search's
# marks (app/Service's SearchMark, owner 2026-10-21) find their groups: the household page under Our Home, the
# walk-through's guide, its kids' guide and the linked guide under Medical. The topics JSON's counts stay the shared fixture's.
EXTRA_LISTED = {
    "Our Home": ((STEPS_PAGE, "Made-up shut-offs"),),
    "Medical": ((f"{WALK_GUIDE}.html", WALK_GUIDE_TITLE), (f"{WALK_KIDS}.html", WALK_KIDS_TITLE),
                (LINKED_PAGE, LINKED_TITLE)),
}


def walk_pages() -> dict[str, tuple[str, str]]:
    """The made-up walk-through's guide (with its Walk me through it button), its kids' guide and its two pages:
    {path: (title, html)}."""
    import tempfile
    from types import SimpleNamespace

    with tempfile.TemporaryDirectory() as tmp:
        spec = Path(tmp) / "walkthroughs.toml"
        spec.write_text(WALK_SPEC, encoding="utf-8")
        found, notes = walkthroughs.load(spec, [SimpleNamespace(name="prepareme-daily", maps=False)])
    if notes:
        sys.exit(f"the made-up walk-through: {notes[0]}")
    texts = {WALK_GUIDE: (WALK_GUIDE_TITLE, WALK_GUIDE_TEXT), WALK_KIDS: (WALK_KIDS_TITLE, WALK_KIDS_TEXT)}
    resolved, problem = walkthroughs.resolve(found["prepareme-daily"][0], texts)
    if problem:
        sys.exit(f"the made-up walk-through: {problem}")
    buttons, titles = walkthroughs.buttons([resolved]), {gid: title for gid, (title, _) in texts.items()}
    out = {}
    for gid, (title, text) in texts.items():
        guide = GuidePage(path=f"{gid}.html", title=title, life_safety=False, approved=None, sources=(), body_md=text)
        out[guide.path] = (title, render_page(guide, "PrepareMe check daily", "check",
                                              walk_button=buttons.get(guide.path, "")))
    for kids, path in ((False, walkthroughs.PAGE), (True, walkthroughs.KIDS_PAGE)):
        out[path.format(id=resolved.walk.id)] = (resolved.walk.title, walkthroughs.render(
            resolved, kids, titles, "PrepareMe check daily", "check"))
    return out


def build_overview(out: Path) -> None:
    """The made-up topo overview, shaped as the real one: its front page a title and two links (packer/build.py's plain
    front page), and Find a map a page of its own beside it (packer/map_pages.py's MAP_PAGES), which Maps opens on the
    Mac and the phone (phase L, finding 1). Until then this front page was Find a map, which hid that Maps opened the
    bare front page."""
    title, pages = "PrepareMe check overview", (("find", "A made-up Find a map page."), ("topo", "No made-up maps."))
    links = "".join(f'<li><a href="{MAP_PAGES[key]}">{FURNITURE[f"{key}_title"]}</a></li>' for key, _ in pages)
    with Creator(str(out)).config_indexing(True, "eng") as creator:
        creator.set_mainpath("index.html")
        metadata(creator, "prepareme_check_overview", title, "Made-up topo overview")
        creator.add_item(Page("index.html", title, html(title, f"<h1>{title}</h1><ul>{links}</ul>")))
        for key, words in pages:
            name = FURNITURE[f"{key}_title"]
            creator.add_item(Page(MAP_PAGES[key], name, html(name, f"<h1>{name}</h1><p>{words}</p>")))
    pin_uuid(out, OVERVIEW_ID)


def build_other(out: Path, name: str, title: str, uuid: str) -> None:
    """A made-up library besides the daily one, one front page: the Mac sidebar's and the phone's Library (owner,
    2026-10-25; Library 2026-11-12)."""
    with Creator(str(out)).config_indexing(True, "eng") as creator:
        creator.set_mainpath("index.html")
        metadata(creator, name, title, "Made-up library")
        creator.add_item(Page("index.html", title, html(title, f"<h1>{title}</h1><p>A made-up front page.</p>")))
    pin_uuid(out, uuid)


def build_games(out: Path, folder: Path) -> None:
    """A made-up games file from a folder's files as they are (games 3b's full-screen checks): the app knows the games
    file by its name, prepareme-games.zim, never by the live volume's ID. Its index.html is the Games list."""
    with Creator(str(out)).config_indexing(False, "eng") as creator:
        creator.set_mainpath("index.html")
        metadata(creator, "prepareme_check_games", "PrepareMe check games", "Made-up games")
        for file in sorted(p for p in folder.rglob("*") if p.is_file()):
            path = file.relative_to(folder).as_posix()
            kind = mimetypes.guess_type(file.name)[0] or "application/octet-stream"
            creator.add_item(Media(path, kind, file.read_bytes()))
    pin_uuid(out, GAMES_ID)


def build_check_home(home: Path, with_topics: bool = True, video: Path | None = None,
                     dc_conditions: bool = False, games: Path | None = None) -> None:
    real = home.resolve()
    if not any(str(real).startswith(root) for root in ("/private/tmp/", "/private/var/folders/")):
        sys.exit(f"--check-home takes a scratch folder under /private/tmp or the temporary folder, not {real}")
    folders = real / "Library/Application Support/PrepareMe"
    delivery, inventory = folders / "delivery", folders / "inventory"
    for folder in (delivery, inventory):
        folder.mkdir(parents=True, exist_ok=True)
    # News's own page.json, where the Mac app reads the owner's marks and News's answers (NewsAnswers; finding 7)
    (folders / "news").mkdir(exist_ok=True)
    shutil.copyfile(NEWS_FIXTURE, folders / "news" / "page.json")
    now = datetime.now().astimezone().isoformat(timespec="seconds")
    files = []
    for name, uuid, kind, make in (
            ("prepareme-daily.zim", DAILY_ID, "library", lambda p: build_daily(p, with_topics, video is not None, dc_conditions)),
            *([("prepareme-media.zim", MEDIA_ID, "library", lambda p: build_media(p, video))] if video else []),
            ("prepareme-item-manuals.zim", MANUALS_ID, "library", build_manuals),
            ("prepareme-maps-topo-overview.zim", OVERVIEW_ID, "map-core", build_overview),
            ("prepareme-street-map.pmtiles", STREET_MAP_ID, "map", lambda p: shutil.copyfile(STREET_MAP, p)),
            ("prepareme-reference.zim", REFERENCE_ID, "library",
             lambda p: build_other(p, "prepareme_check_reference", "PrepareMe check reference", REFERENCE_ID)),
            ("check-wikipedia-sample.zim", DOWNLOAD_ID, "download",
             lambda p: build_other(p, "check_wikipedia_sample", DOWNLOAD_TITLE, DOWNLOAD_ID)),
            # named as Kiwix names its knots collection, so the starting shelf files it under Skills; the sample above
            # matches no starting prefix and shows under Needs a category (Library plan, task 2.2)
            ("zimgit-knots_en_2024-08.zim", KNOTS_ID, "download",
             lambda p: build_other(p, "check_knots", KNOTS_TITLE, KNOTS_ID)),
            *([("prepareme-games.zim", GAMES_ID, "library", lambda p: build_games(p, games))] if games else [])):
        path = delivery / name
        path.unlink(missing_ok=True)
        make(path)
        data = path.read_bytes()
        files.append({"name": name, "id": uuid, "kind": kind,
                      "size": len(data), "sha256": hashlib.sha256(data).hexdigest(), "delivered_at": now,
                      "library_as_of": now[:16] + now[19:], "sources_checked": now,
                      **({"title": KNOTS_TITLE if uuid == KNOTS_ID else DOWNLOAD_TITLE} if kind == "download" else {}),
                      # each file's card facts, read as the packer reads them (library redesign plan 2.3)
                      **(library_card.manifest_keys({"card": library_card.read(path, name)}) if name.endswith(".zim")
                         else {})})
    (delivery / "manifest.json").write_text(json.dumps({"written_at": now, "files": files}, indent=2) + "\n")
    shutil.copyfile(REHEARSAL, inventory / "PrepareMe Inventory.grist")
    add_check_marks(inventory / "PrepareMe Inventory.grist")
    manuals = folders / "item-manuals"  # ItemManuals' folder: the generator's made-up manual
    manuals.mkdir(exist_ok=True)
    pdf = sample_pdf()
    (manuals / f"item-{GENERATOR_ROW}.pdf").write_bytes(pdf)
    (manuals / "manuals.json").write_text(json.dumps({str(GENERATOR_ROW): {
        "file": f"item-{GENERATOR_ROW}.pdf", "item": "Dual fuel generator", "sha256": hashlib.sha256(pdf).hexdigest()}}))
    shutil.copyfile(LISTS_FIXTURE, inventory / "lists.json")
    shutil.copyfile(SUPPLY_FIXTURE, inventory / "supply.json")  # made-up days and calculator figures (step 8b)
    # Printable References (2026-10-21): the made-up card as the card file, never over one a check already changed
    plans = real / "Library/Mobile Documents/com~apple~CloudDocs/Household Private/Plans"
    plans.mkdir(parents=True, exist_ok=True)
    if not (plans / "card.toml").exists():
        shutil.copyfile(CARD_SAMPLE, plans / "card.toml")


if __name__ == "__main__":
    if sys.argv[1] == "--check-home":
        rest = sys.argv[3:]
        video = Path(rest[rest.index("--video") + 1]) if "--video" in rest else None  # a made-up clip (phase C)
        if video:
            VIDEO_BYTES.append(video.read_bytes())
        games = Path(rest[rest.index("--games") + 1]) if "--games" in rest else None  # a folder of pages (games 3b)
        build_check_home(Path(sys.argv[2]), with_topics="--no-topics" not in rest, video=video,
                         dc_conditions="--dc-conditions" in rest, games=games)
        sys.exit(0)
    folder = Path(sys.argv[1])
    for version in ("A", "B"):
        build(folder / f"prepareme-reopen-{version}.zim", version, media=True)
        build(folder / f"prepareme-reopen-titles-{version}.zim", version, fulltext=False)
    build(folder / "prepareme-reopen-other-id.zim", "A", uuid=OTHER_ID)
    build_links(folder / "prepareme-app-links.zim")
    build_maps(folder / "prepareme-app-maps.zim")
    build_search(folder / "prepareme-app-search.zim")
    build_encyclopedia(folder / "prepareme-app-encyclopedia.zim")
    build_long_title(folder / "prepareme-app-long-title.zim")
