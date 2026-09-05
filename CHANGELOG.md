# Changelog

## 1.0.0 - 2026-09-05

First release.

* **F1** opens and closes the game's own admin menu.
* **CTRL + F1** panic key restores input from any state.
* **Bulk Battery** added to *Cheats → Spawn/Craft → Storage Modules*. It is styled from a
  neighbouring button so it matches the rest of the menu, and it is built by the game's
  own crafter, so it arrives with the build animation, the right starting charge and the
  right position on the ground.
* No console commands. Everything the mod does is in the menu.

### Not included yet

**Bulk Petrol Tank** and **Bulk Diesel Tank** are missing from the game's cheat menu too,
and this release does not add them.

They are not in the game's craftable list - neither in the craftable enum (66 entries)
nor in the recipe data (57), and no item asset for them can be reached. The only way to
place them is to spawn the module actor directly, and doing that produces a module the
game never initialised: a fill gauge showing charge that is not there, and, in testing,
a hard crash inside the module's own startup.

They are left out on purpose rather than shipped broken. If a future game patch adds them
to the craftable list, adding the buttons is a two line change - see `M.ADDITIONS` in
`catalog.lua`.

---

Written in Lua against the game's own API, so an engine version bump does not break it
the way a cooked blueprint does. Built and tested on Unreal Engine 5.8.1.
