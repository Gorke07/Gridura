#!/usr/bin/env python3
"""Gives one appcast item release notes in several languages (stdlib only).

generate_appcast embeds a single Markdown <description> in the new item. This marks that description with
xml:lang and adds one for each further language, so Sparkle shows the notes in the user's language (with more
than one description, Sparkle picks by xml:lang and expects it on all of them).
The item is found by its enclosure URL; the rest of the file is left byte for byte as it was.
Usage: localize-appcast.py APPCAST ENCLOSURE_URL EMBEDDED_LANG LANG=NOTES.md [LANG=NOTES.md ...]
"""
import sys
from pathlib import Path

DESCRIPTION = '<description sparkle:format="markdown">'


def localize(appcast: str, url: str, embedded_lang: str, extra: dict[str, str]) -> str:
    anchor = appcast.find(f'url="{url}"')
    if anchor < 0:
        raise ValueError(f"no item with enclosure {url}")
    start = appcast.rfind("<item>", 0, anchor)
    end = appcast.find("</item>", anchor)
    if start < 0 or end < 0:
        raise ValueError(f"the enclosure {url} is not inside an <item>")
    item = appcast[start:end]
    if item.count(DESCRIPTION) != 1:
        raise ValueError("the item must have exactly one unlocalized Markdown description")
    desc_start = item.index(DESCRIPTION)
    desc_end = item.index("</description>", desc_start) + len("</description>")
    indent = item[item.rfind("\n", 0, desc_start) + 1:desc_start]
    added = ""
    for lang, notes in extra.items():
        if "]]>" in notes:
            raise ValueError(f"the {lang} notes contain ']]>', which would end the CDATA section")
        added += f'\n{indent}<description xml:lang="{lang}" sparkle:format="markdown"><![CDATA[{notes}]]></description>'
    item = (item[:desc_start]
            + f'<description xml:lang="{embedded_lang}" sparkle:format="markdown">'
            + item[desc_start + len(DESCRIPTION):desc_end]
            + added
            + item[desc_end:])
    return appcast[:start] + item + appcast[end:]


def main(argv: list[str]) -> int:
    if len(argv) < 5:
        print(__doc__, file=sys.stderr)
        return 2
    path, url, embedded_lang = Path(argv[1]), argv[2], argv[3]
    extra = {}
    for pair in argv[4:]:
        lang, _, notes = pair.partition("=")
        extra[lang] = Path(notes).read_text(encoding="utf-8")
    try:
        result = localize(path.read_text(encoding="utf-8"), url, embedded_lang, extra)
    except ValueError as error:
        print(f"localize-appcast: {error}", file=sys.stderr)
        return 1
    path.write_text(result, encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
