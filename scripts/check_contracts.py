#!/usr/bin/env python3
"""Check the contracts that cross a language boundary, which no compiler sees.

Arc's Swift talks to a TypeScript Worker talking to Postgres. Three of those
seams are matched by NAME at runtime and by nothing at all before it:

  1. Live Activity content-state — Swift struct vs the Worker's JSON.
     ActivityKit decodes a push with a plain JSONDecoder: a field the Worker
     stops emitting turns into nil, and a non-optional one fails the whole
     decode. Either way the lock screen just quietly stops showing something.
  2. The widget's own /flight decoder vs the Worker's mapLeg.
  3. Every column the Worker names in a PostgREST path vs the migrations.
     PostgREST answers 400 for a column that isn't there, and the caller's
     catch swallows it.

Run from anywhere:  python3 scripts/check_contracts.py
(`npm test` in backend/ runs it too.)
Exits non-zero on a mismatch.
"""
import collections
import glob
import os
import re
import sys

# Paths are resolved against the repo root, not the caller's cwd, so this runs
# the same from `backend/` (where npm test lives) as from the root.
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)

FAILURES = []


def fail(msg):
    FAILURES.append(msg)
    print(f"  FAIL  {msg}")


def swift_properties(text):
    """Stored properties only — computed ones have a `{` on the same line."""
    out = {}
    for m in re.finditer(r"^\s+(let|var) (\w+): ([^\n{=]+?)( = [^\n]*)?$", text, re.M):
        out[m.group(2)] = (m.group(1), m.group(4) is not None)
    return out


def object_literal_keys(text):
    """Keys of a returned object literal, including `shorthand,` form."""
    return set(re.findall(r"^    (\w+)[:,]", text, re.M))


def slice_between(text, start, end, what):
    try:
        i = text.index(start)
        return text[i:text.index(end, i)]
    except ValueError:
        fail(f"could not locate {what} — markers moved; fix this script, don't delete the check")
        return ""


def check_content_state():
    print("Live Activity content-state (Swift <-> Worker)")
    swift = slice_between(open("Shared/FlightActivityAttributes.swift").read(),
                          "struct ContentState", "/// The lock screen's own copy", "ContentState")
    ts = open("backend/src/activity.ts").read()
    emitted = object_literal_keys(slice_between(ts, "  return {", "\n}", "contentState() return"))
    declared = swift_properties(swift)
    if not declared or not emitted:
        return
    for name, (kind, has_default) in sorted(declared.items()):
        if name not in emitted:
            severity = ("the whole push fails to decode" if kind == "let" and not has_default
                        else "decodes as nil, silently")
            fail(f"Worker never emits `{name}` — {severity}")
    for name in sorted(emitted - set(declared)):
        fail(f"Worker emits `{name}`, which Swift does not declare — it is dropped")
    print(f"  {len(declared)} fields declared, {len(emitted)} emitted")


def check_widget_leg():
    print("Widget /flight decoder (Swift <- mapLeg)")
    leg = slice_between(open("ArcWidget/WidgetRefresh.swift").read(),
                        "private struct Leg: Decodable", "\n    }", "WidgetRefresh.Leg")
    emitted = object_literal_keys(
        slice_between(open("backend/src/index.ts").read(), "function mapLeg(", "\n}", "mapLeg"))
    declared = swift_properties(leg)
    if not declared or not emitted:
        return
    for name, (kind, has_default) in sorted(declared.items()):
        if name not in emitted:
            severity = ("the whole leg fails to decode" if kind == "let" and not has_default
                        else "decodes as nil")
            fail(f"mapLeg never emits `{name}` — {severity}")
    print(f"  {len(declared)} fields decoded, all present among mapLeg's {len(emitted)}")


def check_postgrest_columns():
    print("Worker PostgREST queries (columns <- migrations)")
    cols = collections.defaultdict(set)
    sql = "\n".join(open(f).read() for f in sorted(glob.glob("supabase/migrations/*.sql")))
    reserved = {"unique", "primary", "foreign", "constraint", "check", "references"}
    for m in re.finditer(r"create table (?:if not exists )?(?:public\.)?(\w+)\s*\((.*?)\n\);", sql, re.S):
        for line in m.group(2).split("\n"):
            c = re.match(r"\s*([a-z_][a-z0-9_]*)\s", line)
            if c and c.group(1) not in reserved:
                cols[m.group(1)].add(c.group(1))
    for m in re.finditer(r"alter table (?:public\.)?(\w+)(.*?);", sql, re.S):
        cols[m.group(1)] |= set(
            re.findall(r"add column (?:if not exists )?([a-z_][a-z0-9_]*)", m.group(2)))
    if not cols:
        fail("parsed no tables out of supabase/migrations — the check is not running")
        return
    src = open("backend/src/index.ts").read()
    checked = 0
    for m in re.finditer(r'["`]/(\w+)\?([^"`]*)', src):
        table, qs = m.group(1), m.group(2)
        if table not in cols:
            continue
        checked += 1
        named = set()
        sel = re.search(r"select=([a-z_,0-9]+)", qs)
        if sel:
            named |= {c for c in sel.group(1).split(",") if c and c != "*"}
        named |= set(re.findall(r"[?&](?:or=\()?([a-z_][a-z0-9_]*)=(?:eq|gte|lte|lt|gt|is|in|neq)\.", qs))
        named |= set(re.findall(r"order=([a-z_][a-z0-9_]*)", qs))
        for missing in sorted(named - cols[table]):
            fail(f"{table} has no column `{missing}` — PostgREST answers 400 and the catch eats it")
    print(f"  {checked} queries across {len(cols)} tables")


check_content_state()
check_widget_leg()
check_postgrest_columns()

print()
if FAILURES:
    print(f"{len(FAILURES)} contract failure(s)")
    sys.exit(1)
print("all cross-language contracts hold")
