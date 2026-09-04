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
| Airstrike | `Airstrike` | no — a marker, then explosions |

**The turret is the only one that wants a model, and that is not an oversight.**
It is the only ability that puts a solid object in the world and leaves it
there. The other four are effects: a sphere reads as "shield" at forty studs
through a horde in a way a modelled riot shield does not, and a heal pulse, a
frost patch and an explosion have no object to model in the first place. Adding
a folder for them would be adding a hook nothing could usefully hang on.

If you later want a different look for one of those, it is a change to that
ability's own build function — not a model drop.

## The turret

Child parts, by name. All three are optional and each degrades on its own — a
model that is nothing but geometry still deploys and still shoots.

| Child | What it does | Without it |
|---|---|---|
| `base` | the part that stands on the floor | the model's `PrimaryPart`, else its largest part |
| `gun` | the part or model that swings to track a target | nothing turns; it shoots from where it stands |
| `Muzzle` | an `Attachment` inside `gun`, at the end of the barrel | tracers start from the middle of the gun |

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
- Range is `AbilityConfig.Definitions.Turret.range` (45 studs).

None of this is a permission check. The client greys out and reddens as a
courtesy; the server independently re-checks alive, round, slot, ownership,
cooldown, range and footing, and refuses a client that skipped every one of
them.

## Scale

A stud is about 28cm. The grey-box turret is a 2.6-stud base with a barrel three
studs up, which is roughly a real tripod-mounted gun. A supplied model much
larger than that will block doorways it is meant to defend; much smaller and
players will not see it in a crowd.
