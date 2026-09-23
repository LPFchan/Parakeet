"""Adds a release to docs/appcast.xml, newest first.

usage: appcast.py VERSION BUILD URL 'sparkle:edSignature="…" length="…"'
(the last argument is sign_update's output, pasted into the enclosure).
"""

import sys
from email.utils import formatdate
from pathlib import Path

version, build, url, signature = sys.argv[1:]
feed = Path(__file__).resolve().parent.parent / "docs/appcast.xml"
item = f"""    <item>
      <title>Version {version}</title>
      <pubDate>{formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>https://github.com/LPFchan/Parakeet/releases/tag/v{version}</sparkle:fullReleaseNotesLink>
      <enclosure url="{url}" type="application/octet-stream" {signature.strip()}/>
    </item>
"""
xml = feed.read_text()
at = xml.find("    <item>")
if at < 0:
    at = xml.index("  </channel>")
feed.write_text(xml[:at] + item + xml[at:])
