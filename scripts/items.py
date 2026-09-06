#!/usr/bin/env python3
"""
Every carried item, traced from the map folder to the effect it produces.

Not a style check. This walks the ACTUAL chain a medkit or a molotov travels —
map folder, spawn point, pickup, slot, hand, use, effect, refill — and fails on
any link that is missing. It exists because every one of those links has broken
at least once, always silently: an item that cannot be picked up looks like a
map with no items, and a throwable with no effect looks like a throw that did
not happen.

Run from scripts/check.sh, after audit.py.
"""
import re, sys, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "src"

def read(rel):
    return (SRC / rel).read_text(encoding="utf-8")

FILES = {
    "enums": read("shared/Enums/init.lua"),
    "mapconfig": read("shared/Config/MapConfig.lua"),
    "inventory": read("server/Survivors/InventoryService.lua"),
    "mapitems": read("server/Level/MapItemService.lua"),
    "projectile": read("server/Combat/ProjectileService.lua"),
    "factory": read("server/Assets/PlaceholderFactory.lua"),
    "carry": read("server/Survivors/CarryVisualService.lua"),
    "backpack": read("client/UI/BackpackController.lua"),
    "survivor": read("server/Survivors/SurvivorService.lua"),
}

def enum_members(name):
    m = re.search(r"Enums\.%s = table\.freeze\(\{(.*?)\}\)" % name, FILES["enums"], re.S)
    if not m:
        return []
    return re.findall(r"^\s*(\w+)\s*=", m.group(1), re.M)

THROWABLES = enum_members("Throwable")
PILLS = enum_members("PillItem")
HEALTH = enum_members("HealthItem")

# ── the map-item families, parsed out of MapConfig ──────────────────────────
FAMILIES = []
for block in re.findall(r"table\.freeze\(\{(.*?)\}\),", FILES["mapconfig"], re.S):
    if "folderName" not in block or "expectedCount" not in block:
        continue
    def field(n, pat=r'"([^"]+)"'):
        mm = re.search(r"\b%s = %s" % (n, pat), block)
        return mm.group(1) if mm else None
    FAMILIES.append({
        "key": field("key"),
        "folder": field("folderName"),
        "model": field("modelName"),
        "count": field("expectedCount", r"(\d+)"),
        "itemId": (re.search(r"itemId = Enums\.\w+\.(\w+)", block) or [None, None])[1],
        "slot": (re.search(r"slot = Enums\.Slot\.(\w+)", block) or [None, None])[1],
        "tag": field("tag"),
    })

problems, notes = [], []

def need(cond, msg):
    if not cond:
        problems.append(msg)

# ── 1. every map family is coherent and reachable ───────────────────────────
seen_tags, seen_folders = {}, {}
for f in FAMILIES:
    where = "MapConfig family %r" % f["key"]
    need(f["folder"] and f["model"] and f["itemId"] and f["slot"],
         "%s is missing folderName / modelName / itemId / slot" % where)
    need(f["tag"] not in seen_tags,
         "%s reuses the CollectionService tag %r, already used by %r — two families "
         "sharing a tag cannot be told apart when a spot is reclaimed"
         % (where, f["tag"], seen_tags.get(f["tag"])))
    seen_tags[f["tag"]] = f["key"]
    need(f["folder"] not in seen_folders,
         "%s reads the same map folder %r as %r" % (where, f["folder"], seen_folders.get(f["folder"])))
    seen_folders[f["folder"]] = f["key"]

    # the item id must exist in the enum its slot accepts
    pool = {"Throwable": THROWABLES, "Pills": PILLS, "Health": HEALTH}.get(f["slot"], [])
    need(f["itemId"] in pool,
         "%s places %r into slot %r, but that slot only accepts %s — InventoryService."
         "giveItem validates against SLOT_ITEMS and would refuse every pickup"
         % (where, f["itemId"], f["slot"], ", ".join(pool) or "(nothing)"))

# ── 2. every throwable can actually be built, thrown and land ───────────────
for kind in THROWABLES:
    need("Enums.Throwable.%s]" % kind in FILES["factory"],
         "throwable %r has no PICKUP_BUILDERS entry in PlaceholderFactory, so "
         "dropWeapon cannot build a model for it — and a pickup whose drop cannot "
         "be built is now REFUSED, so the item becomes unswappable" % kind)
    need(("THROWABLE.%s" % kind) in FILES["projectile"],
         "throwable %r is never named in ProjectileService, so it falls through "
         "every branch to the default effect — check that is deliberate" % kind)
    need(kind in FILES["backpack"],
         "throwable %r has no line in BackpackController, so the backpack shows "
         "a blank description for it" % kind)

# ── 3. the consumption paths that refill a spot ─────────────────────────────
need("self.itemConsumed:fire" in FILES["inventory"],
     "InventoryService never fires itemConsumed; MapItemService listens to that "
     "signal and to nothing else, so no spawn point would ever refill")
need("hasScanned" in FILES["mapitems"] and "hasScanned" in FILES["factory"],
     "the map-item readiness flag is gone; PlaceholderFactory's boot prewarm will "
     "warn about every family on every server start")
need("_onCarrierLostEverything" in FILES["mapitems"],
     "nothing refills a spawn point when its carrier dies, and clearAll destroys "
     "what they were holding rather than dropping it")

# ── 4. what a survivor is holding is actually drawn ────────────────────────
for slot in ("Health", "Pills", "Throwable"):
    need("Enums.Slot.%s]" % slot in FILES["carry"],
         "CarryVisualService has no HAND_SLOTS entry for %r, so the item is "
         "invisible in the survivor's hands" % slot)

# ── report ─────────────────────────────────────────────────────────────────
print("items: %d map famil%s, %d throwable(s), %d pill(s), %d health item(s)"
      % (len(FAMILIES), "y" if len(FAMILIES) == 1 else "ies",
         len(THROWABLES), len(PILLS), len(HEALTH)))
for f in FAMILIES:
    print("  %-14s %-18s %s x%s -> %s/%s"
          % (f["key"], '"%s"' % f["folder"], '"%s 1"' % f["model"], f["count"], f["slot"], f["itemId"]))
unplaced = [k for k in THROWABLES if not any(f["itemId"] == k for f in FAMILIES)]
if unplaced:
    print("  throwables with no map family (supplied or Director-placed only): %s"
          % ", ".join(unplaced))

if problems:
    print("\n── %d broken link(s) ──" % len(problems))
    for p in problems:
        print("  " + p)
    sys.exit(1)
print("every item chain is intact")
