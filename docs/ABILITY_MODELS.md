# Ability Models

**Every ability already works without one.** Each builds a grey-box body at
runtime, the same way `AmmoFactory` fills in ammo you have not modelled. A
supplied model is an upgrade, never a prerequisite — a fresh place with an empty
`Assets` folder plays correctly.

This document is here for when you want to **supply** one.

## Where they go

```
ReplicatedStorage/
└── Assets/
    └── Abilities/
        └── Turret        ← named for the ability, exactly
```

`ReplicatedStorage`, **not** `ServerStorage`. The turret's placement ghost is
drawn on the client, and a client cannot see `ServerStorage` — a model kept
there deploys fine and then leaves the player positioning an invisible turret.
The server checks `ServerStorage` as a courtesy so a misplaced model still
works, but it cannot be previewed from there.

The folder name is the ability id from `Shared/Enums`, so no second table maps
one to the other:

| Ability | Folder name | Reads a supplied model? |
|---|---|---|
| Deployable Turret | `Turret` | **yes** |
| Riot Shield | `Shield` | no — a welded ForceField sphere |
| Field Medic | `Medic` | no — a heal pulse, nothing persists |
| Cryo Blast | `CryoBlast` | no — a frost field on the floor |
| Airstrike | `Airstrike` | no — but see **The airstrike jet** below |

**The turret is the only one that wants a model, and that is not an oversight.**
It is the only ability that puts a solid object in the world and leaves it
there. The other four are effects: a sphere reads as "shield" at forty studs
through a horde in a way a modelled riot shield does not, and a heal pulse, a
frost patch and an explosion have no object to model in the first place. Adding
a folder for them would be adding a hook nothing could usefully hang on.

If you later want a different look for one of those, it is a change to that
ability's own build function — not a model drop.

## The airstrike jet

The airstrike does have a plane, and it is **not** an `Assets` model — it is
built from catalogue mesh ids in `AbilityConfig.Definitions.Airstrike.tuning`:

```
JetMeshId    JetTextureId       the F-22 that makes the run
BombMeshId   BombTextureId      the stick of three it drops
JetHeight    JetRunway          how high it passes and how far out it starts
JetCrossSeconds                 how long it takes to cross
```

Swap those four ids for any mesh you like. If one fails to load, the plane
falls back to a plain block that still crosses the sky — the flyover is the
tell that shells are coming, and losing it to a missing mesh would cost the
player information they need.

**All of it is cosmetic.** The jet has no collision, no `Humanoid`, no
`Explosion` and no `Touched` handler. Damage is the server's five walking
shells through `DamageService`, scheduled the instant the marker goes down, and
they land whether or not a single frame of the plane ever renders.

Every time in the flyover is derived from `JetCrossSeconds`, `JetHeight` and
the ability's own `WarningTime` — when the plane launches, where the bombs
leave it, how long they fall. Change the warning and the plane still arrives
overhead exactly as the shells land. Nothing needs re-tuning by hand.

The one thing it does not have is **sound**. Abilities have no audio hooks in
`AudioConfig` yet, so the jet is silent.

## The turret

Child parts, by name. All three are optional and each degrades on its own — a
model that is nothing but geometry still deploys and still shoots.

| Child | What it does | Without it |
|---|---|---|
| `base` | the part that stands on the floor | the model's `PrimaryPart`, else its largest part |
| `gun` | the part or model that swings to track a target | nothing turns; it shoots from where it stands |
| `Muzzle`… | an `Attachment` at the end of each barrel | tracers start from the middle of the gun |

- **One `Muzzle` attachment per barrel.** Any name starting with `Muzzle`
  counts — `Muzzle` and `Muzzle 2`, or `Muzzle L` and `Muzzle R`, or four of
  them. They are sorted by name and **fired in turn**, so a twin gun visibly
  alternates left, right, left instead of pouring everything out of one barrel.
  Nothing needs to be told how many there are.
- They can sit anywhere inside `gun` — on the gun part itself, or on any part
  inside it if `gun` is a Model. Both are found.
- `gun` may be a **`Part` or a `Model`**. A Model turns as a whole, so a
  multi-part gun keeps its sights and its ammo box attached.
- **Set `gun`'s pivot at the rotation joint** — where it would really pivot on
  the base. It is turned with `PivotTo`, so the pivot is what it swings around;
  left at the default the barrel orbits its own centre.
- The turret **traverses in yaw only** — it does not pitch. Real emplacements
  swing; they do not tip forward onto their face at a zombie three studs away.
- Anything else in the model is left alone. Seats, lights, decals, a name plate
  all come along.

### A seat is decoration

The supplied model has one, and it stays purely visual. The turret is
**automatic**: you drop it, it finds targets and fires on its own while you keep
playing. That is what makes it worth a 45-second cooldown — a turret you had to
sit in would be a worse gun than the one already in your hands, and it would
take you out of the fight to use it.

### It is seated by bounding box

Where the model's **underside** ends up is measured, not assumed, so any size
works and nothing sinks into the floor or hovers over it. The placement ghost
runs the same `AbilityAssets.seat` call the deploy does, so the preview stands
exactly where the real one will.

## Placing one, in game

The turret is a **targeted** ability: pressing its key enters placement rather
than deploying immediately.

- A translucent copy of the model follows the crosshair, standing on the floor
  and facing away from you — which is the direction it will cover.
- **Green** means the server will accept it. **Red** means it will not, and the
  prompt says which: `NO SOLID GROUND THERE` or `TOO FAR AWAY`.
- Fire to place, press the ability key again to place, or Escape / B to cancel.
  A red spot refuses the confirm and leaves you still placing.
- **On a phone the ability card is the button.** Tap it to start placing, drag
  to aim, tap it again to place, or use the CANCEL button under the prompt.
  The fire button stays the fire button — placement never steals it, because
  a drag to aim would otherwise confirm the moment you reached up to turn.
- Range is `AbilityConfig.Definitions.Turret.range` (45 studs).

None of this is a permission check. The client greys out and reddens as a
courtesy; the server independently re-checks alive, round, slot, ownership,
cooldown, range and footing, and refuses a client that skipped every one of
them.

## The gunner's seat

A turret can be manned — sit in it and you aim and fire it yourself. See
`docs/TURRETS.md`.

**If your model contains a `Seat` anywhere inside it, that is the seat players
use.** Model a stool, a saddle, a milk crate; whatever it is, put a Seat where a
gunner should end up and it is used as-is (anchored and made non-collidable on
the way in). With no Seat in the model, an invisible one is placed 2.2 studs
behind the gun along the direction it faces.

## The walrus, and why it has to be a rig

`Become Walrus` hides the survivor and welds `Become Walrus` onto their
HumanoidRootPart. The player keeps driving their own character — their Humanoid,
their WalkSpeed — so the walrus goes wherever they go, and always did.

What it did NOT do was move a muscle, and that is what got reported as other
players seeing it "frozen". Every part was welded to the root, which pins the
whole model into one rigid body: no joint can bend and any Animator inside is
over-constrained. It slid around in a fixed pose.

So the model decides what it gets:

| What you supply | What happens |
|---|---|
| Loose parts, no joints | welded rigid, slides in a fixed pose. The old behaviour, kept because welding one part of a pile of loose parts would drop the rest on the floor |
| A rig — a Motor6D chain, or an R15/R6 skeleton | only its root is welded; the joints stay free and articulate |
| A rig with an `Animation` inside it | the same, and every clip plays on a loop |

It says which of the three you gave it, once, the first time somebody becomes
one — so "my walrus still slides" is one line in the output rather than a guess.

**Do not leave a `Humanoid` in the model.** It is parented INTO the character,
and a second Humanoid there makes `FindFirstChildOfClass("Humanoid")` a coin
toss for every system that reads the player's state off exactly that call —
damage, downs, revives, the HUD. One is replaced with an `AnimationController`
on the way in, which gives the Animator and none of the state machine, but it is
better not to ship one.

## Scale

A stud is about 28cm. The grey-box turret is a 2.6-stud base with a barrel three
studs up, which is roughly a real tripod-mounted gun. A supplied model much
larger than that will block doorways it is meant to defend; much smaller and
players will not see it in a crowd.
