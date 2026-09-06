#!/usr/bin/env python3
"""Cross-check every remote: is each one both SENT and LISTENED TO, on the
right sides of the wire?  The bug this exists for is in ProjectileService's
own header: the client sent ThrowItem for weeks and nobody was listening."""
import re, pathlib, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "src"

def strip_comments(t):
    t = re.sub(r"--\[\[.*?\]\]", lambda m: "\n"*m.group(0).count("\n"), t, flags=re.S)
    return re.sub(r"--[^\n]*", "", t)

man = strip_comments((SRC / "shared/Net/Remotes.lua").read_text())

def block(marker):
    i = man.index(marker)
    i = man.index("= {", i)          # past the "{ string }" type annotation
    j = man.index("\n}", i)          # the closing brace at column 0
    return re.findall(r'"([A-Za-z0-9_]+)"', man[i:j])

events = block("local EVENTS")
funcs  = block("local FUNCTIONS")

# name -> sets of files
fire_server, fire_client, on_server, on_client = {}, {}, {}, {}
invoke_server, invoke_client, cb_server, cb_client = {}, {}, {}, {}

PATTERNS = [
    (r"Remotes\.Event\.(\w+)\s*:\s*FireServer",                      fire_server),
    (r"Remotes\.Event\.(\w+)\s*:\s*Fire(?:All)?Client(?:s)?",        fire_client),
    # The two broadcast helpers name their event as a string literal.
    (r'Remotes\.fireAllExcept\(\s*"(\w+)"',                            fire_client),
    (r'Remotes\.fireInRange\(\s*"(\w+)"',                              fire_client),
    (r"Remotes\.Event\.(\w+)\s*\.\s*OnServerEvent",                  on_server),
    (r"Remotes\.Event\.(\w+)\s*\.\s*OnClientEvent",                  on_client),
    (r"Remotes\.Function\.(\w+)\s*:\s*InvokeServer",                 invoke_server),
    (r"Remotes\.Function\.(\w+)\s*:\s*InvokeClient",                 invoke_client),
    (r"Remotes\.Function\.(\w+)\s*\.\s*OnServerInvoke",              cb_server),
    (r"Remotes\.Function\.(\w+)\s*\.\s*OnClientInvoke",              cb_client),
]

for f in sorted(SRC.rglob("*.lua")):
    if f.name == "Remotes.lua":
        continue
    code = strip_comments(f.read_text())
    r = str(f.relative_to(ROOT))
    for pat, bucket in PATTERNS:
        for m in re.finditer(pat, code):
            bucket.setdefault(m.group(1), set()).add(r)

def side(path):
    return "server" if "/server/" in path else ("client" if "/client/" in path else "shared")

problems, notes = [], []

for name in events:
    senders  = fire_server.get(name, set()) | fire_client.get(name, set())
    liste    = on_server.get(name, set())   | on_client.get(name, set())
    if not senders and not liste:
        problems.append(f"Event {name!r}: declared, never sent, never listened to — dead manifest row")
        continue
    if not senders:
        problems.append(f"Event {name!r}: LISTENED TO in {sorted(liste)} but never sent by anyone")
        continue
    if not liste:
        problems.append(f"Event {name!r}: SENT from {sorted(senders)} and nobody is listening")
        continue
    # direction sanity: FireServer must be met by OnServerEvent, etc.
    if fire_server.get(name) and not on_server.get(name):
        problems.append(f"Event {name!r}: client FireServer from {sorted(fire_server[name])}, no OnServerEvent anywhere")
    if fire_client.get(name) and not on_client.get(name):
        problems.append(f"Event {name!r}: server FireClient from {sorted(fire_client[name])}, no OnClientEvent anywhere")
    if on_server.get(name) and not fire_server.get(name):
        problems.append(f"Event {name!r}: OnServerEvent in {sorted(on_server[name])}, nothing ever FireServers it")
    if on_client.get(name) and not fire_client.get(name):
        problems.append(f"Event {name!r}: OnClientEvent in {sorted(on_client[name])}, nothing ever FireClients it")
    # wrong-side wiring
    for f in fire_server.get(name, set()):
        if side(f) == "server":
            problems.append(f"Event {name!r}: FireServer called from a SERVER file {f}")
    for f in fire_client.get(name, set()):
        if side(f) == "client":
            problems.append(f"Event {name!r}: FireClient called from a CLIENT file {f}")

for name in funcs:
    inv = invoke_server.get(name, set()) | invoke_client.get(name, set())
    cb  = cb_server.get(name, set())     | cb_client.get(name, set())
    if not inv and not cb:
        problems.append(f"Function {name!r}: declared, never invoked, never answered — dead manifest row")
    elif not cb:
        problems.append(f"Function {name!r}: INVOKED from {sorted(inv)} with no OnServerInvoke/OnClientInvoke — this YIELDS FOREVER")
    elif not inv:
        notes.append(f"Function {name!r}: answered in {sorted(cb)} but never invoked")

print(f"remotes: {len(events)} event(s), {len(funcs)} function(s)")
for p in problems:
    print("  PROBLEM  " + p)
for n in notes:
    print("  note     " + n)
if not problems:
    print("  every remote is sent and heard, on the right sides")
sys.exit(1 if problems else 0)
