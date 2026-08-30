# Brickbattle Ultimate

A classic Roblox brickbattle game, rebuilt. Lobby, map vote, two teams, the
classic arsenal, a winner — wrapped in the Tix / shop / level / quest metagame
the original had.

## Status

Scaffolding. The network contract, the enums and the harvested utility layer are
in and verified; the services are not written yet.

## Getting it running

The project syncs into Studio with [Rojo](https://rojo.space). Tool versions are
pinned in `rokit.toml`:

```bash
rokit install
./scripts/dev.sh      # rojo serve, plus a fast-forward pull of the branch
```

Then open Studio, hit the Rojo plugin button, and Connect.

```bash
./scripts/check.sh            # format, syntax-check
./scripts/check.sh --check    # verify without writing
```

`check.sh` prefers the `rokit`-managed StyLua. Where a release binary cannot be
downloaded it falls back to StyLua's WASM build — same parser, so the verdict is
the same. See `scripts/luau-wasm/README.md`.

## The old game

This is a revival, and the old place is the reference. Export it from Studio as
`.rbxlx` (**not** the binary `.rbxl`), drop it in `old-place/`, and:

```bash
python3 scripts/extract_place.py old-place/BrickbattleUltimate.rbxlx -o old-place/extracted
```

That gives the instance tree, every script's real source, and every asset id the
place references. Details in `old-place/README.md`.

## Reading order

- [`docs/DECISIONS.md`](docs/DECISIONS.md) — what was decided, why, what it would
  cost to change, and every question still open. Start here.
