# Getting Fading Light running — macOS (Apple Silicon)

The Rojo Studio plugin is only half of Rojo. The plugin is a *client*; it needs a
Rojo **server** running on your Mac, serving this repo folder. Starting that
server is what "getting Rojo online" means.

## One-time setup

Open **Terminal** (Cmd+Space, type "Terminal").

### 1. Get the code

```bash
cd ~/Documents
git clone https://github.com/liammiller11313-cloud/mygame.git
cd mygame
git checkout claude/fading-light-roblox-game-flg5ig
```

The first `git` command may prompt you to install Apple's command line tools.
Accept it, wait for it to finish, then run the command again.

### 2. Get the Rojo CLI

Your Studio plugin is **7.6.1**, so get the matching CLI. On an M3 you want the
**macos-aarch64** build:

```bash
curl -L -o rojo.zip https://github.com/rojo-rbx/rojo/releases/download/v7.6.1/rojo-7.6.1-macos-aarch64.zip
unzip rojo.zip
chmod +x rojo
```

If that URL 404s, go to <https://github.com/rojo-rbx/rojo/releases>, find v7.6.1,
and download the asset with `macos-aarch64` in its name.

### 3. Get past Gatekeeper

macOS quarantines anything downloaded from the internet and will refuse to run it
with *"cannot be opened because the developer cannot be verified"*. Clear the flag:

```bash
xattr -d com.apple.quarantine rojo
```

(If that says "No such xattr", you're already fine — carry on.)

### 4. Check it works

```bash
./rojo --version
```

Should print `Rojo 7.6.1`.

## Fully automatic — set it up once, never think about it again

```bash
cd ~/Documents/mygame
./scripts/autostart.sh install
```

That installs a launchd LaunchAgent, which is macOS's own "run this for me"
mechanism. From then on, every time you log in: Rojo starts serving this folder,
and the branch fast-forwards itself as commits land. No Terminal window, nothing
to remember, and it restarts itself if it ever dies.

```bash
./scripts/autostart.sh status
./scripts/autostart.sh log
./scripts/autostart.sh uninstall
```

`status` says whether it is running, `log` follows what it is doing (Ctrl+C
stops watching, not the job), and `uninstall` removes it completely.

**The one thing that cannot be automatic** is Studio's end. Click **Rojo** →
**Connect** once per Studio session. A plugin button cannot be pressed from
outside Studio. Check the Rojo plugin's own settings for a reconnect option — if
your version has one, that closes the last gap.

## Or run it by hand

```bash
cd ~/Documents/mygame
./scripts/dev.sh
```

Same thing, in a Terminal window you can watch, stopping when you close it. Rojo
on its own, without the auto-pull:

```bash
./rojo serve
```

You'll see:

```
Rojo server listening:
  Address: localhost
  Port:    34872
```

**Leave that Terminal window open.** That is Rojo being online.

Now in Studio: open your place → click **Rojo** in the Plugins toolbar → **Connect**
(address `localhost`, port `34872`). The whole `src/` tree appears under
ReplicatedStorage, ServerScriptService and StarterPlayer, and stays live-synced
while the server runs.

Press **Stop** in Terminal with Ctrl+C when you're done.

## Getting updates

`./scripts/dev.sh` already does this — it checks the branch every 20 seconds and
fast-forwards when there is something new, printing what it pulled. Changes reach
Studio instantly and no reconnect is needed.

It only ever fast-forwards. If you have edited files, or made commits of your
own, it says so once and keeps serving rather than merging or discarding
anything — sort that out yourself and it resumes on the next check.

If you are running `./rojo serve` by hand instead, then it is manual: a second
Terminal tab, and

```bash
cd ~/Documents/mygame
git pull
```

each time. Or run `./scripts/dev.sh --pull-only` in that second tab, which is
the automatic half without starting a second Rojo.

## Updating Rojo

```bash
cd ~/Documents/mygame
./scripts/update-rojo.sh
```

That finds the newest release, replaces `./rojo`, updates the `rokit.toml` pin
to match, and installs the Studio plugin that belongs to the new CLI. To see
what is available without changing anything, add `--check`; to pin a specific
version, pass it: `./scripts/update-rojo.sh 7.7.0`.

**Already downloaded the zip yourself?** Then use it instead of fetching it
again:

```bash
./scripts/update-rojo.sh --from
```

That picks the newest `rojo-*` zip in `~/Downloads` that matches this Mac's
build, or takes a path if you point it at one:
`./scripts/update-rojo.sh --from ~/Desktop/rojo-7.7.0-macos-aarch64.zip`.
Everything after the download is the part that matters — clearing macOS
quarantine, stopping the autostart job so the swap actually takes, repinning
`rokit.toml`, installing the matching plugin — and it is identical either way.

If the new binary turns out not to run, which almost always means the zip was
for a different architecture, your previous Rojo is put back and nothing is
repinned. A Rojo that does not run where a working one used to be is worse than
not having updated.

**Then restart Roblox Studio.** A plugin that is already loaded stays the old
one until Studio closes and reopens, which looks exactly like the update not
having worked.

### Why it always does both halves

Rojo is two programs talking to each other: the CLI serving your files, and the
plugin receiving them. They speak a versioned protocol, so updating one and not
the other does not give you a newer Rojo — it gives you a Rojo that refuses to
connect, with *"protocol version mismatch"*. `rojo plugin install` installs the
plugin build belonging to the CLI that ran it, which is why the script runs it
for you rather than leaving it as a step to remember.

If it ever cannot install the plugin, it says so and exits non-zero rather than
reporting success — a CLI and plugin on different versions is precisely the
state that breaks Connect, and being told it worked is what would stop you
looking there.

### If you switch to Rokit

`rokit.toml` in this repo pins every tool version, and Rokit is the tidier way
to manage them. If your `rojo` comes from Rokit, the update script notices and
steps aside — do it there instead:

```bash
rokit install
rojo plugin install
```

after editing the version in `rokit.toml`.

## When Studio will not connect

```bash
./scripts/rojo-doctor.sh
```

It reports three versions that all have to agree, and says which one is wrong.

The third of them is the one that catches people out. Rojo is not two things,
it is three: the **binary on disk**, the **server process running**, and the
**Studio plugin**. The middle one is separate from the first because a running
process keeps executing the file it started with even after that file is
replaced — so a server started before an update quietly outlives it, and
nothing looks wrong from the outside.

### `rojo serve` versus `./rojo serve`

The `./` is not decoration. `rojo serve` runs whatever your shell finds on PATH;
`./rojo serve` runs the binary in this folder, which is the one
`update-rojo.sh` replaces and the one `rokit.toml` pins. If an older Rojo is
sitting in `/usr/local/bin`, `/opt/homebrew/bin` or a Rokit shim, it wins — so
the update succeeds, the doctor reports the new version, and `rojo serve` goes
on starting the old one. `./scripts/rojo-doctor.sh` lists every copy it can find
and flags the disagreement.

`./scripts/dev.sh` always uses the right one, which is the simplest way not to
have to think about it.

### `attempt to index number with 'protocolVersion'`

That is this exact situation, between 7.6.1 and 7.7.0 specifically.

The two versions disagree about the wire format: the 7.6.1 plugin decodes
`/api/rojo` as JSON, the 7.7.0 plugin decodes it as MessagePack. So a 7.7.0
plugin talking to a 7.6.1 server does not get the friendly "protocol version
mismatch" message that exists for this — it msgpack-decodes a JSON body, reads
the opening `{` as the number 123, and dies indexing it.

The fix is to restart the server so it is the new binary:

```bash
./scripts/restart-rojo.sh
```

There are two ways a server can be running here — the autostart LaunchAgent, or
`./scripts/dev.sh` in a Terminal window — and which you have decides how to
restart it. That is a silly thing to have to know, so that script works it out:
it stops whichever is running, starts it again, and then checks the version by
asking THE SERVER rather than the binary. That the file on disk is new was never
in doubt; whether the thing now listening is, is the whole question.

## Your models are safe

Rojo only manages what `default.project.json` declares — the `src/` tree plus a few
Lighting and Workspace properties. It will not touch `ReplicatedStorage.Assets`,
your Zombieville map, or anything else you have in the place.

## If Connect fails

| Symptom | Fix |
|---|---|
| "Protocol version mismatch" | Run `./rojo plugin install` — it installs the plugin version that exactly matches your CLI — then **restart Studio**. `./scripts/update-rojo.sh` does this as part of updating. |
| Connect button does nothing | The server isn't running. Check the Terminal window still shows "listening". |
| "Address already in use" | A Rojo server is already running. Close the other Terminal window, or use `./rojo serve --port 34873` and enter that port in Studio. |
| Studio can't reach localhost | Studio → Settings → Security → enable **Allow HTTP Requests** for the place. |
