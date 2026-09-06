# Controls, on all three platforms

Generated from `InputController`'s own keymap. If this table and the game
disagree, the game is right and this file is stale — regenerate it rather than
editing it by hand.

| Action | Keyboard | Controller | Touch |
|---|---|---|---|
| Fire | Left mouse | RT | FIRE button |
| Aim | Right mouse | LT | AIM button |
| Reload | R | Y | RELOAD button |
| Shove | Middle mouse | RB | PUSH button |
| Melee weapon | V | LB | MELEE button |
| Sprint | Shift | L3 | *always on* |
| Jump | Space | A | JUMP button |
| Crouch | Ctrl / C | B | CROUCH button |
| Use / revive / pick up | E | X | USE button |
| Use the held item | H, or **fire** | **Fire** (RT) | **FIRE button** |
| Throw | G, or **fire** | **Fire** (RT), or D-pad ► twice | **FIRE button**, or the tile twice |
| Swap weapon | — | D-pad ◄ | — |
| Primary | 1 | — | hotbar tile |
| Secondary | 2 | — | hotbar tile |
| Throwable | 3 | D-pad ► | hotbar tile |
| Health item | 4 | D-pad ▼ | hotbar tile |
| Pills | 5 | D-pad ▲ | hotbar tile |
| Ping | Q | R3 | USE button, when there is nothing to use |
| Backpack | B | pause menu | pause menu |
| Requisitions | T | pause menu | pause menu |

**On the three dashes that are not gaps.** Touch has no sprint button because
touch *always* sprints — the pad is eight buttons wide on a five-inch screen and
a ninth for something a player wants on permanently is a button that is always
held. The five slot rows have no pad or touch button of their own because the
hotbar is already on screen saying what is in each slot: on touch its tiles are
the tap targets, and a controller reaches the three that matter on the D-pad.
One tap selects; a second tap on a consumable uses it, the same press-again rule
the D-pad follows.

## On a console with a pointer

A PS5 drives a cursor with the DualSense touchpad, and an Xbox has a virtual
cursor. Both arrive as ordinary mouse input, and the menus now get out of their
way: while the pointer is moving, the orange selection highlight is cleared and
the cursor clicks whatever it is over. Touch the stick or the D-pad and the
highlight comes straight back where it was.

A console also stays a console. Clicking the touchpad used to flip the game to
the desktop scheme and show keyboard glyphs on hardware with no keyboard
attached; a ten-foot interface now refuses that outright.

## The trigger spends what is in your hand

With a **gun** out, the fire button shoots. With anything else out, it uses that
thing — because a player holding a medkit and clicking has told you exactly what
they want, and the alternative is a click that does nothing at all.

| Selected | Fire button does |
|---|---|
| Primary / Secondary / Melee | shoot or swing |
| Health item | start healing yourself |
| Pills / Adrenaline | take them |
| Throwable | **throw it, where you are looking** |

The throwable was the last one to join, and it is the one that mattered most:
until it did, a pipe bomb on the trigger produced no throw, no sound and no
message — silence a player cannot tell apart from a broken item. `G` and `H`
both threw it and nothing on screen said so. On a controller or a phone there
was no throw binding at all, so the fire button is now the *only* way those
players can throw without knowing an undocumented gesture.

It aims down the **camera**, not the character. A bomb goes where the crosshair
is — up onto a balcony, down a stairwell — rather than flat out in front of you.
That is true on **all three** schemes now. It was not: selecting a throwable
twice on a pad or a phone used to send it through the *use* path, which carries
no direction at all, so the server aimed it with a level look vector and every
console and mobile throw went at the floor in front of the player however far up
they were looking.

## Three deaths and your round is over

A survivor gets **three deaths per round**. The first two are recoverable — a
teammate's defibrillator, a rescue closet, or the breather's own respawn. The
third ends your round: no defib, no closet, no breather, and the prompt to
defibrillate you stops being offered so nobody spends one finding that out.

The death card counts down to it, so nobody discovers their last life by
spending it. Being out is **not** the same as leaving: you keep your body, you
keep your score, you spectate the team, and the next round starts you at full
health with a clean ledger.

Together with the incap ledger — a third down kills you — that is nine falls
before the game stops handing you another one.

`GameConfig.Survivor.DeathsPerRound`.

## When you die you watch the team

Dying used to unlock the camera and leave it pointed at your own body, so a
player killed early spent the rest of a seventeen-minute round looking at the
spot they died in while the fight walked away from them.

Now it follows a teammate. **Fire cycles forward, Aim cycles back** — the same
two buttons on all three platforms, chosen because both already exist everywhere
and neither means anything while you are dead. A card under the round clock names
who you are watching and which button changes it.

It is a camera choice and nothing else: no remote, no server state, no
permission. Everyone's character is already replicated to everyone, so the worst
failure available is looking at the wrong person.

## The trigger uses what is in your hands

With a **medkit or pills** selected, the fire button uses them on yourself — the
same button, on all three platforms. `H` still works, and so does pressing the
slot key a second time; they were the only two ways before, and a player who knew
neither reasonably concluded the game would not let them heal.

The heal runs on its own timer with a bar, so a click starts it and holding the
button down is harmless. It is gated on the slot rather than on what you are
carrying: pull the trigger with a **throwable** out and nothing is spent.

## Touch

**The prompt is the button.** When something is usable, the prompt in the middle
of the screen becomes a panel you tap — "TAP TAKE UMP-45", "HOLD REVIVE NICK".
Press and hold for anything with a bar; a plain tap for everything else. The
corner USE button still works and is still there; the prompt is where a thumb
actually goes, because it is what the eye is already reading.

**The hotbar is the other button.** Tap a slot to select it, tap it again to
spend a consumable. That is how a phone player takes a medkit or pills — there
is no separate USE-ITEM button and there does not need to be one.

Roblox's own jump button is suppressed and replaced, because it draws in the
bottom-right corner where the pad already lives and the two fought for the same
thumb.

## Controller

The layout is Left 4 Dead 2's, not Roblox's default:

- **X** is use, revive and pick up. **Y** is reload. A is jump, B is crouch.
- **LB** swings the melee weapon, **RB** shoves.
- The **D-pad** is items, in L4D2's order rather than the 1-5 order: ► throwable,
  ▼ health, ▲ pills, ◄ swaps between primary and secondary.
- **Abilities** are on the view button: **hold View, then press a face button.**
  Every other button on the pad is spoken for and Start belongs to Roblox, so the
  pause menu was the only thing that could afford to share — a tap still opens
  it, and a hold opens the ability layer instead.
- Every menu takes the stick and A/B.

Nothing draws a keyboard glyph on a controller. If you see a letter on a prompt
that is not a face button, that is a bug — report it with the screen it was on.

## What to look for when testing

| | Check |
|---|---|
| **Touch** | Can you revive a downed teammate? Take a medkit and use it? Place and confirm an ability? |
| **Controller** | Does every prompt name a face button rather than a letter? Can you reach every menu without touching a mouse? |
| **Tablet** | Does the JUMP button work? This is the one open report on the list — see docs/BACKLOG.md #1. |
| **All three** | Does the round-timer area of the screen ever stack two cards on one another? |
