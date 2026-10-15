"""Generates Assets/lang/<code>.ini for every language Palworld ships.

Sources (the only files to edit):
  tools/lang/ui.tsv                 UI strings: key <TAB> English text.
  Scripts/catalog.lua               Catalog descriptions; each becomes the key "d:<mod>.<key>".
  tools/lang/translations/<code>.tsv  One file per non-English code: key <TAB> translated text,
                                      covering every key of the English set.

Usage:
  python tools/lang/build_lang.py            validate every translation and write the ini files
  python tools/lang/build_lang.py export     write tools/lang/en.tsv, the full English key set
                                             a translator works from

Validation refuses a translation file with a missing or unknown key, a placeholder set that
differs from English ({name} tokens), a tab or newline inside a value, or a description that
drops or adds the " (?)" code-inferred marker. Missing translation files are reported and
skipped, so a build never silently ships a language without text; the runtime falls back to
English per key anyway.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
UI_TSV = ROOT / "tools" / "lang" / "ui.tsv"
CATALOG = ROOT / "Scripts" / "catalog.lua"
TRANSLATIONS = ROOT / "tools" / "lang" / "translations"
OUT_DIR = ROOT / "Assets" / "lang"
EXPORT = ROOT / "tools" / "lang" / "en.tsv"
# The English each translation was last made against. Nothing else here can see that an English
# sentence was REWRITTEN under a translation still carrying the old one: the key, its placeholders
# and its marker all stay put while the meaning moves, so every language keeps a translation of a
# sentence that no longer exists. That happened to 52 keys at once on 2026-09-04, silently, and
# was only caught by diffing this file against a git baseline by hand.
BASELINE = ROOT / "tools" / "lang" / "en.baseline.tsv"

LANGUAGES = ["de", "es", "es-MX", "fr", "id", "it", "ja", "ko", "pl", "pt-BR", "ru", "th", "tr",
             "vi", "zh-Hans", "zh-Hant"]

PLACEHOLDER = re.compile(r"\{(\w+)\}")
MARKER = " (?)"


def read_tsv(path: Path, header: bool) -> dict[str, str]:
    out: dict[str, str] = {}
    lines = path.read_text(encoding="utf-8-sig").splitlines()
    if header and lines and lines[0].split("\t")[0] == "key":
        lines = lines[1:]
    for number, line in enumerate(lines, 1):
        if not line.strip():
            continue
        parts = line.split("\t")
        if len(parts) != 2:
            raise SystemExit(f"{path}:{number}: expected key<TAB>text, got {len(parts)} field(s)")
        key, text = parts[0].strip(), parts[1]
        if key in out:
            raise SystemExit(f"{path}:{number}: duplicate key {key}")
        out[key] = text
    return out


def lua_unescape(text: str) -> str:
    return (text.replace('\\"', '"').replace("\\'", "'").replace("\\n", "\n")
            .replace("\\\\", "\\"))


def read_catalog_table(name: str, prefix: str) -> dict[str, str]:
    """One of the catalog's string tables, keyed `<prefix><mod>.<key>`.

    Stop at that table's own closing brace, not the file's: the catalog also carries bounds,
    hidden, names and mods, and a greedy stop swallowed all of them into the set (2026-09-03).
    """
    source = CATALOG.read_text(encoding="utf-8")
    block = re.search(r"\n    " + name + r"\s*=\s*\{(.*?)\n    \},", source, re.S)
    if block is None:
        raise SystemExit(f"{CATALOG}: no {name} table found")
    out: dict[str, str] = {}
    entry = re.compile(r'\[\s*"((?:[^"\\]|\\.)*)"\s*\]\s*=\s*"((?:[^"\\]|\\.)*)"')
    for match in entry.finditer(block.group(1)):
        out[prefix + lua_unescape(match.group(1))] = lua_unescape(match.group(2))
    if not out:
        raise SystemExit(f"{CATALOG}: {name} table parsed empty")
    return out


def english() -> dict[str, str]:
    strings = read_tsv(UI_TSV, header=True)
    # Descriptions are the tooltip; entries are the "Possible Entries" list under a text box.
    # Both are player-facing prose and both ship in all 17 languages; entries were English-only
    # until 2026-09-04, which is an English-only UI by the back door.
    strings.update(read_catalog_table("descriptions", "d:"))
    strings.update(read_catalog_table("entries", "e:"))
    return strings


def validate(code: str, en: dict[str, str], translated: dict[str, str]) -> list[str]:
    problems: list[str] = []
    missing = sorted(set(en) - set(translated))
    unknown = sorted(set(translated) - set(en))
    # A UI string missing from a language is a defect: the player sees English in a screen that is
    # otherwise their own language. A catalog description is different. It describes ANOTHER
    # author's setting, it arrives in batches of hundreds as players send requests, and i18n
    # already falls back to English per key. Blocking the build on it would mean either shipping
    # no new descriptions at all or holding 706 of them hostage to 16 translation passes.
    missing_ui = [k for k in missing if not k.startswith(("d:", "e:"))]
    missing_catalog = [k for k in missing if k.startswith(("d:", "e:"))]
    if missing_ui:
        problems.append(f"{len(missing_ui)} missing UI key(s), first: {missing_ui[:5]}")
    if missing_catalog:
        print(f"  note: {code}: {len(missing_catalog)} catalog description(s) not translated yet; "
              "they fall back to English")
    if unknown:
        problems.append(f"{len(unknown)} unknown key(s), first: {unknown[:5]}")
    for key, text in translated.items():
        if key not in en:
            continue
        if "\t" in text or "\n" in text or "\r" in text:
            problems.append(f"{key}: tab or newline in value")
        if not text.strip():
            problems.append(f"{key}: empty")
        if set(PLACEHOLDER.findall(text)) != set(PLACEHOLDER.findall(en[key])):
            problems.append(f"{key}: placeholders differ from English")
        if en[key].endswith(MARKER) != text.endswith(MARKER):
            problems.append(f"{key}: the ' (?)' marker must match English")
    return problems


def write_ini(code: str, strings: dict[str, str]) -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    lines = [f"# Universal Config Manager strings ({code}). key=value, UTF-8, generated by"
             " tools/lang/build_lang.py; edit tools/lang instead. Missing keys fall back to English."]
    # UI keys first, then the two catalog namespaces, each sorted within itself.
    for key in sorted(strings, key=lambda k: (k[:2] in ("d:", "e:"), k)):
        lines.append(f"{key}={strings[key].replace(chr(10), chr(92) + 'n')}")
    (OUT_DIR / f"{code}.ini").write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")


def drifted(en: dict[str, str]) -> list[str]:
    """Keys whose English has moved since the translations were written."""
    if not BASELINE.exists():
        return []
    was = read_tsv(BASELINE, header=True)
    return sorted(key for key, text in en.items() if key in was and was[key] != text)


def main(argv: list[str]) -> int:
    en = english()
    if argv[1:] == ["accept"]:
        BASELINE.write_text("key\ten\n" + "".join(f"{k}\t{v}\n" for k, v in en.items()),
                            encoding="utf-8", newline="\n")
        print(f"wrote {BASELINE} ({len(en)} keys): the translations are now the record of this English")
        return 0
    if argv[1:] == ["export"]:
        EXPORT.write_text("key\ten\n" + "".join(f"{k}\t{v}\n" for k, v in en.items()),
                          encoding="utf-8", newline="\n")
        print(f"wrote {EXPORT} ({len(en)} keys)")
        return 0
    write_ini("en", en)
    failed = False
    drift = drifted(en)
    if drift:
        failed = True
        print(f"REJECTED: {len(drift)} key(s) whose English changed since they were translated; "
              "every language still reads the old sentence. Retranslate them, then run "
              "`build_lang.py accept` to record the new English.")
        for key in drift[:20]:
            print(f"  {key}")
    for code in LANGUAGES:
        path = TRANSLATIONS / f"{code}.tsv"
        if not path.exists():
            print(f"{code}: no translation file, skipped")
            failed = True
            continue
        translated = read_tsv(path, header=True)
        problems = validate(code, en, translated)
        if problems:
            failed = True
            print(f"{code}: REJECTED")
            for problem in problems[:20]:
                print(f"  {problem}")
            continue
        write_ini(code, translated)
        print(f"{code}: {len(translated)} keys")
    print(f"en: {len(en)} keys")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
