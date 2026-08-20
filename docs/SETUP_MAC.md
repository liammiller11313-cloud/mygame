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

## Every time you want to work on the game

```bash
cd ~/Documents/mygame
./scripts/dev.sh
```

That runs Rojo **and** keeps the folder up to date with the branch, which is the
whole loop in one command. If you would rather run Rojo on its own:

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

## Your models are safe

Rojo only manages what `default.project.json` declares — the `src/` tree plus a few
Lighting and Workspace properties. It will not touch `ReplicatedStorage.Assets`,
your Zombieville map, or anything else you have in the place.

## If Connect fails

| Symptom | Fix |
|---|---|
| "Protocol version mismatch" | Run `./rojo plugin install` — it installs the plugin version that exactly matches your CLI. |
| Connect button does nothing | The server isn't running. Check the Terminal window still shows "listening". |
| "Address already in use" | A Rojo server is already running. Close the other Terminal window, or use `./rojo serve --port 34873` and enter that port in Studio. |
| Studio can't reach localhost | Studio → Settings → Security → enable **Allow HTTP Requests** for the place. |
