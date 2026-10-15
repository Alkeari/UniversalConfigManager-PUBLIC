"""Merge catalog fragments into Scripts/catalog.lua.

Usage: python merge_catalog.py <fragment dir> <Scripts/catalog.lua>
       python merge_catalog.py --audit <Scripts/catalog.lua>

Each fragment is a Lua module returning { descriptions = { ["Mod.key"] = "sentence", ... },
names = {...}, mods = {...} }, the shape catalog.lua itself uses. Fragments are read with a
small pattern-based parser (one string entry per line), merged with the existing catalog
(fragments win), validated, sorted, and written back.

Every table has its own rules, because they hold different things (until 2026-09-06 only
`descriptions` was checked at all, and the other five went in unread):

  descriptions  one sentence of 20 to 200 characters ending in a period
  entries       a value list or a format with an example, no length cap: what a long one
                actually breaks is the rendered width of the Possible Entries strip, and that
                is checked where the real width model lives
  bounds        "min|max" or "min|max|step", the shape Bounds.overrideFor matches
  hidden        one sentence saying why a setting is not a preference
  names, mods   a short title, never a sentence
  restart       why we KNOW that mod needs the whole game restarted, keyed by mod folder;
                without an entry the tab promises a world reload instead

No table takes an em dash or a semicolon. `--audit` runs the same rules over a whole catalog
without merging anything, so an entry that predates its validator still surfaces; a normal run
audits the merged result too and exits nonzero on a problem.
"""
import re
import sys
from pathlib import Path

ENTRY = re.compile(r'^\s*\["((?:[^"\\]|\\.)*)"\]\s*=\s*"((?:[^"\\]|\\.)*)"\s*,?\s*$')
SECTION = re.compile(r"^\s*(bounds|descriptions|entries|hidden|names|mods|restart)\s*=\s*\{")


def unescape(text):
    return text.encode("utf-8").decode("unicode_escape").encode("latin-1").decode("utf-8")


def escape(text):
    return text.replace("\\", "\\\\").replace('"', '\\"')


def parse(path):
    tables = {"bounds": {}, "descriptions": {}, "entries": {}, "hidden": {}, "names": {}, "mods": {}, "restart": {}}
    current = None
    for line in path.read_text(encoding="utf-8").splitlines():
        section = SECTION.match(line)
        if section:
            current = section.group(1)
            continue
        entry = ENTRY.match(line)
        if entry and current:
            tables[current][unescape(entry.group(1))] = unescape(entry.group(2))
    return tables


def normalize(text):
    """The house form for a description or a hidden reason: "Sentence. (?)", period before marker.

    Writing the marker in place of the final period is the obvious reading, and it cost 221 good
    lines a rejection on the first batch of contributed entries (2026-09-06). The shape is
    mechanical, so it is corrected here rather than explained again. A semicolon is corrected the
    same way: the checker refuses one, and splitting the clause in two is refused as well.
    """
    if text.endswith(" (?)") and not text[:-4].endswith("."):
        text = text[:-4] + ". (?)"
    return text.replace("; ", ", ").replace(";", ",")


def common(key, text):
    """The rules every table shares: a key that names a setting, and text a player can read."""
    problems = []
    if "." not in key:
        problems.append("key without mod prefix")
    if text != text.strip() or text == "":
        problems.append("empty or padded")
    if "\t" in text or "\n" in text or "\r" in text:
        problems.append("tab or newline")
    if "—" in text or "–" in text:
        problems.append("dash")
    if ";" in text:
        problems.append("semicolon")
    return problems


def valid_description(key, text):
    problems = common(key, text)
    if text.endswith(" (?)"):
        text = text[:-4]
    if not 20 <= len(text) <= 200:
        problems.append("length")
    if not text.endswith("."):
        problems.append("no period")
    if text.count(". ") > 0:
        problems.append("two sentences")
    return problems


def top_level_values(text):
    """The comma-separated values of an entries list, keeping each value's note attached."""
    values, depth, current = [], 0, []
    for character in text:
        if character == "(":
            depth += 1
        elif character == ")":
            depth -= 1
        if character == "," and depth == 0:
            values.append("".join(current).strip())
            current = []
            continue
        current.append(character)
    values.append("".join(current).strip())
    return values


def valid_entries(key, text):
    """An entries value is a LIST, not a sentence, so the description rules do not fit it.

    It carries no length cap: a gamepad vocabulary is 17 names and a reaction profile list is
    eleven values with a note each, and every entry is shown, with the strip's filter box
    narrowing a long one. What a too-long value actually breaks
    is the RENDERED width, and that is checked where the real width model lives, against
    every shipped language.
    """
    problems = common(key, text)
    body = text[:-4] if text.endswith(" (?)") else text
    if "(?)" in body:
        problems.append("the ' (?)' marker belongs at the end, once")
    if text.count("(") != text.count(")"):
        problems.append("unbalanced parentheses")
    if "\\u{" in text:
        problems.append("escape text a player would type literally")
    values = top_level_values(body)
    for value in values:
        # Entries.hasNotes finds a note by the space before its "(", so "value(note)" is invisible
        # to the dropdown gate and that row loses its strip. A value that IS a parenthesis,
        # "(empty)" for the empty string, opens at the start and is not a note.
        if re.search(r"[^\s(]\(", value):
            problems.append(f"note without a space before it: {value!r}")
    # The list rules apply only to a LIST. Some entries are a format with an example instead
    # ("up to four accessory ids separated by commas, for example A,B,,"), where a repeated word
    # and a trailing comma are the point. A value carrying a space outside its note marks that
    # shape, so the strict rules stay off it.
    if len(values) >= 2 and all(" " not in value.split(" (")[0] for value in values):
        if body.endswith(",") or body.endswith("."):
            problems.append("trailing comma or period")
        seen = set()
        for value in values:
            name = value.split(" (")[0].strip().lower()
            if name == "":
                problems.append("empty value in the list")
            elif name in seen:
                problems.append(f"duplicate value {name!r}")
            seen.add(name)
    return problems


BOUNDS = re.compile(r"^(-?\d+(?:\.\d+)?)\|(-?\d+(?:\.\d+)?)(?:\|(-?\d+(?:\.\d+)?))?$")


def valid_bounds(key, text):
    """"min|max" or "min|max|step", the shape Bounds.overrideFor pattern-matches.

    Its Lua match fails silently on anything else, so a typo here does not log: it just leaves
    the slider on whatever the mining ladder guessed, which is the case the override exists to
    correct.
    """
    problems = common(key, text)
    match = BOUNDS.match(text)
    if match is None:
        return problems + ["not min|max or min|max|step"]
    low, high = float(match.group(1)), float(match.group(2))
    if low >= high:
        problems.append("min is not below max")
    if match.group(3) is not None:
        step = float(match.group(3))
        if step <= 0 or step > high - low:
            problems.append("step is not a positive fraction of the range")
    return problems


def valid_hidden(key, text):
    """Why a setting is not a preference. The catalog author reads it, so one plain sentence."""
    problems = common(key, text)
    if not 20 <= len(text) <= 200:
        problems.append("length")
    if not text.endswith("."):
        problems.append("no period")
    return problems


def valid_label(key, text, prefixed):
    """A row label or a mod's display name: a short title, never a sentence."""
    problems = [p for p in common(key, text) if p != "key without mod prefix"]
    if prefixed and "." not in key:
        problems.append("key without mod prefix")
    if not prefixed and "." in key:
        problems.append("a mods key is the folder name, with no setting after it")
    if not 2 <= len(text) <= 60:
        problems.append("length")
    if text.endswith("."):
        problems.append("a label is not a sentence")
    if text[:1].islower():
        problems.append("label does not start capitalized")
    return problems


def valid_restart(key, text):
    """Evidence that a mod truly needs the whole game restarted, keyed by its folder.

    The default promise is that reloading into a world or server is enough, so an entry here is
    a claim we have to have PROVEN, and the value is where that proof is written down.
    """
    problems = [p for p in common(key, text) if p != "key without mod prefix"]
    if "." in key:
        problems.append("a restart key is the mod folder, with no setting after it")
    if not 20 <= len(text) <= 200:
        problems.append("length")
    if not text.endswith("."):
        problems.append("no period")
    return problems


VALIDATORS = {
    "bounds": valid_bounds,
    "descriptions": valid_description,
    "entries": valid_entries,
    "hidden": valid_hidden,
    "names": lambda key, text: valid_label(key, text, True),
    "mods": lambda key, text: valid_label(key, text, False),
    "restart": valid_restart,
}


def render(tables):
    lines = ["-- The curated catalog: player-facing descriptions, labels, and mod names that the evidence",
             "-- ladders in present.lua cannot derive from a mod's own files. Keys are \"<mod folder>.<raw key>\"",
             "-- (mods[\"<mod folder>\"] for a display name). Sources per mod are the Workshop page, the mod's",
             "-- README, and its code; every entry is one plain sentence a player can act on.",
             "-- Built by tools\\catalog (fetch_workshop.py, dump_gaps.lua, merge_catalog.py); a missing",
             "-- entry falls back to Present.COMMUNITY_PROMPT, never an error.",
             "return {"]
    for section in ("bounds", "descriptions", "entries", "hidden", "names", "mods", "restart"):
        lines.append(f"    {section} = {{")
        for key in sorted(tables[section], key=str.lower):
            lines.append(f'        ["{escape(key)}"] = "{escape(tables[section][key])}",')
        lines.append("    },")
    lines.append("}")
    return "\n".join(lines) + "\n"


def audit(tables):
    """Every problem in a whole catalog, so an entry that predates its validator still surfaces."""
    problems = []
    for section, entries in tables.items():
        for key, text in sorted(entries.items()):
            for problem in VALIDATORS[section](key, text):
                problems.append(f"{section} {key}: {problem}: {text}")
    return problems


def main():
    target = Path(sys.argv[-1])
    if sys.argv[1:2] == ["--audit"]:
        problems = audit(parse(target))
        for problem in problems:
            print(f"PROBLEM {problem}")
        print(f"audited {target}: {len(problems)} problem(s)")
        return 1 if problems else 0
    fragments = Path(sys.argv[1])
    merged = parse(target) if target.exists() else {"bounds": {}, "descriptions": {}, "entries": {}, "hidden": {}, "names": {}, "mods": {}, "restart": {}}
    added = 0
    rejected = 0
    for fragment in sorted(fragments.glob("*.lua")):
        tables = parse(fragment)
        for section, entries in tables.items():
            for key, text in entries.items():
                if section in ("descriptions", "hidden"):
                    text = normalize(text)
                problems = VALIDATORS[section](key, text)
                if problems:
                    rejected += 1
                    print(f"REJECT {fragment.name} {section} {key}: {', '.join(problems)}: {text}")
                    continue
                if merged[section].get(key) != text:
                    added += 1
                merged[section][key] = text
    target.write_text(render(merged), encoding="utf-8")
    total = sum(len(v) for v in merged.values())
    print(f"merged {added} new or changed, rejected {rejected}, catalog now {total} entries")
    standing = audit(merged)
    for problem in standing:
        print(f"PROBLEM {problem}")
    if standing:
        print(f"{len(standing)} problem(s) already in {target.name}; fix them by hand")
    return 1 if rejected or standing else 0


if __name__ == "__main__":
    sys.exit(main())
