# Alpha Testing 02

Build stamp **`2026-09-07b-alpha02`**. It is printed in the server log at boot
and is the fastest way to tell whether the place you are in is the build you
think it is — check it first, before reporting anything.

---

## Before you invite anybody

Six things, in this order. The first three are the ones that have actually gone
wrong before.

### 1. Press Play in Studio and read the boot banner

It is one screen of output and it answers most of what a first playtest would
otherwise discover the slow way.

```
  modules     37 of 37 loaded
  init        32 ran, 0 failed
  start       32 ran, 0 failed
```

(37 on the server; the client boots 46 controllers and prints its own banner.)

**Only `failed` matters, and it must be 0 on both lines.** `ran` is lower than
`loaded` and that is not a fault: it counts the modules that *have* an `init` or
a `start` at all, and five services need neither — they do their whole job when
they are required. A module that fails init is skipped at start rather than run
half-built, so one broken service is one line rather than a cascade; it is still
a service the game does not have.

Then the asset line. Anything on the grey-boxed side is a stand-in, not a bug:

```
  assets      weapons 34/37 · viewmodels 37/37 · infected 10/10 kinds
```

There are **two** asset lines and they answer different questions. The
`[PlaceholderFactory]` one, printed just above the banner, is what the game
ended up with. The banner's is a survey of the folders taken before any module
loaded, so that a place whose factory failed outright still gets an honest
answer. They used to disagree — the survey did not know that a first-person
model falls back to the world model, and reported 15 viewmodels of 37 where the
factory reported 37. If they disagree again, the factory's is the real one.

### 2. Check the new asset ids resolved

Three checks run on the **client**, so open the client console (F9) after
joining, not just the server output. Each names the thing rather than a number:

- `[ImageCheck]` — the menu photograph, one card per map (four now, with
  Backrooms), the splash mark.
  It now also refuses a **decal** id, which is the mistake that cost a day: the
  id shown on a Creator Store page wraps the image rather than being it.
- `[SoundCheck]` — all 57 ids behind 110 cues, in one preload. **Silence is not
  proof of success here** — `AudioConfig` ships deliberate blanks, so a missing
  cue reads as an unfinished row. Several cues share one id, which is why the
  two numbers differ and why one failed id takes a handful of cues with it.
- `[PlaceholderFactory]` — which weapons and rigs are still stand-ins.

> **The failure mode you cannot see from your own machine.** Both images and
> audio are licensed per *place*. An asset uploaded under a personal account
> into a group-owned experience loads perfectly in Studio for whoever uploaded
> it and fails for every other player. If a tester reports something missing
> that works for you, this is the first thing to check.

### 3. Put the map items in

Six folders per map, and there are **four maps now** — Backrooms is new this
build. Missing folders are not fatal — the Director falls back —
but the map-item warnings at boot tell you exactly which are absent:

```
Medkits/           Medkit 1 … 11
Pain Pills/        Pain Pills 1 … 9
Adrenaline Shots/  Adrenaline Shot 1 … 7
Molotovs/          Molotov 1 … 6
Pipe Bombs/        Pipe Bomb 1 … 7
Hazardous Wastes/  Hazardous Waste 1 … 7      ← new this build
```

### 4. Run the checks

```
./scripts/check.sh
```

Format, undefined names, the code audit, **every remote's two ends**, **every
item chain**, and the economy model. All six must be clean.

The remote check is new this build and it is worth knowing what it is for: a
remote has two halves in two different files, and a missing half is invisible —
no error, no warning, just a button that does nothing. That is not hypothetical
here. Every throwable in the game was inert for weeks because the client sent
`ThrowItem` and nothing listened.

### 5. Test on a phone and a controller, not only a desktop

Three schemes, and two of them cannot be checked by reasoning. See
`docs/CONTROLS.md` for the full table.

### 6. Decide what you are testing

The list below is what changed. An alpha that tests everything tests nothing.

---

## What is new since Alpha 01

### Two new items

**Hazardous waste** — a throwable, seven per map, and it **replaces the bile
jar**, which is gone. Both put a puddle on the floor that the horde walks to,
and two items doing that are one item and a copy of it.

The waste is the one worth keeping: fifty seconds, wide, and it coats nobody. A
pipe bomb is thrown at a horde that is already on you; this is put down *before*
one, on the corridor you have decided not to defend, and it is still running
when the wave arrives. Watch whether players work that out without being told,
or whether they throw it at things like a grenade.

**Flare gun** — a secondary, $3,500 in the shop. Twelve damage on impact, which
will not kill a Common; what it does is set them alight. One shell, four-second
reload. Watch whether the trade reads as interesting or just weak.

### Throwing changed

The **fire button now throws** a selected throwable, aimed down the camera. This
is the single most likely thing to need retuning — `G` still works, and on a pad
or a phone the fire button is now the primary route.

### Bodies stay

Ordinary kills leave a corpse instead of bursting. Commons gibbed on any
headshot from any gun before this, which deleted the body. Expect the map to
look substantially different during a horde; watch the frame rate on a phone.

### Boomers pop

They could not before. One flag was answering two questions.

### Boomer bile actually covers your screen

It did not. `applyBile` set the flag the server reads and never told the client,
so the only thing in the game that ever drew the green wash was a thrown bile
jar — which is why it looked fine in testing and the Boomer's entire threat did
not exist. **Test this deliberately**: let one burst on you and check that you
are blinded for about eleven seconds, and about seven from a vomit.

---

## Frame rate: what changed, honestly

You asked whether it is the same as before. Mostly yes, with one deliberate
exception, and one thing that was fixed before it shipped.

**The corpse ceiling has not moved.** It was 48 and it is still 48. What changed
is that it will now actually be *reached* — ordinary kills used to gib, which
deleted the body, so the ring rarely filled. Per body, once it stops moving:

- every part is **anchored** — no physics, and no physics replication
- the Humanoid's **state machine is switched off** — forty-eight corpses are not
  forty-eight state machines
- the client's pose loop **early-returns** on a dead body, and is strided and
  distance-culled besides

So a settled corpse costs draw calls and essentially nothing else. That is what
made 48 affordable when the number was chosen; the difference is that the number
is no longer theoretical. **Watch a phone during a wave 12 horde** — this is the
one change most likely to show up on a handset, and it is not device-scaled,
deliberately: corpses are replicated instances every client shares, so one
player's hardware must not decide how many bodies everyone else sees.

**The hazardous waste's particles were cut before shipping.** As first written
it put roughly 450 large soft particles on screen at four zones — three and a
half times the most expensive thing this system had ever done, on a zone that
lasts fifty seconds, so four at once is likely rather than exotic. These are
server-side emitters on a replicated part, so a phone cannot scale them the way
it scales a blood burst; they have to be affordable on the weakest device in the
server. Retuned to 183 at four zones. **This is the one number in the game I
would most like a phone to argue with** — it was chosen by counting emitters,
not by looking at a handset.

**Nothing else added per-frame work.** The new asset checks run once at join
(one `PreloadAsync` for the whole sound bank, which also warms it, so the first
gunshot of a round is not the one that streams in late). The nav-agent sizing is
computed once per body when its brain is built, off a measurement cached per
kind.

---

## Textures

Supplied models keep their textures. The pipeline strips scripts, sounds,
prompts and stray `ThumbnailCamera`s from anything you hand it — and writes no
colour, material or texture of its own. Recolouring happens only in the
grey-box builder, which is the path a model *replaces*.

So if a model of yours looks flat or untextured in game, it is not this pipeline
doing it: check the model in Studio, and check the client console for an
`[ImageCheck]` or `[PlaceholderFactory]` line naming it.

---

## Known issues

Honest list. None of these are worth a report.

- **The ambush and fake-out are gone**, not broken — deleted rather than left as
  tuned config for a feature with no code path. See `docs/BACKLOG.md`.
- **Three audio cues are defined and never played**: `UI.MenuPage`,
  `WeaponReload.Bolt`, `Gore.Squelch`. Re-checked this build against all 92
  cues in the bank; it is still exactly these three.
- **The ammo-crate broadcast has no consumer.** The server tells everyone which
  crate went and when it returns; only the person who used it is told anything.
- **Two files are near Luau's 200-locals-per-scope limit**: `MainMenuController`
  at 181 and `ViewmodelController` at 167. Both compile. Both stop compiling if
  they keep growing, and the fix is splitting them rather than shaving names.
- **Jump on iPad** is unverified since the pad was reworked — the original
  report predates that change and nobody has re-tested it.
- **The Metallic boss has parts named `Part` and `triangle`.** They are not in
  `GameConfig.PartRegions`, so shots on them score as a **torso** hit. That is a
  reasonable default for armour plating and wrong if either of them covers the
  head — worth one look at the rig in Studio. The boot log names them.

---

## Not an issue with the game — but it will stop your test

If the client console says every sound failed:

```
[SoundCheck] 57 of 57 sound id(s) across 110 cue(s) will not play on this client.
```

…that is **not** 57 broken ids. Roblox audio is private by default and granted
**per experience**, and Studio says which in a line that is easy to scroll past:

> The experience doesn't have access permission to use asset id … *Click to
> share access*

All-or-nothing failure means one of three things, in order of likelihood:

1. **The place is not published.** An unpublished place has no experience for
   the permission to be granted *to*, so every private id fails at once.
2. **Account mismatch** — audio uploaded under a personal account into a
   group-owned place, or the other way round.
3. **They are not yours.** Ids taken from a Creator Store page cannot be granted
   at all and need re-uploading under the account that owns the place.

The same applies to the two images, with one extra cause: an id copied from a
Creator Store page or an inventory tile is usually a **decal**, which wraps the
image rather than being it. Insert the decal in Studio and read the id off its
`Texture` property.

---

## The first session, in order

Do this alone, on a desktop, before anybody else is in the server. It is about
fifteen minutes and it is ordered so that a failure early makes the later steps
pointless — stop and report rather than pushing past one.

Everything below has a **stated expected result**. Where the real one differs,
that difference is the report; "it felt wrong" is not actionable and "I expected
X and got Y" always is.

### A. Does it boot

1. Press Play. Read the server banner. → **`0 failed` on both lines**, and the
   stamp reads `2026-09-07b-alpha02`.
2. Open the client console (F9). → `[ImageCheck]`, `[SoundCheck]` and
   `[PlaceholderFactory]` each report. Grey-boxed entries are fine; **failures
   are not**.

A failure in either step is the whole session. Paste the log and stop.

### B. The two things most likely to be broken

These are the changes with the least prior testing, so they come first.

3. **Boomer bile.** Let a Boomer burst on you.
   → Your screen goes green for about **eleven seconds**. From a vomit, about
   **seven**. This did nothing at all until this build, so treat a working
   result as new information rather than as normal.
4. **The fire button throws.** Select a throwable and pull the trigger.
   → It throws, **where you are looking** — aim at a balcony and it should land
   up there, not at your feet. Then do it again with a medkit selected (it
   should start healing) and with pills (it should take them).

### C. The new items

5. **Hazardous waste.** Find one, throw it down a corridor you are *not*
   standing in. → A green zone; the horde walks to it and **stays** for about
   fifty seconds. It should coat nobody — if your screen goes green from
   standing in it, that is a bug, and a specific one: that is the Boomer's job
   and this item is not supposed to have it.
6. **Flare gun.** Buy it ($3,500, SECONDARY). Shoot a Common.
   → It **does not die** — twelve damage — but it **catches fire** and burns
   down. One shell, four-second reload. If it kills on impact, the damage
   number is wrong.

### D. Bodies and frame rate

7. Kill twenty Commons with headshots. → **The bodies stay.** They used to
   vanish, because every headshot gibbed. Corpses stop at 48 and the oldest is
   recycled after that.
8. Play to a wave 12 horde and watch the frame rate. **On a phone if you have
   one.** This is the change most likely to cost performance and the least
   possible to verify by reasoning.

### E. The interface

The poll asked for a better UI and this build is the first pass. It is
deliberately not a redesign — the layout is unchanged — it is the measured
readability problems fixed.

11. **Look at an empty hotbar slot** (THROWABLE / HEALTH / PILLS with nothing
    in them). → Readable. That text was at **2.73:1** contrast, a long way under
    the 4.5:1 body text needs; it is now 4.80:1. It was the least legible thing
    on screen and it is what tells you what you are missing.
12. **Look at the hotbar as a whole.** → **Four visible steps**: bright orange
    is the gun in your hands, orange is a slot with something in it, dim orange
    is a state a panel wants to highlight, grey is empty. The held slot and a
    merely-filled slot used to draw the *same* border colour.
13. **Panels and buttons have edges now.** → The border was **1.47:1** against
    the panel it sat on, under the 3:1 at which a boundary is perceivable at
    all; it is 3.32:1 and two pixels instead of one, with square corners. This
    is the "the buttons aren't clear" report: a tile whose edge you cannot see
    is not a button.
14. **The map vote and the loadout.** → "The map you voted for" vs "a map
    somebody voted for", and "the slate you are editing" vs "the active slate",
    are now different colours. They were the same one.
15. **Open any menu — shop, loadout, settings, career, play.** → A band of
    **diagonal quarantine tape** under the title, on every one of them. It is
    drawn with a gradient rather than an image, so it needs no uploaded asset
    and cannot fail to load — which matters given the asset permissions above.
16. **The panels themselves.** → Dirtier. The surfaces were near-black with two
    points of warmth in them, which at that value is grey; they now carry six,
    which reads as damp concrete rather than as a dark app. The corner brackets
    are half again as large and the grime gradient is nearly twice as strong.
    **This is the visible half of the UI work** — the last pass was measurable
    and nearly invisible, this one is meant to be seen.

### F. The four fixes that landed before that

These are the newest code in the build and therefore the least exercised.

17. **Join an active match** — ideally from the console, which is where it was
    reported. → You arrive **standing on the floor**, not through it. You may
    stand still for a beat while the map finishes arriving; that is the fix
    working, not a freeze. If it lasts more than a second or two, say so.
18. **The dual pistols.** Buy them, look down. → **Two guns, one per hand**, an
    arm on each, spread apart rather than overlapping. Fire: the hands
    **alternate**, and the flash and tracer come from the gun that fired. Look
    at a teammate holding them — one pistol per hand there too.
19. **The tactical shotgun in the hand.** → Held at the wrist of the stock, not
    by its middle with the stock through the forearm. Check the client console
    for a `[PlaceholderFactory]` line naming models whose grip had to be
    guessed — that list is what to add a `Grip` attachment to.
20. **PS5 touchpad.** Move the cursor in a menu → the orange highlight goes away
    and the cursor clicks what it is over. Touch the stick → the highlight comes
    straight back. Tap the touchpad → glyphs stay **console**, not keyboard.

### G. The other two schemes

21. **Controller.** Fire, aim, reload, the D-pad slots. Tap **View** → pause
    menu. *Hold* **View** → ability cards, and no pause menu on release.
22. **Phone.** The eight-button pad, and the hotbar tiles as slot buttons —
    one tap selects, a second tap on a consumable uses it. Sprint is always on;
    there is no button and there should not be one.

`docs/CONTROLS.md` is the full table for all three.

---

## After that: what to actually watch for

Once it works, these are the judgement calls — ranked by how likely they are to
be *wrong*, not by how bad it would be.

1. **Does the fire button throwing feel right**, or does it eat clicks people
   meant as shots?
2. **Is the hazardous waste legible** as area denial rather than a grenade —
   from the floor, in a dark room, before anybody explains it?
3. **Frame rate during a horde on a phone**, now that bodies persist.
4. **The flare gun's damage.** Twelve is deliberately almost nothing.
5. **The dual pistols' spread and cant in first person.** How far apart the two
   guns sit, and their outward angle, were chosen by arithmetic rather than by
   looking at them. Too close, too far, or wrongly angled is a one-line fix —
   `DUAL_SPREAD`, `DUAL_CANT`, `DUAL_FORWARD` in `ViewmodelController`.
6. **Is anything missing now the bile jar is gone?** It was the short-range
   "get them off me" panic button. Between the pipe bomb and the molotov I do
   not think there is a hole, but that is a guess and a session will settle it.

---

## Reporting

A report needs three things to be actionable: **the build stamp**, **the
platform**, and **what you expected instead**. The third matters most — several
of the bugs fixed for this build were code doing exactly what a comment said it
should, where the comment had been wrong for months.
