# Ammo Models — what to make and where to put it

Everything here is **optional**. The game builds a stand-in for anything missing,
at the right size and colour for its calibre, so a half-filled folder still plays.
Drop a real model in and it's used automatically — no code changes.

## Folder layout

Create this next to the folders you already made:

```
ReplicatedStorage/
└── Assets/
    └── Ammo/
        ├── Casings/      the brass that flies out when you shoot
        ├── Magazines/    the mag that drops when you reload
        └── Pickups/      ammo on the floor
```

Names must match **exactly** — they're the lookup keys.

---

## 1. Casings — 6 models

Ejected on every shot. At the Vector's 1100rpm that's eighteen a second, so keep
these **cheap**: a single mesh part, no unions, no textures beyond a colour. They
live under a second each and are only ever seen tumbling.

One per **calibre**, not per gun — 16 guns share 6 casings.

| Model name | Used by | Should look like |
|---|---|---|
| `Casing_9mm` | MP7A1 | Small brass bottleneck case, ~17mm |
| `Casing_45ACP` | M1911A1, UMP-45, Kriss Vector | Fatter, stubbier brass, straight-walled |
| `Casing_357` | .357 Magnum | Long slim brass revolver case |
| `Casing_556` | M4A1, HK416A5, Mk 18, Scoped Mk-18, AKS-74U | Slender bottleneck rifle brass |
| `Casing_762` | AKM, M1A EBR, PPSh-41 | Noticeably longer and fatter than 5.56 |
| `Casing_12ga` | Shotgun | **Red plastic hull with a brass base.** The only casing players consciously notice — worth the most effort. |

> Orient them lying along **Z** (long axis forward). If you don't, they'll still
> work, they'll just tumble from a different starting angle.

## 2. Magazines — 8 models

This is the one worth real effort. A magazine falls out of frame at arm's length
over about a second, and it's the clearest signal in the game that a reload is
happening. Players *look* at this one.

| Model name | Used by | Should look like |
|---|---|---|
| `Mag_Pistol` | M1911A1 | Slim single-stack blued steel |
| `Speedloader_357` | .357 Magnum | Round six-shot speedloader |
| `Mag_SMG` | MP7A1, UMP-45, Kriss Vector | Straight box magazine |
| `Mag_Drum` | PPSh-41 | **The 71-round drum.** Big, round, unmistakable |
| `Mag_STANAG` | M4A1, HK416A5, Mk 18, Scoped Mk-18 | Grey/black polymer AR magazine |
| `Mag_AK` | AKM, AK-12, AKS-74U | Curved, orange-brown bakelite — should read as *obviously* not a STANAG |
| `Mag_Marksman` | M1A EBR | Shorter, fatter 20-round box |
| `Round_12ga` | Shotgun | A single shell. The shotgun loads one at a time and drops no magazine |

## 3. Pickups — 3 models

Sat on the floor, seen from any angle and further away. These want to be readable
in silhouette in a dark room, so favour a distinctive shape over detail.

| Model name | What it is |
|---|---|
| `AmmoPile` | The shared refill everyone can draw from. A loose heap of boxes and belts |
| `AmmoBox` | Single-use pickup. A sealed military ammo can |
| `ShellBox` | Shotgun-specific. An open box of red hulls |

---

## Format notes

- **A `Part`, a `MeshPart`, or a `Model` wrapping one part** all work. If you give
  a Model, the first BasePart inside it is used.
- **Size doesn't need to be exact** — but keep it roughly to scale, because it's
  cloned as-is. A stud is about 28cm. A rifle case should be around `0.06 × 0.06 ×
  0.2` studs.
- **Don't include scripts.** They're stripped anyway (that's a security measure,
  not tidiness), and any child objects on casings are cleared for performance.
- **No welds or constraints needed.** Casings and magazines are thrown by physics.

## Tuning

Every number — eject speed, spin, lifetime, how far a magazine falls — is in
`src/shared/Config/AmmoConfig.lua`, one block per calibre and per magazine family,
commented with what each does. Adding a **new** calibre is: add a block, point a
weapon at it. No new code.
