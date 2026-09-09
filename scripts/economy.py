#!/usr/bin/env python3
"""
Models Fading Light's economy from the real config, and reports how long the
roster actually takes to unlock.

EconomyConfig's header claims "roughly 30-40 rounds". This is what makes that
claim true rather than asserted: it reads the real catalogue and the real wave
table, and fails when the pacing drifts out of the band.

    ./scripts/economy.py            report
    ./scripts/economy.py --check    report, and exit 1 on drift

── THE ONE THING THIS CANNOT DERIVE ──────────────────────────────────────────
How many infected a player kills in a round. The Director is a feedback loop:
it holds a target population and replaces what you kill, so the kill count is a
function of how fast the team shoots rather than of anything written down. So
that number is an ASSUMPTION, stated below and printed in the report. Everything
else — wave durations, pacing targets, prices, payouts — is read from the config.

If the live game turns out to play faster or slower than TEAM_KILLS_PER_SECOND,
change it here and re-run; the prices follow from it.
"""

import re
import sys
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent


def read(rel):
    return (ROOT / rel).read_text(encoding="utf-8")


ECON = read("src/shared/Config/EconomyConfig.lua")
PROG = read("src/shared/Config/ProgressionConfig.lua")
MODE = read("src/shared/Config/GameModeConfig.lua")
DIRECTOR = read("src/shared/Config/DirectorConfig.lua")

# What one weapon is worth, in won rounds. Change this only with the header.
#
# This was an absolute "the roster unlocks in 30-40 won rounds", and it held
# while the roster was twenty weapons. It is not the invariant it looked like.
# What the number was actually protecting is that EACH weapon costs about two
# won rounds — near enough that the next one is always in sight, far enough that
# buying it meant something. 39 rounds across 20 weapons WAS 1.95 each; the 39
# was the consequence, not the rule.
#
# Holding the absolute while the roster grows forces one of two bad answers:
# halve every price, so no purchase is a decision any more, or raise income,
# which drags kill share below the 45% EconomyConfig documents. Both break
# something real to protect a number that was only ever a proxy.
#
# So the target is per weapon, and the absolute is a sanity ceiling underneath
# it — because "two rounds each" across two hundred weapons is still nonsense,
# and a rule with no upper bound is not a rule.
PER_WEAPON_MIN, PER_WEAPON_MAX = 1.6, 2.4
ABSOLUTE_CEILING = 90

# The per-kill band the design promises, read from the config that enforces it.
BAND_MIN = int(re.search(r"EconomyConfig\.MinKillReward = (\d+)", read("src/shared/Config/EconomyConfig.lua")).group(1))
BAND_MAX = int(re.search(r"EconomyConfig\.MaxKillReward = (\d+)", read("src/shared/Config/EconomyConfig.lua")).group(1))

# ── the assumptions, all in one place ───────────────────────────────────────
# A four-survivor team fighting a horde held near its target population. At the
# Director's SustainPeak target of 46 alive this is conservative; during Relax it
# is generous. It is the average across a whole round that matters.
TEAM_KILLS_PER_SECOND = 1.2
PLAYERS = 4
# One player's share of the team's kills. Above an even 25% because the model is
# for a DECENT player — the one the pacing target is written for.
KILL_SHARE = 0.35
HEADSHOT_RATE = 0.25


def scalar(name):
    m = re.search(rf"^EconomyConfig\.{name} = ([0-9_]+)$", ECON, re.M)
    assert m, f"EconomyConfig.{name} not found"
    return int(m.group(1).replace("_", ""))


def kill_rewards():
    block = ECON.split("EconomyConfig.KillReward")[1].split("})")[0]
    return {k: int(v) for k, v in re.findall(r"\[Enums\.Infected\.(\w+)\] = (\d+)", block)}


def catalogue():
    block = ECON.split("EconomyConfig.Catalogue")[1].split("\n} :: { ShopEntry })")[0]
    out = []
    for m in re.finditer(
        r"id = (Enums\.Weapon\.\w+|\"\w+\"),\s*\n?\s*category = \"(\w+)\",\s*\n?\s*price = (\d+),?"
        r"(\s*\n?\s*soon = true)?(\s*,?\s*prestige = true)?",
        block,
    ):
        out.append(
            {
                "id": m.group(1).replace("Enums.Weapon.", "").strip('"'),
                "category": m.group(2),
                "price": int(m.group(3)),
                "soon": bool(m.group(4)),
                # Priced far above the ladder and deliberately outside the
                # pacing target. See the field's own note in EconomyConfig.
                "prestige": bool(m.group(5)),
            }
        )
    return out


def abilities():
    """The other Dollars sink, which this model could not see until now.

    Abilities are permanent unlocks bought with the same currency as the weapon
    roster, and nothing here knew they existed — so "the roster costs N rounds"
    was answering a smaller question than it looked like it was answering. They
    are reported SEPARATELY rather than folded into the roster sum, for the same
    reason the RPG-7 is: the per-weapon pacing target is about the weapon ladder,
    and averaging a five-item set into a thirty-two-item one describes neither.
    """
    src = read("src/shared/Config/AbilityConfig.lua")
    out = []
    for m in re.finditer(
        r"id = Enums\.Ability\.(\w+),\s*\n\s*displayName = \"([^\"]+)\","
        r"(?:.*?\n)*?\s*price = ([\d_]+),",
        src,
    ):
        out.append({"id": m.group(1), "name": m.group(2), "price": int(m.group(3).replace("_", ""))})
    return out


def waves():
    """Every wave's duration and how hard it leans on the horde."""
    block = MODE.split("GameModeConfig.Waves = {")[1]
    out = []
    for chunk in re.split(r"\n\t\{", block):
        d = re.search(r"duration = (\d+)", chunk)
        p = re.search(r"populationScale = ([\d.]+)", chunk)
        s = re.search(r"specialInterval = (\d+)", chunk)
        b = re.findall(r"Enums\.Infected\.(\w+)", chunk)
        if d and p:
            out.append(
                {
                    "duration": int(d.group(1)),
                    "population": float(p.group(1)),
                    "specialInterval": int(s.group(1)) if s else 0,
                    "bosses": b,
                }
            )
    return out


REWARDS = kill_rewards()
CATALOGUE = catalogue()
ABILITIES = abilities()
WAVES = waves()

START = scalar("StartingDollars")
HEADSHOT = scalar("HeadshotBonus")
VICTORY = scalar("VictoryBonus")
DEFEAT = scalar("DefeatBonus")
WAVE_BONUS = scalar("WaveBonus")
CAP = scalar("MaxPerRound")


def round_income(waves_reached: int, won: bool) -> dict:
    """What ONE player banks for a round that got this far."""
    commons = specials = bosses = 0.0
    seconds = 0
    for wave in WAVES[:waves_reached]:
        seconds += wave["duration"]
        # Commons scale with how hard the wave leans on the horde.
        commons += TEAM_KILLS_PER_SECOND * wave["duration"] * wave["population"]
        if wave["specialInterval"] > 0:
            specials += wave["duration"] / wave["specialInterval"]
        bosses += len(wave["bosses"])

    mine = lambda n: n * KILL_SHARE  # noqa: E731

    common_pay = mine(commons) * (REWARDS.get("Common", 2) + HEADSHOT * HEADSHOT_RATE)
    special_pay = mine(specials) * (REWARDS.get("Hunter", 5) + HEADSHOT * HEADSHOT_RATE)
    boss_pay = mine(bosses) * REWARDS.get("Tank", 8)
    bonus = (VICTORY if won else DEFEAT) + WAVE_BONUS * waves_reached

    kills = common_pay + special_pay + boss_pay
    return {
        "kills": kills,
        "bonus": bonus,
        "total": min(kills + bonus, CAP),
        "seconds": seconds,
        "commons": mine(commons),
        "specials": mine(specials),
        "bosses": mine(bosses),
    }


def prog_scalar(name):
    """A plain number off ProgressionConfig, the way scalar() reads EconomyConfig."""
    m = re.search(rf"^ProgressionConfig\.{name} = ([0-9_]+)$", PROG, re.M)
    assert m, f"ProgressionConfig.{name} not found"
    return int(m.group(1).replace("_", ""))


def xp_table():
    block = PROG.split("ProgressionConfig.Xp = table.freeze({")[1].split("})")[0]
    return {k: int(v) for k, v in re.findall(r"^\t(\w+) = (\d+),", block, re.M)}


def pass_costs():
    """Every tier's price, from the track's length and the same linear rule the
    config uses. Counted rather than assumed: the track is a list somebody adds
    to, and a hard-coded 20 here would go stale the first time they do."""
    block = PROG.split("local PASS_TRACK: { PassTier } = table.freeze({")[1].split("\n})")[0]
    tiers = len(re.findall(r"kind = \"", block))
    base, step = prog_scalar("PassCostBase"), prog_scalar("PassCostStep")
    return [base + step * (t - 1) for t in range(1, tiers + 1)]


def round_xp(r: dict, won: bool, waves_reached: int, revives: float = 1.0) -> float:
    """What ONE player's round is worth in experience.

    Commons are the remainder, exactly as ProgressionService computes them:
    StatsService's `kills` is the total, so paying the flat Common rate on it
    would pay a Tank at the Common rate on top of the Boss rate it already got.
    """
    xp = xp_table()
    kills = r["commons"] + r["specials"] + r["bosses"]
    return (
        r["commons"] * xp["Common"]
        + r["specials"] * xp["Special"]
        + r["bosses"] * xp["Boss"]
        + kills * HEADSHOT_RATE * xp["Headshot"]
        + revives * xp["Revive"]
        + waves_reached * xp["WaveReached"]
        + (xp["Victory"] if won else 0)
    )


def level_cost(level: int) -> int:
    base, step = prog_scalar("XpBase"), prog_scalar("XpStep")
    return 0 if level >= prog_scalar("MaxLevel") else base + step * (level - 1)


def scrip_through(level: int) -> int:
    per, milestone, every = (
        prog_scalar("ScripPerLevel"),
        prog_scalar("ScripMilestone"),
        prog_scalar("MilestoneEvery"),
    )
    return sum(per + (milestone if k % every == 0 else 0) for k in range(1, level))


def progression(won: dict) -> None:
    """The second axis, printed against the same round as the first.

    Informational, not a gate. The Dollars checks below fail the build because
    an unaffordable roster is a broken game; a progression curve that has
    drifted is a design call somebody should SEE, and failing on it would only
    teach whoever is tuning it to edit the threshold.
    """
    per_round = round_xp(won, True, len(WAVES))
    print(f"  a won round is worth {per_round:,.0f} XP\n")

    print(f"  {'':<12}{'total XP':>11}{'won rounds':>12}{'that level':>12}{'scrip':>9}")
    for level in (5, 10, 20, 50):
        total = sum(level_cost(k) for k in range(1, level))
        print(
            f"  level {level:<6}{total:>11,}{total / per_round:>12.1f}"
            f"{level_cost(level) / per_round:>12.2f}{scrip_through(level):>9,}"
        )

    costs = pass_costs()
    track = sum(costs)
    on_levels = next(
        (lv for lv in range(1, prog_scalar("MaxLevel")) if scrip_through(lv) >= track), None
    )
    daily = prog_scalar("DailyQuests")
    quest_scrip = [int(m) for m in re.findall(r"^\t\tscrip = (\d+),", PROG, re.M)]
    per_day = daily * (sum(quest_scrip) / len(quest_scrip)) if quest_scrip else 0
    print(f"\n  the pass is {len(costs)} tiers, {track:,} scrip in total")
    print(f"  levelling alone pays for it by level {on_levels}")
    if per_day:
        print(f"  {daily} dailies a day pays for it in {track / per_day:.0f} days\n")


def main() -> int:
    buyable = [e for e in CATALOGUE if not e["soon"] and e["price"] > 0 and not e["prestige"]]
    free = [e for e in CATALOGUE if not e["soon"] and e["price"] == 0]
    soon = [e for e in CATALOGUE if e["soon"]]
    prestige = [e for e in CATALOGUE if e["prestige"] and not e["soon"]]
    roster = sum(e["price"] for e in buyable)

    bar = "─" * 68
    print(f"{bar}\n  FADING LIGHT — economy model\n{bar}\n")

    print(f"  {len(WAVES)} waves, {sum(w['duration'] for w in WAVES) / 60:.0f} minutes of combat")
    print(f"  ASSUMED: the team kills {TEAM_KILLS_PER_SECOND}/s, one player takes "
          f"{KILL_SHARE:.0%} of it, {HEADSHOT_RATE:.0%} headshots")
    print("  (everything else below is read from the config)\n")

    won = round_income(len(WAVES), True)
    deep = round_income(len(WAVES) - 2, False)
    early = round_income(2, False)

    print(f"  {'':<18}{'kills':>9}{'bonus':>9}{'total':>10}   what you killed")
    for label, r in (("won round", won), (f"wiped wave {len(WAVES) - 2}", deep), ("wiped wave 2", early)):
        print(f"  {label:<18}${r['kills']:>8,.0f}${r['bonus']:>8,.0f}${r['total']:>9,.0f}   "
              f"{r['commons']:.0f} commons, {r['specials']:.0f} specials, {r['bosses']:.1f} bosses")
    print(f"\n  a deep loss is worth {deep['total'] / early['total']:.1f}x a shallow one")
    print(f"  kills are {won['kills'] / won['total']:.0%} of a won round — the rest is finishing it\n")

    print(f"{bar}\n  PROGRESSION — the axis that does not reset\n{bar}\n")
    progression(won)
    print(f"{bar}\n")

    print(f"  free at the start  {len(free)}: {', '.join(e['id'] for e in free)}")
    print(f"  purchasable        {len(buyable)}, ${roster:,} in total")
    print(f"  coming soon        {len(soon)}: {', '.join(e['id'] for e in soon)}")
    if prestige:
        print(f"  outside the roster {len(prestige)}: "
              f"{', '.join(e['id'] for e in prestige)}")
    print()

    cheapest = min(buyable, key=lambda e: e["price"])
    rounds = (roster - START) / won["total"]
    per_weapon = rounds / max(len(buyable), 1)
    print(f"  starting balance   ${START:,}")
    print(f"  first purchase     {cheapest['id']} at ${cheapest['price']:,}"
          f"{' — affordable on the first visit' if START >= cheapest['price'] else ''}")
    print(f"  ROSTER UNLOCKED IN {rounds:.0f} won rounds   "
          f"(ceiling {ABSOLUTE_CEILING})")
    print(f"  a weapon costs     {per_weapon:.2f} won rounds   "
          f"(target {PER_WEAPON_MIN}-{PER_WEAPON_MAX})")
    # Reported, never folded in. A prestige item is a goal a player reaches for
    # AFTER the roster, so averaging it into "how long is the roster" would
    # describe neither honestly. Printing it is not optional though: an item left
    # out of the model entirely is how one ends up costing a hundred rounds with
    # nobody noticing.
    for entry in prestige:
        print(f"  then {entry['id']} at ${entry['price']:,} — "
              f"{entry['price'] / won['total']:.0f} more won rounds on top")
    print()

    if ABILITIES:
        total = sum(a["price"] for a in ABILITIES)
        cheap = min(ABILITIES, key=lambda a: a["price"])
        dear = max(ABILITIES, key=lambda a: a["price"])
        print(f"  abilities          {len(ABILITIES)}, ${total:,} in total — "
              f"{cheap['name']} ${cheap['price']:,} to {dear['name']} ${dear['price']:,}")
        print(f"                     the whole set is {total / won['total']:.1f} won rounds, "
              f"or {total / roster:.0%} of the weapon roster\n")

    print(f"  {'price':>8}  {'category':<9} id")
    for entry in sorted(CATALOGUE, key=lambda e: (e["category"], e["soon"], e["price"], e["id"])):
        price = "soon" if entry["soon"] else ("free" if entry["price"] == 0 else f"${entry['price']:,}")
        print(f"  {price:>8}  {entry['category']:<9} {entry['id']}")

    problems = []
    if not PER_WEAPON_MIN <= per_weapon <= PER_WEAPON_MAX:
        problems.append(
            f"a weapon costs {per_weapon:.2f} won rounds, outside the "
            f"{PER_WEAPON_MIN}-{PER_WEAPON_MAX} "
            f"EconomyConfig's header promises"
        )
    if rounds > ABSOLUTE_CEILING:
        problems.append(
            f"the whole roster takes {rounds:.0f} won rounds — past the {ABSOLUTE_CEILING} "
            f"ceiling, whatever the per-weapon pace says"
        )
    # The band is enforced by EconomyConfig.rewardForKill's clamp, so what is
    # checked here is that the clamp is still there and still says 2-8 — a table
    # entry outside the band would otherwise be silently corrected rather than
    # noticed.
    for kind, pay in REWARDS.items():
        if not BAND_MIN <= pay <= BAND_MAX:
            problems.append(f"{kind} pays {pay}, outside the {BAND_MIN}-{BAND_MAX} band")
    if "math.clamp(total" not in ECON:
        problems.append("rewardForKill no longer clamps into the band")
    if deep["total"] <= early["total"]:
        problems.append("a deep loss pays no more than a shallow one")
    if START < cheapest["price"]:
        problems.append(
            f"a new player cannot afford anything: ${START:,} against a cheapest of "
            f"${cheapest['price']:,}"
        )
    # The two CHEAPEST things, not twice the cheapest one.
    #
    # The old test was `START >= cheapest * 2`, which asks whether a player could
    # buy the cheapest item twice — something no shop in this game allows, since
    # everything is a one-time unlock. With a $900 pistol and a $1,400 bat it
    # fired on a starting balance that in fact buys exactly one of them, which is
    # precisely the state it exists to protect.
    two_cheapest = sorted(e["price"] for e in buyable)[:2]
    if len(two_cheapest) == 2 and START >= sum(two_cheapest):
        problems.append(
            f"the starting balance buys the two cheapest items at once "
            f"(${sum(two_cheapest):,} against ${START:,}); the first visit should be one choice"
        )
    if won["total"] > CAP * 0.8:
        problems.append(f"a normal won round (${won['total']:,.0f}) is close to MaxPerRound (${CAP:,})")

    if problems:
        print(f"\n{bar}")
        for p in problems:
            print(f"  DRIFT: {p}")
        print(bar)
        return 1 if "--check" in sys.argv else 0

    print(f"\n  ── the pacing matches what EconomyConfig claims ──\n{bar}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
