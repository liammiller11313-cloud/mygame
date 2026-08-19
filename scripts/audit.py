#!/usr/bin/env python3
"""
Static audit for Fading Light.

stylua proves the code parses; it cannot prove that a name resolves. Almost every
runtime failure in a Roblox codebase this size is a name that is spelled slightly
differently in two places: a remote that no longer exists, an enum key that was
renamed, a service looked up under the wrong string. This walks the tree and
checks those cross-references, which is exactly the class of bug that only shows
up when a player happens to trigger that one line.
"""
import re, sys, pathlib, collections

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "src"
files = sorted(SRC.rglob("*.lua"))
problems = []
notes = []

def read(p): return p.read_text(encoding="utf-8", errors="replace")
def rel(p): return str(p.relative_to(ROOT))

def lineno(text, idx): return text.count("\n", 0, idx) + 1

def strip_comments(text):
    """
    Blank out --[[ ]] blocks and -- line comments so that comment prose is not
    audited. Comments are replaced with spaces of the SAME LENGTH, preserving
    newlines, so every byte offset still matches the original file — otherwise
    every reported line number would be wrong, which is worse than no report.
    """
    def blank(m):
        return "".join("\n" if c == "\n" else " " for c in m.group(0))
    text = re.sub(r"--\[(=*)\[.*?\]\1\]", blank, text, flags=re.S)
    text = re.sub(r"--[^\n]*", blank, text)
    # String literals too: a warn() that mentions "spawn(" is prose, not a call.
    text = re.sub(r'"(?:[^"\\\n]|\\.)*"', blank, text)
    text = re.sub(r"'(?:[^'\\\n]|\\.)*'", blank, text)
    text = re.sub(r"\[(=*)\[.*?\]\1\]", blank, text, flags=re.S)
    return text

sources = {p: strip_comments(read(p)) for p in files}
raw = {p: read(p) for p in files}

def strip_comments_only(text):
    def blank(m):
        return "".join("\n" if c == "\n" else " " for c in m.group(0))
    text = re.sub(r"--\[(=*)\[.*?\]\1\]", blank, text, flags=re.S)
    return re.sub(r"--[^\n]*", blank, text)

# `sources` blanks string literals, which is right for spotting deprecated calls
# and wrong for anything that reads a remote name OUT of a string argument.
code = {p: strip_comments_only(read(p)) for p in files}

# ── 1. Enums ────────────────────────────────────────────────────────────────
enums_text = read(SRC / "shared/Enums/init.lua")
enum_tables = {}
for m in re.finditer(r"Enums\.(\w+)\s*=\s*table\.freeze\(\{(.*?)\n\}\)", enums_text, re.S):
    enum_tables[m.group(1)] = set(re.findall(r"^\s*(\w+)\s*=", m.group(2), re.M))

for p, text in sources.items():
    for m in re.finditer(r"\bEnums\.(\w+)\.(\w+)", text):
        table, key = m.group(1), m.group(2)
        if table not in enum_tables:
            continue
        if key not in enum_tables[table]:
            problems.append(f"{rel(p)}:{lineno(text, m.start())}  Enums.{table}.{key} does not exist")

# ── 2. Remotes ──────────────────────────────────────────────────────────────
rem_text = read(SRC / "shared/Net/Remotes.lua")
events = set(re.findall(r'^\t"(\w+)",', rem_text.split("local EVENTS")[1].split("]")[0], re.M))
funcs = set(re.findall(r'^\t"(\w+)",', rem_text.split("local FUNCTIONS")[1].split("\n}")[0], re.M))

used_events, fired, listened = set(), set(), set()
for p, text in sources.items():
    for m in re.finditer(r"Remotes\.Event\.(\w+)", text):
        name = m.group(1)
        used_events.add(name)
        if name not in events:
            problems.append(f"{rel(p)}:{lineno(text, m.start())}  Remotes.Event.{name} is not in the manifest")
        tail = text[m.end():m.end()+40]
        if "Fire" in tail: fired.add(name)
        if "OnServerEvent" in tail or "OnClientEvent" in tail: listened.add(name)
    for m in re.finditer(r"Remotes\.Function\.(\w+)", text):
        if m.group(1) not in funcs:
            problems.append(f"{rel(p)}:{lineno(text, m.start())}  Remotes.Function.{m.group(1)} is not in the manifest")
    for m in re.finditer(r'Remotes\.fire(?:AllExcept|InRange)\(\s*"(\w+)"', code[p]):
        used_events.add(m.group(1)); fired.add(m.group(1))
        if m.group(1) not in events:
            problems.append(f"{rel(p)}:{lineno(text, m.start())}  fired remote \"{m.group(1)}\" is not in the manifest")

for name in sorted((events - funcs) - used_events):
    notes.append(f"remote {name!r} is declared but never referenced")
for name in sorted(fired - listened):
    if name in events: notes.append(f"remote {name!r} is fired but nothing listens for it")
for name in sorted(listened - fired):
    if name in events: notes.append(f"remote {name!r} is listened for but never fired")

# ── 3. Attributes ───────────────────────────────────────────────────────────
attr_text = read(SRC / "shared/Net/Attributes.lua")
attr_groups = {}
for m in re.finditer(r"Attributes\.(\w+)\s*=\s*table\.freeze\(\{(.*?)\n\}\)", attr_text, re.S):
    attr_groups[m.group(1)] = set(re.findall(r"^\s*(\w+)\s*=", m.group(2), re.M))

alias_re = re.compile(r"local\s+(\w+)\s*=\s*Attributes\.(\w+)\b")
for p, text in sources.items():
    aliases = {m.group(1): m.group(2) for m in alias_re.finditer(text)}
    for m in re.finditer(r"\bAttributes\.(\w+)\.(\w+)", text):
        g, k = m.group(1), m.group(2)
        if g in attr_groups and k not in attr_groups[g]:
            problems.append(f"{rel(p)}:{lineno(text, m.start())}  Attributes.{g}.{k} does not exist")
    for alias, group in aliases.items():
        if group not in attr_groups: continue
        for m in re.finditer(rf"\b{alias}\.(\w+)", text):
            if m.group(1) not in attr_groups[group]:
                problems.append(f"{rel(p)}:{lineno(text, m.start())}  {alias}.{m.group(1)} (Attributes.{group}) does not exist")

# ── 4. Registry ─────────────────────────────────────────────────────────────
registered = collections.Counter()
for p, text in sources.items():
    for m in re.finditer(r'Registry\.register\(\s*"(\w+)"', code[p]):
        registered[m.group(1)] += 1
for name, n in registered.items():
    if n > 1:
        problems.append(f"service {name!r} is registered {n} times — Registry.register errors on a duplicate")
for p, text in sources.items():
    for m in re.finditer(r'Registry\.(?:get|find|waitFor)\(\s*"(\w+)"', code[p]):
        if m.group(1) not in registered:
            problems.append(f"{rel(p)}:{lineno(text, m.start())}  Registry lookup {m.group(1)!r} is never registered")

# ── 5. Config keys ──────────────────────────────────────────────────────────
def table_keys(text, name):
    m = re.search(rf"{re.escape(name)}\s*=\s*(?:table\.freeze\()?\{{", text)
    if not m: return None
    i = text.index("{", m.start()); depth, j = 0, i
    while j < len(text):
        if text[j] == "{": depth += 1
        elif text[j] == "}":
            depth -= 1
            if depth == 0: break
        j += 1
    body = text[i:j]
    keys = set(re.findall(r"^\t(\w+)\s*=", body, re.M))
    keys |= set(re.findall(r"\[Enums\.\w+\.(\w+)\]\s*=", body))
    return keys

audio_text = strip_comments(read(SRC / "shared/Config/AudioConfig.lua"))
for cat in ("WeaponFire", "WeaponReload", "Impact", "Gore", "Infected", "Survivor", "UI", "Music", "Mix"):
    keys = table_keys(audio_text, f"AudioConfig.{cat}")
    if keys is None: continue
    for p, text in sources.items():
        for m in re.finditer(rf"AudioConfig\.{cat}\.(\w+)", text):
            if m.group(1) not in keys:
                problems.append(f"{rel(p)}:{lineno(text, m.start())}  AudioConfig.{cat}.{m.group(1)} does not exist")

# ── 6. Module hygiene ───────────────────────────────────────────────────────
for p, text in raw.items():
    name = p.name
    body = sources[p].rstrip()
    if name.endswith((".server.lua", ".client.lua")):
        continue
    if not re.search(r"\breturn\b[^\n]*$", body):
        problems.append(f"{rel(p)}  ModuleScript does not end in a return statement")

# ── 7. Obvious runtime hazards ──────────────────────────────────────────────
for p, text in sources.items():
    for m in re.finditer(r"(?<![.:\w])wait\s*\(", text):
        problems.append(f"{rel(p)}:{lineno(text, m.start())}  bare wait() — use task.wait()")
    for m in re.finditer(r"(?<![.:\w])spawn\s*\(", text):
        problems.append(f"{rel(p)}:{lineno(text, m.start())}  bare spawn() — use task.spawn()")
    for m in re.finditer(r"(?<![.:\w])delay\s*\(", text):
        problems.append(f"{rel(p)}:{lineno(text, m.start())}  bare delay() — use task.delay()")
    for m in re.finditer(r":FindFirstChild\(\s*\"Humanoid\"\s*\)", text):
        problems.append(f"{rel(p)}:{lineno(text, m.start())}  Humanoid looked up by NAME — the Rusher rig names its Humanoid \"Zombie\"; use FindFirstChildOfClass")

print(f"audited {len(files)} Luau files\n")
if problems:
    print(f"── {len(problems)} PROBLEM(S) ──")
    for x in problems: print("  " + x)
else:
    print("── no problems found ──")
if notes:
    print(f"\n── {len(notes)} note(s) (not necessarily wrong) ──")
    for x in notes: print("  " + x)
sys.exit(1 if problems else 0)
