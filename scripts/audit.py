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
SIGNAL_DECL_RE = re.compile(r"(?:^|\n)\s*(?:local\s+)?[\w.]*?(\w+)\s*=\s*Signal\.new\(\)")

declared = {}   # signal name -> file that declares it
for p, text in sources.items():
    for m in SIGNAL_DECL_RE.finditer(text):
        declared.setdefault(m.group(1), []).append((p, lineno(text, m.start())))

for name, sites in sorted(declared.items()):
    consumed = False
    for p, text in sources.items():
        # `x.name:connect(` / `:once(` anywhere, including the declaring file.
        if re.search(r"[.:]" + re.escape(name) + r"\s*[:.]\s*(?:connect|Connect|once|Once)\b", text):
            consumed = True
            break
        # Passed to something that will connect it: `trove:connect(x.name, fn)`.
        if re.search(r"connect\s*\(\s*[\w.]*\.?" + re.escape(name) + r"\s*,", text):
            consumed = True
            break
    if not consumed:
        where = ", ".join(f"{rel(f)}:{ln}" for f, ln in sites)
        notes.append(
            f"{where}  Signal '{name}' is declared and fired but nothing connects to it "
            f"— either a consumer is missing, or a direct call/attribute already does the job "
            f"and the signal is dead weight"
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
