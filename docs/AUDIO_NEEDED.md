# Sound & Music Brief — Fading Light

Every id in `src/shared/Config/AudioConfig.lua` is empty on purpose. Audio asset
ids are account-specific and can't be guessed — a made-up number either fails to
load or pulls somebody else's unrelated audio into your game. So the game runs
silent until you fill them in, warning once per missing id and then staying quiet.

Volumes, pitch ranges, rolloff distances and voice priorities are **already
tuned** in that file. You only supply ids.

> **The single most important thing in this document:** get 3–5 variations of
> anything you hear more than once a second (gunshots, flesh impacts, common
> infected vocals). The engine pitch-shifts them automatically. One unvaried
> gunshot at 900rpm turns an SMG into a buzzsaw, and one unvaried zombie groan
> turns a horde of 46 into an obvious copy-paste.

---

## TIER 1 — the game feels broken without these

### Weapon fire
By an enormous margin the sound you hear most. Each of your guns gets its own.

| Gun | What it should sound like |
|---|---|
| **M1911A1** | Dry, sharp, slappy .45 crack. Short tail. It's the fallback gun — it should sound *adequate*, not powerful. |
| **.357 Magnum** | Enormous. Slow. Room-filling with a long concrete tail. Firing it indoors should feel like a mistake you made. |
| **Shotgun** | Two layers: a deep chest-hitting boom, then the mechanical *chk-CHK* of the pump as its own separate sound. The pump is half of why shotguns feel good. |
| **PPSh-41** | Frantic, tinny, high-cyclic. A sewing machine. 71 rounds of it. |
| **Kriss Vector** | Very fast, flat, almost no low end. Reads as a blur rather than individual shots. |
| **MP7A1** | Light, papery, high-pitched. Small caliber energy. |
| **UMP-45** | Slower, meatier, thumpier than the other SMGs. You should hear the .45. |
| **AKS-74U** | Sharp bark with a distinctive metallic ring. Louder than it should be for its size. |
| **AKM** | Deep, heavy, throaty. The most *aggressive* sounding gun in the set. |
| **AK-12** | Tighter, cleaner, more modern than the AKM. Same family, less snarl. |
| **M4A1** | The reference AR sound: balanced crack, moderate tail. |
| **HK416A5** | Slightly higher and snappier than the M4. |
| **Mk 18 CQBR** | Short barrel = louder, blastier, more concussive. |
| **Scoped Mk-18** | Same body as the Mk 18, but with more air around it. |
| **M1A EBR** | Big, authoritative, single-shot 7.62. Long tail that carries across the map. |
| **Machete** | Not a gunshot — a fast air *whoosh*. |

Also needed: **dry fire** (a hollow click — the player has to *feel* empty before
they read the number), **mag out / mag in / bolt release**, **shell insert** for
the shotgun, and **pump**.

### Flesh impact — the confirmation you connected
Only two sounds, and they carry an enormous amount of weight:

- **Flesh** — a wet, heavy thud. Close-mic'd, no reverb.
- **Bone** — a sharper, higher crack. **This is the headshot sound.** If flesh and
  bone sound the same, the 4× headshot multiplier has no audible existence and
  aiming stops feeling like it matters.

### Gore
- **Dismember** — a wet tearing rip. Fabric and meat.
- **Gib** — a burst. Heavier, lower, with debris scatter in the tail.
- **Decapitate** — a clean sharp *shk* plus a wet aftermath.
- **Body fall** — a limp, boneless flop. No impact "thud" — bodies aren't rocks.

---

## TIER 2 — the early-warning system

In Left 4 Dead these are not flavour. A player who knows the Hunter growl
survives; one who doesn't, doesn't. **Treat these as gameplay, not decoration.**
Each needs to be identifiable in under half a second through a firefight.

| Sound | Character |
|---|---|
| **Hunter idle** | A low, tightening growl that builds. The sound of something *deciding*. This is your only warning before it leaps. |
| **Hunter pounce** | A shriek, launched. Doppler-ish. |
| **Jockey idle** | High, unhinged giggling. Genuinely unpleasant. It should make players turn around. |
| **Jockey ride** | Cackling laughter that continues while it's steering someone — that's how teammates locate the victim. |
| **Rusher idle** | Fast, ragged, panting breath. Something moving quickly toward you. |
| **Rusher charge** | A bellow as it commits. **This is the dodge cue** — it needs a hard, unmistakable transient at the front. |
| **Witch cry** | Distant, quiet sobbing. Audible from very far away, and genuinely unsettling. This one should make players *slow down*. |
| **Witch summon** | A rising wail that resolves into a scream — the moment she calls the horde. Everyone in the round should know what just happened. |
| **Witch startle** | A shriek, then silence. |
| **Tank roar** | The set-piece announcement. Huge, guttural, longer than you think it needs to be. |
| **Tank footstep** | Heavy, low, ground-shaking. Loops while it runs. Should be audible through walls. |

### Common infected
`Idle`, `Alert`, `Attack`, `Death` — **get many variants of each.** These play
forty times a minute. Idle should be a low background murmur of groaning; Alert is
the moment a crowd notices you and turns, and it should be a genuine *chorus*, not
one voice.

---

## TIER 3 — polish

**Surface impacts:** Concrete, Metal, Wood, Glass, Water, Dirt. Material variety is
most of what makes a firefight feel like it's happening in a *place* rather than in
a shooting gallery.

**Survivor:** Hurt grunts, incap (a heavy fall plus pained breathing), death,
revived (a gasp — relief), medkit use, pills, **looped labored breathing** that
fades in below the hurt threshold, footsteps.

**UI:** Pickup, prompt appear, objective change, **wave cleared** (a short release
sting — this is the reward for surviving 90 seconds of pressure, make it land),
hitmarker tick, and a **distinct headshot hitmarker tick**. Those two little ticks
are a surprisingly large share of why shooting feels good.

---

## MUSIC

All looped and cross-faded by the Director, never cut. Each cue gets faded in and
out repeatedly, so **avoid strong intros** — anything with a big downbeat at bar 1
will sound wrong every time it fades up mid-round.

| Cue | When | Character |
|---|---|---|
| **Ambient** | During a breather | Barely music. Sparse drones, distant sirens, wind. Texture that makes the silence uncomfortable. |
| **Buildup** | Last 8s of a breather | A pulse enters. Low, insistent, accelerating. Something is coming and everyone knows it. |
| **Horde** | Wave active | Full percussion-led drive. Relentless rather than melodic — this plays for two minutes at a time and a tune would wear out. |
| **Tank theme** | Tank alive | The big one. Heavy, brass-and-drums, unmistakable. Everything else ducks under it automatically. |
| **Witch theme** | Near the Witch | Strings, detuned, wrong-sounding. Quiet. It should make players uneasy rather than aggressive. |
| **Wave cleared** | Wave survived | 3–4 second release sting. Resolution. |
| **Defeat** | Team wiped | One-shot. Low, final, no hope in it. |
| **Victory** | Survived 17:00 | One-shot. Earned, exhausted, not triumphant — you survived, you didn't win. |

---

## Filling them in

```lua
[Enums.Weapon.M1911A1] = {
    id = "rbxassetid://YOUR_ID_HERE",   -- was ""
    volume = 0.7,
    ...
}
```

If you're sourcing a few at a time, the order that buys the most feel per sound:
**weapon fire → flesh/bone impact → gore → special infected calls → everything else.**
