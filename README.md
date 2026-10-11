# Admin Menu Mod

Opens The Last Caretaker's own built-in admin menu with **F1**, adds the Bulk Battery
button the menu is missing, and adds a button that puts the game's own weather back after
the menu's Weather page has changed it.

**Works on Update 6 "The Jump"** (tested on build 0.8.5.653002, Unreal Engine 5.8.1).
The mod is plain Lua and ships no cooked assets, so an engine update does not take it down.

The game already contains a full admin panel. It just has no key bound to it. This mod
binds one, and fills in a button the developers left out.

> **Not included yet:** the 2026-08-31 patch added three bulk containers and the cheat
> menu got buttons for none of them. Only Bulk Battery can be added without risking the
> game — see [Why only Bulk Battery](#why-only-bulk-battery). Bulk Petrol Tank and Bulk
> Diesel Tank are deliberately left out until the game makes them reachable.

## Download

**[Latest release](https://github.com/Nerfus-TLC/TLC-AdminMenuMod/releases/latest)** — two
archives, pick one:

| | |
|---|---|
| `AdminMenuMod-<ver>-with-UE4SS.zip` | Everything, UE4SS included. Extract into `Voyage\Binaries\Win64\` and start the game. |
| `AdminMenuMod-<ver>.zip` | Just the mod, for anyone already running UE4SS. Same place. |

Nothing to edit either way. The mod enables itself.

Also on **[Nexus Mods](https://www.nexusmods.com/thelastcaretaker/mods/230)** - same files,
and the place for comments, endorsements and update notifications.

## What it does

* **F1** opens and closes the game's admin menu.
* **You can walk while the menu is open.** The mouse works the menu and the movement keys
  still move the character, so several things can be placed one after another without
  closing the menu in between. The camera stays still until the menu closes.
* **CTRL + F1** is a panic key. It hands input back to the game whatever state the menu
  is in, so a stuck menu never means killing the game.
* Adds **Bulk Battery** to *Cheats → Spawn/Craft → Storage Modules*. It looks like the
  buttons the game ships, because its appearance is copied from a neighbouring button at
  runtime, and it builds the battery through the game's own crafter - build animation,
  correct placement, correct starting charge.
* Adds **Reset Weather to Default** at the bottom of the menu's *Weather* page. See
  [Weather stuck after using the admin menu](#weather-stuck-after-using-the-admin-menu).

Everything is in the menu. The mod adds no console commands.

## Weather stuck after using the admin menu

Update 6 "The Jump" made temperature part of the game: cold now hurts you and slows you
down. The admin menu's Weather page changes the weather that covers the whole world, and
that change is saved with your game. If you have ever tried it, a snowy region can stay
warm and sunny for good, and the game itself has no way to undo it.

**Reset Weather to Default**, at the bottom of the Weather page, does. Press it, then save
the game. The label changes to *Weather reset - save to keep* so you can see it worked.

It puts the world-wide weather back to the game's own preset and removes any preset you
picked in the menu this session. The game's regional weather - the snow biome, wind and
rain - is left alone.

## Why Lua

A mod shipped as cooked blueprint assets is tied to the engine version it was cooked for.
When the game moves to a new engine version, as it did on 2026-08-31 from 5.7 to 5.8.1,
those assets stop loading and the mod has to be rebuilt.

This mod is plain Lua. It ships no game content and no compiled assets. It asks the game
to open a widget the game already has, and to build an item the game already knows how to
build, so an engine bump does not break it.

## Why only Bulk Battery

The 2026-08-31 patch added three bulk storage containers, and the cheat menu got buttons
for none of them. Only one of the three can be added honestly.

The game builds modules through an item system that addresses everything by soft asset
reference. **Bulk Battery** is in the game's craftable list, as "Large Battery", so the
mod can ask the game's own crafter to build it and everything comes out right.

**Bulk Petrol Tank** and **Bulk Diesel Tank** are not in that list - not in the craftable
enum, not in the recipe data. The only way to place them is to spawn the actor directly,
which produces a module the game never initialised: a fill gauge showing charge that is
not there, and, in testing, a hard crash inside the module's own startup. A mod that can
crash the game is worse than a mod that does less, so those two are left out.

## Requirements

**UE4SS**, a build that supports Unreal Engine 5.8. The `-with-UE4SS` archive ships the
official build unmodified, so with that one there is nothing more to get.

With the mod-only archive, install UE4SS yourself first. Take the **experimental-latest**
release from [RE-UE4SS releases](https://github.com/UE4SS-RE/RE-UE4SS/releases), not the
stable release: only the experimental build knows Unreal Engine 5.8. Verified against
commit `24b12662`, which reports itself as `v3.0.1 Beta #0` in `UE4SS.log` - the same
version number as the old stable release, so go by the commit and the asset date, not
the version string.

Check the release **asset** date rather than the tag date when judging how current a
build is. The tag can be years older than the file.

## Install

1. Install UE4SS into the game, so that `dwmapi.dll` and `ue4ss/` sit in the folder
   below. If you took the `-with-UE4SS` archive, extracting it there does this for you:

   ```
   <SteamLibrary>/steamapps/common/Voyage/Voyage/Binaries/Win64/
   ```

2. Extract the `ue4ss` folder from the release archive into that same folder. You should
   end up with:

   ```
   Voyage/Binaries/Win64/ue4ss/Mods/AdminMenuMod/enabled.txt
   Voyage/Binaries/Win64/ue4ss/Mods/AdminMenuMod/Scripts/*.lua
   ```

3. Start the game and load a save. Press **F1**.

There is nothing to edit. `enabled.txt` turns the mod on by itself - `mods.txt` does not
need touching.

## Uninstall

Delete `ue4ss/Mods/AdminMenuMod`. Nothing else is modified: the mod writes no files and
changes no settings. The only thing it ever changes in a save is the weather, and only
when you press **Reset Weather to Default** - and then only back to the game's own values.

## Known behaviour

**A module put down on the boat does not follow the deck through the swell.** It stays
where the world put it while the boat rides up and down. This is not a fault in the mod -
the game's own admin menu does the same with its own modules.

To make one part of the boat, it has to go through the game's own building. Small modules
can simply be picked up and placed. Larger ones - Medium Battery and Bulk Battery among
them - cannot be carried at all: break them down with the **Dismantle Tool** for parts,
then build them again from the in-game build menu.

## If F1 is taken

If another mod has already bound F1, this mod does not take the key. `UE4SS.log` says so,
and `TOGGLE_KEY` at the top of `main.lua` is where to pick another one.

## Reporting a problem

`Voyage/Binaries/Win64/ue4ss/UE4SS.log` records what the mod did, step by step, right up
to the moment anything went wrong. Attach it to any bug report - the last line before a
crash usually names the exact call that caused it.

## Building from source

`tools/build.ps1` produces both release archives.

Four of the files under `AdminMenuMod/Scripts` are developer tools and are deliberately
left out of them: **`menu.lua`** adds a `menuscan` command that walks the game's live
widget tree, **`craft.lua`** adds `craftlist` and `craftdata`, which read the game's
craftable list and recipe data, **`patterns.lua`** adds `patterns`, and **`weather.lua`**
adds `weatherscan`, which lists every weather volume in the world with its priority,
climate and preset, plus commands that change a volume - each previews first and only
acts with `confirm`. `main.lua` loads them with `pcall`, so their absence is normal.

They are worth keeping. If a patch renames the menu panel this mod injects into,
`menuscan` finds the new name in a minute. If a patch makes the bulk tanks craftable,
`craftlist bulk` is the command that says so.

`tools/` also holds `luacheck.py`, which checks the Lua for syntax errors and for local
functions used before they are declared, `test_weatherreset.py`, which runs the weather
reset against stand-in objects without the game, and `jmap.py`, which reads objects out
of a UE4SS reflection dump.

## Licence

MIT, © 2026 Nerfus. See [LICENSE](LICENSE).

UE4SS is a separate project, MIT licensed, © 2022 Narknon. It is not part of this
repository. The `-with-UE4SS` release archive redistributes the official build unmodified,
with its licence alongside it in `ue4ss/LICENSE`.
