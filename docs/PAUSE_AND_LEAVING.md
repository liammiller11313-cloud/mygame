# Pausing, and leaving a match

## The pause is real when you are alone

Roblox has no pause in a multiplayer game, and the pause menu has said so
honestly for a long time: *"pretending otherwise would be a lie told to one
player while three others fight."*

That is still true, and it quietly assumed a case Classic does not require.
`MinPlayersToStart` is 1 — solo is allowed and the Director scales down for it —
so you can be the only person in the server, and **a pause told to nobody is not
a lie**.

So the menu asks every time it opens and the **server** decides, counting the
players itself:

| | |
|---|---|
| Alone in the server, round running | Granted. The overlay says `PAUSED. YOU ARE ALONE IN THIS SERVER.` |
| Anyone else present | Refused. The overlay says `THE ROUND IS STILL RUNNING.` |
| Down on the floor, not alone | `YOU ARE STILL ON THE FLOOR. THIS DOES NOT STOP ANYTHING.` |

There is no reply remote and there does not need to be one. The answer is the
`FL_Paused` attribute on Workspace, which every client watches anyway — a
refusal is simply the attribute not changing.

### What actually stops

- **The horde.** InfectedService's loop stops. Burning stops with it, because
  the burn tick rides that loop — a player who paused while on fire should not
  come back to a corpse.
- **The Director.** Its clock freezes, so it resumes into the decision it was
  about to make rather than into a backlog of them.
- **The round.** The schedule is held still using the same push-`startedAt`-
  forward trick the ready gate has used since before pausing existed. No wave
  boundary, boss release or round end moves closer.

### What does not

**Ability cooldowns and other per-player timers.** They are between a player and
themselves, this is only reachable when that player is the only one here, and
the exploit — pausing to skip a cooldown — is cheating at solitaire. Freezing
them would mean a second clock in six more services for no gain anybody can feel.

**Physics.** A body mid-fall keeps falling. Anchoring the character on a pause
and unanchoring it after is a good way to drop somebody through the floor, and
the horde being frozen is what the pause was for.

### It ends itself

A **second player joining lifts the pause immediately** — from that moment the
honest answer changed. So does the pauser leaving, and the round ending under
them.

## Leaving a match means it now

`RETURN TO MAIN MENU` takes you out of the round. It does not leave the server:
that is what the Roblox menu is for, and the mode entries on the main menu are
how you move servers here.

Two things were broken about it and both are fixed.

**It was a no-op on the results screen.** The whole handler sat behind an
`isRunning()` check, and `RoundState` is `TeamWipe` there — which is the state
you are most likely to leave from. Nothing happened, and then the next round
started and spawned everybody in the server, putting you back in a match with
the menu still fading off your screen.

**The next round spawned you anyway.** Leaving now sets `FL_LeftMatch` on the
player. It outlives the round, and round start skips anybody carrying it.

**Coming back is a decision too.** Picking a mode from the main menu clears the
flag. Nothing else does.

A round is never started when every player in the server has left one — it stays
in the lobby instead. Without that guard the round would have no survivors to
spawn, `sawLivingSurvivor` would never become true, the wipe check would read
that (correctly) as "the round has not begun yet", and the round would run its
full seventeen minutes with a Director sending waves at an empty map.
