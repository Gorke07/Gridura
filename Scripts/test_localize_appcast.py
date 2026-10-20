"""Tests for localize-appcast.py (run: python3 -m unittest Scripts/test_localize_appcast.py)."""
import importlib.util
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent / "localize-appcast.py"
spec = importlib.util.spec_from_file_location("localize_appcast", SCRIPT)
localize_appcast = importlib.util.module_from_spec(spec)
spec.loader.exec_module(localize_appcast)

NEW = "https://example.com/v0.3.0/App-0.3.0.dmg"
OLD = "https://example.com/v0.2.0/App-0.2.0.dmg"
APPCAST = f"""<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
    <channel>
        <title>App</title>
        <item>
            <title>0.3.0</title>
            <description sparkle:format="markdown"><![CDATA[### New
- **Bold** item
]]></description>
            <enclosure url="{NEW}" length="1" type="application/octet-stream" sparkle:edSignature="sig"/>
        </item>
        <item>
            <title>0.2.0</title>
            <description xml:lang="en" sparkle:format="markdown"><![CDATA[old en]]></description>
            <description xml:lang="tr" sparkle:format="markdown"><![CDATA[old tr]]></description>
            <enclosure url="{OLD}" length="1" type="application/octet-stream" sparkle:edSignature="sig"/>
        </item>
    </channel>
</rss>"""
LANG = "{http://www.w3.org/XML/1998/namespace}lang"


def descriptions(xml, title):
    root = ET.fromstring(xml)
    item = next(i for i in root.iter("item") if i.findtext("title") == title)
    return {d.get(LANG): d.text for d in item.findall("description")}


class LocalizeAppcastTests(unittest.TestCase):
    def test_new_item_gets_a_description_per_language(self):
        result = localize_appcast.localize(APPCAST, NEW, "en", {"tr": "### Yeni\n- **Kalın** madde\n"})
        self.assertEqual(descriptions(result, "0.3.0"), {
            "en": "### New\n- **Bold** item\n",
            "tr": "### Yeni\n- **Kalın** madde\n",
        })

    def test_everything_outside_the_new_item_is_unchanged(self):
        result = localize_appcast.localize(APPCAST, NEW, "en", {"tr": "x"})
        old_item = APPCAST[APPCAST.index("<item>", APPCAST.index(NEW)):]
        self.assertTrue(result.endswith(old_item))
        self.assertTrue(result.startswith(APPCAST[:APPCAST.index("<item>")]))

    def test_added_description_keeps_the_items_indentation(self):
        result = localize_appcast.localize(APPCAST, NEW, "en", {"tr": "x"})
        self.assertIn('\n            <description xml:lang="tr" sparkle:format="markdown"><![CDATA[x]]></description>\n', result)

    def test_unknown_url_is_an_error(self):
        with self.assertRaisesRegex(ValueError, "no item"):
            localize_appcast.localize(APPCAST, "https://example.com/missing.dmg", "en", {"tr": "x"})

    def test_already_localized_item_is_an_error(self):
        with self.assertRaisesRegex(ValueError, "exactly one"):
            localize_appcast.localize(APPCAST, OLD, "en", {"tr": "x"})

    def test_notes_that_would_end_the_cdata_section_are_an_error(self):
        with self.assertRaisesRegex(ValueError, r"\]\]>"):
            localize_appcast.localize(APPCAST, NEW, "en", {"tr": "a ]]> b"})

    def test_command_line_rewrites_the_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            appcast = Path(tmp) / "appcast.xml"
            notes = Path(tmp) / "tr.md"
            appcast.write_text(APPCAST, encoding="utf-8")
            notes.write_text("Türkçe notlar", encoding="utf-8")
            run = subprocess.run([sys.executable, str(SCRIPT), str(appcast), NEW, "en", f"tr={notes}"],
                                 capture_output=True, text=True)
            self.assertEqual(run.returncode, 0, run.stderr)
            self.assertEqual(descriptions(appcast.read_text(encoding="utf-8"), "0.3.0")["tr"], "Türkçe notlar")

    def test_command_line_failure_leaves_the_file_alone(self):
        with tempfile.TemporaryDirectory() as tmp:
            appcast = Path(tmp) / "appcast.xml"
            notes = Path(tmp) / "tr.md"
            appcast.write_text(APPCAST, encoding="utf-8")
            notes.write_text("x", encoding="utf-8")
            run = subprocess.run([sys.executable, str(SCRIPT), str(appcast), OLD, "en", f"tr={notes}"],
                                 capture_output=True, text=True)
            self.assertEqual(run.returncode, 1)
            self.assertEqual(appcast.read_text(encoding="utf-8"), APPCAST)


if __name__ == "__main__":
    unittest.main()
