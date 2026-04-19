# Station Production Overview

Adds a **Production Overview** tab to the info panel tab strip in the map menu (alongside Object Info, Crew, etc.) for player-owned stations. Shows per-ware production and consumption rates, groups wares into Products, Intermediates, and Resources, and previews the impact of planned (not yet built) modules.

## Features

- **Production Overview Tab**: A dedicated tab in the station info panel shows all production and consumption data at a glance.
- **Sector Production Overview**: A dedicated tab in the sector info panel shows all production stations within the sector with their respective production data, equal to the single station production overview.
- **Per-ware rates**: For each ware the tab displays produced, consumed, and net total amounts per hour.
- **Ware icons**: Each ware row shows the ware icon alongside its name for quick visual identification.
- **Production issue indicators**: If any production modules for a ware are waiting for resources or waiting for storage, the ware name is highlighted in warning colour and a mouseover tooltip lists the exact issue counts per state.
- **Live vs Estimated mode**: A dropdown lets you switch between *Current (live state)* (reflecting only active modules and workforce) and *Estimated (all modules active)* (the theoretical maximum output).
- **Active module count**: In live mode the module count column shows how many modules are currently running out of the total installed (e.g. `3 (5)`).
- **Ware grouping**: Wares are grouped into **Products** (not consumed on-site), **Intermediates** (produced and consumed on-site), and **Resources** (pure inputs, not produced on-site).
- **Workforce resource consumption**: Wares consumed exclusively by workforce (food, medicine, and similar consumer goods) appear in the Resources group when no production module produces them. Otherwise they are shown according to their production modules places.
- **Planned module preview**: When the construction plan contains new modules a second delta row per ware shows the expected impact once those modules are built.
- **Empire balance**: For Products and Intermediates, an optional *All stations:* sub-row shows the total consumption of that ware across all your player-owned stations and a coloured balance indicating how much this station's production covers the empire-wide demand. Hidden by default; enable it with the **Show empire balance** checkbox below the mode dropdown. Respects the current Live / Estimated mode.
- **Configurable data refresh**: A slider in the Extensions options menu (Extensions > Station Production Overview) controls how many UI ticks production data is cached before recomputing (1-10, default 3), reducing CPU overhead in large saves.
- **Quick-navigation buttons**: *Configure Station* and *Station Overview* buttons are available at the bottom of the tab.

## Requirements

- **X4: Foundations**: Version **8.00HF4** or higher and **UI Extensions and HUD**: Version **v8.0.4.3** or higher by [kuertee](https://next.nexusmods.com/profile/kuertee?gameId=2659).
  - Available on Nexus Mods: [UI Extensions and HUD](https://www.nexusmods.com/x4foundations/mods/552)
- **X4: Foundations**: Version **9.00 beta 3** or higher and **UI Extensions and HUD**: Version **v9.0.0.0.3** or higher by [kuertee](https://next.nexusmods.com/profile/kuertee?gameId=2659).
  - Available on Nexus Mods: [UI Extensions and HUD](https://www.nexusmods.com/x4foundations/mods/552)
- **Mod Support APIs**: Version 1.95 or higher by [SirNukes](https://next.nexusmods.com/profile/sirnukes?gameId=2659).
  - Available on Steam: [SirNukes Mod Support APIs](https://steamcommunity.com/sharedfiles/filedetails/?id=2042901274)
  - Available on Nexus Mods: [Mod Support APIs](https://www.nexusmods.com/x4foundations/mods/503)

## Installation

- **Steam Workshop**: [Station Production Overview](https://steamcommunity.com/sharedfiles/filedetails/?id=3695609478) - only for **Game version 8.00** with latest Steam version of the `UI Extensions and HUD` mod (version 80.43 from April 8).
- **Nexus Mods**: [Station Production Overview](https://www.nexusmods.com/x4foundations/mods/2049)

## Usage

Open the map, select a player-owned station, and click the **Production Overview** tab in the info panel on the left or right side.

### Production Overview Tab

The tab renders a table with one row per ware that is produced or consumed by the station's production and processing modules.

![Production Overview Tab](docs/images/production_overview_tab.png)

### Live vs Estimated mode

Use the dropdown at the top of the tab to switch between two display modes:

![Production Calculation Type Dropdown](docs/images/production_calculation_type_dropdown.png)

- **Current (live state) / hour**: uses the actual running rate from the engine, accounting for modules that are idle due to missing resources or workforce shortages. The Modules column shows `active (total)` when not all modules are running.
- **Estimated (all modules active) / hour**: reports the theoretical rate assuming all installed modules run at full capacity with the current workforce bonus applied.

![Production Estimated](docs/images/production_estimated.png)

### Planned module preview

If the station's construction plan contains new production or processing modules that have not been built yet, a secondary delta row appears directly below the ware row. It shows:

- `(+N)` in the Modules column: the number of planned new modules
- The additional production/consumption contribution those modules would add once built

### Ware groups

Wares are organized into three groups:

- **Products**: wares produced at this station that are not also consumed as a resource by any other module here.
- **Intermediates**: wares that are both produced and consumed internally (e.g. a station that refines ore into silicon and then uses that silicon further).
- **Resources**: wares consumed as raw inputs that are not produced on-site.

### Workforce resource consumption

Wares that are consumed exclusively by workforce modules (e.g. food, medicine, and similar consumer goods) are shown in the Resources group when no production module produces them.

![Workforce Resource Usage Example](docs/images/workforce_resource_usage.png)

If there are production modules for those wares, they are shown according to their production modules places, and the workforce consumption is shown in the consumption column for that ware.

![Workforce Resource Production Example](docs/images/workforce_resource_production.png)

### Empire balance

Below the mode dropdown (single-station view only) a **Show empire balance** checkbox controls whether an extra *All stations:* sub-row is shown for each Product and Intermediate ware. When enabled, the sub-row displays:

- empire-wide production of that ware across all player-owned stations
- empire-wide consumption of that ware across all player-owned stations
- a coloured **balance** (green = surplus, red = deficit, grey = neutral)

![Empire Balance Example](docs/images/show_empire_balance.png)

The balance respects the current Live / Estimated mode. The checkbox is hidden in Sector view.

### Extensions options

Open **Extension options > Station Production Overview** in the game **Options Menu** to configure:

- **Data Refresh Interval**: how many UI ticks the cached production data is reused before a full recompute (1-10, default 3). Lower values give more up-to-date numbers; higher values reduce CPU usage.

![Extension options](docs/images/options.png)

### Sector Production Overview

When viewing the info panel for a sector, a similar **Production Overview** tab lists all player-owned production stations in that sector with their respective production data, equal to the single station production overview.

![Sector Production Overview Tab](docs/images/sector_production_overview_tab.png)

## Credits

- **Author**: Chem O`Dun, on [Nexus Mods](https://next.nexusmods.com/profile/ChemODun/mods?gameId=2659) and [Steam Workshop](https://steamcommunity.com/id/chemodun/myworkshopfiles/?appid=392160)
- *"X4: Foundations"* is a trademark of [Egosoft](https://www.egosoft.com).

## Acknowledgements

- [EGOSOFT](https://www.egosoft.com) - for the X series.
- [kuertee](https://next.nexusmods.com/profile/kuertee?gameId=2659) - for the `UI Extensions and HUD` that makes this extension possible.
- [SirNukes](https://next.nexusmods.com/profile/sirnukes?gameId=2659) — for the `Mod Support APIs` that power the UI hooks.

## Changelog

### [9.00.08] - 2026-04-19

- **Added**
  - Workforce resource consumption: food, medicine, and other wares consumed only by workforce modules now appear in the Resources group.
  - Empire balance: an optional *All stations:* sub-row shows empire-wide production and consumption for each Product and Intermediate ware with a coloured surplus/deficit balance. Available in single-station view only.
- **Improved**
  - Data cache throttle: expensive C API calls are reused for `dataRefreshInterval` UI ticks before recomputing. Configurable in the Extensions options menu (default 3, range 1-10).

### [9.00.07] - 2026-04-10

- **Improved**
  - Added possibility to be distributed via Steam after upgrade Steam version the `UI Extensions and HUD` mod.

### [9.00.06] - 2026-04-06

- **Improved**
  - Added possibility to work under the v.8.00 of the game in case of usage the 8.0.4.3 version of the `UI Extensions and HUD` mod.

### [9.00.05] - 2026-04-02

- **Fixed**
  - Production overview table used too-small font for ware names and module counts on higher screen resolutions. Introduced in v9.00.04.

### [9.00.04] - 2026-04-01

- **Improved**
  - Ware icon is now displayed next to the ware name in each row.
  - Production issue highlighting: if any modules for a ware are waiting for resources or waiting for storage the ware name changes to warning colour and a mouseover tooltip shows the counts per issue state.

### [9.00.03] - 2026-03-31

- **Added**
  - **Sector Production Overview**: A new tab in the sector info panel that lists all player-owned production stations in the sector with their production data, equal to the single station production overview.

### [9.00.02] - 2026-03-31

- **Fixed**
  - Disappearing the info menu on a right panel when this mod enabled tab is selected

### [9.00.01] - 2026-03-30

- **Added**
  - Initial public version
