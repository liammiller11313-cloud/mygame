# scripts/luau-wasm

`scripts/check.sh` prefers the StyLua that `rokit install` puts on your PATH —
that is the pinned version (`rokit.toml`) and the one that decides CI.

This directory is the fallback for environments that cannot download a release
binary at all. StyLua also publishes a WebAssembly build to npm, which needs
nothing but Node, and it is the *same* full-moon parser underneath — so a file
that parses and formats here parses and formats there.

    npm install --prefix scripts/luau-wasm
    node scripts/luau-wasm/check.mjs  $(find src -name '*.lua')   # verify
    node scripts/luau-wasm/format.mjs $(find src -name '*.lua')   # rewrite

The config in both scripts mirrors `stylua.toml` by hand. If you change one,
change the other — there is no shared source, and a silent drift between them
shows up as CI reformatting files that were clean locally.
