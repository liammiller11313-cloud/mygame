# old-place/

Drop the exported **Brickbattle Ultimate** place here, then run:

```bash
python3 scripts/extract_place.py old-place/BrickbattleUltimate.rbxlx -o old-place/extracted
```

It writes `TREE.txt` (the whole instance tree), `SCRIPTS/` (every script's real
source, at a path mirroring its place path), `ASSET_IDS.txt` (every sound, image
and mesh id the place references, and what referenced it) and `INVENTORY.json`.

## Getting the export out of Studio

**File → Save to File As…**, and in the "Save as type" dropdown pick
**Roblox XML Place Files (\*.rbxlx)**. The default `.rbxl` is a binary format
that can't be read here — the extractor will stop and tell you if you pick it.

If the whole place is too big to move, export the parts that matter one at a
time instead: right-click a service or folder in Explorer → **Save to File…** →
choose `.rbxmx`. The extractor reads those too. The ones worth having first are
`ServerScriptService`, `ReplicatedStorage`, `StarterPack`, `StarterGui`,
`StarterPlayer`, and `ServerStorage.Maps`.

`.rbxlx` is XML, so it compresses hard — `zip` it if you're near a size limit.
