# Changelog

For game version 2.5.

## 1.2.4 - 2026-11-26
### Fixed
- Androids came out in a random skin on every spawn: the copied android record had no appearance name, so the game picked one of the template's appearances at random. Each look now names one appearance, and after the spawn the mod applies it if the entity shows another one.

Mock test: 180 of 180. Not run in game yet.

## 1.2.3 - 2026-11-26
### Added
- CET input "Salvage android 1: hold = deploy / send home, tap = go / wait" (unbound by default). Hold (0.5 s): climbs out of the trunk of an own car within 12 m, or is sent home. Tap: waits where it stands, or goes on working. Uses `registerInput`, so it also works while moving.

Mock test: 174 of 174. Not run in game yet.

## 1.2.2 - 2026-11-25
### Fixed
- The game could crash while a save loaded with 1.2.0 or 1.2.1. Every item drop reported itself to the Salvage system from inside its attach callback, and a save load attaches many drops at once. The attach wrap now only queues a request; the system adds the drop when it works through its own request queue. Proven: the crash signature, the load timing and this mod's call on all three crash stacks. Inferred: that writing the system's array from an attach callback during a load is not safe.

Not run in game yet.

## 1.2.1 - 2026-11-25
### Changed
- A body or drop with nothing the unit would take is not visited.
- The loot line in the log names the items taken, skipped and left for lack of room.

Mock test: 162 of 162. Not run in game.

## 1.2.0 - 2026-11-25
### Added
- Guns lying on the ground are picked up, next to a body or not. Every item drop reports itself to the Salvage system; an idle unit out of combat looks for weapon drops within 35 m. Away from bodies: plain weapons only (iconics and quest items are left for you). Weapons you dropped yourself are left alone (the last 64 are remembered in the save).
- Settings: "Pick up guns lying away from any body" (on), "Also pick up weapons V dropped" (off).
### Changed
- A pickup takes half the search time of a body and 0.1 % wear instead of 0.5 %; this also applies to ammo and loot bags.

Ran in game on 2.5: one session, 7 guns picked up, no errors in the log. Could crash on save load (fixed in 1.2.2).

## 1.1.1 - 2026-11-23
### Changed
- "Take" and "Take all" work only when the unit is within 6 m of the player. Before, a unit on standby up to 150 m away could be emptied from a distance.

Mock test: 125 of 125 after adjusting the test for this rule.

## 1.1.0 - 2026-11-23
### Added
- Five salvage androids, each with its own cargo: android 1 from the trunk of any owned car, androids 2 to 5 from one specific van.
- Standby and resume for all units.
- Wear per unit, and service paid in crafting components.
- Handling for units that lose contact (too far away).
### Fixed (review before the first launch)
- A full unit no longer goes back to work when another unit's cargo changes; it waits for its own cargo to shrink.
- The list of looted bodies is cleared when a save is loaded.
- A unit sent on a trip leaves the field at once, so a save cannot store it as both away and out.
- Routine notices (items aboard, cash wired, a unit arriving) are no longer queued; one "units lost contact" notice instead of one per unit.

Mock test: 125 of 125.

## 1.0.0 - 2026-11-22
- First version: a cosmetic carry drone, one salvage android and one salvage drone, a cargo ledger kept in the save, sell and recycle trips.

Mock test: 43 of 43.
