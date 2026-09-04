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
| Sprint | Shift | L3 | — |
| Jump | Space | A | JUMP button |
| Crouch | Ctrl / C | B | CROUCH button |
| Use / revive / pick up | E | X | USE button |
| Use the held item | H | — | — |
| Throw | G | — | — |
| Swap weapon | — | D-pad ◄ | — |
| Primary | 1 | — | — |
| Secondary | 2 | — | — |
| Throwable | 3 | D-pad ► | — |
| Health item | 4 | D-pad ▼ | — |
| Pills | 5 | D-pad ▲ | — |
| Ping | Q | R3 | — |
| Backpack | B | — | — |
| Requisitions | T | — | — |

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
