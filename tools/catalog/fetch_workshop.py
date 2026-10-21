"""Fetch every installed loader package's Steam Workshop description into a folder of text files.

Usage: python fetch_workshop.py <ManagedMods dir> <output dir>

Reads each package's InstallManifest.json for its WorkshopId, asks the public Steam Web API
(ISteamRemoteStorage/GetPublishedFileDetails, no key needed) for the items in one request, and
writes <output dir>/<PackageName>.txt holding the item title, id, and description with BBCode
tags stripped. Local-only packages (ids at or above 9000000000) are skipped. Nothing is written
into the game.
"""
import json
import re
import sys
from pathlib import Path

import requests

LOCAL_ID_FLOOR = 9000000000
API = "https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/"


def read_json(path):
    try:
        return json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, ValueError):
        return None


def strip_bbcode(text):
    text = re.sub(r"\[/?(b|i|u|s|h1|h2|h3|list|olist|table|tr|th|td|hr|noparse|spoiler|strike|code|quote)[^\]]*\]", "", text)
    text = re.sub(r"\[url=[^\]]*\]", "", text).replace("[/url]", "")
    text = re.sub(r"\[img\][^\[]*\[/img\]", "", text)
    text = re.sub(r"\[\*\]", "- ", text)
    text = re.sub(r"\[/?[a-z]+[^\]]*\]", "", text)
    return text


def main():
    managed = Path(sys.argv[1])
    out = Path(sys.argv[2])
    out.mkdir(parents=True, exist_ok=True)
    items = {}
    for package in sorted(p for p in managed.iterdir() if p.is_dir()):
        manifest = read_json(package / "InstallManifest.json") or {}
        item = manifest.get("WorkshopId")
        if isinstance(item, int) and item < LOCAL_ID_FLOOR:
            items[item] = package.name
    form = {"itemcount": len(items)}
    for index, item in enumerate(items):
        form[f"publishedfileids[{index}]"] = item
    response = requests.post(API, data=form, timeout=60)
    response.raise_for_status()
    details = response.json()["response"]["publishedfiledetails"]
    fetched = empty = 0
    for detail in details:
        item = int(detail.get("publishedfileid", 0))
        package = items.get(item)
        text = strip_bbcode(detail.get("description") or "").strip()
        if package is None or not text:
            empty += 1
            print(f"EMPTY {package} {item} result={detail.get('result')}")
            continue
        (out / f"{package}.txt").write_text(
            f"{detail.get('title', '')}\nWorkshop item {item}\n\n{text}\n", encoding="utf-8")
        fetched += 1
    print(f"fetched {fetched}, empty {empty}, asked {len(items)}")


if __name__ == "__main__":
    main()
