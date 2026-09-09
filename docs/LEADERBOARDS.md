# Leaderboards

Three global boards, every server, all time — plus the player tag that goes on a
row. `RANKS` on the main menu.

| Board | What it ranks | Shape |
|---|---|---|
| **FURTHEST** | Highest wave reached in a single round | best-ever |
| **VICTORIES** | Rounds survived to the end | running total |
| **BODY COUNT** | Infected put down, lifetime | running total |

Three rather than one, deliberately. A single board answers one question and
tells everybody who cannot win it that they are nobody. These measure different
virtues: FURTHEST is skill and nerve in one number and the only board where a
first-time player can take a top rank in an afternoon; VICTORIES is persistence,
which is not the same thing; BODY COUNT rewards nothing but time and everybody
knows it, which is exactly why it should exist and exactly why it must not be
the only one.

---

## The player tag

A row is a **rank**, a **tag**, a **name** and a **number**.

The tag is the callsign the player earned on the pass track, drawn in the accent
colour they earned with it — so a leaderboard is also an advertisement for the
thing that unlocks them, and somebody scrolling it can see what the ranks above
are wearing.

**It is earned, not typed, and that is the deliberate half.** Free text on a
global leaderboard is a moderation surface that renders to every player in the
game before anybody looks at it. Letting players choose their own tag is the
intention; when it lands it lands as a **choice among things they have
unlocked**, and `LeaderboardConfig.tagFor` is where the two meet.

### Why most rows have no tag

A callsign rides `Attributes.Player`, which every client already has for
everybody **in their own server**. For the ninety-odd rows belonging to players
who are somewhere else, there is nothing to look up and no request that would
produce one.

That reads like a limitation and is the opposite: the handful of names you
recognise on a global board are exactly the ones that light up.

---

## How it works

### Publishing

At the end of a round, for every player who was actually in it (the same roster
rule `ProgressionService` uses — joining during the results screen does not count
as having reached wave nine):

1. Fold the round into the profile's **lifetime** totals. `ProfileService.recordLifetime`
   applies each field's own rule — a *best* is replaced only when beaten, a
   *total* is added to — and returns **which fields moved**.
2. Publish only those. A best that was not beaten costs no request.

Nothing is published mid-round. A board that updated live would be a board that
has a player on it for a wave they died on.

### Reading

One `GetSortedAsync` page per board, cached on the server for
`LeaderboardConfig.CacheSeconds` (two minutes), and **only when somebody asks** —
there is no timer, so an empty lobby fetches nothing. Ten players opening the
panel together produce one fetch, and the result is broadcast to all of them
rather than to whoever happened to ask first.

The staleness is real and the panel says so in words. A player who has just
finished a round may not see themselves move for two minutes, and a board that
silently disagreed with the round they just played is a board they stop
believing.

### Why an OrderedDataStore

Because "the top hundred" is a question a plain DataStore cannot answer — it
hands back the key you name, not the largest hundred keys. The cost is that an
OrderedDataStore holds **one signed integer per key**, so there is one store per
board and nothing but a number lives in them. Names are resolved at serve time
(`GetNameFromUserIdAsync`, cached for the life of the server) and tags are
resolved on the client, from attributes it already has.

### Your own line

Pinned under the list, always. It shows your **number** always and your **rank**
only when you are somewhere on the page — because there is no request on an
OrderedDataStore that answers "what rank is this one player" without walking the
whole thing, and inventing an answer is worse than not having one.

---

## Resetting a board

`LeaderboardConfig.Season`. An OrderedDataStore cannot be emptied — there is no
call for it — so the only way to start over is to stop reading the old store.
Bumping the season does exactly that and leaves the previous season intact
underneath, in case the reset was the mistake.

Change it **for a reset and nothing else**. If a stat's *meaning* changes, change
the board's `id` instead: that is a smaller and more honest break.

---

## When it does not work

Studio has no DataStore access unless it is switched on, and a live server can be
refused. Every call is `pcall`ed and every failure ends in a line of text on the
panel rather than an error:

- `GLOBAL RANKS ARE OFF IN THIS SESSION` — no DataStore access at all. Normal in
  Studio, not normal in production.
- `THE BOARDS ARE UNAVAILABLE RIGHT NOW` — the request was refused.
- `NOBODY HAS MADE THIS BOARD YET. GO FIRST.` — it worked and the board is empty,
  which for a new season is the correct answer.

A leaderboard is the least important screen in the game and must never be the
thing that stops a round starting.

---

## Adding a board

1. An entry in `LeaderboardConfig.Boards` — `id`, `displayName`, `blurb`, `stat`,
   `mode`.
2. The `stat` must already be a field of `LeaderboardConfig.blankLifetime`. That
   table holds more fields than there are boards on purpose: a lifetime counter
   that was never started cannot be started retroactively, so `bossKills`,
   `revives` and the rest have been counting since launch against the day
   somebody wants a board for one.

That is the whole change. The panel builds its tabs from the list, the service
publishes from it, and the profile folds each field by `mode`.
