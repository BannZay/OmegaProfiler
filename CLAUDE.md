# OmegaProfiler

WoW 3.3.5a addon: live per-addon CPU graph, load-screen profiling, lag spike detection (`/omp`).

## Layout
- `src/` Lua modules (load order in the `.toc`), `media/` textures, `tests/` offline tests, `screenshots/` README images.
- `Series.lua` (tiered ring buffers + zoom/pan maths), `Classify.lua` (lag cause logic), `Persist.lua` and `Pack.lua`
  (compact SavedVariables encoding) are pure Lua: no WoW API.
- SavedVariables are packed only at PLAYER_LOGOUT and unpacked at ADDON_LOADED (`Core.lua`); in memory `db.lags` /
  `db.loads` are full tables. Saved rows and liveData keys refer to `db.strings` by index.
- `Sampler.lua` snapshots CPU; `LagDetector.lua`, `LoadProfile.lua` consume it; `Graph.lua`/`UI.lua`/`Extras.lua` are UI.
- Texture paths are built from the addon folder name (`Interface\AddOns\<folder>\media\...`), so the folder name may change.

## Tests
- Offline (plain Lua 5.1, no WoW), from the addon folder: `lua tests/test_offline.lua`.
- In-game tests need `SET scriptProfile "1"` in `WTF\Config.wtf`.

## Non-obvious facts
- `UpdateAddOnCPUUsage()` walks the whole Lua object list: call it per sample tick only, never per frame.
- Addon CPU is attributed through taint (function taint = addon name). Test clients that run addon code as secure
  code report 0 CPU for every addon; tests fake `GetAddOnCPUUsage` to exercise attribution.
- scriptProfile is read when the Lua state is created: changing it needs `/reload`.
- The folder is named `!!!!!OmegaProfiler` so it loads first and can time (wall) addons that load after it; addons
  that load before it are not covered.