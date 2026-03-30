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

local ffi          = require("ffi")
local C            = ffi.C

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
]]

-- infoMode.left key that identifies our sub-tab (must be unique across mods)
local SPO_CATEGORY = "chem_station_prod_overview"

-- Resolved in init()
local menu         = nil
local config       = nil

local spo          = {}
spo.showEstimated  = false   -- false = live state, true = all modules active (ignorestate)

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

-- ─── formatting helpers ──────────────────────────────────────────────────────

local function fmt(n)
  return ConvertIntegerString(Helper.round(n), true, 0, true, false)
end

local function formatPair(cur, pla)
  local cs = fmt(cur)
  if Helper.round(cur) ~= Helper.round(pla) then
    return cs .. "\n(+" .. fmt(pla - cur) .. ")"
  end
  return cs
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

--- Populate tableInfo with the production summary rows.
--- Wares are grouped into "Products" (not consumed as a resource by any module at this
--- station) and "Intermediates" (also consumed as input by other modules here).
--- Within each group wares are sorted alphabetically.
function spo.setupProductionSubmenuRows(tableInfo, station, instance)
  local isStation = station and (tonumber(station) ~= 0)
      and C.IsComponentClass(station, "station")

  -- ── info_focus row: object name + map-focus button ──
  local titleColor = isStation and menu.getObjectColor(station) or Color["text_normal"]
  local objectName = isStation
      and ffi.string(C.GetComponentName(station))
      or "Production Overview"

  local row = tableInfo:addRow("info_focus", { fixed = true })
  row[6]:createButton({ width = config.mapRowHeight, height = config.mapRowHeight, cellBGColor = Color["row_background"] })
      :setIcon("menu_center_selection", { width = config.mapRowHeight, height = config.mapRowHeight })
  row[6].handlers.onClick = function() return C.SetFocusMapComponent(menu.holomap, menu.infoSubmenuObject, true) end
  row[1]:setBackgroundColSpan(5):setColSpan(5):createText(objectName, { fontsize = Helper.headerRow1FontSize, color = titleColor })

  -- ── estimated/current toggle row ──
  local modeOptions = {
    { id = "live",      text = ReadText(1972092416, 100), icon = "", displayremoveoption = false },
    { id = "estimated", text = ReadText(1972092416, 101), icon = "", displayremoveoption = false },
  }
  row = tableInfo:addRow(true, { fixed = true })
  row[1]:setColSpan(6):createDropDown(modeOptions, { height = config.mapRowHeight, startOption = spo.showEstimated and "estimated" or "live" })
      :setTextProperties({ halign = "center", font = Helper.titleFont, fontsize = Helper.standardFontSize, y = Helper.headerRow1Offsety })
  row[1].handlers.onDropDownConfirmed = function(_, id)
    spo.showEstimated = (id == "estimated")
    menu.refreshInfoFrame()
  end
  row[1].handlers.onDropDownActivated = function() menu.noupdate = true end

  -- ── column header row ──
  row = tableInfo:addRow(false, { fixed = true })
  row[1]:createText(ReadText(1972092416, 110), Helper.headerRowCenteredProperties)
  row[2]:createText(ReadText(1972092416, 111), Helper.headerRowCenteredProperties)
  row[3]:createText(ReadText(1972092416, 112), Helper.headerRowCenteredProperties)
  row[4]:createText(ReadText(1972092416, 113), Helper.headerRowCenteredProperties)
  row[5]:setColSpan(2):createText(ReadText(1972092416, 114), Helper.headerRowCenteredProperties)

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
  local workforceBonus        = GetComponentData(station, "workforcebonus") or 0
  local workforceMultiplier   = 1 + workforceBonus

  local resourceWares   = {}   -- [ware] = { name, moduleCount, plannedCount }  (pure inputs)
  local wareProduction  = {}   -- [ware] = { name, moduleCount, plannedCount, plannedBaseRate }

  for _, data in pairs(moduleData) do
    local rates = getBaseRates(data.macro)
    for _, rateInfo in ipairs(rates) do
      local ware = rateInfo.ware
      if not wareProduction[ware] then
        wareProduction[ware] = {
          name              = GetWareData(ware, "name") or ware,
          moduleCount       = 0,
          plannedCount      = 0,
          plannedBaseRate   = 0,   -- sum of ratePerModule * numplanned across all macros
        }
      end
      local wp               = wareProduction[ware]
      wp.moduleCount         = wp.moduleCount        + data.count
      wp.plannedCount        = wp.plannedCount       + data.numPlanned
      wp.plannedBaseRate     = wp.plannedBaseRate    + rateInfo.ratePerModule * data.numPlanned
      for resourceWare in pairs(rateInfo.resources) do
        if not resourceWares[resourceWare] then
          resourceWares[resourceWare] = {
            name         = GetWareData(resourceWare, "name") or resourceWare,
            moduleCount  = 0,
            plannedCount = 0,
          }
        end
        resourceWares[resourceWare].moduleCount  = resourceWares[resourceWare].moduleCount  + data.count
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

  -- ── classify produced wares as products or intermediates ──
  -- A ware is an "intermediate" if it also appears as a resource (input) consumed
  -- by other modules on this same station; otherwise it is a "product".
  local products      = {}
  local intermediates = {}
  local resources     = {}

  local function makeEntry(ware, wp, productionCurrent, productionPlanned, moduleCount, plannedCount)
    local consumptionCurrentRaw = math.max(0, C.GetContainerWareConsumption(station, ware, spo.showEstimated))
    local consumptionCurrent = consumptionCurrentRaw
    if Helper.getWorkforceConsumption then
      consumptionCurrent = consumptionCurrent + Helper.getWorkforceConsumption(station, ware)
    end
    local consumptionPlanned   = consumptionCurrent + (extraConsumption[ware] or 0)
    -- activeCount: number of modules currently running (live mode only)
    local activeCount = moduleCount
    if not spo.showEstimated and moduleCount > 0 then
      local productionMax = Helper.round(C.GetContainerWareProduction(station, ware, true))
      if productionMax > 0 then
        -- produced ware: ratio of live rate to theoretical-max gives running count
        activeCount = math.min(moduleCount, math.max(0, Helper.round(productionCurrent * moduleCount / productionMax)))
      else
        -- pure resource ware: use consumption ratio instead
        local consumptionMax = math.max(0, C.GetContainerWareConsumption(station, ware, true))
        if consumptionMax > 0 then
          activeCount = math.min(moduleCount, math.max(0, Helper.round(consumptionCurrentRaw * moduleCount / consumptionMax)))
        end
      end
    end
    return {
      name         = wp.name,
      moduleCount  = moduleCount,
      plannedCount = plannedCount,
      activeCount  = activeCount,
      productionCurrent = productionCurrent,
      productionPlanned = productionPlanned,
      consumptionCurrent = consumptionCurrent,
      consumptionPlanned = consumptionPlanned,
      totalCurrent = productionCurrent - consumptionCurrent,
      totalPlanned = productionPlanned - consumptionPlanned,
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

  table.sort(products,      function(a, b) return a.name < b.name end)
  table.sort(intermediates, function(a, b) return a.name < b.name end)
  table.sort(resources,     function(a, b) return a.name < b.name end)

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

  local function renderGroup(entries, label)
    if #entries == 0 then return end
    row = tableInfo:addRow(false, Helper.headerRowProperties)
    row[1]:setColSpan(6):createText(label, Helper.headerRowCenteredProperties)
    for _, entry in ipairs(entries) do
      local entryGroup = tableInfo:addRowGroup({})
      -- main row: current figures (selectable — matches NPC name row in crew submenu)
      row = entryGroup:addRow(true, { bgColor = Color["row_background_unselectable"] })
      row[1]:createText(entry.name, { wordwrap = true })
      local countStr
      if not spo.showEstimated and entry.activeCount < entry.moduleCount then
        countStr = tostring(entry.activeCount) .. " (" .. tostring(entry.moduleCount) .. ")"
      else
        countStr = tostring(entry.moduleCount)
      end
      row[2]:createText(countStr, { halign = "right" })
      row[3]:createText(entry.productionCurrent > 0 and fmt(entry.productionCurrent) or "--", { halign = "right" })
      row[4]:createText(entry.consumptionCurrent > 0 and fmt(entry.consumptionCurrent) or "--", { halign = "right" })
      row[5]:setColSpan(2):createText(formatTotal(entry.totalCurrent, entry.totalCurrent), { halign = "right" })
      -- planned delta row (matches skill sub-rows in crew submenu)
      if entry.plannedCount > 0 then
        local productionDelta  = entry.productionPlanned  - entry.productionCurrent
        local consumptionDelta = entry.consumptionPlanned - entry.consumptionCurrent
        row = entryGroup:addRow(false, {  })
        row[2]:createText("(+" .. tostring(entry.plannedCount) .. ")", { halign = "right" })
        row[3]:createText(formatDelta(productionDelta),    { halign = "right" })
        row[4]:createText(formatDelta(consumptionDelta),   { halign = "right" })
        row[5]:setColSpan(2):createText(formatDelta(entry.totalPlanned), { halign = "right" })
      end
    end
  end

  renderGroup(products,      ReadText(1972092416, 120))
  renderGroup(intermediates, ReadText(1972092416, 121))
  renderGroup(resources,     ReadText(1972092416, 122))
end

--- Build the frame-border, table, and connections for the production submenu.
--- Follows the structure of menu.createCrewInfoSubmenu exactly.
function spo.createProductionSubmenu(inputframe, instance)
  local frameHeight = inputframe.properties.height
  -- infoSubmenuObject fallback (mirrors all vanilla info submenus)
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

  local infoBorder = inputframe:addFrameBorder("spo_prodoverview", {
    offsetBottom = Helper.standardContainerOffset,
    active       = menu.panelState[instance .. "menu"],
    color        = Helper.getFrameBorderColor(menu, menu.panelState[instance .. "menu"], menu.panelPins[instance .. "menu"]),
    linewidth    = Helper.getFrameBorderLineWidth(menu, menu.panelState[instance .. "menu"]),
  })
  Helper.setFrameBorderIcon(menu, infoBorder, instance, menu.sideBarWidth / 2)

  local tableInfo = inputframe:addTable(6, {
    tabOrder          = 1,
    x                 = Helper.standardContainerOffset,
    width             = inputframe.properties.width - 2 * Helper.standardContainerOffset,
    backgroundID      = "solid",
    backgroundColor   = Color["container_subsection_background"],
    backgroundPadding = 0,
    frameborder       = infoBorder.id,
  })
  tableInfo:setColWidthMinPercent(1, 32)          -- variable width; grows to fill space reserved for scrollbar
  tableInfo:setColWidthPercent(2, 11)             -- Count
  tableInfo:setColWidthPercent(3, 16)             -- Prod/h
  tableInfo:setColWidthPercent(4, 16)             -- Cons/h
  tableInfo:setColWidthPercent(5, 16)             -- Total/h
  tableInfo:setColWidth(6, config.mapRowHeight)   -- focus button (auto-scaled)
  tableInfo:setDefaultBackgroundColSpan(1, 6)
  tableInfo:setDefaultCellProperties("text", { minRowHeight = config.mapRowHeight, fontsize = config.mapFontSize })
  tableInfo:setDefaultCellProperties("button", { height = config.mapRowHeight })

  spo.setupProductionSubmenuRows(tableInfo, menu.infoSubmenuObject, instance)

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
  menu.setrow             = nil
  menu.settoprow          = nil
  menu.setcol             = nil

  local tableHeader      = menu.createOrdersMenuHeader(inputframe, infoBorder, instance)
  tableInfo.properties.y = tableHeader.properties.y + tableHeader:getFullHeight() + Helper.borderSize

  -- ── bottom buttons: Configure Station + Station Overview ──
  local tableButton      = inputframe:addTable(2, {
    tabOrder          = 2,
    backgroundID      = "solid",
    backgroundColor   = Color["container_subsection_background"],
    backgroundPadding = 0,
    frameborder       = infoBorder.id,
  })
  tableButton:setColWidthPercent(2, 50)
  local buttonRowGroup = tableButton:addRowGroup({})
  local row = buttonRowGroup:addRow("info_button_bottom", { fixed = true })
  row[1]:createButton({ y = Helper.borderSize }):setText(ReadText(1001, 1136), { halign = "center" })   -- Configure Station
  row[1].handlers.onClick = function()
    Helper.closeMenuAndOpenNewMenu(menu, "StationConfigurationMenu", { 0, 0, menu.infoSubmenuObject })
    menu.cleanup()
  end
  row[2]:createButton({ y = Helper.borderSize }):setText(ReadText(1001, 1138), { halign = "center" })   -- Station Overview
  row[2].handlers.onClick = function()
    Helper.closeMenuAndOpenNewMenu(menu, "StationOverviewMenu", { 0, 0, menu.infoSubmenuObject })
    menu.cleanup()
  end
  tableButton.properties.y = frameHeight - tableButton:getFullHeight()

  local infoTableHeight   = tableInfo:getFullHeight()
  local buttonTableHeight = tableButton:getFullHeight()
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

-- ─── init ────────────────────────────────────────────────────────────────────

local function init()
  menu = Helper.getMenu("MapMenu")
  if not menu then
    DebugError("station_production_overview: MapMenu not found – is kuertee_ui_extensions loaded?")
    return
  end

  config = type(menu.uix_getConfig) == "function" and menu.uix_getConfig() or {}

  -- Insert our tab into config.infoCategories immediately after "objectinfo".
  if config.infoCategories then
    local insertAt = #config.infoCategories
    for i, entry in ipairs(config.infoCategories) do
      if entry.category == SPO_CATEGORY then
        insertAt = nil; break         -- already present
      end
      if entry.category == "objectinfo" then
        insertAt = i
      end
    end
    if insertAt then
      table.insert(config.infoCategories, insertAt + 1, {
        category        = SPO_CATEGORY,
        name            = ReadText(1972092416, 1),
        icon            = "stationbuildst_production",
        helpOverlayID   = "chem_station_prod_overview",
        helpOverlayText = ReadText(1972092416, 2),
      })
    end
  end

  menu.registerCallback("info_sub_menu_to_show", spo.onInfoSubMenuToShow)
  menu.registerCallback("info_sub_menu_is_valid_for", spo.onInfoSubMenuIsValidFor)
  menu.registerCallback("info_sub_menu_create", spo.onInfoSubMenuCreate)
end

Register_OnLoad_Init(init)
