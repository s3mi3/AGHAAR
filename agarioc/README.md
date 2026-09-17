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

## Updating the place file

After editing one of the gameplay source mirrors, run:

```sh
python3 tools/sync_place_sources.py
```

This copies the edited Config, GameService, Camera2D, CirclePool,
InputController, and Renderer modules into `Agar.rbxlx`, which can then be
opened and tested in Roblox Studio.

## Notes / limits

- All source is authored by [s3mi3](https://github.com/s3mi3). Check the repo for
  license before publishing your derivative game.
- The included sync script is one-way: source mirror → place file.
- For full two-way project synchronization, use
  [Rojo](https://rojo.space).
