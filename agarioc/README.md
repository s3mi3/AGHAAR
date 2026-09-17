# agaric base — working folder

Source: https://github.com/s3mi3/agaric  (place file `Agar.rbxlx`)

## What this folder is

- `Agar.rbxlx` — the original Roblox place file. Open this in Studio, that's your game.
- `src/` — every Script / LocalScript / ModuleScript from inside the place, extracted
  to plain `.lua` files so you can read / edit / diff them without Studio open. The
  folder tree mirrors the Explorer hierarchy exactly.

## Quick start

1. Double-click `Agar.rbxlx` — Studio opens with the full project loaded.
2. Press **Play** (F5). It should just work — this base is complete.
3. Controls:
   - **Mouse** — move
   - **Space** — split
   - **W (hold)** — self-feed / eject mass

## Explorer layout (already inside the .rbxlx)

```
ReplicatedStorage/
  Agar2D/
    Shared/
      Config          <- tweak knobs here (mass, speed, virus behaviour...)
      SpatialHash
      Vec2
      SkinData

ServerScriptService/
  Agar2D/
    ServerMain        <- entry point, requires GameService
    GameService       <- 4545 lines, the whole server sim

StarterPlayer/StarterPlayerScripts/
  Agar2DClient        <- entry point, requires Agar2D modules
  Agar2D/
    Camera2D
    CirclePool
    InputController   <- Space=split, W=self-feed, mouse=move
    Renderer          <- 2069 lines, draws the whole game as UI
    SkinShop
    Localization
```

## Already implemented (verified in Config)

| Feature                       | Config location                                |
|-------------------------------|------------------------------------------------|
| 32-cell split cap             | `Player.MaxCells = 32`                         |
| Split (Space)                 | `Cell.SplitMinMass = 1000`, `SplitImpulse=700` |
| Self-feed (W held)            | `Ejected.*`                                    |
| Virus pushing / eat-split     | `Virus.BumpMinSpeed/BumpMaxSpeed`, `EatSplitMinMass` |
| Grow on eat                   | `Cell.MinEatRatio = 1.25`                      |
| Food respawn                  | `Food.TargetCount = 240`, `SpawnBatch = 120`   |
| Bots (spawners)               | `Spawner.TargetCount = 3`                      |
| Barriers                      | `Barrier.TargetCount = 4`                      |
| Coins / progression           | `Coin.*`, `Progression.*`                      |
| XP / leveling                 | `Progression.MaxLevel = 100`                   |
| Skin shop                     | `SkinShop` module + `SkinData`                 |

## Not yet implemented — the feature list you asked for

- [ ] **Freeze blobs** — no `Config.Freeze` block, no `FreezeSystem` module.
  This is the one thing missing from your requested feature set.
  Design (to be built): pickup entity spawns like coins → grants charge →
  activate with a key (e.g. `F`) → freezes enemy cells within radius R
  for T seconds, tinted blue, velocity zeroed.

## Recommended next steps

1. Confirm the place opens in Studio and Play mode works. Report any errors.
2. Once confirmed, ask for the freeze mechanic to be added — it will touch:
   - `ReplicatedStorage/Agar2D/Shared/Config` (new `Config.Freeze` block)
   - `ServerScriptService/Agar2D/GameService` (spawn pickups, apply freeze state, tick down)
   - `StarterPlayer/StarterPlayerScripts/Agar2D/InputController` (new `F` key binding)
   - `StarterPlayer/StarterPlayerScripts/Agar2D/Renderer` (draw pickups + frozen tint)

## Notes / limits

- All source is authored by [s3mi3](https://github.com/s3mi3). Check the repo for
  license before publishing your derivative game.
- Editing the extracted `.lua` files in `src/` does **not** update the `.rbxlx`.
  Edit inside Studio. `src/` is a read-only mirror for browsing.
- If you want two-way sync between disk and Studio, look into
  [Rojo](https://rojo.space) — it's the standard tool for that.
