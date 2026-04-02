-- Station Production Overview
-- Adds a "Production Overview" tab to the info panel tab strip in the map
-- menu (the strip that holds Object Info, Crew, etc.), visible only for
-- player-owned stations.
-- Shows per-ware production and consumption rates (live or estimated), groups
-- wares into Products, Intermediates, and Resources, and previews the impact
-- of planned (not yet built) modules as a delta row per ware.
-- Uses kuertee UI Extensions callbacks:
--   info_sub_menu_create       — render when our infoMode.left is active
--   info_sub_menu_is_valid_for — allow the tab for player-owned stations only
-- config.infoCategories is extended to insert the tab button in the strip.
--
-- FFI types and functions used by this mod are declared in the ffi.cdef block
-- below.  The ego_detailmonitor addon (menu_map.lua, menu_station_overview.lua)
-- and ego_detailmonitorhelper (helper.lua) declare a superset, so there is no
-- conflict — re-declaring the same typedef/function signatures is harmless.

local ffi = require("ffi")
local C   = ffi.C

ffi.cdef [[
	typedef uint64_t UniverseID;

	typedef struct {
		float x;
		float y;
		float z;
		float yaw;
		float pitch;
		float roll;
	} UIPosRot;

	typedef struct {
		size_t idx;
		const char* macroid;
		UniverseID componentid;
		UIPosRot offset;
		const char* connectionid;
		size_t predecessoridx;
		const char* predecessorconnectionid;
		bool isfixed;
	} UIConstructionPlanEntry;

	const char*  GetComponentName(UniverseID componentid);
	double       GetContainerWareConsumption(UniverseID containerid, const char* wareid, bool ignorestate);
	double       GetContainerWareProduction(UniverseID containerid, const char* wareid, bool ignorestate);
	size_t       GetNumPlannedStationModules(UniverseID defensibleid, bool includeall);
	uint32_t     GetNumStationModules(UniverseID stationid, bool includeconstructions, bool includewrecks);
	UniverseID   GetPlayerContainerID(void);
	UniverseID   GetPlayerOccupiedShipID(void);
	size_t       GetPlannedStationModules(UIConstructionPlanEntry* result, uint32_t resultlen, UniverseID defensibleid, bool includeall);
	uint32_t     GetStationModules(UniverseID* result, uint32_t resultlen, UniverseID stationid, bool includeconstructions, bool includewrecks);
	bool         IsComponentClass(UniverseID componentid, const char* classname);
	bool         IsComponentWrecked(UniverseID componentid);
	bool         IsRealComponentClass(UniverseID componentid, const char* classname);
	void         SetFocusMapComponent(UniverseID holomapid, UniverseID componentid, bool resetplayerpan);

	typedef struct {
		int major;
		int minor;
	} GameVersion;
	GameVersion  GetGameVersion();
]]

-- infoMode.left key that identifies our sub-tab (must be unique across mods)
local SPO_CATEGORY = "chem_station_prod_overview"
local SSPO_CATEGORY = "chem_sector_prod_overview"

-- Resolved in init()
local menu         = nil
local config       = nil

local spo          = {
  showEstimated  = false, -- false = live state, true = all modules active (ignorestate)
  isV9           = C.GetGameVersion().major >= 9,
  modeOptions = {
    { id = "live",      text = ReadText(1972092416, 100), icon = "", displayremoveoption = false },
    { id = "estimated", text = ReadText(1972092416, 101), icon = "", displayremoveoption = false },
  }
}

-- ─── data collection ────────────────────────────────────────────────────────

--- Collect production / processing modules grouped by macro from a station.
--- Returns a table keyed by macroid:
---   { macro, name, count, numPlanned, isProcessing }
local function collectModuleData(station)
  local moduleData = {}

  -- 1. Live modules (including under-construction; excludes wrecked ones)
  local n = tonumber(C.GetNumStationModules(station, true, true))
  if n > 0 then
    local buf = ffi.new("UniverseID[?]", n)
    n = tonumber(C.GetStationModules(buf, n, station, true, true))
    for i = 0, n - 1 do
      local module = ConvertStringTo64Bit(tostring(buf[i]))
      local isProd = C.IsRealComponentClass(module, "production")
      local isProc = C.IsRealComponentClass(module, "processingmodule")
      if (isProd or isProc)
          and IsValidComponent(module)
          and not IsComponentConstruction(module)
          and not C.IsComponentWrecked(module) then
        local macro = GetComponentData(module, "macro")
        if not moduleData[macro] then
          moduleData[macro] = {
            macro        = macro,
            name         = GetMacroData(macro, "name") or macro,
            count        = 0,
            numPlanned   = 0,
            isProcessing = isProc,
          }
        end
        moduleData[macro].count = moduleData[macro].count + 1
      end
    end
  end

  -- 2. Newly planned modules (componentid == 0 → brand-new, not an upgrade)
  local np = tonumber(C.GetNumPlannedStationModules(station, true))
  if np > 0 then
    local pBuf = ffi.new("UIConstructionPlanEntry[?]", np)
    np = tonumber(C.GetPlannedStationModules(pBuf, np, station, true))
    for i = 0, np - 1 do
      if tonumber(pBuf[i].componentid) == 0 then
        local mac    = ffi.string(pBuf[i].macroid)
        local isProd = IsMacroClass(mac, "production")
        local isProc = IsMacroClass(mac, "processingmodule")
        if isProd or isProc then
          if not moduleData[mac] then
            moduleData[mac] = {
              macro        = mac,
              name         = GetMacroData(mac, "name") or mac,
              count        = 0,
              numPlanned   = 0,
              isProcessing = isProc,
            }
          end
          moduleData[mac].numPlanned = moduleData[mac].numPlanned + 1
        end
      end
    end
  end

  return moduleData
end

--- Base theoretical production/consumption rates per module instance per hour.
--- Returns list of:
---   { ware, ratePerModule, resources = { [ware] = ratePerModule } }
local function getBaseRates(macro)
  local results = {}
  local mData = GetLibraryEntry(GetMacroData(macro, "infolibrary"), macro)
  if not mData or not mData.products or #mData.products == 0 then
    return results
  end
  local queueDuration = 0
  for _, entry in ipairs(mData.products) do
    queueDuration = queueDuration + (entry.cycle or 0)
  end
  if queueDuration <= 0 then return results end
  for _, entry in ipairs(mData.products) do
    local resources = {}
    for _, res in ipairs(entry.resources or {}) do
      resources[res.ware] = Helper.round(res.amount * 3600 / queueDuration)
    end
    table.insert(results, {
      ware          = entry.ware,
      ratePerModule = Helper.round(entry.amount * 3600 / queueDuration),
      resources     = resources,
    })
  end
  return results
end

--- Extra consumption that would be added by all not-yet-built planned modules.
--- Returns { [ware] = extra_units_per_hour }
local function extraConsumptionFromPlanned(moduleData)
  local extra = {}
  for _, data in pairs(moduleData) do
    if data.numPlanned > 0 then
      for _, rateInfo in ipairs(getBaseRates(data.macro)) do
        for resourceWare, resourceRate in pairs(rateInfo.resources) do
          extra[resourceWare] = (extra[resourceWare] or 0) + resourceRate * data.numPlanned
        end
      end
    end
  end
  return extra
end

--- Scan live (non-wrecked) production/processing modules at a station and return
--- a table mapping ware → { noRes, waitStore } issue counts.
local function collectModuleCountsForWares(stationId)
  local counts = {}
  local n = tonumber(C.GetNumStationModules(stationId, false, false))
  if n == 0 then return counts end
  local buf = ffi.new("UniverseID[?]", n)
  n = tonumber(C.GetStationModules(buf, n, stationId, false, false))
  for i = 0, n - 1 do
    local mod = ConvertStringTo64Bit(tostring(buf[i]))
    if IsValidComponent(mod) and not C.IsComponentWrecked(mod) then
      if C.IsRealComponentClass(mod, "production") or C.IsRealComponentClass(mod, "processingmodule") then
        local proddata = GetProductionModuleData(mod)
        if proddata and proddata.products then
          local state = proddata.state
          for _, entry in ipairs(proddata.products) do
            local w = entry.ware
            if not counts[w] then
              counts[w] = { noRes = 0, waitStore = 0 }
            end
            if state == "waitingforresources" then
              counts[w].noRes = counts[w].noRes + 1
            elseif state == "waitingforstorage" or state == "choosingitem" then
              counts[w].waitStore = counts[w].waitStore + 1
            end
          end
        end
      end
    end
  end
  return counts
end

-- ─── formatting helpers ──────────────────────────────────────────────────────

local function fmt(n)
  return ConvertIntegerString(Helper.round(n), true, 0, true, false)
end

local function formatTotal(cur, pla)
  local function coloured(v)
    if Helper.round(v) == 0 then
      return fmt(v)
    elseif v > 0 then
      return ColorText["text_positive"] .. "+" .. fmt(v)
    else
      return ColorText["text_negative"] .. "-" .. fmt(math.abs(v))
    end
  end
  local s = coloured(cur)
  if Helper.round(cur) ~= Helper.round(pla) then
    return s .. "\n(" .. coloured(pla) .. ")"
  end
  return s
end

-- ─── panel builder ───────────────────────────────────────────────────────────

--- Resolve menu.infoSubmenuObject from selected components / player ship if not already set.
local function resolveInfoSubmenuObject()
  if (not menu.infoSubmenuObject) or (menu.infoSubmenuObject == 0) then
    for id in pairs(menu.selectedcomponents) do
      menu.infoSubmenuObject = ConvertStringTo64Bit(tostring(id)); break
    end
    if (not menu.infoSubmenuObject) or (menu.infoSubmenuObject == 0) then
      menu.infoSubmenuObject = ConvertStringTo64Bit(tostring(C.GetPlayerOccupiedShipID()))
      if (not menu.infoSubmenuObject) or (menu.infoSubmenuObject == 0) then
        menu.infoSubmenuObject = ConvertStringTo64Bit(tostring(C.GetPlayerContainerID()))
      end
    end
  end
end

--- Create and configure the standard 6-column info table inside inputframe.
local function addInfoTable(inputframe, infoBorder)
  local tableInfo = inputframe:addTable(6, spo.isV9 and {
    tabOrder          = 1,
    x                 = Helper.standardContainerOffset,
    width             = inputframe.properties.width - 2 * Helper.standardContainerOffset,
    backgroundID      = "solid",
    backgroundColor   = Color["container_subsection_background"] or nil,
    backgroundPadding = 0,
    frameborder       = infoBorder and infoBorder.id or nil,
  } or {
    tabOrder = 1,
  })
  tableInfo:setColWidthMinPercent(1, 30)          -- variable width; grows to fill space reserved for scrollbar
  tableInfo:setColWidthPercent(2, 13)             -- Count
  tableInfo:setColWidthPercent(3, 16)             -- Prod/h
  tableInfo:setColWidthPercent(4, 16)             -- Cons/h
  tableInfo:setColWidthPercent(5, 16)             -- Total/h
  tableInfo:setColWidth(6, config.mapRowHeight)   -- focus button (auto-scaled)
  tableInfo:setDefaultBackgroundColSpan(1, 6)
  tableInfo:setDefaultCellProperties("text", { minRowHeight = config.mapRowHeight, fontsize = config.mapFontSize })
  tableInfo:setDefaultCellProperties("button", { height = config.mapRowHeight })
  return tableInfo
end

--- Restore previously saved selected/top row and col for infotable<instance>.
local function restoreTableSelection(tableInfo, instance)
  if menu.selectedRows["infotable" .. instance] then
    tableInfo:setSelectedRow(menu.selectedRows["infotable" .. instance])
    menu.selectedRows["infotable" .. instance] = nil
    if menu.topRows["infotable" .. instance] then
      tableInfo:setTopRow(menu.topRows["infotable" .. instance])
      menu.topRows["infotable" .. instance] = nil
    end
    if menu.selectedCols["infotable" .. instance] then
      tableInfo:setSelectedCol(menu.selectedCols["infotable" .. instance])
      menu.selectedCols["infotable" .. instance] = nil
    end
  end
  menu.setrow    = nil
  menu.settoprow = nil
  menu.setcol    = nil
end

-- Add the estimated/current toggle dropdown row to the top of the table (below the title and info_focus rows).
function spo.toggleEstimatedCurrent(tableInfo)
  -- ── estimated/current toggle row ──
  local row = tableInfo:addRow(true, { fixed = true })
  row[1]:setColSpan(6):createDropDown(spo.modeOptions,
    { height = config.mapRowHeight, startOption = spo.showEstimated and "estimated" or "live" })
      :setTextProperties({
        halign = "center",
        font = Helper.titleFont,
        fontsize = Helper.standardFontSize,
        y = Helper
            .headerRow1Offsety
      })
  row[1].handlers.onDropDownConfirmed = function(_, id)
    spo.showEstimated = (id == "estimated")
    menu.refreshInfoFrame()
  end
  row[1].handlers.onDropDownActivated = function() menu.noupdate = true end
end

-- Add the column headers row below the title and info_focus rows (and toggle row, if in station mode).
function spo.columnHeaders(tableInfo)
  -- ── column header row ──
  row = tableInfo:addRow(false, { fixed = true })
  row[1]:createText(ReadText(1972092416, 110), Helper.headerRowCenteredProperties)
  row[2]:createText(ReadText(1972092416, 111), Helper.headerRowCenteredProperties)
  row[3]:createText(ReadText(1972092416, 112), Helper.headerRowCenteredProperties)
  row[4]:createText(ReadText(1972092416, 113), Helper.headerRowCenteredProperties)
  row[5]:setColSpan(2):createText(ReadText(1972092416, 114), Helper.headerRowCenteredProperties)
end

--- Populate tableInfo with the production summary rows.
--- Wares are grouped into "Products" (not consumed as a resource by any module at this
--- station) and "Intermediates" (also consumed as input by other modules here).
--- Within each group wares are sorted alphabetically.
function spo.setupProductionSubmenuRows(tableInfo, station, instance, sectorMode)
  local isStation = station and (tonumber(station) ~= 0)
      and C.IsComponentClass(station, "station")

  -- ── info_focus row: object name + map-focus button ──
  local titleColor = spo.isV9 and (isStation and menu.getObjectColor(station) or Color["text_normal"]) or
      menu.holomapcolor.playercolor
  local objectName = isStation
      and ffi.string(C.GetComponentName(station))
      or ReadText(1972092416, 1)

  local row = tableInfo:addRow("info_focus",
    { fixed = not sectorMode, bgColor = not spo.isV9 and Color["row_title_background"] or nil })
  row[6]:createButton({
    width = config.mapRowHeight,
    height = config.mapRowHeight,
    cellBGColor = Color
        ["row_background"]
  })
      :setIcon("menu_center_selection",
        {
          width = config.mapRowHeight,
          height = config.mapRowHeight,
          y = not spo.isV9 and
              (Helper.headerRow1Height - config.mapRowHeight) / 2 or nil
        }
      )
  row[6].handlers.onClick = function() return C.SetFocusMapComponent(menu.holomap, menu.infoSubmenuObject, true) end

  row[1]:setBackgroundColSpan(5):setColSpan(3):createText(objectName, spo.isV9 and { fontsize = Helper.headerRow1FontSize } or Helper.headerRow1Properties)
  row[1].properties.color = titleColor
  row[4]:setColSpan(2):createText(ffi.string(C.GetObjectIDCode(station)), spo.isV9 and { fontsize = Helper.headerRow1FontSize } or Helper.headerRow1Properties)
  row[4].properties.halign = "right"
  row[4].properties.color = titleColor


  if not sectorMode then
    spo.toggleEstimatedCurrent(tableInfo)
    spo.columnHeaders(tableInfo)
  end

  if not isStation then
    row = tableInfo:addRow(true, {})
    row[1]:setColSpan(6):createText(ReadText(1972092416, 1001), { halign = "center", wordwrap = true })
    return
  end

  local moduleData = collectModuleData(station)

  if next(moduleData) == nil then
    row = tableInfo:addRow(true, {})
    row[1]:setColSpan(6):createText(ReadText(1972092416, 1002), { halign = "center", wordwrap = true })
    return
  end

  -- ── aggregate per-ware production and resource-consumption data ──
  -- workforceMultiplier: workforce raises output above the base theoretical rate.
  -- C.GetContainerWareProduction(station, ware, false) already returns the live
  -- effective rate (base * workforce bonus).  We use it directly for productionCurrent,
  -- and scale planned modules' base contribution by the same multiplier.
  local workforceBonus      = GetComponentData(station, "workforcebonus") or 0
  local workforceMultiplier = 1 + workforceBonus

  local resourceWares       = {}   -- [ware] = { name, moduleCount, plannedCount }  (pure inputs)
  local wareProduction      = {}   -- [ware] = { name, moduleCount, plannedCount, plannedBaseRate }

  for _, data in pairs(moduleData) do
    local rates = getBaseRates(data.macro)
    for _, rateInfo in ipairs(rates) do
      local ware = rateInfo.ware
      if not wareProduction[ware] then
        local wareName, wareIcon = GetWareData(ware, "name", "icon")
        wareProduction[ware] = {
          name            = wareName or ware,
          icon            = (wareIcon and wareIcon ~= "") and wareIcon or "solid",
          moduleCount     = 0,
          plannedCount    = 0,
          plannedBaseRate = 0,           -- sum of ratePerModule * numplanned across all macros
        }
      end
      local wp           = wareProduction[ware]
      wp.moduleCount     = wp.moduleCount + data.count
      wp.plannedCount    = wp.plannedCount + data.numPlanned
      wp.plannedBaseRate = wp.plannedBaseRate + rateInfo.ratePerModule * data.numPlanned
      for resourceWare in pairs(rateInfo.resources) do
        if not resourceWares[resourceWare] then
          local resName, resIcon = GetWareData(resourceWare, "name", "icon")
          resourceWares[resourceWare] = {
            name         = resName or resourceWare,
            icon         = (resIcon and resIcon ~= "") and resIcon or "solid",
            moduleCount  = 0,
            plannedCount = 0,
          }
        end
        resourceWares[resourceWare].moduleCount  = resourceWares[resourceWare].moduleCount + data.count
        resourceWares[resourceWare].plannedCount = resourceWares[resourceWare].plannedCount + data.numPlanned
      end
    end
  end

  if next(wareProduction) == nil and next(resourceWares) == nil then
    row = tableInfo:addRow(true, {})
    row[1]:setColSpan(6):createText(ReadText(1972092416, 1003), { halign = "center", wordwrap = true })
    return
  end

  -- Populate live production figures from the engine (includes workforce bonus).
  -- productionCurrent = current effective rate (C API, ignorestate=false).
  -- productionPlanned = current effective + planned-module base contribution * workforceMultiplier.
  for ware, wp in pairs(wareProduction) do
    wp.productionCurrent = Helper.round(C.GetContainerWareProduction(station, ware, spo.showEstimated))
    wp.productionPlanned = wp.productionCurrent + Helper.round(wp.plannedBaseRate * workforceMultiplier)
  end

  local extraConsumption = extraConsumptionFromPlanned(moduleData)
  local moduleCounts     = not spo.showEstimated and collectModuleCountsForWares(station) or {}

  -- ── classify produced wares as products or intermediates ──
  -- A ware is an "intermediate" if it also appears as a resource (input) consumed
  -- by other modules on this same station; otherwise it is a "product".
  local products         = {}
  local intermediates    = {}
  local resources        = {}

  local function makeEntry(ware, wp, productionCurrent, productionPlanned, moduleCount, plannedCount)
    local consumptionCurrentRaw = math.max(0, C.GetContainerWareConsumption(station, ware, spo.showEstimated))
    local consumptionCurrent = consumptionCurrentRaw
    if Helper.getWorkforceConsumption then
      consumptionCurrent = consumptionCurrent + Helper.getWorkforceConsumption(station, ware)
    end
    local consumptionPlanned = consumptionCurrent + (extraConsumption[ware] or 0)
    -- activeCount: number of modules currently running (live mode only)
    local activeCount        = moduleCount
    if not spo.showEstimated and moduleCount > 0 then
      local productionMax = Helper.round(C.GetContainerWareProduction(station, ware, true))
      if productionMax > 0 then
        -- produced ware: ratio of live rate to theoretical-max gives running count
        activeCount = math.min(moduleCount,
          math.max(0, Helper.round(productionCurrent * moduleCount / productionMax)))
      else
        -- pure resource ware: use consumption ratio instead
        local consumptionMax = math.max(0, C.GetContainerWareConsumption(station, ware, true))
        if consumptionMax > 0 then
          activeCount = math.min(moduleCount,
            math.max(0, Helper.round(consumptionCurrentRaw * moduleCount / consumptionMax)))
        end
      end
    end
    local mc = moduleCounts[ware] or { noRes = 0, waitStore = 0 }
    return {
      name               = wp.name,
      icon               = wp.icon,
      noRes              = mc.noRes,
      waitStore          = mc.waitStore,
      moduleCount        = moduleCount,
      plannedCount       = plannedCount,
      activeCount        = activeCount,
      productionCurrent  = productionCurrent,
      productionPlanned  = productionPlanned,
      consumptionCurrent = consumptionCurrent,
      consumptionPlanned = consumptionPlanned,
      totalCurrent       = productionCurrent - consumptionCurrent,
      totalPlanned       = productionPlanned - consumptionPlanned,
    }
  end

  for ware, wp in pairs(wareProduction) do
    local entry = makeEntry(ware, wp, wp.productionCurrent, wp.productionPlanned, wp.moduleCount, wp.plannedCount)
    if resourceWares[ware] then
      table.insert(intermediates, entry)
    else
      table.insert(products, entry)
    end
  end

  -- Pure resource wares: not produced at this station
  for ware, rd in pairs(resourceWares) do
    if not wareProduction[ware] then
      table.insert(resources, makeEntry(ware, rd, 0, 0, rd.moduleCount, rd.plannedCount))
    end
  end

  table.sort(products, function(a, b) return a.name < b.name end)
  table.sort(intermediates, function(a, b) return a.name < b.name end)
  table.sort(resources, function(a, b) return a.name < b.name end)

  -- ── render a group of ware rows under a labelled header ──
  -- Each ware gets a main row with current figures; if planned modules exist a
  -- second row immediately below shows only the incremental planned deltas.
  local function formatDelta(v)
    if Helper.round(v) == 0 then return "" end
    if v > 0 then
      return ColorText["text_positive"] .. "(+" .. fmt(v) .. ")"
    else
      return ColorText["text_negative"] .. "(-" .. fmt(math.abs(v)) .. ")"
    end
  end

  local function renderGroup(tableInfo, entries, label)
    if #entries == 0 then return end
    row = tableInfo:addRow(sectorMode, Helper.headerRowProperties)
    row[1]:setColSpan(6):createText(label, Helper.headerRowCenteredProperties)
    for _, entry in ipairs(entries) do
      local entryGroup = spo.isV9 and not sectorMode and tableInfo:addRowGroup({}) or tableInfo
      -- main row: current figures (selectable — matches NPC name row in crew submenu)
      row = entryGroup:addRow(true, { bgColor = Color["row_background_unselectable"] })
      local countStr
      if not spo.showEstimated and entry.activeCount < entry.moduleCount then
        countStr = tostring(entry.activeCount) .. " (" .. tostring(entry.moduleCount) .. ")"
      else
        countStr = tostring(entry.moduleCount)
      end
      local hasIssue = entry.noRes > 0 or entry.waitStore > 0
      local wareName = hasIssue
          and (Helper.convertColorToText(Color["text_warning"]) .. entry.name .. "\027X")
          or entry.name
      local wareMouseover = ""
      if hasIssue then
        local errColor   = Helper.convertColorToText(Color["text_error"])
        local resetColor = "\027X"
        local lines = {}
        if entry.noRes > 0 then
          lines[#lines + 1] = errColor .. ReadText(1001, 8431) .. " (" .. entry.noRes .. ")" .. resetColor
        end
        if entry.waitStore > 0 then
          lines[#lines + 1] = errColor .. ReadText(1001, 8432) .. " (" .. entry.waitStore .. ")" .. resetColor
        end
        wareMouseover = table.concat(lines, "\n")
      end
      row[1]:createText("\027[" .. entry.icon .. "] " .. wareName, { halign = "left", mouseOverText = wareMouseover })
      row[2]:createText(countStr, { halign = "right" })
      row[3]:createText(entry.productionCurrent > 0 and fmt(entry.productionCurrent) or "--", { halign = "right" })
      row[4]:createText(entry.consumptionCurrent > 0 and fmt(entry.consumptionCurrent) or "--",
        { halign = "right" })
      row[5]:setColSpan(2):createText(formatTotal(entry.totalCurrent, entry.totalCurrent), { halign = "right" })
      -- planned delta row (matches skill sub-rows in crew submenu)
      if entry.plannedCount > 0 then
        local productionDelta  = entry.productionPlanned - entry.productionCurrent
        local consumptionDelta = entry.consumptionPlanned - entry.consumptionCurrent
        row                    = entryGroup:addRow(sectorMode, {})
        row[2]:createText("(+" .. tostring(entry.plannedCount) .. ")", { halign = "right" })
        row[3]:createText(formatDelta(productionDelta), { halign = "right" })
        row[4]:createText(formatDelta(consumptionDelta), { halign = "right" })
        row[5]:setColSpan(2):createText(formatDelta(entry.totalPlanned), { halign = "right" })
      end
    end
  end

  local stationGroup = spo.isV9 and sectorMode and tableInfo:addRowGroup({}) or tableInfo
  renderGroup(stationGroup, products, ReadText(1972092416, 120))
  renderGroup(stationGroup, intermediates, ReadText(1972092416, 121))
  renderGroup(stationGroup, resources, ReadText(1972092416, 122))
end

--- Add the Configure Station and Station Overview buttons to the bottom of the production submenu.
function spo.addButtonsToProductionSubmenu(tableButton, station, sectorMode, active)
  if active == nil then active = true end
  local buttonRowGroup = spo.isV9 and sectorMode and tableButton:addRowGroup({}) or tableButton
  local row = buttonRowGroup:addRow("info_button_bottom", { fixed = not sectorMode })
  row[1]:setColSpan(sectorMode and 2 or 1):createButton({ y = Helper.borderSize, active = active }):setText(ReadText(1001, 1136), { halign = "center" }) -- Configure Station
  row[1].handlers.onClick = function()
    Helper.closeMenuAndOpenNewMenu(menu, "StationConfigurationMenu", { 0, 0, station })
    menu.cleanup()
  end
  local nextButtonCell = sectorMode and 3 or 2
  row[nextButtonCell]:setColSpan(sectorMode and 4 or 1):createButton({ y = Helper.borderSize, active = active }):setText(ReadText(1001, 1138), { halign = "center" }) -- Station Overview
  row[nextButtonCell].handlers.onClick  = function()
    Helper.closeMenuAndOpenNewMenu(menu, "StationOverviewMenu", { 0, 0, station })
    menu.cleanup()
  end
end

--- Build the frame-border, table, and connections for the production submenu.
--- Follows the structure of menu.createCrewInfoSubmenu exactly.
function spo.createProductionSubmenu(inputframe, instance)
  -- temporary fix
  if instance == "right" then
    inputframe = menu.infoFrame2
  end
  -- temporary fix

  local frameHeight = inputframe.properties.height
  resolveInfoSubmenuObject()

  local infoBorder = nil
  if spo.isV9 then
    infoBorder = inputframe:addFrameBorder("spo_prodoverview", {
      offsetBottom = Helper.standardContainerOffset,
      active       = menu.panelState[instance .. "menu"],
      color        = Helper.getFrameBorderColor(menu, menu.panelState[instance .. "menu"],
        menu.panelPins[instance .. "menu"]),
      linewidth    = Helper.getFrameBorderLineWidth(menu, menu.panelState[instance .. "menu"]),
    })
    Helper.setFrameBorderIcon(menu, infoBorder, instance, menu.sideBarWidth / 2)
  end

  local tableInfo = addInfoTable(inputframe, infoBorder)

  if not spo.isV9 then
    --- title ---
    local row = tableInfo:addRow(false, { fixed = true, bgColor = Color["row_title_background"] })
    row[1]:setColSpan(6):createText(ReadText(1001, 2427), Helper.headerRowCenteredProperties)

    local row = tableInfo:addRow(false, { fixed = true, bgColor = Color["row_title_background"] })
    row[1]:setColSpan(6):createText(ReadText(1972092416, 1), Helper.headerRowCenteredProperties)
  end

  spo.setupProductionSubmenuRows(tableInfo, menu.infoSubmenuObject, instance, false)

  restoreTableSelection(tableInfo, instance)

  local tableHeader      = spo.isV9 and menu.createOrdersMenuHeader(inputframe, infoBorder, instance) or
      menu.createOrdersMenuHeader(inputframe, instance)
  tableInfo.properties.y = tableHeader.properties.y + tableHeader:getFullHeight() + Helper.borderSize

  -- ── bottom buttons: Configure Station + Station Overview ──
  local tableButton      = inputframe:addTable(2, spo.isV9 and {
    tabOrder          = 2,
    backgroundID      = "solid",
    backgroundColor   = Color["container_subsection_background"] or nil,
    backgroundPadding = 0,
    frameborder       = infoBorder.id or nil,
  } or {
    tabOrder = 2,
  })
  tableButton:setColWidthPercent(2, 50)

  local isStation = menu.infoSubmenuObject and (tonumber(menu.infoSubmenuObject) ~= 0)
      and C.IsComponentClass(menu.infoSubmenuObject, "station")
  spo.addButtonsToProductionSubmenu(tableButton, menu.infoSubmenuObject, false, isStation)

  tableButton.properties.y = frameHeight - tableButton:getFullHeight()

  local infoTableHeight    = tableInfo:getFullHeight()
  local buttonTableHeight  = tableButton:getFullHeight()
  if tableInfo.properties.y + infoTableHeight + buttonTableHeight + Helper.borderSize + Helper.frameBorder < frameHeight then
    tableButton.properties.y = tableInfo.properties.y + infoTableHeight + Helper.borderSize
  else
    tableButton.properties.y = frameHeight - Helper.frameBorder - buttonTableHeight
    tableInfo.properties.maxVisibleHeight = tableButton.properties.y - Helper.borderSize - tableInfo.properties.y
  end

  local isLeft = instance == "left"
  if isLeft then
    menu.playerinfotable:addConnection(1, 2, true)
  end
  tableHeader:addConnection(isLeft and 2 or 1, isLeft and 2 or 3, true)
  tableInfo:addConnection(isLeft and 3 or 2, isLeft and 2 or 3)
  tableButton:addConnection(isLeft and 4 or 3, isLeft and 2 or 3)
end

-- ─── sector panel builder ────────────────────────────────────────────────────

--- Populate tableInfo with production rows for all player stations in a sector.
--- Each station is a self-contained block (reuses setupProductionSubmenuRows),
--- followed by Configure Station / Station Overview buttons in the same table.
function spo.setupSectorProductionSubmenuRows(tableInfo, sector, instance)
  local isSector = sector and (tonumber(sector) ~= 0)
      and C.IsComponentClass(sector, "sector")

  local titleColor = Color["text_normal"]
  if not spo.isV9 then
    local isPlayerOwned, isEnemy, isHostile = GetComponentData(sector, "isplayerowned", "isenemy", "ishostile")
    if isPlayerOwned then
      titleColor = menu.holomapcolor.playercolor
    elseif isHostile then
      titleColor = menu.holomapcolor.hostilecolor
    elseif isEnemy then
      titleColor = menu.holomapcolor.enemycolor
    end
  end

  if not spo.isV9 then
    --- title ---
    local row = tableInfo:addRow(false, { fixed = true, bgColor = Color["row_title_background"] })
    row[1]:setColSpan(6):createText(ReadText(1001, 2427), Helper.headerRowCenteredProperties)

    local row = tableInfo:addRow(false, { fixed = true, bgColor = Color["row_title_background"] })
    row[1]:setColSpan(6):createText(ReadText(1972092416, 3), Helper.headerRowCenteredProperties)
  end

  -- ── sector title row ──
  titleColor = spo.isV9 and (isSector and menu.getObjectColor(sector) or Color["text_normal"]) or titleColor
  local sectorName = isSector
      and ffi.string(C.GetComponentName(sector))
      or ReadText(1972092416, 3)

  local row = tableInfo:addRow("info_focus",
    { fixed = true, bgColor = not spo.isV9 and Color["row_title_background"] or nil })
  row[6]:createButton({
    width = config.mapRowHeight,
    height = config.mapRowHeight,
    cellBGColor = Color
        ["row_background"]
  })
      :setIcon("menu_center_selection",
        {
          width = config.mapRowHeight,
          height = config.mapRowHeight,
          y = not spo.isV9 and
              (Helper.headerRow1Height - config.mapRowHeight) / 2 or nil
        })
  row[6].handlers.onClick = function() return C.SetFocusMapComponent(menu.holomap, menu.infoSubmenuObject, true) end
  if spo.isV9 then
    row[1]:setBackgroundColSpan(5):setColSpan(5):createText(sectorName,
      { fontsize = Helper.headerRow1FontSize, color = titleColor })
  else
    row[1]:setBackgroundColSpan(5):setColSpan(5):createText(sectorName, Helper.headerRow1Properties)
    row[1].properties.color = titleColor
  end

  if not isSector then
    row = tableInfo:addRow(true, {})
    row[1]:setColSpan(6):createText(ReadText(1972092416, 1004), { halign = "center", wordwrap = true })
    return
  end

  -- collect player-owned stations in this sector that have production modules
  local stations = {}
  local stationIds = GetContainedStationsByOwner("player", sector)
  for _, stationId in ipairs(stationIds) do
    local station64 = ConvertIDTo64Bit(stationId)
    local moduleData = collectModuleData(station64)
    if next(moduleData) ~= nil then
      table.insert(stations, { id = station64, name = ffi.string(C.GetComponentName(station64)) })
    end
  end

  if #stations == 0 then
    row = tableInfo:addRow(true, {})
    row[1]:setColSpan(6):createText(ReadText(1972092416, 1004), { halign = "center", wordwrap = true })
    return
  end

  table.sort(stations, Helper.sortName)

  spo.toggleEstimatedCurrent(tableInfo)
  spo.columnHeaders(tableInfo)
  -- render each station block, followed by its action buttons
  for i = 1, #stations do
    local stationInfo = stations[i]
    local station = stationInfo.id
    spo.setupProductionSubmenuRows(tableInfo, station, instance, true)
    spo.addButtonsToProductionSubmenu(tableInfo, station, true)
    if i < #stations then
      tableInfo:addEmptyRow(2 * Helper.standardContainerOffset, false, Color["row_background_unselectable"])
    end
  end
end

--- Build the frame-border, table, and connections for the sector production submenu.
function spo.createSectorProductionSubmenu(inputframe, instance)
  -- temporary fix
  if instance == "right" then
    inputframe = menu.infoFrame2
  end
  -- temporary fix

  local frameHeight = inputframe.properties.height
  resolveInfoSubmenuObject()

  local infoBorder = nil
  if spo.isV9 then
    infoBorder = inputframe:addFrameBorder("spo_sectoroverview", {
      offsetBottom = Helper.standardContainerOffset,
      active       = menu.panelState[instance .. "menu"],
      color        = Helper.getFrameBorderColor(menu, menu.panelState[instance .. "menu"],
        menu.panelPins[instance .. "menu"]),
      linewidth    = Helper.getFrameBorderLineWidth(menu, menu.panelState[instance .. "menu"]),
    })
    Helper.setFrameBorderIcon(menu, infoBorder, instance, menu.sideBarWidth / 2)
  end

  local tableInfo = addInfoTable(inputframe, infoBorder)

  spo.setupSectorProductionSubmenuRows(tableInfo, menu.infoSubmenuObject, instance)

  restoreTableSelection(tableInfo, instance)

  local tableHeader = spo.isV9 and menu.createOrdersMenuHeader(inputframe, infoBorder, instance) or
      menu.createOrdersMenuHeader(inputframe, instance)
  tableInfo.properties.y                = tableHeader.properties.y + tableHeader:getFullHeight() + Helper.borderSize
  tableInfo.properties.maxVisibleHeight = frameHeight - tableInfo.properties.y - Helper.frameBorder

  local isLeft                          = instance == "left"
  if isLeft then
    menu.playerinfotable:addConnection(1, 2, true)
  end
  tableHeader:addConnection(isLeft and 2 or 1, isLeft and 2 or 3, true)
  tableInfo:addConnection(isLeft and 3 or 2, isLeft and 2 or 3)
end

--- info_sub_menu_create callback: render our sub-tab.
--- ALL registered info_sub_menu_create callbacks fire for any unknown infoMode,
--- so we must guard against other mods' modes.
function spo.onInfoSubMenuCreate(infoFrame, instance)
  local activeMode = (instance == "right") and menu.infoMode.right or menu.infoMode.left
  if activeMode ~= SPO_CATEGORY then return end
  spo.createProductionSubmenu(infoFrame, instance)
end

--- info_sub_menu_is_valid_for callback: allow our tab for player-owned stations only.
function spo.onInfoSubMenuIsValidFor(object, mode)
  if mode ~= SPO_CATEGORY then return false end
  if not object or object == 0 then return false end
  local classId, isPlayerOwned = GetComponentData(object, "realclassid", "isplayerowned")
  return classId ~= nil and Helper.isComponentClass(classId, "station") and isPlayerOwned
end

function spo.onInfoSubMenuToShow(object, mode)
  if mode ~= SPO_CATEGORY then return nil end
  return spo.onInfoSubMenuIsValidFor(object, mode)
end

function spo.onSectorInfoSubMenuCreate(infoFrame, instance)
  local activeMode = (instance == "right") and menu.infoMode.right or menu.infoMode.left
  if activeMode ~= SSPO_CATEGORY then return end
  spo.createSectorProductionSubmenu(infoFrame, instance)
end

function spo.onSectorInfoSubMenuIsValidFor(object, mode)
  if mode ~= SSPO_CATEGORY then return false end
  if not object or object == 0 then return false end
  local classId = GetComponentData(object, "realclassid")
  return classId ~= nil and Helper.isComponentClass(classId, "sector")
end

function spo.onSectorInfoSubMenuToShow(object, mode)
  if mode ~= SSPO_CATEGORY then return nil end
  return spo.onSectorInfoSubMenuIsValidFor(object, mode)
end

-- ─── init ────────────────────────────────────────────────────────────────────

local function init()
  menu = Helper.getMenu("MapMenu")
  if not menu then
    DebugError("station_production_overview: MapMenu not found – is kuertee_ui_extensions loaded?")
    return
  end

  config = type(menu.uix_getConfig) == "function" and menu.uix_getConfig() or {}

  -- Insert station + sector tabs into config.infoCategories after "objectinfo".
  if config.infoCategories then
    local objectInfoIdx  = nil
    local stationTabIdx  = nil
    local sectorTabFound = false
    for i, entry in ipairs(config.infoCategories) do
      if entry.category == "objectinfo"  then objectInfoIdx  = i end
      if entry.category == SPO_CATEGORY  then stationTabIdx  = i end
      if entry.category == SSPO_CATEGORY then sectorTabFound = true end
    end
    if not stationTabIdx and objectInfoIdx then
      table.insert(config.infoCategories, objectInfoIdx + 1, {
        category        = SPO_CATEGORY,
        name            = ReadText(1972092416, 1),
        icon            = "stationbuildst_production",
        helpOverlayID   = "chem_station_prod_overview",
        helpOverlayText = ReadText(1972092416, 2),
      })
      stationTabIdx = objectInfoIdx + 1
    end
    if not sectorTabFound and stationTabIdx then
      table.insert(config.infoCategories, stationTabIdx + 1, {
        category        = SSPO_CATEGORY,
        name            = ReadText(1972092416, 3),
        icon            = "stationbuildst_production",
        helpOverlayID   = "chem_sector_prod_overview",
        helpOverlayText = ReadText(1972092416, 4),
      })
    end
  end

  menu.registerCallback("info_sub_menu_to_show", spo.onInfoSubMenuToShow)
  menu.registerCallback("info_sub_menu_is_valid_for", spo.onInfoSubMenuIsValidFor)
  menu.registerCallback("info_sub_menu_create", spo.onInfoSubMenuCreate)
  menu.registerCallback("info_sub_menu_to_show", spo.onSectorInfoSubMenuToShow)
  menu.registerCallback("info_sub_menu_is_valid_for", spo.onSectorInfoSubMenuIsValidFor)
  menu.registerCallback("info_sub_menu_create", spo.onSectorInfoSubMenuCreate)
end

Register_OnLoad_Init(init)
