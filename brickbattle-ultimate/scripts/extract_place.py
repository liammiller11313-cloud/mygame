#!/usr/bin/env python3
"""
extract_place.py — read a Roblox place saved as .rbxlx (XML) and turn it into
something a human or an agent can actually study.

Roblox's binary .rbxl is opaque; the XML .rbxlx variant is not, and it carries
every instance, every property and — the reason this exists — the full source of
every Script, LocalScript and ModuleScript in the place. So the whole of an old
game can be read without opening Studio.

    python3 scripts/extract_place.py old-place/BrickbattleUltimate.rbxlx -o old-place/extracted

Produces, under the output directory:

    TREE.txt          the whole instance tree, one line per instance, with class
    SCRIPTS/          every script, written to a path mirroring its place path
    INVENTORY.json    machine-readable: counts by class, script index, asset ids
    ASSET_IDS.txt     every rbxassetid referenced anywhere, with what referenced it

Nothing is executed and nothing is trusted: script source is written to disk as
data, never run. Big places stream through iterparse rather than loading the
whole DOM, because a place with a lot of geometry does not fit in memory twice.
"""

from __future__ import annotations

import argparse
import base64
import binascii
import json
import os
import re
import sys
from collections import Counter, defaultdict
from xml.etree import ElementTree as ET

SCRIPT_CLASSES = {"Script", "LocalScript", "ModuleScript"}

# Roblox writes asset references a few different ways depending on the property
# and the era of the file. Catching only "rbxassetid://" misses the old
# "http://www.roblox.com/asset/?id=" form that classic places are full of.
ASSET_PATTERNS = [
    re.compile(r"rbxassetid://(\d+)"),
    re.compile(r"rbxasset://[^\s\"'<>]+"),
    re.compile(r"roblox\.com/asset/?\?id=(\d+)", re.I),
    re.compile(r"roblox\.com/asset/?id=(\d+)", re.I),
]

# Properties worth keeping in the tree dump. Everything else is noise at this
# stage — we are trying to understand a game, not clone a CFrame.
INTERESTING_PROPS = {
    "Name", "ClassName", "Disabled", "Value", "Text", "Image", "SoundId",
    "MeshId", "TextureId", "Anchored", "CanCollide", "Transparency",
    "BrickColor", "Material", "Size", "Attributes", "PrimaryPart",
    "MaxActivationDistance", "Volume", "Looped", "Playing",
}


def sanitize(name: str) -> str:
    """Make an instance name safe as a single path segment."""
    cleaned = re.sub(r'[<>:"/\\|?*\x00-\x1f]', "_", name).strip().rstrip(".")
    return cleaned or "_unnamed_"


class Node:
    __slots__ = ("cls", "name", "props", "children", "parent")

    def __init__(self, cls: str, parent: "Node | None"):
        self.cls = cls
        self.name = cls
        self.props: dict[str, str] = {}
        self.children: list[Node] = []
        self.parent = parent

    def path(self) -> str:
        parts, node = [], self
        while node is not None and node.parent is not None:
            parts.append(node.name)
            node = node.parent
        return ".".join(reversed(parts)) or self.name


def read_properties(item: ET.Element, shared: dict[str, str]) -> dict[str, str]:
    """Flatten an <Item>'s own <Properties> block into name -> text."""
    props: dict[str, str] = {}
    block = item.find("Properties")
    if block is None:
        return props
    for prop in block:
        key = prop.get("name")
        if not key:
            continue
        if prop.tag in ("ProtectedString", "string", "BinaryString"):
            props[key] = prop.text or ""
        elif prop.tag in ("bool", "int", "int64", "float", "double", "token"):
            props[key] = (prop.text or "").strip()
        elif prop.tag == "SharedString":
            props[key] = shared.get((prop.text or "").strip(), "")
        elif prop.tag == "Content":
            url = prop.find("url")
            if url is not None and url.text:
                props[key] = url.text.strip()
        elif key in INTERESTING_PROPS:
            # Composite types (Vector3, Color3, ...) — keep a terse rendering.
            bits = [f"{c.tag}={(c.text or '').strip()}" for c in prop]
            props[key] = " ".join(bits) if bits else (prop.text or "").strip()
    return props


def read_shared_strings(path: str) -> dict[str, str]:
    """Roblox parks some property values in a <SharedStrings> table at the end of
    the file and leaves a hash behind in the property. A place saved that way
    yields empty scripts unless the table is resolved, so read it up front."""
    table: dict[str, str] = {}
    try:
        for _, elem in ET.iterparse(path, events=("end",)):
            if elem.tag != "SharedString":
                continue
            key = elem.get("md5")
            if key and elem.text:
                try:
                    table[key] = base64.b64decode(elem.text).decode("utf-8", "replace")
                except (ValueError, binascii.Error):
                    pass
            elem.clear()
    except ET.ParseError:
        return table
    return table


def parse(path: str, shared: dict[str, str]) -> Node:
    """Stream the file and rebuild the instance tree.

    iterparse gives us 'start' before children exist and 'end' after they do, so
    the tree is built on 'start' and properties are read on 'end' — the point at
    which an Item's own <Properties> block has been parsed.
    """
    root = Node("DataModel", None)
    root.name = "game"
    stack: list[Node] = [root]

    context = ET.iterparse(path, events=("start", "end"))
    for event, elem in context:
        if elem.tag != "Item":
            continue
        if event == "start":
            node = Node(elem.get("class") or "Instance", stack[-1])
            stack[-1].children.append(node)
            stack.append(node)
        else:
            node = stack.pop()
            node.props = read_properties(elem, shared)
            node.name = node.props.get("Name") or node.cls
            # Drop the payload now it is copied out — a place with a lot of
            # geometry will not fit in memory as both XML and tree. The emptied
            # <Item> stays in its parent's list, which is what keeps the walk valid.
            elem.clear()
    return root


def walk(node: Node):
    yield node
    for child in node.children:
        yield from walk(child)


def find_assets(text: str) -> set[str]:
    found: set[str] = set()
    for pattern in ASSET_PATTERNS:
        for match in pattern.finditer(text):
            found.add(match.group(0))
    return found


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("place", help="path to a .rbxlx or .rbxmx file (XML, not the binary .rbxl)")
    ap.add_argument("-o", "--out", default="extracted", help="output directory")
    ap.add_argument("--max-depth", type=int, default=0, help="limit TREE.txt depth (0 = unlimited)")
    args = ap.parse_args()

    if not os.path.exists(args.place):
        print(f"error: no such file: {args.place}", file=sys.stderr)
        return 1

    with open(args.place, "rb") as handle:
        head = handle.read(64)
    if head.startswith(b"<roblox!"):
        print(
            "error: this is a BINARY .rbxl. Re-save it as XML:\n"
            "  Roblox Studio -> File -> Save to File As... -> set 'Save as type' to\n"
            "  'Roblox XML Place Files (*.rbxlx)'.",
            file=sys.stderr,
        )
        return 2
    if not head.lstrip().startswith(b"<roblox"):
        print("error: does not look like a Roblox XML file.", file=sys.stderr)
        return 2

    print(f"parsing {args.place} ({os.path.getsize(args.place) / 1e6:.1f} MB)...")
    shared = read_shared_strings(args.place)
    if shared:
        print(f"  resolved {len(shared)} shared strings")
    root = parse(args.place, shared)

    os.makedirs(args.out, exist_ok=True)
    scripts_dir = os.path.join(args.out, "SCRIPTS")
    os.makedirs(scripts_dir, exist_ok=True)

    class_counts: Counter[str] = Counter()
    script_index: list[dict] = []
    asset_refs: dict[str, list[str]] = defaultdict(list)
    tree_lines: list[str] = []

    for node in walk(root):
        if node is root:
            continue
        class_counts[node.cls] += 1
        depth = node.path().count(".")
        if args.max_depth == 0 or depth <= args.max_depth:
            marker = ""
            if node.cls in SCRIPT_CLASSES:
                lines = (node.props.get("Source") or "").count("\n") + 1
                disabled = " DISABLED" if node.props.get("Disabled") == "true" else ""
                marker = f"  [{lines} lines{disabled}]"
            tree_lines.append(f"{'  ' * depth}{node.name}  <{node.cls}>{marker}")

        for key, value in node.props.items():
            if not isinstance(value, str) or not value:
                continue
            for asset in find_assets(value):
                asset_refs[asset].append(f"{node.path()}.{key}")

        if node.cls in SCRIPT_CLASSES:
            source = node.props.get("Source") or ""
            segments = [sanitize(p) for p in node.path().split(".")]
            ext = {"Script": ".server.lua", "LocalScript": ".client.lua", "ModuleScript": ".lua"}[node.cls]
            dest = os.path.join(scripts_dir, *segments[:-1], segments[-1] + ext)
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            # Two instances can share a name under one parent; never clobber.
            if os.path.exists(dest):
                stem, suffix = dest[: -len(ext)], ext
                n = 2
                while os.path.exists(f"{stem}_{n}{suffix}"):
                    n += 1
                dest = f"{stem}_{n}{suffix}"
            with open(dest, "w", encoding="utf-8") as out:
                out.write(source)
            script_index.append({
                "path": node.path(),
                "class": node.cls,
                "file": os.path.relpath(dest, args.out),
                "lines": source.count("\n") + 1 if source else 0,
                "disabled": node.props.get("Disabled") == "true",
            })

    with open(os.path.join(args.out, "TREE.txt"), "w", encoding="utf-8") as out:
        out.write("\n".join(tree_lines) + "\n")

    with open(os.path.join(args.out, "ASSET_IDS.txt"), "w", encoding="utf-8") as out:
        for asset in sorted(asset_refs, key=lambda a: (-len(asset_refs[a]), a)):
            out.write(f"{asset}\n")
            for where in sorted(set(asset_refs[asset]))[:12]:
                out.write(f"    {where}\n")

    inventory = {
        "source": os.path.basename(args.place),
        "totalInstances": sum(class_counts.values()),
        "classCounts": dict(class_counts.most_common()),
        "scripts": sorted(script_index, key=lambda s: -s["lines"]),
        "totalScriptLines": sum(s["lines"] for s in script_index),
        "assetIdCount": len(asset_refs),
    }
    with open(os.path.join(args.out, "INVENTORY.json"), "w", encoding="utf-8") as out:
        json.dump(inventory, out, indent=2)

    empty = [s for s in script_index if s["lines"] == 0]
    if len(script_index) >= 10 and len(empty) > len(script_index) * 0.5:
        print(
            f"  WARNING: {len(empty)}/{len(script_index)} scripts came out empty. The place was\n"
            "           probably saved with 'Save to File As' from a session where source was\n"
            "           not loaded, or it is not really a place file. Re-save and re-run.",
            file=sys.stderr,
        )

    print(f"  {inventory['totalInstances']} instances, {len(class_counts)} distinct classes")
    print(f"  {len(script_index)} scripts, {inventory['totalScriptLines']} lines -> {scripts_dir}/")
    print(f"  {len(asset_refs)} distinct asset ids -> ASSET_IDS.txt")
    print(f"  tree -> {os.path.join(args.out, 'TREE.txt')}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
