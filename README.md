# Loot Ledger

A clean, lightweight loot tracker for grinding sessions in WoW TBC Classic.
Every item, kill, and copper you pick up — organised the way you'd expect.

## Features

- **Per-mob tracking** — items, gold, and kill counts grouped by the mob
  you actually looted (mobs you killed but didn't loot don't appear).
- **Gathering bucket** — mining, herbing, fishing, skinning, prospecting,
  disenchanting, and lockboxes all roll up into one entry.
- **Per-dungeon aggregation** — every drop, coin, and gathered node inside
  an instance is grouped under that dungeon's name.
- **Vendor value** — total estimated sell price shown in the footer.
- **Right-click menus** — ignore items, ignore mobs, reset specific entries.
- **Search filter, compact grid view, opacity slider, hide-during-combat.**
- **Shift-click any item** to link it in chat.

## Installation

Drop the `LootLedger` folder into:
`World of Warcraft/_anniversary_/Interface/AddOns/`

Or install via [CurseForge](https://www.curseforge.com/wow/addons/loot-ledger).

## Slash commands
/ll toggle window
/ll reset clear all tracked data
/ll resetwindow reset window size and position
/ll debug toggle event-debug printing
/ll status print current internal state
/ll help list commands

## Reporting issues
If something tracks oddly, run `/ll debug`, kill or loot the offending
target, then [open an issue](https://github.com/Paradise-Ace/LootLedger/issues)
and paste the resulting `LL ...` chat lines into your bug report.
## License
MIT — see [LICENSE](LICENSE).
