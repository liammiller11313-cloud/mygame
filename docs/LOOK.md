# The look

Everything about how this game reads is in `UITheme` and nothing is a literal in
a controller. This is the map of which number does what, and why the ones that
look arbitrary are not.

## The palette is three colours

Near-black, an off-white, and one orange. That is the whole system.

| | |
|---|---|
| **Background / Panel** | warm near-black. Not pure black — `#000` is a hole punched in an OLED panel and it makes the orange beside it look radioactive |
| **TextPrimary** | off-white, never `#fff` |
| **Accent** | the orange. Objective lines, prompts, wave calls — anything meant to be read before the player thinks |

Red is the one colour that means *something is wrong*, which is exactly why it
works. It is spent on health, danger and the damage vignette and nowhere else.

The single deliberate exception is `SurvivorColors`: telling four teammates apart
through a wall is a **function**, not decoration, and four shades of orange
cannot do it. They stay distinguishable but are all pulled warm.

## The dread layer

Two full-screen effects under and over everything, for the whole session. Neither
says anything — that is the point. Every other layer in this game is a readout,
and a game that only ever draws information is a game played in a clean
rectangle.

### The edges

A black vignette that is always there and **breathes** on an eighteen-second
period. Slow enough that nobody consciously sees it move: a still frame reads as
a picture, a frame that is never quite still reads as a place.

This is not the vignette in `UITheme.Vignette` — that one is a readout, it
reddens as you get hurt and is honestly blank when you are fine. The consequence
nobody noticed for a long time is that a **healthy survivor played inside a
perfectly clean frame**. The dread edges draw *under* the red one, so at full
health you get only black edges and the red composites over a frame that already
had them.

The main menu does not get them, deliberately: it draws its own, stronger, tuned
against its own photograph and its own two text columns. Two vignettes over one
picture is a muddy corner and a number nobody can tune.

### The haze

Two full-screen gradients at angles that share no common factor, re-randomised
fourteen times a second. Where they cross they interfere, and the frame develops
a slow uneven cast that keeps moving — light through dirty glass.

**It is not film grain and is deliberately not called that.** A `UIGradient`
interpolates smoothly between at most twenty stops, so the finest thing it can
draw is soft banding tens of pixels across, not speckle.

> **Want real grain?** Upload a seamless noise tile and put its id in
> `UITheme.Dread.HazeImage`. The layers become that tile, repeated at
> `HazeTileSize` and jerked to a new offset on the same clock — per-pixel
> speckle, no code change. It is empty by default because an image that fails to
> load is a broken square over somebody's HUD, and an atmosphere layer must never
> be able to do that.

The haze draws **over** everything including the menu, because it is grime on the
glass the whole game is seen through and a menu exempt from it reads as a
different, cleaner screen. At 4.5% black it costs nothing legible even over body
text. Above the fade, so a transition to black keeps its texture at the one
moment there is nothing else to look at; below the splash, so the boot logo is
the one image not seen through dirt.

**Turning it down:** `EdgeStrength` and `HazeTransparency` are the two numbers.
Bigger transparency = fainter. Phones get `MobileScale` of the edge strength — a
smaller screen held closer, with the least frame budget to spend on something
nobody is looking at.

## The main menu

A photograph, and everything that makes it this game's photograph is stacked on
top in `UITheme.Backdrop` rather than baked into the upload. A grade written into
an asset is a grade nobody can change without re-exporting.

| | |
|---|---|
| `Tint` | multiplied into the image. The only number here that is purely taste |
| `DimDark` / `DimBright` | a black sheet, and what the flicker actually drives |
| `VignetteExtent` | four edge gradients, **measured against `COLUMN_X`** in `MainMenuController` — anything that moves the columns has to come back to this number |
| `Overscan` / `Drift*` | the image is oversized and never stops moving |

The scrim is not decoration. `DimBright` is the *lightest* the backdrop is ever
allowed to be and it is still 60% black, because the menu draws white headline
type straight over it. **A background that looks beautiful in isolation and eats
the word PLAY has failed.** Raise it and check the title, not the picture.

### The flicker

One number from 0 to 1, built from three things that disagree: a slow breath, a
**stutter** every few seconds, and a rare **brown-out**. The stutter is the one
that reads as a failing bulb rather than a dimmer — real filaments do not fade,
they interrupt. It never reaches zero, because a backdrop that goes fully black
reads as the game having crashed.

The title runs its own fixture on the same idea (`TitleFlicker`), so the word
LIGHT and the rule under it flicker together as one failing tube.

## Motion

Everything animates fast. A HUD element that takes 300ms to appear is one the
player has already stopped looking for. `UITheme.Motion` holds the whole scale
from `FastIn` (0.08) to `Cinematic` (0.9).

## Scale

`UITheme.Scale` owns the reference-pixel convention with a 0.75 floor on phones,
so two layers never disagree about how big a stud of interface is. See
`ScaleLayer`.

---

## Where the guards are

Two `scripts/audit.py` checks exist because of bugs in this area:

- **A cue that does not exist.** Every sound played by name must have a row in
  `AudioConfig`. A missing one warns once at startup and is then silent forever.
- **A menu photograph that never arrives.** Not an audit check — it cannot be
  one, because whether an asset resolves is a fact about the client running it,
  not about the source. `MenuBackdrop.verifyImage` preloads the id once and warns
  by name if it fails, because the failure mode is a black menu that looks
  deliberate. The usual cause is a **decal** id where an image id was wanted.
- **A property the class does not have.** Setting one throws, and inside a
  controller's `init()` the boot runner swallows it and reports one failed
  service among forty — the symptom is a layer of the interface that silently
  does not exist. This check exists because the dread layer set `Active` on a
  `ScreenGui`, which is a real property on `GuiObject` and not on that.
