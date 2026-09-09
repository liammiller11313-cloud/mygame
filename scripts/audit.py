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
def manifest_block(text, marker):
    """
    The names between `local <marker> ... = {` and its matching closing brace.

    Splitting on the first "]" was wrong: a comment like `{[string]: number}`
    contains one, which silently truncated the manifest and made every remote
    declared after it look missing.
    """
    start = text.index(marker)
    # Anchor on the assignment, not the first brace: `local EVENTS: { string } = {`
    # opens a brace in its TYPE annotation before the table itself begins.
    open_brace = text.index("{", text.index("=", start))
    depth, i = 0, open_brace
    while i < len(text):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                break
        i += 1
    return set(re.findall(r'^\t"(\w+)"', text[open_brace:i], re.M))

events = manifest_block(rem_text, "local EVENTS")
funcs = manifest_block(rem_text, "local FUNCTIONS")

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

# ── 3b. UITheme, through an alias ───────────────────────────────────────────
# The bug this exists for: `local LAYOUT = UITheme.Layout` and then
# `LAYOUT.RowHeightTouch`, which lives on UITheme.Panel. Luau is happy — a
# missing key is nil — and the failure lands three lines later as
# `UDim2.fromOffset(138, nil)`, which throws at BUILD time and takes the whole
# controller with it. stylua parses it, selene sees a defined name, and the
# check that would have caught it only knew about Attributes.
#
# Same shape as check 3 above, and for the same reason: a theme table is a
# frozen namespace read through a short alias in forty files, which is exactly
# the shape where a key drifts to a neighbouring table and nothing notices.
theme_text = read(SRC / "shared/Config/UITheme.lua")
theme_groups = {}
for m in re.finditer(r"UITheme\.(\w+)\s*=\s*table\.freeze\(\{(.*?)\n\}\)", theme_text, re.S):
    theme_groups[m.group(1)] = set(re.findall(r"^\t(\w+)\s*=", m.group(2), re.M))

theme_alias_re = re.compile(r"^local\s+(\w+)\s*=\s*UITheme\.(\w+)\s*$", re.M)
for p, text in sources.items():
    body = strip_comments(text)
    for alias, group in theme_alias_re.findall(text):
        if group not in theme_groups or not theme_groups[group]: continue
        for m in re.finditer(rf"\b{alias}\.(\w+)", body):
            key = m.group(1)
            if key in theme_groups[group]: continue
            owner = [g for g, keys in theme_groups.items() if key in keys]
            where = f" — it is on UITheme.{owner[0]}" if owner else ""
            problems.append(
                f"{rel(p)}:{lineno(body, m.start())}  {alias}.{key} "
                f"(UITheme.{group}) does not exist{where}"
            )

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

# ── 5b. EVERY config module's keys, direct and through an alias ─────────────
# The bug this exists for, caught the hard way: ShotPattern was edited to read
# GameConfig.Recoil.FirstShotScale and friends in the same change that was
# supposed to add them — and the half that added them silently did not apply.
# Every one of those reads was nil, every arithmetic on them would have thrown
# on the first shot fired, and the whole toolchain said the file was clean:
# stylua parses it, selene sees a table index on a defined name, and check 5
# only knows about AudioConfig.
#
# This started as a GameConfig-only check and covered one module out of
# twenty-one. Generalised, because nothing about that bug was specific to
# GameConfig — it is the shape of every frozen namespace read through a short
# alias in forty files, and the other twenty modules had no cover at all.
#
# Aliased on purpose, because that is how these are actually used: nobody writes
# GameConfig.Recoil.ViewScale at the call site, they write
# `local RECOIL = GameConfig.Recoil` once and RECOIL.ViewScale after. Check 3
# learned the same lesson for Attributes.
_cfg_groups = {}
for _f in sorted((SRC / "shared/Config").glob("*.lua")):
    _mod = _f.stem
    _text = strip_comments(read(_f))
    _g = {}
    for _group in re.findall(rf"^{_mod}\.(\w+)\s*=\s*(?:table\.freeze\()?\{{", _text, re.M):
        _keys = table_keys(_text, f"{_mod}.{_group}")
        if _keys:
            _g[_group] = _keys
    if _g:
        _cfg_groups[_mod] = _g

_seen_cfg = set()
for p, text in sources.items():
    for _mod, _groups in _cfg_groups.items():
        # Direct reads: Config.Group.Key
        for _group, _keys in _groups.items():
            for m in re.finditer(rf"\b{_mod}\.{_group}\.(\w+)", text):
                if m.group(1) not in _keys:
                    _msg = (f"{rel(p)}:{lineno(text, m.start())}  "
                            f"{_mod}.{_group}.{m.group(1)} does not exist")
                    if _msg not in _seen_cfg:
                        _seen_cfg.add(_msg)
                        problems.append(_msg)
        # Aliased reads: `local A = Config.Group` … `A.Key`.
        #
        # Deliberately NOT `local A = Config.Group[k]`, which binds one ELEMENT
        # of the group and has entirely different keys — SettingsConfig.Difficulty
        # is a table of profiles, and `profile.incomingDamage` is a real read of
        # one of them rather than a missing key on the group.
        for _alias, _group in re.findall(rf"local\s+(\w+)\s*=\s*{_mod}\.(\w+)\s*(?![\[.\w])", text):
            if _group not in _groups:
                continue
            for m in re.finditer(rf"\b{_alias}\.(\w+)", text):
                if m.group(1) not in _groups[_group]:
                    _msg = (f"{rel(p)}:{lineno(text, m.start())}  "
                            f"{_alias}.{m.group(1)} ({_mod}.{_group}) does not exist")
                    if _msg not in _seen_cfg:
                        _seen_cfg.add(_msg)
                        problems.append(_msg)

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


# ── 8. Calls to names that are never defined ────────────────────────────────
# The bug this exists for: an edit deletes a local function while leaving its
# call sites behind. Luau parses that perfectly happily and it only fails when a
# player pulls the trigger. Anything not defined in the file, not a parameter,
# not a loop variable and not a known global is reported.
LUA_GLOBALS = {
    "assert","error","getfenv","getmetatable","ipairs","loadstring","newproxy","next",
    "pairs","pcall","print","rawequal","rawget","rawlen","rawset","require","select",
    "setmetatable","tonumber","tostring","type","typeof","unpack","warn","xpcall",
    "collectgarbage","gcinfo","delay","spawn","wait","tick","time","elapsedTime",
    "settings","version","Instance","Vector2","Vector3","CFrame","Color3","UDim","UDim2",
    "Ray","Rect","Region3","BrickColor","NumberRange","NumberSequence","ColorSequence",
    "NumberSequenceKeypoint","ColorSequenceKeypoint","PhysicalProperties","TweenInfo",
    "Random","Enum","game","workspace","script","shared","string","table","math","os",
    "coroutine","task","utf8","bit32","debug","buffer","Font","OverlapParams",
    "RaycastParams","Faces","Axes","DateTime","CatalogSearchParams","FloatCurveKey",
    "RotationCurveKey","SharedTable","Content","Secret","Path2D","if","then","else",
    "elseif","end","and","or","not","return","function","local","for","while","do",
    "repeat","until","break","continue","true","false","nil","in",
}

DECL_PATTERNS = [
    r"local\s+function\s+(\w+)",
    r"local\s+([\w\s,]+?)\s*[:=]",
    r"function\s+[\w.:]*[.:](\w+)\s*\(",
    r"function\s+(\w+)\s*\(",
    r"for\s+([\w\s,]+?)\s+in\b",
    r"for\s+(\w+)\s*=",
]

for p, text in sources.items():
    defined = set(LUA_GLOBALS)

    for pattern in DECL_PATTERNS:
        for m in re.finditer(pattern, text):
            for name in re.split(r"[,\s]+", m.group(1)):
                name = name.strip()
                if name:
                    defined.add(name)

    # Every parameter list, including anonymous functions.
    for m in re.finditer(r"function\s*[\w.:]*\s*\(([^)]*)\)", text):
        for param in m.group(1).split(","):
            name = param.split(":")[0].strip().lstrip(".")
            if name:
                defined.add(name)

    # Table fields declared as `name = function(...)`.
    for m in re.finditer(r"(\w+)\s*=\s*function", text):
        defined.add(m.group(1))

    for m in re.finditer(r"(?<![.:\w\"])(\w+)\s*\(", text):
        name = m.group(1)
        if name in defined or name.isdigit():
            continue
        problems.append(
            f"{rel(p)}:{lineno(text, m.start())}  calls {name}() which is never defined in this file"
        )



# ── 9. Constants used but never defined ─────────────────────────────────────
# The bug this exists for: a rename replaces a constant's definition and some,
# but not all, of its uses. Luau reads the survivors as nil globals and only
# fails when that line runs — which for UI construction means the whole
# controller dies at init and takes everything built after it down with it.
#
# Limited to SCREAMING_CASE names on purpose. Those are module constants by
# convention, so an undefined one is essentially always a real bug, whereas
# checking every lowercase identifier would need a real scope analysis to avoid
# drowning in false positives.
CONST_RE = re.compile(r"(?<![.:\w])([A-Z][A-Z0-9_]{2,})\b")

for p, text in sources.items():
    defined = set()
    for m in re.finditer(r"local\s+([A-Z][A-Z0-9_]{2,})\s*[:=]", text):
        defined.add(m.group(1))
    for m in re.finditer(r"local\s+function\s+([A-Z][A-Z0-9_]{2,})", text):
        defined.add(m.group(1))
    # Multiple declarations on one line: `local A, B = 1, 2`
    for m in re.finditer(r"local\s+([A-Z][A-Z0-9_,\s]*?)\s*=", text):
        for name in re.split(r"[,\s]+", m.group(1)):
            if name:
                defined.add(name)
    # Loop variables and parameters can be shouty too.
    for m in re.finditer(r"for\s+([\w\s,]+?)\s+in\b", text):
        for name in re.split(r"[,\s]+", m.group(1)):
            if name:
                defined.add(name)
    for m in re.finditer(r"function\s*[\w.:]*\s*\(([^)]*)\)", text):
        for param in m.group(1).split(","):
            name = param.split(":")[0].strip()
            if name:
                defined.add(name)

    for m in CONST_RE.finditer(text):
        name = m.group(1)
        if name in defined or name in LUA_GLOBALS:
            continue
        # A name being ASSIGNED is a declaration or a table key, not a read.
        # `SMG = { ... }` inside a config table is the common case.
        after = text[m.end():m.end() + 4]
        if re.match(r"\s*=(?!=)", after):
            continue
        problems.append(
            f"{rel(p)}:{lineno(text, m.start())}  uses {name} which is never defined in this file"
        )


# ── 9b. Services used without being fetched ─────────────────────────────────
# The bug this exists for: `Workspace.CurrentCamera` in a file that never wrote
# `local Workspace = game:GetService("Workspace")`. Roblox's global is `workspace`
# in lowercase — capitalised `Workspace` is not a global at all, so the line
# throws "attempt to index nil" the first time it runs and nothing catches it
# earlier, because it parses perfectly and reads exactly like every other file.
#
# Check 9 misses these because it only looks at SCREAMING_CASE names, and
# widening that to any capitalised identifier would need real scope analysis.
# A fixed list of service names does not.
SERVICE_NAMES = [
    "Workspace", "Players", "Lighting", "ReplicatedStorage", "ServerStorage",
    "ServerScriptService", "StarterGui", "StarterPlayer", "RunService",
    "UserInputService", "ContextActionService", "TweenService", "Debris",
    "CollectionService", "HttpService", "TeleportService", "MemoryStoreService",
    "DataStoreService", "MarketplaceService", "SoundService", "PhysicsService",
    "GuiService", "ChangeHistoryService", "TextService", "PathfindingService",
    "MessagingService", "InsertService", "ContentProvider", "Chat", "Teams",
]

for p, text in sources.items():
    fetched = set(re.findall(r'local\s+(\w+)\s*=\s*game:GetService\(', text))
    # A local of the same name from any other source counts too.
    declared = set(re.findall(r'local\s+(\w+)\s*[:=]', text))
    for name in SERVICE_NAMES:
        if name in fetched or name in declared:
            continue
        m = re.search(r'(?<![.:\w"])' + name + r'\s*[.:]', text)
        if m:
            problems.append(
                f"{rel(p)}:{lineno(text, m.start())}  uses {name} but never did "
                f'game:GetService("{name}") — capitalised service names are not globals'
            )


# ── 9c. Local functions called before they are declared ─────────────────────
# The bug this exists for: `applyTouchLayout` at line 926 calling `feedLimit()`,
# which is `local function feedLimit` at line 1046. A Lua closure binds only the
# locals that EXIST where it is written — a local declared further down is a
# different variable the closure never sees, so the name resolves to a global and
# is nil. Nothing complains until that line runs, and it ran in start(): the HUD
# died and took every screen with it.
#
# Check 8 misses this because the name IS defined in the file, just too late.
#
# A bare forward declaration (`local f` early, `f = function()` later) is the
# correct way to do this deliberately, so a call after one of those is fine.
for p, text in sources.items():
    lines = text.split("\n")

    declared_at = {}          # name -> line of `local function name`
    forward_at = {}           # name -> line of a bare `local name` declaration
    for index, line in enumerate(lines, start=1):
        m = re.match(r'\s*local function ([A-Za-z_]\w*)', line)
        if m and m.group(1) not in declared_at:
            declared_at[m.group(1)] = index
        m = re.match(r'\s*local ([A-Za-z_]\w*)\s*(?::\s*[^=]+)?$', line)
        if m and m.group(1) not in forward_at:
            forward_at[m.group(1)] = index

    for name, decl_line in declared_at.items():
        forward = forward_at.get(name)
        if forward and forward < decl_line:
            continue          # properly forward-declared
        for index, line in enumerate(lines[: decl_line - 1], start=1):
            if re.match(r'\s*(--|\])', line):
                continue
            if re.search(r'(?<![.:\w])' + re.escape(name) + r'\s*\(', line):
                problems.append(
                    f"{rel(p)}:{index}  calls {name}() but `local function {name}` is not until "
                    f"line {decl_line} — the closure binds a nil global, not that local"
                )
                break


# ── 9d. A local used inside a closure written before it is declared ─────────
# The general form of 9c: not just `local function`, any module-level local. A
# closure binds the locals that exist where it is WRITTEN, so a name declared
# further down resolves to a nil global instead. Reported as a note rather than a
# problem because the crude function-boundary tracking here can pick up a mention
# inside a long comment block.
DECL_RE = re.compile(r'^local (?:function )?([A-Za-z_]\w*)')

for p, text in sources.items():
    lines = text.split("\n")
    decl = {}
    for index, line in enumerate(lines, start=1):
        m = DECL_RE.match(line)
        if m:
            decl.setdefault(m.group(1), index)

    fn_start = None
    for index, line in enumerate(lines, start=1):
        if re.match(r'(local function|function)\b', line):
            fn_start = index
            continue
        if fn_start is None:
            continue
        if re.match(r'end\b', line):
            fn_start = None
            continue
        if re.match(r'\s*(--|\s*\])', line):
            continue
        for m in re.finditer(r'(?<![.:\w"])([A-Za-z_]\w*)\s*\(', line):
            at = decl.get(m.group(1))
            if at and at > fn_start:
                notes.append(
                    f"{rel(p)}:{index}  '{m.group(1)}' is called here but `local {m.group(1)}` is "
                    f"line {at} — if that is a real reference it binds a nil global"
                )
                break


# ── 9e. A style table missing a field its applier reads ─────────────────────
# The bug this exists for: GoreController's STYLES holds one entry per look and
# applyStyle copies every field of it onto an emitter. Add a field to one entry
# and forget the other, and the effect works everywhere except the one case that
# uses the other style — a Char burst that only happens when something burns.
# Silent, rare, and exactly the shape that reaches players.
#
# Generalises to any `local NAME = { A = { ... }, B = { ... } }` whose sibling
# entries are meant to be interchangeable: they must all carry the same keys.
for p, text in sources.items():
    for table_match in re.finditer(
        r'local ([A-Z][A-Z_]*) = \{\n(.*?)\n\}\n', text, re.S
    ):
        name, block = table_match.group(1), table_match.group(2)
        entries = {}
        for m in re.finditer(r'\n\t(\w+) = \{(.*?)\n\t\},', "\n" + block, re.S):
            keys = set(re.findall(r'\n\t\t(\w+) = ', m.group(2)))
            if keys:
                entries[m.group(1)] = keys
        if len(entries) < 2:
            continue
        union = set()
        for keys in entries.values():
            union |= keys
        for entry, keys in sorted(entries.items()):
            gap = union - keys
            # Only complain when an entry is nearly complete. Two tables that
            # share three keys out of thirty are not siblings, they just live in
            # the same variable.
            if gap and len(keys) >= len(union) * 0.6:
                problems.append(
                    f"{rel(p)}:{lineno(text, table_match.start())}  {name}.{entry} is missing "
                    f"{', '.join(sorted(gap))} — its siblings define them, so whatever reads this "
                    f"table gets nil for that entry"
                )


# ── 9f. A local function nobody calls ───────────────────────────────────────
# The bug this exists for: `warnFriendlyFire` was written, committed, described
# at length in the commit message — and never called. The edit that was meant to
# call it was lost by a patch script that asserted after writing, so friendly
# fire went on being applied at 0.25 while everything ABOUT the change was in the
# tree. Nothing failed. The file parsed, the audit passed, and the feature was
# simply absent.
#
# That shape — helper landed, call site lost — is the most expensive kind of
# silent failure in this codebase, because the evidence that the work was done is
# all present.
#
# A problem rather than a note: a module-level local function with no caller in
# its own file is either dead code or a missing call, and both want removing.
for p, text in sources.items():
    lines = text.split("\n")
    for index, line in enumerate(lines, start=1):
        m = re.match(r"local function ([A-Za-z_]\w*)", line)
        if not m:
            continue
        name = m.group(1)
        # `name(` anywhere else in the file, or the name passed as a value
        # (`trove:connect(sig, name)`, `table.sort(t, name)`, `return name`).
        called = re.search(
            r"(?<![.:\w])" + re.escape(name) + r"\s*[({\"']", text.replace(line, "", 1)
        )
        # `= name` at the end of a line covers `local alias = fn` and, with the
        # optional trailing comma, `[Kind.Wire] = buildWireMatch,` — a dispatch
        # table. A function put into a table IS passed somewhere, and requiring
        # the line to end at the name flagged every such table as dead code.
        passed = re.search(
            r"[(,]\s*" + re.escape(name) + r"\s*[,)]|=\s*" + re.escape(name) + r"\s*,?\s*$",
            text.replace(line, "", 1),
            re.M,
        )
        if not called and not passed:
            problems.append(
                f"{rel(p)}:{index}  local function {name}() is never called or passed anywhere "
                f"in this file — either it is dead code, or the call site that was meant to use "
                f"it never landed"
            )


# ── 9g. A require or a constant nobody uses ─────────────────────────────────
# Cheap, and it catches the residue of every refactor: a service still required
# after the code that used it moved out, a constant left behind by the block it
# tuned. Neither breaks anything, but both read as "this file does that" to the
# next person, and a require that is not used is a module loaded for nothing.
#
# A note rather than a problem: something declared a minute ago and about to be
# used is a normal state to be in halfway through writing a file.
for p, text in sources.items():
    for pattern in (
        r'^local (\w+) = (?:require\([^)]*\)|game:GetService\("[^"]+"\))\s*$',
        r'^local ([A-Z][A-Z0-9_]{2,}) = ',
    ):
        for m in re.finditer(pattern, text, re.M):
            name = m.group(1)
            elsewhere = text[: m.start()] + text[m.end() :]
            if not re.search(r"(?<![.\w])" + re.escape(name) + r"(?![\w])", elsewhere):
                notes.append(
                    f"{rel(p)}:{lineno(text, m.start())}  {name} is declared and never used"
                )


# ── 9h. A bootstrap list naming a module that is not there ──────────────────
# Both bootstraps walk a list of paths and require each one. A path that does not
# resolve is REPORTED AND SKIPPED — deliberately, because during development
# something in that list is always half-written and the rest of the game still
# has to run. The cost of that kindness is that a typo costs you a whole
# controller and says so once, in a boot log, among twenty other lines.
#
# Nothing else in this file can catch it: the name is a string, and the module it
# names never existed to be cross-referenced.
for bootstrap, folder in (
    ("src/client/init.client.lua", "src/client"),
    ("src/server/init.server.lua", "src/server"),
):
    path = ROOT / bootstrap
    if not path.exists():
        continue
    text = path.read_text(encoding="utf-8")
    for list_name in ("CONTROLLERS", "MODULES", "SERVICES"):
        marker = f"local {list_name} = {{"
        if marker not in text:
            continue
        block = text[text.index(marker) :]
        block = block[: block.index("\n}")]
        for m in re.finditer(r'^\t"([\w/]+)",', block, re.M):
            if not (ROOT / folder / f"{m.group(1)}.lua").exists():
                problems.append(
                    f"{bootstrap}  {list_name} names {m.group(1)!r}, but "
                    f"{folder}/{m.group(1)}.lua does not exist — the bootstrap will "
                    f"warn once and run without it"
                )


# ── 9i. Calling a function a required module does not have ──────────────────
# The bug this exists for: `Attributes.set(player, key, value)` was written in
# three places against a module that only ever defined `get`. Every call threw
# "attempt to call a nil value (field 'set')" the first time it ran, which took
# out crouching and personal difficulty — and nothing said so until somebody
# happened to grep the module for what it actually exported.
#
# Luau's own analysis would catch it in a strict file. Most of this codebase is
# --!nonstrict, deliberately, because Roblox instance types fight it constantly.
# So this does the one narrow version that is worth doing without a type checker:
# for `local X = require(Shared.Foo)`, resolve Foo, collect what it defines, and
# flag `X.name(` where `name` is not one of them.
#
# DOT calls only, never colon: a method call on a returned object is not a call
# on the module. Fields that are tables of data (X.Config.Thing) are skipped for
# the same reason — only a direct call is checked, which is where the runtime
# error actually is.
SHARED_DIR = ROOT / "src" / "shared"


def _module_exports(path):
    """Every name a Shared module makes callable, by any of the four spellings."""
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return None
    module = path.stem
    names = set()
    names |= set(re.findall(r"^function [\w.]+\.(\w+)", text, re.M))
    names |= set(re.findall(r"^\s*(\w+)\s*=\s*function", text, re.M))
    names |= set(re.findall(rf"^{re.escape(module)}\.(\w+)\s*=", text, re.M))
    names |= set(re.findall(r"^\s*(\w+)\s*=\s*[^=]", text, re.M))
    return names


_export_cache = {}


def _exports_for(dotted):
    if dotted in _export_cache:
        return _export_cache[dotted]
    parts = dotted.split(".")
    candidates = [SHARED_DIR.joinpath(*parts).with_suffix(".lua"),
                  SHARED_DIR.joinpath(*parts) / "init.lua"]
    result = None
    for candidate in candidates:
        if candidate.exists():
            result = _module_exports(candidate)
            break
    _export_cache[dotted] = result
    return result


for p, text in sources.items():
    for m in re.finditer(r"^local (\w+) = require\(Shared\.([\w.]+)\)$", text, re.M):
        alias, dotted = m.group(1), m.group(2)
        exports = _exports_for(dotted)
        # Unresolvable module, or one whose shape this parser cannot read: say
        # nothing rather than guess. A false positive here would be noise on
        # every file that requires it.
        if not exports:
            continue
        for call in re.finditer(r"(?<![.:\w])" + re.escape(alias) + r"\.(\w+)\s*\(", text):
            name = call.group(1)
            if name not in exports:
                problems.append(
                    f"{rel(p)}:{lineno(text, call.start())}  {alias}.{name}() is called, but "
                    f"Shared/{dotted.replace('.', '/')} does not define {name} — this throws "
                    f"'attempt to call a nil value' the first time it runs"
                )


# ── 9k. A Shared module used without being required ─────────────────────────
# The bug this exists for: LoadoutController grew a call to
# `Attributes.get(Workspace, ...)` in a file that had never required Attributes.
# In Luau that is a read of a nil GLOBAL, so it does not fail to compile, does
# not fail to load, and does not fail until the exact line runs — which was
# inside a start-up branch that only fires for a client booting during the round
# start window. Check 9i could not see it: it only inspects aliases that WERE
# required.
#
# So: for every module under src/shared, if a file mentions it as `Name.` or
# `Name(` and does not require it, that is a nil global.
#
# Deliberately conservative. A file that declares a local of the same name is
# skipped entirely, as is the module's own source, as is any name that appears
# on the left of an assignment — those are all legitimate ways for the identifier
# to be something other than the module.
SHARED_MODULE_NAMES = set()
for candidate in SHARED_DIR.rglob("*.lua"):
    SHARED_MODULE_NAMES.add(
        candidate.parent.name if candidate.stem == "init" else candidate.stem
    )

for p, text in sources.items():
    own = p.parent.name if p.stem == "init" else p.stem
    required = set(re.findall(r"^local (\w+) = require\(", text, re.M))
    declared = set(re.findall(r"^\s*local (\w+)", text, re.M))
    declared |= set(re.findall(r"^\s*(\w+)\s*=[^=]", text, re.M))
    for name in SHARED_MODULE_NAMES:
        if name == own or name in required or name in declared:
            continue
        m = re.search(r"(?<![.:\w])" + re.escape(name) + r"\s*[.(]", text)
        if not m:
            continue
        problems.append(
            f"{rel(p)}:{lineno(text, m.start())}  uses {name} but never requires it — "
            f"that is a nil global, and it throws the first time this line actually runs "
            f"rather than at load"
        )


# ── 9l. A Roblox service used without GetService ────────────────────────────
# The bug this exists for: `sound.Parent = SoundService` was written into
# WeaponController, which had never called game:GetService("SoundService").
# Same failure as 9k and same reason it slipped past it — 9k only knows the
# names of modules under src/shared, and a Roblox service is not one of those.
# In Luau it is a read of a nil global: it compiles, it loads, and it throws the
# first time that line runs, which for a weapon sound is the first shot fired.
#
# `sources` rather than `code`, and getting that backwards is most of this
# check's history. sources blanks STRING LITERALS, which is exactly what is
# wanted in both directions:
#
#   * the usage half must not see "…at ServerScriptService.Server…" inside a
#     warning string and call it a nil global, which the code version did, twice;
#   * the declaration half still works, because `local SoundService` is real code
#     — only the "SoundService" argument to GetService is blanked, and nothing
#     needs to read that.
#
# The first version matched only `Service.` and `Service:`, so it could not see
# the bare `sound.Parent = SoundService` that prompted it. It was inert in both
# directions at once and reported nothing at all.
ROBLOX_SERVICES = (
    "Players", "ReplicatedStorage", "ServerStorage", "ServerScriptService",
    "RunService", "SoundService", "Lighting", "TweenService",
    "UserInputService", "ContextActionService", "HttpService", "TeleportService",
    "DataStoreService", "CollectionService", "ContentProvider", "GuiService",
    "PathfindingService", "PhysicsService", "Debris", "MarketplaceService",
    "TextChatService", "ChangeHistoryService", "StarterGui", "MessagingService",
)

for p, text in sources.items():
    declared = set(re.findall(r"^\s*local (\w+)", text, re.M))
    declared |= set(re.findall(r"^\s*(\w+)\s*=[^=]", text, re.M))
    for params in re.findall(r"function\s*[\w.:]*\s*\(([^)]*)\)", text):
        declared |= {a.strip().split(":")[0].strip() for a in params.split(",") if a.strip()}
    for name in ROBLOX_SERVICES:
        if name in declared:
            continue
        # A bare identifier, not the same word inside the GetService string that
        # would have defined it, and not a field of something else.
        m = re.search(r'(?<![.:\w"\'])' + re.escape(name) + r"(?![\w\"])", text)
        if not m:
            continue
        problems.append(
            f"{rel(p)}:{lineno(text, m.start())}  uses {name} but never calls "
            f'game:GetService("{name}") — that is a nil global, and it throws the first '
            f"time this line actually runs rather than at load"
        )


# ── 9j. An Animation destroyed after it was loaded ──────────────────────────
# The bug this exists for: animations that loaded "sometimes".
#
#     local animation = Instance.new("Animation")
#     animation.AnimationId = "rbxassetid://" .. id
#     local track = animator:LoadAnimation(animation)
#     animation:Destroy()
#
# LoadAnimation returns a track immediately but the KeyframeSequence behind it is
# fetched ASYNCHRONOUSLY, and the track resolves that fetch through the Animation
# instance it was handed. Destroy the instance and the track is left pointing at
# nothing: it works when the id happened to be cached already and silently never
# plays when it was not. Two files did this, and the symptom was intermittent in
# exactly the way that makes it hard to attribute.
#
# Shared/Util/AnimationCache exists so nobody has to write that sequence again.
#
# `code` rather than `sources`: sources blanks string literals so that a warn()
# mentioning "spawn(" is not read as a call, which also means `Instance.new(
# "Animation")` can never match there. code keeps the strings and drops only the
# comments, which is exactly what this needs.
for p, text in code.items():
    if p.name == "AnimationCache.lua":
        continue
    for m in re.finditer(r'Instance\.new\(\s*"Animation"\s*\)', text):
        line = lineno(text, m.start())
        problems.append(
            f"{rel(p)}:{line}  builds an Animation by hand — use AnimationCache.get(id) or "
            f".load(animator, id) instead. A hand-built one is destroyed on the next line "
            f"often enough that it is worth not offering the option; see check 9j"
        )
    for m in re.finditer(r"(\w+)\s*:\s*Destroy\(\)", text):
        name = m.group(1)
        if name not in ("animation", "anim", "track"):
            continue
        # Only when the same name was loaded just above: this is the sequence,
        # not any variable that happens to be called `animation`.
        window = text[max(0, m.start() - 400) : m.start()]
        if re.search(r"LoadAnimation\s*\([^)]*" + re.escape(name), window) or re.search(
            r"LoadAnimation,\s*\w+,\s*" + re.escape(name), window
        ):
            problems.append(
                f"{rel(p)}:{lineno(text, m.start())}  destroys {name} after LoadAnimation — the "
                f"track resolves its asset fetch through that instance, so this plays only when "
                f"the id was already cached. Use AnimationCache; see check 9j"
            )


# ── 10. Signals fired into the void ─────────────────────────────────────────
# The bug this exists for: a module declares a Signal, fires it faithfully on
# every state change, and nothing anywhere connects to it. Nothing errors, no
# test fails, and the feature it was carrying is simply absent — WeaponController
# predicted the ammo count down on the frame the trigger went and fired
# ammoChanged for a year with no listener, so the HUD rendered the server's
# number a full round trip late and looked, in Studio, exactly right.
#
# A note rather than a problem: a signal with no consumer yet is a normal state
# during development, and the point is to make it visible rather than to fail
# the build over it.
# A FIELD, not a bare local. `Module.thing = Signal.new()` is a public signal
# somebody is expected to connect to; `local x = Signal.new()` inside a factory
# is private plumbing handed out by a method, and its consumers reach it through
# that method rather than by name — InputController's per-action store is the
# example, and counting it produced a note nobody could ever action.
SIGNAL_DECL_RE = re.compile(r"(?:^|\n)\s*[\w.]+\.(\w+)\s*=\s*Signal\.new\(\)")

declared = {}   # signal name -> file that declares it
for p, text in sources.items():
    for m in SIGNAL_DECL_RE.finditer(text):
        declared.setdefault(m.group(1), []).append((p, lineno(text, m.start())))

# A connect is only evidence for a DECLARING FILE if the connecting file could
# plausibly be talking to that module. Without this the census matched by bare
# name across the whole tree, so two modules that both declare `fired` covered
# for each other and an entirely unconsumed signal never appeared — which is
# exactly what hid WeaponController.fired behind BallisticsService.fired.
def _mentions_module(decl_path, consumer_path):
    # `code` keeps string literals; `sources` blanks them, and a module is very
    # often named ONLY inside one — Registry.find("SettingsController"). Reading
    # the blanked text here made every Registry-based consumer invisible.
    stem = pathlib.Path(decl_path).stem
    return re.search(r"\b" + re.escape(stem) + r"\b", code[consumer_path]) is not None


for name, sites in sorted(declared.items()):
    shared = len(sites) > 1
    for decl_path, decl_line in sites:
        consumed = False
        for p, text in sources.items():
            # A name declared in ONE place is answered by a connect anywhere: the
            # reference is unambiguous. A name declared in several has to be
            # answered by a file that at least names the module it belongs to,
            # or one module's consumer silently vouches for another's.
            if shared and p != decl_path and not _mentions_module(decl_path, p):
                continue
            # `x.name:connect(` / `:once(` anywhere, including the declaring file.
            if re.search(r"[.:]" + re.escape(name) + r"\s*[:.]\s*(?:connect|Connect|once|Once)\b", text):
                consumed = True
                break
            # Passed to something that will connect it: `trove:connect(x.name, fn)`.
            if re.search(r"connect\s*\(\s*[\w.]*\.?" + re.escape(name) + r"\s*,", text):
                consumed = True
                break
        if not consumed:
            notes.append(
                f"{rel(decl_path)}:{decl_line}  Signal '{name}' is declared and fired but nothing "
                f"connects to it — either a consumer is missing, or a direct call/attribute already "
                f"does the job and the signal is dead weight"
            )



# ── 10. Luau's 200-locals-per-scope limit ───────────────────────────────────
#
# This one is invisible to every other tool in this script. Luau allocates one
# register per live local and allows 200 per FUNCTION SCOPE — and a module's top
# level is a single function scope. Go over it and the module does not compile:
#
#   MainMenuController:1930: Out of local registers when trying to allocate
#   layoutColumns: exceeded limit 200
#
# stylua parsed it, selene linted it, and every check above passed, because the
# file is perfectly valid source. It just cannot be turned into bytecode. The
# controller had 205 and the main menu simply never appeared, with the failure
# buried in the client's require log.
#
# Only column-0 `local` counts: anything declared inside a function body or a
# `do` block gets its registers back when that scope ends.
LOCAL_LIMIT = 200
LOCAL_FAIL = 185   # leaves room for the compiler's own temporaries
LOCAL_WARN = 165

def _names_declared(line: str) -> int:
    """How many registers this one declaration burns. `local function f` is 1;
    `local a, b, c = ...` is 3. Type annotations can themselves contain commas
    (`local t: {[string]: number}, n`), so split at bracket depth zero."""
    decl = line[len("local "):]
    if decl.lstrip().startswith("function"):
        return 1
    decl = decl.split("=", 1)[0]
    depth, count, seen = 0, 0, False
    for ch in decl:
        if ch in "({[<":
            depth += 1
        elif ch in ")}]>":
            depth -= 1
        elif ch == "," and depth == 0:
            count += 1
            seen = False
            continue
        elif not ch.isspace():
            seen = True
    return count + (1 if seen else 0)

for p, text in sources.items():
    total = 0
    for line in text.split("\n"):
        if line.startswith("local "):
            total += _names_declared(line)
    if total >= LOCAL_FAIL:
        problems.append(
            f"{rel(p)}  {total} top-level locals — Luau's hard limit is {LOCAL_LIMIT} per scope "
            f"and a module's top level is one scope. Move a self-contained subsystem into its "
            f"own module; shaving one or two locals just breaks again on the next addition."
        )
    elif total >= LOCAL_WARN:
        notes.append(
            f"{rel(p)}  {total} top-level locals, heading for Luau's {LOCAL_LIMIT}-per-scope limit "
            f"— worth splitting before it stops compiling"
        )



# ── 11. Assigning a top-level local before it is declared ───────────────────
#
# In Lua, `FOO = x` inside a function assigns a GLOBAL unless a `local FOO` is
# already in scope. So a helper written ABOVE the local it means to update
# silently creates a global, and the real local keeps its initial value forever:
#
#     local function adoptDeviceScale()
#         HOLE_POOL = Device.pick(...)   -- writes a global
#     end
#     local HOLE_POOL = 56               -- declared AFTER; stays 56
#
# It parses, it runs, and nothing errors — the pool just never changes size. It
# happened exactly like that, and selene reports it only as an "unused variable"
# warning on the assignment, which reads like tidiness rather than a bug.
#
# Only names this file declares as a top-level local are considered, so a real
# global from another module is not flagged.
for p, text in sources.items():
    lines = text.split("\n")
    declared: dict = {}
    for i, line in enumerate(lines):
        m = re.match(r"^local (?:function )?([A-Za-z_]\w*)", line)
        if m and m.group(1) not in declared:
            declared[m.group(1)] = i

    # Brace depth, so a TABLE FIELD is never mistaken for an assignment. Both
    # look like `    name = value`, and the first pass at this check reported two
    # of them — `state = { editing = 1, ... }` beside a separate
    # `local function editing()`. Same spelling, different things, no bug.
    # `sources` has comments and string literals blanked, so counting is safe.
    depth = 0
    for i, line in enumerate(lines):
        at_line_start = depth
        depth += line.count("{") - line.count("}")

        if at_line_start > 0:
            continue
        # Indented, so inside a function. `name = ...` but not `name.x =`,
        # `name[i] =`, `==`, or a local declaration of its own.
        m = re.match(r"^[ \t]+([A-Za-z_]\w*)\s*(=[^=]|[-+*/%]=|\.\.=)", line)
        if not m:
            continue
        name = m.group(1)
        at = declared.get(name)
        if at is not None and at > i:
            problems.append(
                f"{rel(p)}:{i + 1}  assigns '{name}' but `local {name}` is not declared until "
                f"line {at + 1} — this writes a GLOBAL and the local keeps its initial value"
            )

# ── 11b. READING a top-level local before it is declared ────────────────────
#
# Same trap as 11, other direction, and it bites harder. A function written
# above the local it reads does not see that local at all — the name resolves to
# a global, which is nil:
#
#     local function latchedState()
#         return Attributes.get(player, ...)   -- `player` is nil here
#     end
#     local player = Players.LocalPlayer       -- declared AFTER
#
# 11 catches the write and reports a value that never changes. This is the read,
# and it does not fail quietly: it errors the first time the function is called,
# which on a control surface is the first time somebody presses the button.
#
# Only inside a `local function` body, and only for a name the function does not
# introduce itself as a parameter or a local of its own.
for p, text in sources.items():
    lines = text.split("\n")
    declared: dict = {}
    for i, line in enumerate(lines):
        m = re.match(r"^local (?:function )?([A-Za-z_]\w*)", line)
        if m and m.group(1) not in declared:
            declared[m.group(1)] = i

    start = None
    shadowed: set = set()
    for i, line in enumerate(lines):
        head = re.match(r"^local function [A-Za-z_]\w*\(([^)]*)\)", line)
        if head:
            start = i
            shadowed = {a.split(":")[0].strip() for a in head.group(1).split(",") if a.strip()}
            continue
        if start is None:
            continue
        if line == "end":
            start = None
            continue
        own = re.match(r"^[ \t]+local (?:function )?([A-Za-z_]\w*)", line)
        if own:
            shadowed.add(own.group(1))
        for m in re.finditer(r"(?<![.:\w])([A-Za-z_]\w*)", line):
            name = m.group(1)
            if name in shadowed:
                continue
            # The assignment form is 11's to report, not this one's.
            if re.match(r"^[ \t]*" + re.escape(name) + r"\s*(=[^=]|[-+*/%]=|\.\.=)", line):
                continue
            at = declared.get(name)
            if at is not None and at > i and at > start:
                problems.append(
                    f"{rel(p)}:{i + 1}  reads '{name}' but `local {name}` is not declared until "
                    f"line {at + 1} — inside this function the name is a GLOBAL, so it is nil "
                    f"and the call errors the first time anything reaches it"
                )



# ── 12. The two corpse ceilings must agree ──────────────────────────────────
#
# GoreService takes math.min(GoreConfig.Budget.MaxActiveRagdolls,
# GameConfig.Corpses.MaxRagdolls). Raising one and not the other is a change
# that does nothing and looks like it worked — which is exactly what happened
# the first time this was raised.
def _number_in(path: str, table_name: str, key: str):
    for p, text in sources.items():
        if not str(p).endswith(path):
            continue
        block = text.split(table_name, 1)
        if len(block) < 2:
            return None
        m = re.search(r"^\t%s = (\d+)," % key, block[1], re.M)
        return int(m.group(1)) if m else None
    return None

_gore_cap = _number_in("GoreConfig.lua", "GoreConfig.Budget", "MaxActiveRagdolls")
_game_cap = _number_in("GameConfig.lua", "GameConfig.Corpses", "MaxRagdolls")
if _gore_cap is not None and _game_cap is not None and _gore_cap != _game_cap:
    problems.append(
        f"GoreConfig.Budget.MaxActiveRagdolls ({_gore_cap}) and "
        f"GameConfig.Corpses.MaxRagdolls ({_game_cap}) disagree — GoreService takes the "
        f"tighter of the two, so the larger one has no effect and reads like it does"
    )


# ── 13. The round-end clock has to fit what it plays ────────────────────────
#
# A round ends in three acts on two independent task.delay timers:
# ResultsDuration later the map vote opens, and PostRoundDuration later the
# server returns to the lobby regardless. So PostRoundDuration has to cover the
# results screen AND the whole vote, or the server walks out on a vote that is
# still open — the winner is discarded, the next round loads the old map, and
# nothing anywhere says why.
#
# GameModeConfig's own comment already claims this is audited. It was not.
_results = _number_in("GameModeConfig.lua", "GameModeConfig.Matchmaking", "ResultsDuration")
_post = _number_in("GameModeConfig.lua", "GameModeConfig.Matchmaking", "PostRoundDuration")
_vote = _number_in("MapConfig.lua", "MapConfig.Vote", "DurationSeconds")
if None not in (_results, _post, _vote) and _results + _vote > _post:
    problems.append(
        f"GameModeConfig.Matchmaking.PostRoundDuration ({_post}s) is shorter than "
        f"ResultsDuration ({_results}s) + MapConfig.Vote.DurationSeconds ({_vote}s) = "
        f"{_results + _vote}s — the server returns to the lobby with the vote still open, "
        f"so the winner is thrown away and the next round reloads the old map"
    )


# ── 14. One animation id may not be declared under two different rigs ───────
#
# A Roblox animation addresses joints BY NAME. An R6 clip keys "Left Arm" and
# "Right Hip"; an R15 rig has no joints called that, so the track loads, reports
# IsPlaying, has a real Length, and moves absolutely nothing — and
# InfectedPoseController stands down for any body with a track playing, so the
# body is animated by neither the clip nor the fallback.
#
# That is why the sets are keyed by rig. Listing the SAME id under two of them
# says the one clip addresses both skeletons, which no clip does.
#
# Found the hard way: 85609984089861 was the death clip in ZOMBIE_R6 and in
# ZOMBIE_R15. It is an R6 clip. Every R15 special therefore froze upright for
# the 0.97s GoreService held its ragdoll waiting for a collapse that was never
# going to play. CheckAnimations could not catch it either — its `expected` map
# is keyed by id, so the second set overwrote the first and the mismatch test
# compared the id against itself.
def _enclosing_table(text: str, at: int):
    """The brace-balanced { ... } that directly contains offset `at`."""
    depth, start = 0, None
    for i in range(at, -1, -1):
        c = text[i]
        if c == "}":
            depth += 1
        elif c == "{":
            if depth == 0:
                start = i
                break
            depth -= 1
    if start is None:
        return None
    depth = 0
    for i in range(start, len(text)):
        c = text[i]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return text[start : i + 1]
    return None

_ANIM = next((t for p, t in code.items() if str(p).endswith("AnimationConfig.lua")), None)
if _ANIM:
    _rig_of_id = {}
    # Anchored on the `rig` FIELD rather than on the `AnimationSet` type
    # annotation, so a per-kind override under AnimationConfig.Infected — which
    # is written inline and carries no annotation — is covered by the same rule
    # as the two named sets. That table is empty today; it is where the next one
    # of these comes from.
    for _m in re.finditer(r'rig = "(\w+)"', _ANIM):
        _block = _enclosing_table(_ANIM, _m.start())
        if _block is None:
            continue
        for _id in set(re.findall(r"\b(\d{6,})\b", _block)):
            _rig_of_id.setdefault(_id, set()).add(_m.group(1))
    # SurvivorHold is the same hazard in a flatter shape: R6 = id, R15 = id.
    _hold = re.search(r"SurvivorHold = table\.freeze\(\{(.*?)\}\)", _ANIM, re.S)
    if _hold:
        for _rig, _id in re.findall(r"(\w+) = (\d{6,})", _hold.group(1)):
            _rig_of_id.setdefault(_id, set()).add(_rig)
    for _id, _rigs in sorted(_rig_of_id.items()):
        if len(_rigs) > 1:
            problems.append(
                f"src/shared/Config/AnimationConfig.lua  animation {_id} is declared under "
                f"{' and '.join(sorted(_rigs))} — one clip addresses ONE skeleton's joint names, "
                f"so on the other build it loads, reports itself playing, and moves nothing while "
                f"the procedural poser stands down for it"
            )


# ── 15. The three copies of the R6 joint basis must agree ───────────────────
#
# An animation's rotations are applied inside a Motor6D's C0, so they are read in
# the joint's OWN axes. Roblox's R6 shoulders and hips are turned a quarter-turn
# about Y and its neck and root are tipped onto their backs; a joint framed any
# other way holds the limb in a perfect rest pose and then swings it sideways the
# moment a clip plays — an arm sticking straight out, legs splaying instead of
# stepping, the body dragging. No rest-pose check can see it.
#
# Three files state those constants: RigUtil repairs bodies at spawn with them,
# RigDoctor repairs the saved models, and ProveAnimation reports on them. This
# project has already been bitten once by three hand-written copies of one
# predicate drifting apart — the rival-joint test — where the game went on
# cutting a joint the report called clean. Same shape, worse failure, so the
# copies are checked rather than trusted.
_BASIS_FILES = {
    "src/shared/Util/RigUtil.lua": ("LEFT_LIMB_BASIS", "RIGHT_LIMB_BASIS", "AXIAL_BASIS"),
    "studio-scripts/RigDoctor.lua": ("LEFT_LIMB", "RIGHT_LIMB", "AXIAL"),
    "studio-scripts/ProveAnimation.lua": ("LEFT_LIMB", "RIGHT_LIMB", "AXIAL"),
}
_EXPECTED = (
    "CFrame.Angles(0, -math.pi / 2, 0)",
    "CFrame.Angles(0, math.pi / 2, 0)",
    "CFrame.Angles(-math.pi / 2, 0, math.pi)",
)
for _path, _names in _BASIS_FILES.items():
    try:
        _text = (ROOT / _path).read_text(encoding="utf-8")
    except OSError:
        problems.append(f"{_path} is missing — it carries one of the three copies of the R6 joint basis")
        continue
    for _name, _want in zip(_names, _EXPECTED):
        _decl = f"local {_name} = "
        _at = _text.find(_decl)
        if _at < 0:
            problems.append(
                f"{_path} no longer declares {_name} — it is one of the three copies of the R6 "
                f"joint basis, and a rig framed on the wrong axes animates sideways while every "
                f"rest-pose check calls it clean"
            )
            continue
        _got = _text[_at + len(_decl):_text.index("\n", _at)].strip()
        if _got != _want:
            problems.append(
                f"{_path}  {_name} is {_got}, but the R6 joint basis is {_want} — the three "
                f"copies of this constant have drifted, so a body repaired by one of them will "
                f"be judged broken by another"
            )


# ── 16. A weapon must be complete before it is a weapon ─────────────────────
# The bug this exists for: fifteen of thirty-one weapons fired in total silence.
# AudioConfig.WeaponFire is indexed directly — `AudioConfig.WeaponFire[weaponId]`
# — with no fallback and no warning, so a weapon added to WeaponConfig without a
# row there is simply silent, and nothing anywhere says so. The same shape of
# mistake leaves a gun with no price (unbuyable), no ammo row (no casing, no
# magazine on reload), or a class with no viewmodel pose (held at the generic
# length, which on a machine gun is through the player's own chest).
#
# Every one of those is a table somebody has to remember to update, which is
# exactly the kind of thing that should not depend on remembering.
_wc = read(SRC / "shared/Config/WeaponConfig.lua")
_ac = read(SRC / "shared/Config/AudioConfig.lua")
_mc = read(SRC / "shared/Config/AmmoConfig.lua")
_ec = read(SRC / "shared/Config/EconomyConfig.lua")
_vm = read(SRC / "client/Weapon/ViewmodelController.lua")

_weapons = {
    m.group(1): re.search(r'class = "(\w+)"', m.group(2)).group(1)
    for m in re.finditer(r"\[Enums\.Weapon\.(\w+)\]\s*=\s*\{(.*?)\n\t\},", _wc, re.S)
    if re.search(r'class = "(\w+)"', m.group(2))
}
if _weapons:
    _fire_block = _ac[_ac.index("AudioConfig.WeaponFire"):_ac.index("AudioConfig.WeaponReload")]
    _fire = set(re.findall(r"\[Enums\.Weapon\.(\w+)\] = sound", _fire_block))
    _ammo = set(re.findall(r"\[Enums\.Weapon\.(\w+)\] = \{ casing", _mc))
    _shop = set(re.findall(r"id = Enums\.Weapon\.(\w+),", _ec))
    _pose_block = _vm[_vm.index("local CLASS_POSE"):_vm.index("local WEAPON_POSE")]
    _poses = set(re.findall(r"^\t(\w+) = \{", _pose_block, re.M))

    # Weapons that declare themselves found-not-bought. Parsed off the same text
    # the class map came from, so a flag added to a definition is seen here
    # without a second list to keep in step.
    _pass_claimed = set()
    _floor_only = set()
    for _m in re.finditer(r"\[Enums\.Weapon\.(\w+)\]\s*=\s*\{(.*?)\n\t\},", _wc, re.S):
        if re.search(r"^\s*floorOnly\s*=\s*true", _m.group(2), re.M):
            _floor_only.add(_m.group(1))
        if re.search(r"^\s*passOnly\s*=\s*true", _m.group(2), re.M):
            _pass_claimed.add(_m.group(1))

    # What the passes ACTUALLY grant, read from PassConfig rather than believed
    # from the weapon's own flag. Two files that have to agree, so the build
    # checks that they do instead of hoping.
    _pc = read(SRC / "shared/Config/PassConfig.lua")
    _pass_only = set()
    for _m in re.finditer(r"grantsWeapons\s*=\s*\{(.*?)\}", _pc, re.S):
        _pass_only.update(re.findall(r'"(\w+)"', _m.group(1)))

    for _id in sorted(_pass_claimed - _pass_only):
        problems.append(
            f"{_id} says passOnly = true but no PassConfig pass lists it in grantsWeapons — "
            f"nothing unlocks it, so it is in the game and unreachable"
        )
    for _id in sorted(_pass_only - _pass_claimed):
        problems.append(
            f"a PassConfig pass grants {_id!r}, which is not a WeaponConfig weapon marked "
            f"passOnly = true — the storefront promises something the roster does not have"
        )
    for _id in sorted(_pass_only & _floor_only):
        problems.append(
            f"{_id} is both passOnly and floorOnly — a paid weapon the Director also leaves "
            f"on a shelf has not been made cheaper, it has been made free"
        )

    for _id, _class in sorted(_weapons.items()):
        if _id not in _fire:
            problems.append(
                f"{_id} has no AudioConfig.WeaponFire row — that table is indexed directly, "
                f"so this weapon fires in silence and nothing warns about it"
            )
        if _id not in _ammo:
            problems.append(
                f"{_id} has no AmmoConfig.Weapons row — it will eject no casing and drop no "
                f'magazine. A weapon that genuinely has neither still needs the row, as '
                f'{{ casing = "", magazine = "" }}, so "has none" is distinguishable from '
                f"\"was forgotten\""
            )
        # A weapon can legitimately be FOUND rather than bought, and then it is
        # absent from the catalogue on purpose. InventoryService:pickup reads
        # FL_Slot / FL_ItemId and never asks about ownership, so the pickup path
        # works with no shop row; the loadout path does not, which is the point.
        # `floorOnly = true` is the only way to say that — everything else that
        # is missing from the catalogue is a mistake, and far more often.
        # passOnly is the third way to own a weapon, beside bought and found:
        # unlocked by a Robux game pass, with no shop row and never one.
        # ProfileService merges PassService's grants into the set it sanitises
        # against, and LoadoutConfig.candidates already appends anything in
        # WeaponConfig the catalogue does not list, so the loadout path works.
        if _id not in _shop and _id not in _floor_only and _id not in _pass_only:
            problems.append(
                f"{_id} is in WeaponConfig but not in EconomyConfig.Catalogue — there is no way "
                f"to buy it or put it in a loadout. If it is meant to be found on the floor "
                f"instead, say so with floorOnly = true, or passOnly = true if a game pass unlocks it"
            )
        if _id in _shop and _id in _floor_only:
            problems.append(
                f"{_id} is floorOnly = true AND in EconomyConfig.Catalogue — it is either "
                f"found or sold, and a weapon that is both makes the vault reward buyable"
            )
        if _class not in _poses:
            problems.append(
                f"{_id} is class {_class!r}, which has no ViewmodelController CLASS_POSE — it "
                f"falls back to the generic long-gun pose, which is the wrong length for any "
                f"class that needed its own"
            )

# ── 17. The lighting keyframes must still be spread across the round ────────
# The bug this exists for: AtmosphereService anchors its five lighting keyframes
# to WAVE NUMBERS — 3, 5 and 7 for a seven-wave round, which put them at 0.24,
# 0.51 and 0.82 of the way through. The schedule then became fifteen waves and
# the same three numbers landed at 0.11, 0.21 and 0.33: the whole evening
# collapsed into the first third and the remaining eleven minutes were one flat
# interpolation to black.
#
# Nothing failed. The file's own runtime guard only catches keyframes that land
# out of ORDER, which these did not — they were merely all at the start. The
# round just got dark early and then stopped changing, which is the entire arc
# the file exists to produce, silently deleted by a change in another file.
#
# So: the numeric anchors have to keep spanning the round. Anything that retunes
# the wave schedule has to come back and re-anchor them.
_atm = read(SRC / "server/Level/AtmosphereService.lua")
_gm = read(SRC / "shared/Config/GameModeConfig.lua")
_anchors = [int(m) for m in re.findall(r"^\t\tanchor = (\d+),", _atm, re.M)]
_durations = [
    (int(a), int(b))
    for a, b in re.findall(r"^\t\tduration = (\d+),\n\t\tbreather = (\d+),", _gm, re.M)
]
_prep = re.search(r"PrepDuration = (\d+)", _gm)
_total = re.search(r"TotalDuration = (\d+)", _gm)
if _anchors and _durations and _prep and _total:
    _prep, _total = int(_prep.group(1)), int(_total.group(1))

    def _wave_t(index):
        seconds = _prep
        for d, b in _durations[: index - 1]:
            seconds += d + b
        return seconds / _total

    _ts = [_wave_t(a) for a in _anchors]
    # The last numeric keyframe is the one that says "it is night now". Landing
    # it before two thirds through leaves the rest of the round with nowhere to
    # go, which is what a stale anchor looks like.
    if _ts[-1] < 0.6:
        problems.append(
            f"AtmosphereService's last wave-anchored lighting keyframe (wave {_anchors[-1]}) is "
            f"{_ts[-1]:.2f} of the way through the round — the light finishes changing in the "
            f"first half and the rest of the round is flat. Re-anchor the keyframes against the "
            f"current wave schedule; see the note above KEYFRAMES"
        )
    # And they must not bunch: five looks crammed into a quarter of the round is
    # the same failure in a less obvious shape.
    if _ts[-1] - _ts[0] < 0.4:
        problems.append(
            f"AtmosphereService's wave-anchored lighting keyframes span only "
            f"{_ts[-1] - _ts[0]:.2f} of the round (waves {_anchors[0]} to {_anchors[-1]}) — they "
            f"are bunched rather than spread, so the round changes light all at once and then "
            f"holds. Re-anchor them against the current wave schedule"
        )

# ── 32. Two verbs on one button ─────────────────────────────────────────────
#
# The bug this exists for has not happened yet, and that is the point: the
# keymap is one list of literals that four different features append to, and a
# collision in it is silent. Two actions on ButtonX means one of them is
# unreachable on every console in the world and nothing anywhere says so — the
# player just finds that a button does the wrong thing.
#
# Cheap to check and impossible to notice by eye once the table is twenty rows.
_input = ROOT / "src/client/Input/InputController.lua"
if _input.exists():
    _text = _input.read_text(encoding="utf-8")
    _start = _text.find("local BINDINGS: { Binding } = {")
    if _start != -1:
        _block = _text[_start:]
        _block = _block[: _block.index("\n}\n")]
        # Split at each entry rather than matching action-then-keys across the
        # block. A spanning match pairs an entry that has no `keys` with the NEXT
        # entry's keys and reports a collision that is not there — which is not
        # hypothetical: the same pattern over `touch` silently attributed Jump's
        # button to Sprint, which has none.
        _bounds = [m.start() for m in re.finditer(r"action = Action\.\w+", _block)]
        _bounds.append(len(_block))
        _seen = {}
        for _i in range(len(_bounds) - 1):
            _chunk = _block[_bounds[_i] : _bounds[_i + 1]]
            _action = re.match(r"action = Action\.(\w+)", _chunk).group(1)
            _km = re.search(r"keys = \{([^}]*)\}", _chunk)
            if not _km:
                continue
            for _key in re.findall(r"Enum\.(?:KeyCode|UserInputType)\.(\w+)", _km.group(1)):
                if _key in _seen and _seen[_key] != _action:
                    problems.append(
                        f"InputController binds {_key} to both {_seen[_key]!r} and {_action!r} — "
                        f"one of the two is unreachable on whatever device that key belongs to, "
                        f"and nothing warns at runtime"
                    )
                _seen[_key] = _action

        # And the verbs a player cannot finish a round without. A console build
        # that cannot pick a gun up is not a console build.
        _pad = {k for k in _seen if k.startswith("Button") or k.startswith("DPad")}
        for _need in ("Fire", "Aim", "Reload", "Interact", "Jump", "Crouch", "Melee", "Shove"):
            _has = any(
                _seen[k] == _need for k in _pad
            )
            if not _has:
                problems.append(
                    f"InputController has no gamepad button bound to {_need!r} — a controller "
                    f"player cannot do it at all. Every essential verb needs a pad key in BINDINGS"
                )


# ── 33. A sound cue that does not exist ─────────────────────────────────────
#
# Every cue is played by NAME through AudioService, and a name with no row in
# AudioConfig is not an error anywhere: the service warns once at startup and
# then stays silent for the life of the server. That is the right behaviour for
# a half-filled bank and the wrong one for a typo, and the two are
# indistinguishable from the output window.
#
# It matters most for exactly the cues you cannot afford to lose. A special's
# vocalisations are the game's early-warning system — the wind-up before a
# charge, the vent that says the damage window is open — and a boss shipped with
# six new cue names and no rows would be a boss with no tells, silently, on
# every machine.
_audio_src = (ROOT / "src/shared/Config/AudioConfig.lua").read_text(encoding="utf-8")
_audio_groups = {}
for _m in re.finditer(r"^AudioConfig\.(\w+)\s*=\s*\{(.*?)^\}", _audio_src, re.S | re.M):
    _g, _body = _m.group(1), _m.group(2)
    _keys = set(re.findall(r"^\t(\w+)\s*=\s*(?:sound|varied)\(", _body, re.M))
    _keys |= set(re.findall(r"^\t(\w+)\s*=\s*\{", _body, re.M))
    _audio_groups[_g] = _keys

# Over `code` rather than `sources`: sources blanks string literals, and the cue
# name IS a string literal. Comments are still stripped, so a name mentioned in
# prose is not mistaken for a call.
for _path, _text in code.items():
    if _path.name == "AudioConfig.lua":
        continue
    _refs = [(m.group(1), m.group(2), m.start()) for m in
             re.finditer(r'(?::play|:playAt|playSound)\(\s*"(\w+)"\s*,\s*"(\w+)"', _text)]
    # Specials/Support.playSound takes the key alone and always means Infected.
    _refs += [("Infected", m.group(1), m.start()) for m in
              re.finditer(r'Support\.playSound\(\s*"(\w+)"', _text)]
    for _group, _key, _at in _refs:
        if _group not in _audio_groups or _key in _audio_groups[_group]:
            continue
        problems.append(
            f"{rel(_path)}:{_text[:_at].count(chr(10)) + 1}  plays AudioConfig.{_group}.{_key}, "
            f"which does not exist. AudioService warns once at startup and is then silent "
            f"forever, so this is a cue that never plays and never complains again"
        )


# ── 34. A property the class does not have ──────────────────────────────────
#
# Setting one throws, and in this codebase a throw during a controller's init()
# is caught by the boot runner and reported as one failed service among forty.
# The symptom is not an error anybody chases: it is a layer of the interface
# that silently does not exist, on a screen nobody thought to check.
#
# That is exactly how it happened. A full-screen atmosphere layer set `Active`
# on its ScreenGui — a real property, on GuiObject, which ScreenGui is not — and
# the entire effect would have drawn nothing at all while every test of the code
# around it passed.
#
# Only the small, closed classes are listed. A Frame or a TextLabel has upwards
# of eighty inherited properties and a list of those would be wrong within a
# release; these seven are leaf classes with short, stable surfaces, which is
# what makes an exhaustive list defensible at all.
_UI_PROPS = {
    "ScreenGui": {
        "Enabled", "DisplayOrder", "IgnoreGuiInset", "ResetOnSpawn", "ZIndexBehavior",
        "ClipToDeviceSafeArea", "ScreenInsets", "SafeAreaCompatibility", "OnTopOfCoreBlur",
        "SelectionBehaviorUp", "SelectionBehaviorDown", "SelectionBehaviorLeft",
        "SelectionBehaviorRight", "SelectionGroup", "AutoLocalize", "RootLocalizationTable",
    },
    "UIGradient": {"Color", "Enabled", "Offset", "Rotation", "Transparency"},
    "UIStroke": {"ApplyStrokeMode", "Color", "Enabled", "LineJoinMode", "Thickness", "Transparency"},
    "UIScale": {"Scale"},
    "UIPadding": {"PaddingBottom", "PaddingLeft", "PaddingRight", "PaddingTop"},
    "UICorner": {"CornerRadius"},
    "UIAspectRatioConstraint": {"AspectRatio", "AspectType", "DominantAxis"},
}
# Every Instance has these, whatever it is.
_UI_COMMON = {"Name", "Parent", "Archivable"}

for _path, _text in code.items():
    for _m in re.finditer(r'\b(?:local\s+)?(\w+)\s*=\s*Instance\.new\("(\w+)"\)', _text):
        _var, _cls = _m.group(1), _m.group(2)
        _allowed = _UI_PROPS.get(_cls)
        if not _allowed:
            continue
        # Only up to the point the same name is pointed at a different instance.
        _tail = _text[_m.end():]
        _next = re.search(r"\b" + re.escape(_var) + r"\s*=\s*Instance\.new\(", _tail)
        _region = _tail[: _next.start()] if _next else _tail
        for _pm in re.finditer(r"\b" + re.escape(_var) + r"\.(\w+)\s*=[^=]", _region):
            _prop = _pm.group(1)
            if _prop in _allowed or _prop in _UI_COMMON:
                continue
            problems.append(
                f"{rel(_path)}:{_text[: _m.end() + _pm.start()].count(chr(10)) + 1}  sets "
                f"{_var}.{_prop}, and {_var} is a {_cls}, which has no such property. "
                f"This throws at runtime; inside a controller's init() the boot runner "
                f"swallows it and the whole layer silently does not exist"
            )


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
