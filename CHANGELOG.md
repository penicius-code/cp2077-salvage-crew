# Changelog

For game version 2.5.

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
