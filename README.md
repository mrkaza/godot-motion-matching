# Godot Motion Matching

A Godot 4.7 port of Unreal Engine 5.8's Game Animation Sample: motion matching locomotion, traversal (vault, mantle, climb), the active ragdoll with get-ups, shoves, tackles and takedowns, foot placement and foley. It runs on the sample's own pose search databases, schemas, chooser tables and settings.

None of the sample's content is in this repository: no animations, meshes, skeletons, sounds or data. After you clone it, one script exports them from your own copy of the sample and builds everything the game needs.

## Requirements

- [Godot 4.7](https://godotengine.org/download)
- Unreal Engine 5.8, installed with the [Epic Games Launcher](https://www.unrealengine.com/download)
- The **Game Animation Sample** for UE 5.8, free on [Fab](https://www.fab.com)
- About 4 GB of free disk space for the exported files

The native extension comes prebuilt in `bin/`.

## Getting started

1. In the Epic Games Launcher, install Unreal Engine 5.8.
2. On Fab, add the Game Animation Sample to your library. In the launcher, create a project from it.
3. Open that project once in the Unreal editor and wait until the shaders finish compiling. Then close Unreal.
4. Clone this repository:

   ```powershell
   git clone https://github.com/mrqasuka/godot-motion-matching
   cd godot-motion-matching
   ```

5. Run the setup script with the paths to the sample's `.uproject` file and to Godot:

   ```powershell
   .\tools\extract_gasp.ps1 -UnrealProject "<path to>\GameAnimationSample.uproject" -Godot "<path to>\Godot_v4.7-stable_win64.exe"
   ```

   If Unreal is not in `C:\Program Files\Epic Games\UE_5.8`, add `-UnrealEditor "<path to>\UnrealEditor-Cmd.exe"`. If Windows blocks the script, run `Set-ExecutionPolicy -Scope Process Bypass` first in the same window.

6. When it says "Done", open the project in Godot and press Play.

The script runs four steps:

1. Unreal, headless: exports the 1,879 animation clips as FBX, the UEFN mannequin, the foley sounds, and the motion matching assets (pose search databases, schemas, choosers, montages, the physics asset) into `extracted/`.
2. The Unreal editor opens and exports Manny, the character you see. Unreal's FBX exporter needs a window, so this step can't run headless. Don't close it.
3. Godot imports the clips.
4. Godot builds the pose search databases into `databases/`.

The script stops with an error and the log's path if a step fails. Logs are in `extracted/`.

`extracted/` and `databases/` are gitignored, so they stay on your machine.

The level (`scenes/level.tscn`) is in the repository. It is plain Godot boxes placed like the sample's Traversal Gym.

## Controls

| Key | Action |
|---|---|
| WASD | Move |
| Mouse | Camera; wheel zooms |
| Shift (hold) | Sprint |
| Ctrl | Walk on/off |
| C | Crouch on/off; slides when running |
| Tab | Strafe / face movement |
| Space | Traverse the obstacle ahead, otherwise jump |
| R | Ragdoll |
| F | Shove the character in front of you (a tackle when running) |
| Q | Take down the character in front of you |
| B | Switch to your own character, if you add one: a glTF with UE5 bone names, listed in `Mannequin.BODY_MESHES` |
| F1 | Debug view (trajectory, database, clip, cost) |
| F11 | Fullscreen |
| Esc | Free the mouse; click to capture it again |

## Where things are

| Part | Files |
|---|---|
| Unreal export | `tools/extract_gasp.ps1`, `tools/unreal/` |
| Database build (Unreal's indexer) | `tools/bake/` |
| Character movement | `scripts/character/gasp_character.gd` |
| Trajectory, chooser, search, blend stack | `scripts/motion/` |
| Pose search and blend stack in C++ | `native/src/` |
| Foot placement | `scripts/motion/foot_placement.gd`, `ue_leg_ik.gd` |
| Traversal | `scripts/traversal/` |
| Ragdoll and get-ups | `scripts/ragdoll/` |
| Shove, tackle, takedown | `scripts/interactions/` |
| Foley | `scripts/audio/` |
| Level and NPC | `scripts/game/` |
| Scripted camera takes for videos | `tools/takes/` |

The search is exact: it checks every pose and skips blocks whose bounding box can't win. Unreal's default search is approximate.

## Tests

Headless checks are in `tools/checks/`. Run one after setup:

```powershell
& "<path to>\Godot_v4.7-stable_win64.exe" --headless --fixed-fps 60 --path . --script res://tools/checks/test_traversal.gd | Out-Host
```

The `test_*.gd` files cover locomotion, modes, pose search, pops, foot sliding, traversal, ragdoll, physical animation, interactions and foley.

## Native extension

The C++ source is in `native/`, with [godot-cpp](https://github.com/godotengine/godot-cpp) as a submodule. Building it needs Python, SCons and MinGW:

```powershell
git submodule update --init
cd native
scons platform=windows target=template_debug use_mingw=yes
scons platform=windows target=template_release use_mingw=yes
```

## Licence

MIT covers the code in this repository, not what you export from Epic's Game Animation Sample. Check the sample's licence on Fab before using that content outside Unreal Engine.
