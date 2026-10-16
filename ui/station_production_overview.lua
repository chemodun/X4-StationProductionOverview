-- Station Production Overview: a Production Overview tab in the map info panel for player-owned stations
-- and sectors, built on the kuertee UI Extensions info_sub_menu_* callbacks.

local ffi = require("ffi")
local C   = ffi.C

-- StorageInfo, GetCargoTransportTypes and GetContainerWareMaxProductionStorageForTime come from vanilla's cdefs.
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
	UniverseID   GetPlayerID(void);
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

	typedef struct {
		uint32_t current;
		uint32_t capacity;
		uint32_t optimal;
		uint32_t available;
		uint32_t maxavailable;
		double   timeuntilnextupdate;
	} WorkForceInfo;
	WorkForceInfo GetWorkForceInfo(UniverseID containerid, const char* raceid);
]]

local PAGE          = 1972092416

-- infoMode.left keys of our sub-tabs (must be unique across mods)
local SPO_CATEGORY  = "chem_station_prod_overview"
local SSPO_CATEGORY = "chem_sector_prod_overview"

local menu          = nil
local config        = nil

local spo           = {
  showEstimated       = false, -- false = live state, true = all modules active (ignorestate)
  showEmpireData      = false,
  showStorage         = false,
  isV9                = C.GetGameVersion().major >= 9,
  playerId            = nil,
  debugLevel          = "none",
  modeOptions         = {
    { id = "live",      text = ReadText(PAGE, 100), icon = "", displayremoveoption = false },
    { id = "estimated", text = ReadText(PAGE, 101), icon = "", displayremoveoption = false },
  },
  dataRefreshInterval = 3,
  dataCache           = {}, -- "station:instance" -> computed station data
  ignoreNoResources   = false,
  ignoreWaitStore     = false,
  ignorePaused        = false,
  showErrorsAsSubrow  = true,
  sortBy              = "name",
  forecastRedHours    = 2,
  forecastYellowHours = 6,
}

-- Module states in vanilla station overview order; ignore names the spo flag that hides the state.
local ISSUES        = {
  { key = "destroyed", text = 8428, color = "text_error" },
  { key = "damaged",   text = 8429, color = "text_error" },
  { key = "hacked",    text = 8430, color = "text_error" },
  { key = "paused",    text = 8448, color = "text_warning", ignore = "ignorePaused" },
  { key = "noRes",     text = 8431, color = "text_error",   ignore = "ignoreNoResources" },
  { key = "waitStore", text = 8432, color = "text_warning", ignore = "ignoreWaitStore" },
}

local FLOW_KEYS     = { "productionCurrent", "productionPlanned", "consumptionCurrent", "consumptionPlanned", "totalCurrent", "totalPlanned" }

local STORAGE_NAMES = { container = 101, solid = 301, liquid = 601, condensate = 9801 } -- page 20109

local function write(message, ...)
  if select("#", ...) > 0 then
    message = string.format(message, ...)
  end
  DebugError("StationProductionOverview: " .. message)
end

function spo.Error(message, ...) write(message, ...) end

function spo.Debug(message, ...) if spo.debugLevel ~= "none" then write(message, ...) end end

function spo.Trace(message, ...) if spo.debugLevel == "trace" then write(message, ...) end end

local function spoOnConfigChanged()
  if spo.playerId == nil then return end
  local cfg = GetNPCBlackboard(spo.playerId, "$stationProductionOverview")
  if cfg then
    if cfg.dataRefreshInterval then
      spo.dataRefreshInterval = math.max(1, math.min(10, tonumber(cfg.dataRefreshInterval) or 3))
    end
    spo.ignoreNoResources  = cfg.ignoreNoResources == 1
    spo.ignoreWaitStore    = cfg.ignoreWaitStore == 1
    spo.ignorePaused       = cfg.ignorePaused == 1
    spo.showErrorsAsSubrow = cfg.showErrorsAsSubrow ~= 0 -- nil counts as true
    spo.sortBy             = (cfg.sortBy == "balance") and "balance" or "name"
    spo.forecastRedHours   = math.max(1, math.min(24, tonumber(cfg.forecastRedHours) or 2))
    spo.forecastYellowHours = math.max(spo.forecastRedHours, math.min(24, tonumber(cfg.forecastYellowHours) or 6))
    spo.debugLevel         = cfg.debugLevel and tostring(cfg.debugLevel) or "none"
    spo.dataCache          = {}
    spo.Debug("config: refresh %s, ignore noRes %s waitStore %s paused %s, subrows %s, sort %s, forecast red %sh yellow %sh",
      spo.dataRefreshInterval, tostring(spo.ignoreNoResources), tostring(spo.ignoreWaitStore),
      tostring(spo.ignorePaused), tostring(spo.showErrorsAsSubrow), spo.sortBy,
      spo.forecastRedHours, spo.forecastYellowHours)
  end
end

-- ─── data collection ────────────────────────────────────────────────────────

local function moduleIssue(module, isProcessing)
  local hacked, functional, paused = GetComponentData(module, "ishacked", "isfunctional", "ispausedmanually")
  if hacked then return "hacked" end
  if paused then return "paused" end
  if not functional then return "damaged" end
  local data = isProcessing and GetProcessingModuleData(module) or GetProductionModuleData(module)
  local state = data and data.state
  if state == "waitingforstorage" or ((state == "choosingitem") and not isProcessing) then return "waitStore" end
  if state == "waitingforresources" then return "noRes" end
  return nil
end

local function newModuleEntry(macro)
  local entry = { macro = macro, count = 0, numPlanned = 0 }
  for _, issue in ipairs(ISSUES) do entry[issue.key] = 0 end
  return entry
end

--- Production / processing modules of a station grouped by macro, with planned and per-state counts.
local function collectModuleData(station)
  local moduleData = {}

  local n = tonumber(C.GetNumStationModules(station, true, true))
  if n > 0 then
    local buf = ffi.new("UniverseID[?]", n)
    n = tonumber(C.GetStationModules(buf, n, station, true, true))
    for i = 0, n - 1 do
      local module = ConvertStringTo64Bit(tostring(buf[i]))
      local isProc = C.IsRealComponentClass(module, "processingmodule")
      if isProc or C.IsRealComponentClass(module, "production") then
        local wrecked = C.IsComponentWrecked(module)
        if wrecked or (IsValidComponent(module) and not IsComponentConstruction(module)) then
          local macro = GetComponentData(module, "macro")
          local entry = moduleData[macro] or newModuleEntry(macro)
          moduleData[macro] = entry
          if wrecked then
            entry.destroyed = entry.destroyed + 1
          else
            entry.count = entry.count + 1
            local issue = moduleIssue(module, isProc)
            if issue then
              entry[issue] = entry[issue] + 1
            end
          end
        end
      end
    end
  end

  -- componentid == 0: a brand-new module, not a rebuild or an upgrade
  local np = tonumber(C.GetNumPlannedStationModules(station, true))
  if np > 0 then
    local pBuf = ffi.new("UIConstructionPlanEntry[?]", np)
    np = tonumber(C.GetPlannedStationModules(pBuf, np, station, true))
    for i = 0, np - 1 do
      if tonumber(pBuf[i].componentid) == 0 then
        local mac = ffi.string(pBuf[i].macroid)
        if IsMacroClass(mac, "production") or IsMacroClass(mac, "processingmodule") then
          local entry = moduleData[mac] or newModuleEntry(mac)
          moduleData[mac] = entry
          entry.numPlanned = entry.numPlanned + 1
        end
      end
    end
  end

  return moduleData
end

--- Theoretical rates per module instance per hour: list of { ware, ratePerModule, resources = { [ware] = rate } }.
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

--- Extra consumption of all not yet built planned modules: { [ware] = units per hour }.
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

--- Production and consumption (modules + present workforce) of each ware in wareSet over all player stations.
local function collectEmpireDataForWares(wareSet, theoretical)
  local consumption = {}
  local production  = {}
  if not next(wareSet) then return consumption, production end
  for _, stationId in ipairs(GetContainedStationsByOwner("player")) do
    local s64 = ConvertIDTo64Bit(stationId)
    for ware in pairs(wareSet) do
      production[ware]  = (production[ware] or 0) + (C.GetContainerWareProduction(s64, ware, theoretical) or 0)
      consumption[ware] = (consumption[ware] or 0) + (C.GetContainerWareConsumption(s64, ware, theoretical) or 0)
    end
    if type(GetWorkForceRaceResources) == "function" and C.IsComponentClass(s64, "container") then
      for _, ri in ipairs(GetWorkForceRaceResources(s64) or {}) do
        local workerCount = tonumber(C.GetWorkForceInfo(s64, ri.race).current)
        if workerCount > 0 then
          for _, resource in ipairs(ri.resources or {}) do
            if wareSet[resource.ware] then
              local amount = Helper.round(resource.cycle * 3600 / resource.cycleduration * workerCount / ri.productamount)
              if amount > 0 then
                consumption[resource.ware] = (consumption[resource.ware] or 0) + amount
              end
            end
          end
        end
      end
    end
  end
  return consumption, production
end

--- Storage modules by transport type with the hourly volume flow of the given ware entries.
local function collectStorage(station, groups)
  local list = {}
  local n = tonumber(C.GetNumCargoTransportTypes(station, true))
  if n > 0 then
    local buf = ffi.new("StorageInfo[?]", n)
    n = tonumber(C.GetCargoTransportTypes(buf, n, station, true, false))
    for i = 0, n - 1 do
      local tags = {}
      for tag in string.gmatch(ffi.string(buf[i].transport), "%S+") do
        tags[tag] = true
      end
      table.insert(list, {
        name        = ffi.string(buf[i].name),
        tags        = tags,
        used        = tonumber(buf[i].spaceused),
        capacity    = tonumber(buf[i].capacity),
        production  = 0,
        consumption = 0,
      })
    end
  end
  for _, entries in ipairs(groups) do
    for _, entry in ipairs(entries) do
      if entry.transport and entry.volume > 0 then
        local storage
        for _, s in ipairs(list) do
          if s.tags[entry.transport] then
            storage = s
            break
          end
        end
        if not storage then
          storage = {
            name        = STORAGE_NAMES[entry.transport] and ReadText(20109, STORAGE_NAMES[entry.transport]) or entry.transport,
            tags        = { [entry.transport] = true },
            used        = 0,
            capacity    = 0,
            production  = 0,
            consumption = 0,
            missing     = true,
          }
          table.insert(list, storage)
        end
        storage.production  = storage.production + entry.productionCurrent * entry.volume
        storage.consumption = storage.consumption + entry.consumptionCurrent * entry.volume
        entry.noStorage     = storage.missing
      end
    end
  end
  return list
end

local function sortEntries(entries)
  if spo.sortBy == "balance" then
    table.sort(entries, function(a, b)
      if a.totalCurrent ~= b.totalCurrent then return a.totalCurrent < b.totalCurrent end
      return a.name < b.name
    end)
  else
    table.sort(entries, function(a, b) return a.name < b.name end)
  end
end

--- Per-ware figures of a station, grouped into products, intermediates and resources.
---@return table<string, any>
local function computeStationData(station, withEmpire)
  local moduleData = collectModuleData(station)
  if next(moduleData) == nil then
    return { status = "nomodules" }
  end

  -- GetContainerWareProduction already includes the current workforce bonus; planned modules get the same.
  local workforceMultiplier = 1 + (GetComponentData(station, "workforcebonus") or 0)

  local function newWare(ware)
    local name, icon, transport, volume = GetWareData(ware, "name", "icon", "transport", "volume")
    local wd = {
      ware         = ware,
      name         = name or ware,
      icon         = (icon and icon ~= "") and icon or "solid",
      transport    = transport,
      volume       = volume or 0,
      moduleCount  = 0,
      plannedCount = 0,
    }
    for _, issue in ipairs(ISSUES) do wd[issue.key] = 0 end
    return wd
  end

  local produced = {}
  local consumed = {}
  for _, data in pairs(moduleData) do
    for _, rateInfo in ipairs(getBaseRates(data.macro)) do
      local wp = produced[rateInfo.ware]
      if not wp then
        wp = newWare(rateInfo.ware)
        wp.plannedBaseRate = 0
        produced[rateInfo.ware] = wp
      end
      wp.moduleCount     = wp.moduleCount + data.count
      wp.plannedCount    = wp.plannedCount + data.numPlanned
      wp.plannedBaseRate = wp.plannedBaseRate + rateInfo.ratePerModule * data.numPlanned
      for _, issue in ipairs(ISSUES) do
        wp[issue.key] = wp[issue.key] + data[issue.key]
      end
      for resourceWare in pairs(rateInfo.resources) do
        local rd = consumed[resourceWare] or newWare(resourceWare)
        consumed[resourceWare] = rd
        rd.moduleCount  = rd.moduleCount + data.count
        rd.plannedCount = rd.plannedCount + data.numPlanned
      end
    end
  end

  -- wares only the workforce consumes (food, medicine); moduleCount -1 marks them
  if type(GetWorkForceRaceResources) == "function" then
    for _, ri in ipairs(GetWorkForceRaceResources(station) or {}) do
      for _, resource in ipairs(ri.resources or {}) do
        if not produced[resource.ware] and not consumed[resource.ware] then
          local rd = newWare(resource.ware)
          rd.moduleCount, rd.plannedCount = -1, -1
          consumed[resource.ware] = rd
        end
      end
    end
  end

  if next(produced) == nil and next(consumed) == nil then
    return { status = "nowares" }
  end

  local extraConsumption = extraConsumptionFromPlanned(moduleData)
  local cargo = spo.showStorage and (GetComponentData(station, "cargo") or {}) or nil

  local function makeEntry(wd, productionCurrent, productionPlanned)
    local ware = wd.ware
    local consumptionRaw = math.max(0, C.GetContainerWareConsumption(station, ware, spo.showEstimated))
    local consumptionCurrent = consumptionRaw
    if Helper.getWorkforceConsumption then
      consumptionCurrent = consumptionCurrent + Helper.getWorkforceConsumption(station, ware)
    end
    local consumptionPlanned = consumptionCurrent + (extraConsumption[ware] or 0)
    local activeCount = wd.moduleCount
    if not spo.showEstimated and wd.moduleCount > 0 then
      local productionMax = Helper.round(C.GetContainerWareProduction(station, ware, true))
      if productionMax > 0 then
        activeCount = math.min(wd.moduleCount, math.max(0, Helper.round(productionCurrent * wd.moduleCount / productionMax)))
      else
        local consumptionMax = math.max(0, C.GetContainerWareConsumption(station, ware, true))
        if consumptionMax > 0 then
          activeCount = math.min(wd.moduleCount, math.max(0, Helper.round(consumptionRaw * wd.moduleCount / consumptionMax)))
        end
      end
    end
    local entry = {
      ware               = ware,
      name               = wd.name,
      icon               = wd.icon,
      transport          = wd.transport,
      volume             = wd.volume,
      moduleCount        = wd.moduleCount,
      plannedCount       = wd.plannedCount,
      activeCount        = activeCount,
      productionCurrent  = productionCurrent,
      productionPlanned  = productionPlanned,
      consumptionCurrent = consumptionCurrent,
      consumptionPlanned = consumptionPlanned,
      totalCurrent       = productionCurrent - consumptionCurrent,
      totalPlanned       = productionPlanned - consumptionPlanned,
    }
    for _, issue in ipairs(ISSUES) do
      entry[issue.key] = spo.showEstimated and 0 or wd[issue.key]
    end
    if cargo then
      entry.stock        = cargo[ware] or 0
      entry.stockLimit   = GetWareProductionLimit(station, ware)
      entry.stockWarning = ((entry.stockLimit > 0) and (entry.stock > entry.stockLimit))
          or ((Helper.getContainerWareType(station, ware) ~= "trade")
            and (entry.stockLimit < C.GetContainerWareMaxProductionStorageForTime(station, ware, 7200, true)))
    end
    return entry
  end

  local data = { status = "ok", products = {}, intermediates = {}, resources = {} }
  for ware, wp in pairs(produced) do
    local productionCurrent = Helper.round(C.GetContainerWareProduction(station, ware, spo.showEstimated))
    local productionPlanned = productionCurrent + Helper.round(wp.plannedBaseRate * workforceMultiplier)
    table.insert(consumed[ware] and data.intermediates or data.products, makeEntry(wp, productionCurrent, productionPlanned))
  end
  for ware, rd in pairs(consumed) do
    if not produced[ware] then
      table.insert(data.resources, makeEntry(rd, 0, 0))
    end
  end
  sortEntries(data.products)
  sortEntries(data.intermediates)
  sortEntries(data.resources)

  data.empireConsumption, data.empireProduction, data.empireWares = {}, {}, {}
  if withEmpire then
    for ware in pairs(produced) do data.empireWares[ware] = true end
    -- mined and salvaged wares have no production method, so no station can balance them
    for ware in pairs(consumed) do
      local methods = GetWareData(ware, "productionmethods")
      if methods and #methods > 0 then
        data.empireWares[ware] = true
      end
    end
    data.empireConsumption, data.empireProduction = collectEmpireDataForWares(data.empireWares, spo.showEstimated)
  end

  if spo.showStorage then
    data.storage = collectStorage(station, { data.products, data.intermediates, data.resources })
  end

  spo.Trace("station %s: %d products, %d intermediates, %d resources, estimated %s, empire %s, storage %s",
    ffi.string(C.GetComponentName(station)), #data.products, #data.intermediates, #data.resources,
    tostring(spo.showEstimated), tostring(withEmpire), tostring(spo.showStorage))
  return data
end

--- Station data, recomputed every dataRefreshInterval renders or when a display switch changes.
local function getStationData(station, instance, sectorMode)
  local withEmpire = (not sectorMode) and spo.showEmpireData
  local key        = tostring(station) .. ":" .. instance
  local cached     = spo.dataCache[key]
  if cached
      and (cached.showEstimated == spo.showEstimated)
      and (cached.withEmpire == withEmpire)
      and (cached.showStorage == spo.showStorage)
      and (cached.turnCounter < spo.dataRefreshInterval) then
    cached.turnCounter = cached.turnCounter + 1
    return cached
  end
  local data         = computeStationData(station, withEmpire)
  data.showEstimated = spo.showEstimated
  data.withEmpire    = withEmpire
  data.showStorage   = spo.showStorage
  data.turnCounter   = 1
  spo.dataCache[key] = data
  return data
end

--- Sector-wide sums of the station entries, regrouped by where the wares are made and used in the sector.
local function sumSectorEntries(stations)
  local byWare = {}
  local function add(entry, isProduced, isConsumed)
    local sum = byWare[entry.ware]
    if not sum then
      sum = { ware = entry.ware, name = entry.name, icon = entry.icon, moduleCount = -1, activeCount = 0, plannedCount = 0 }
      for _, key in ipairs(FLOW_KEYS) do sum[key] = 0 end
      for _, issue in ipairs(ISSUES) do sum[issue.key] = 0 end
      byWare[entry.ware] = sum
    end
    if entry.moduleCount >= 0 then
      sum.moduleCount = math.max(sum.moduleCount, 0) + entry.moduleCount
      sum.activeCount = sum.activeCount + entry.activeCount
    end
    sum.plannedCount = sum.plannedCount + math.max(entry.plannedCount, 0)
    for _, key in ipairs(FLOW_KEYS) do sum[key] = sum[key] + entry[key] end
    for _, issue in ipairs(ISSUES) do sum[issue.key] = sum[issue.key] + entry[issue.key] end
    sum.isProduced = sum.isProduced or isProduced
    sum.isConsumed = sum.isConsumed or isConsumed
  end
  for _, stationInfo in ipairs(stations) do
    local data = stationInfo.data
    if data.status == "ok" then
      for _, entry in ipairs(data.products) do add(entry, true, false) end
      for _, entry in ipairs(data.intermediates) do add(entry, true, true) end
      for _, entry in ipairs(data.resources) do add(entry, false, true) end
    end
  end
  local products, intermediates, resources = {}, {}, {}
  for _, sum in pairs(byWare) do
    if sum.isProduced and sum.isConsumed then
      table.insert(intermediates, sum)
    elseif sum.isProduced then
      table.insert(products, sum)
    else
      table.insert(resources, sum)
    end
  end
  sortEntries(products)
  sortEntries(intermediates)
  sortEntries(resources)
  return products, intermediates, resources
end

-- ─── formatting helpers ──────────────────────────────────────────────────────

local function fmt(n)
  return ConvertIntegerString(Helper.round(n), true, 0, true, false)
end

local function formatTotal(v)
  if Helper.round(v) == 0 then
    return fmt(v)
  elseif v > 0 then
    return ColorText["text_positive"] .. "+" .. fmt(v)
  else
    return ColorText["text_negative"] .. "-" .. fmt(math.abs(v))
  end
end

local function formatDelta(v)
  if Helper.round(v) == 0 then return "" end
  if v > 0 then
    return ColorText["text_positive"] .. "(+" .. fmt(v) .. ")"
  else
    return ColorText["text_negative"] .. "(-" .. fmt(math.abs(v)) .. ")"
  end
end

--- Empire balance text and colour, dimmer than the main row.
local function formatEmpireBalance(v)
  if Helper.round(v) == 0 then
    return fmt(v), Color["text_inactive"]
  elseif v > 0 then
    return "+" .. fmt(v), Color["text_player_lowlight"]
  else
    return "-" .. fmt(math.abs(v)), Color["faction_xenon"]
  end
end

local function formatDuration(seconds)
  return ConvertTimeString(seconds, (seconds < 3600) and ReadText(1001, 209) or ReadText(1001, 207))
end

local function fmtShort(n)
  return ConvertIntegerString(Helper.round(n), true, 3, true)
end

local function forecastColor(seconds)
  if seconds < spo.forecastRedHours * 3600 then
    return ColorText["text_negative"]
  elseif seconds < spo.forecastYellowHours * 3600 then
    return ColorText["text_warning"]
  end
  return ColorText["text_positive"]
end

--- When the amount runs out or reaches the limit at the given hourly balance; "" when steady or far away.
local function stockForecast(amount, limit, balance)
  balance = Helper.round(balance)
  if (limit > 0) and (amount >= limit) and (balance >= 0) then
    return forecastColor(0) .. ReadText(PAGE, 135)
  end
  if balance < 0 then
    if amount <= 0 then
      return forecastColor(0) .. ReadText(PAGE, 134)
    end
    local seconds = amount / -balance * 3600
    if seconds < 1000 * 3600 then
      return forecastColor(seconds) .. string.format(ReadText(PAGE, 132), formatDuration(seconds))
    end
  elseif balance > 0 and limit > 0 then
    local seconds = (limit - amount) / balance * 3600
    if seconds < 1000 * 3600 then
      return forecastColor(seconds) .. string.format(ReadText(PAGE, 133), formatDuration(seconds))
    end
  end
  return ""
end

local function issueLines(entry)
  local lines = {}
  for _, issue in ipairs(ISSUES) do
    local count = entry[issue.key] or 0
    if count > 0 and not (issue.ignore and spo[issue.ignore]) then
      lines[#lines + 1] = ColorText[issue.color] .. ReadText(1001, issue.text) .. " (" .. count .. ")\027X"
    end
  end
  return lines
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

--- The standard 6-column info table inside inputframe.
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
  tableInfo:setColWidthMinPercent(1, 30)        -- grows into the space reserved for the scrollbar
  tableInfo:setColWidthPercent(2, 13)           -- Count
  tableInfo:setColWidthPercent(3, 16)           -- Prod/h
  tableInfo:setColWidthPercent(4, 16)           -- Cons/h
  tableInfo:setColWidthPercent(5, 16)           -- Total/h
  tableInfo:setColWidth(6, config.mapRowHeight) -- focus button
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

--- Mode dropdown plus the display checkboxes; the empire balance one only in station mode.
function spo.toggleEstimatedCurrent(tableInfo, sectorMode)
  local row = tableInfo:addRow(true, { fixed = true })
  row[1]:setColSpan(6):createDropDown(spo.modeOptions,
    { height = config.mapRowHeight, startOption = spo.showEstimated and "estimated" or "live" })
      :setTextProperties({
        halign = "center",
        font = Helper.titleFont,
        fontsize = Helper.standardFontSize,
        y = Helper.headerRow1Offsety
      })
  row[1].handlers.onDropDownConfirmed = function(_, id)
    spo.showEstimated = (id == "estimated")
    spo.Debug("mode: %s", id)
    menu.refreshInfoFrame()
  end
  row[1].handlers.onDropDownActivated = function() menu.noupdate = true end

  local labelProperties = { font = Helper.titleFont, fontsize = Helper.standardFontSize }
  local checkBoxProperties = function(text)
    return { height = config.mapRowHeight, width = config.mapRowHeight, mouseOverText = text }
  end
  row = tableInfo:addRow(true, { fixed = true })
  local storageCell
  if sectorMode then
    row[1]:createText(ReadText(PAGE, 103), labelProperties)
    storageCell = row[2]:setColSpan(5)
  else
    row[1]:createText(ReadText(PAGE, 102), labelProperties)
    row[2]:createCheckBox(spo.showEmpireData, checkBoxProperties(ReadText(PAGE, 102)))
    row[2].handlers.onClick = function(_, checked)
      spo.showEmpireData = checked
      spo.Debug("empire balance: %s", tostring(checked))
      menu.refreshInfoFrame()
    end
    row[3]:setColSpan(3):createText(ReadText(PAGE, 103), { font = Helper.titleFont, fontsize = Helper.standardFontSize, halign = "right" })
    storageCell = row[6]
  end
  storageCell:createCheckBox(spo.showStorage, checkBoxProperties(ReadText(PAGE, 103)))
  storageCell.handlers.onClick = function(_, checked)
    spo.showStorage = checked
    spo.Debug("storage: %s", tostring(checked))
    menu.refreshInfoFrame()
  end
end

function spo.columnHeaders(tableInfo)
  local row = tableInfo:addRow(false, { fixed = true })
  row[1]:createText(ReadText(PAGE, 110), Helper.headerRowCenteredProperties)
  row[2]:createText(ReadText(PAGE, 111), Helper.headerRowCenteredProperties)
  row[3]:createText(ReadText(PAGE, 112), Helper.headerRowCenteredProperties)
  row[4]:createText(ReadText(PAGE, 113), Helper.headerRowCenteredProperties)
  row[5]:setColSpan(2):createText(ReadText(PAGE, 114), Helper.headerRowCenteredProperties)
end

--- "Label:" with "amount / limit" and the forecast, as a dim sub-row.
local function addStockRow(group, selectable, label, amount, limit, balance, format, unit, warning)
  local row = group:addRow(selectable, {})
  local text = format(amount) .. ((limit > 0) and (" / " .. format(limit)) or "") .. (unit or "")
  row[1]:createText(label .. ReadText(1001, 120), { halign = "right", color = Color["text_inactive"] })
  row[2]:setColSpan(2):createText(text, { halign = "right", color = warning and Color["text_warning"] or Color["text_inactive"] })
  row[4]:setColSpan(3):createText(stockForecast(amount, limit, balance), { halign = "right" })
end

--- A labelled group of ware rows: main row, then planned delta, issues, empire balance and stock sub-rows.
--- ctx: { sectorMode, empire = station data with empire tables or nil, showStock }
function spo.renderGroup(tableInfo, entries, label, ctx)
  if #entries == 0 then return end
  local sectorMode = ctx.sectorMode
  local row = tableInfo:addRow(sectorMode, Helper.headerRowProperties)
  row[1]:setColSpan(6):createText(label, Helper.headerRowCenteredProperties)
  for _, entry in ipairs(entries) do
    local entryGroup = spo.isV9 and not sectorMode and tableInfo:addRowGroup({}) or tableInfo
    row = entryGroup:addRow(true, { bgColor = Color["row_background_unselectable"] })
    local countStr
    if entry.moduleCount < 0 then
      countStr = "--"
    elseif not spo.showEstimated and entry.activeCount < entry.moduleCount then
      countStr = tostring(entry.activeCount) .. " (" .. tostring(entry.moduleCount) .. ")"
    else
      countStr = tostring(entry.moduleCount)
    end
    local lines    = spo.showEstimated and {} or issueLines(entry)
    local hasIssue = #lines > 0
    local wareName = hasIssue and (ColorText["text_warning"] .. entry.name .. "\027X") or entry.name
    local mouseover = (hasIssue and not spo.showErrorsAsSubrow) and table.concat(lines, "\n") or ""
    row[1]:createText("\027[" .. entry.icon .. "] " .. wareName, { halign = "left", mouseOverText = mouseover })
    row[2]:createText(countStr, { halign = "right" })
    row[3]:createText(entry.productionCurrent > 0 and fmt(entry.productionCurrent) or "--", { halign = "right" })
    row[4]:createText(entry.consumptionCurrent > 0 and fmt(entry.consumptionCurrent) or "--", { halign = "right" })
    row[5]:setColSpan(2):createText(formatTotal(entry.totalCurrent), { halign = "right" })
    if entry.plannedCount > 0 then
      row = entryGroup:addRow(sectorMode, { bgColor = Color["row_background_unselectable"] })
      row[2]:createText("(+" .. tostring(entry.plannedCount) .. ")", { halign = "right" })
      row[3]:createText(formatDelta(entry.productionPlanned - entry.productionCurrent), { halign = "right" })
      row[4]:createText(formatDelta(entry.consumptionPlanned - entry.consumptionCurrent), { halign = "right" })
      row[5]:setColSpan(2):createText(formatDelta(entry.totalPlanned), { halign = "right" })
    end
    if hasIssue and spo.showErrorsAsSubrow then
      row = entryGroup:addRow(sectorMode, { bgColor = Color["row_background_unselectable"] })
      row[1]:setColSpan(6):createText(table.concat(lines, "; "), { halign = "center", wordwrap = true })
    end
    if ctx.empire and ctx.empire.empireWares[entry.ware] then
      local empireCons = ctx.empire.empireConsumption[entry.ware] or 0
      local empireProd = ctx.empire.empireProduction[entry.ware] or 0
      local balanceStr, balanceColor = formatEmpireBalance(empireProd - empireCons)
      row = entryGroup:addRow(sectorMode, {})
      row[1]:createText(ReadText(PAGE, 130), { halign = "right", color = Color["text_inactive"] })
      row[3]:createText(empireProd > 0 and fmt(empireProd) or "--", { halign = "right", color = Color["text_inactive"] })
      row[4]:createText(empireCons > 0 and fmt(empireCons) or "--", { halign = "right", color = Color["text_inactive"] })
      row[5]:setColSpan(2):createText(balanceStr, { halign = "right", color = balanceColor })
    end
    if ctx.showStock and entry.noStorage then
      row = entryGroup:addRow(sectorMode, {})
      row[1]:setColSpan(6):createText(ReadText(PAGE, 136), { halign = "center", color = Color["text_error"], wordwrap = true })
    elseif ctx.showStock and entry.stock then
      addStockRow(entryGroup, sectorMode, ReadText(1001, 20), entry.stock, entry.stockLimit, entry.totalCurrent, fmt, nil, entry.stockWarning)
    end
  end
end

--- Storage per transport type: fill level, hourly volume flow of production and consumption, capacity sub-row.
function spo.renderStorage(tableInfo, storage, sectorMode)
  if not storage or #storage == 0 then return end
  local unit = " " .. ReadText(1001, 110)
  local row = tableInfo:addRow(sectorMode, Helper.headerRowProperties)
  row[1]:setColSpan(6):createText(ReadText(1001, 1400), Helper.headerRowCenteredProperties)
  for _, s in ipairs(storage) do
    local group = spo.isV9 and not sectorMode and tableInfo:addRowGroup({}) or tableInfo
    local net = s.production - s.consumption
    row = group:addRow(true, { bgColor = Color["row_background_unselectable"] })
    row[1]:createText(s.missing and (ColorText["text_error"] .. s.name .. "\027X") or s.name, { halign = "left" })
    row[2]:createText((s.capacity > 0) and (Helper.round(s.used * 100 / s.capacity) .. "%") or "--", { halign = "right" })
    row[3]:createText(s.production > 0 and fmt(s.production) or "--", { halign = "right" })
    row[4]:createText(s.consumption > 0 and fmt(s.consumption) or "--", { halign = "right" })
    row[5]:setColSpan(2):createText(formatTotal(net), { halign = "right" })
    if s.missing then
      row = group:addRow(sectorMode, {})
      row[1]:setColSpan(6):createText(ReadText(PAGE, 136), { halign = "center", color = Color["text_error"], wordwrap = true })
    else
      addStockRow(group, sectorMode, ReadText(1001, 8393), s.used, s.capacity, net, fmtShort, unit, false)
    end
  end
end

--- Populate tableInfo with one station's rows; data is passed in by the sector view.
function spo.setupProductionSubmenuRows(tableInfo, station, instance, sectorMode, data)
  local isStation = station and (tonumber(station) ~= 0)
      and C.IsComponentClass(station, "station")

  -- object name + map-focus button
  local titleColor = spo.isV9 and (isStation and menu.getObjectColor(station) or Color["text_normal"]) or
      menu.holomapcolor.playercolor
  local objectName = isStation
      and ffi.string(C.GetComponentName(station))
      or ReadText(PAGE, 1)

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
    spo.toggleEstimatedCurrent(tableInfo, false)
    spo.columnHeaders(tableInfo)
  end

  local message
  if not isStation then
    message = 1001
  else
    data = data or getStationData(station, instance, sectorMode)
    if data.status == "nomodules" then
      message = 1002
    elseif data.status == "nowares" then
      message = 1003
    end
  end
  if message then
    row = tableInfo:addRow(true, {})
    row[1]:setColSpan(6):createText(ReadText(PAGE, message), { halign = "center", wordwrap = true })
    return
  end

  local ctx = { sectorMode = sectorMode, empire = data.withEmpire and data or nil, showStock = data.showStorage }
  local stationGroup = spo.isV9 and sectorMode and tableInfo:addRowGroup({}) or tableInfo
  spo.renderGroup(stationGroup, data.products, ReadText(PAGE, 120), ctx)
  spo.renderGroup(stationGroup, data.intermediates, ReadText(PAGE, 121), ctx)
  spo.renderGroup(stationGroup, data.resources, ReadText(PAGE, 122), ctx)
  spo.renderStorage(stationGroup, data.storage, sectorMode)
end

--- Configure Station and Station Overview buttons below the production rows.
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
  row[nextButtonCell]:setColSpan(sectorMode and 4 or 1):createButton({ y = Helper.borderSize, active = active }):setText(ReadText(1001, 1138),
    { halign = "center" })                                                                                                                                            -- Station Overview
  row[nextButtonCell].handlers.onClick = function()
    Helper.closeMenuAndOpenNewMenu(menu, "StationOverviewMenu", { 0, 0, station })
    menu.cleanup()
  end
end

--- Frame border, table and connections of the station production submenu, as menu.createCrewInfoSubmenu does.
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
    local row = tableInfo:addRow(false, { fixed = true, bgColor = Color["row_title_background"] })
    row[1]:setColSpan(6):createText(ReadText(1001, 2427), Helper.headerRowCenteredProperties)

    row = tableInfo:addRow(false, { fixed = true, bgColor = Color["row_title_background"] })
    row[1]:setColSpan(6):createText(ReadText(PAGE, 1), Helper.headerRowCenteredProperties)
  end

  spo.setupProductionSubmenuRows(tableInfo, menu.infoSubmenuObject, instance, false)

  restoreTableSelection(tableInfo, instance)

  local tableHeader      = spo.isV9 and menu.createOrdersMenuHeader(inputframe, infoBorder, instance) or
      menu.createOrdersMenuHeader(inputframe, instance)
  tableInfo.properties.y = tableHeader.properties.y + tableHeader:getFullHeight() + Helper.borderSize

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

--- Sector total block: the station entries summed per ware.
function spo.renderSectorTotal(tableInfo, stations)
  local row = tableInfo:addRow(true, { bgColor = not spo.isV9 and Color["row_title_background"] or nil })
  row[1]:setColSpan(6):createText(ReadText(PAGE, 140), spo.isV9 and { fontsize = Helper.headerRow1FontSize } or Helper.headerRow1Properties)
  local products, intermediates, resources = sumSectorEntries(stations)
  local group = spo.isV9 and tableInfo:addRowGroup({}) or tableInfo
  local ctx = { sectorMode = true }
  spo.renderGroup(group, products, ReadText(PAGE, 120), ctx)
  spo.renderGroup(group, intermediates, ReadText(PAGE, 121), ctx)
  spo.renderGroup(group, resources, ReadText(PAGE, 122), ctx)
end

--- All player stations of a sector with production modules: an optional sector total, then one block each.
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
    local row = tableInfo:addRow(false, { fixed = true, bgColor = Color["row_title_background"] })
    row[1]:setColSpan(6):createText(ReadText(1001, 2427), Helper.headerRowCenteredProperties)

    row = tableInfo:addRow(false, { fixed = true, bgColor = Color["row_title_background"] })
    row[1]:setColSpan(6):createText(ReadText(PAGE, 3), Helper.headerRowCenteredProperties)
  end

  titleColor = spo.isV9 and (isSector and menu.getObjectColor(sector) or Color["text_normal"]) or titleColor
  local sectorName = isSector
      and ffi.string(C.GetComponentName(sector))
      or ReadText(PAGE, 3)

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
    row[1]:setColSpan(6):createText(ReadText(PAGE, 1004), { halign = "center", wordwrap = true })
    return
  end

  local stations = {}
  for _, stationId in ipairs(GetContainedStationsByOwner("player", sector)) do
    local station64 = ConvertIDTo64Bit(stationId)
    local data = getStationData(station64, instance, true)
    if data.status ~= "nomodules" then
      table.insert(stations, { id = station64, name = ffi.string(C.GetComponentName(station64)), data = data })
    end
  end

  if #stations == 0 then
    row = tableInfo:addRow(true, {})
    row[1]:setColSpan(6):createText(ReadText(PAGE, 1004), { halign = "center", wordwrap = true })
    return
  end

  table.sort(stations, Helper.sortName)

  spo.toggleEstimatedCurrent(tableInfo, true)
  spo.columnHeaders(tableInfo)
  if #stations > 1 then
    spo.renderSectorTotal(tableInfo, stations)
    tableInfo:addEmptyRow(2 * Helper.standardContainerOffset, false, Color["row_background_unselectable"])
  end
  for i = 1, #stations do
    local stationInfo = stations[i]
    spo.setupProductionSubmenuRows(tableInfo, stationInfo.id, instance, true, stationInfo.data)
    spo.addButtonsToProductionSubmenu(tableInfo, stationInfo.id, true)
    if i < #stations then
      tableInfo:addEmptyRow(2 * Helper.standardContainerOffset, false, Color["row_background_unselectable"])
    end
  end
end

--- Frame border, table and connections of the sector production submenu.
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

  local tableHeader                     = spo.isV9 and menu.createOrdersMenuHeader(inputframe, infoBorder, instance) or
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

--- info_sub_menu_create fires for every unknown infoMode, so other mods' modes must be skipped.
function spo.onInfoSubMenuCreate(infoFrame, instance)
  local activeMode = (instance == "right") and menu.infoMode.right or menu.infoMode.left
  if activeMode ~= SPO_CATEGORY then return end
  spo.createProductionSubmenu(infoFrame, instance)
end

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
    spo.Error("MapMenu not found, is kuertee_ui_extensions loaded?")
    return
  end

  config = type(menu.uix_getConfig) == "function" and menu.uix_getConfig() or {}

  -- station and sector tabs go right after "objectinfo"
  if config.infoCategories then
    local objectInfoIdx  = nil
    local stationTabIdx  = nil
    local sectorTabFound = false
    for i, entry in ipairs(config.infoCategories) do
      if entry.category == "objectinfo" then objectInfoIdx = i end
      if entry.category == SPO_CATEGORY then stationTabIdx = i end
      if entry.category == SSPO_CATEGORY then sectorTabFound = true end
    end
    if not stationTabIdx and objectInfoIdx then
      table.insert(config.infoCategories, objectInfoIdx + 1, {
        category        = SPO_CATEGORY,
        name            = ReadText(PAGE, 1),
        icon            = "stationbuildst_production",
        helpOverlayID   = "chem_station_prod_overview",
        helpOverlayText = ReadText(PAGE, 2),
      })
      stationTabIdx = objectInfoIdx + 1
    end
    if not sectorTabFound and stationTabIdx then
      table.insert(config.infoCategories, stationTabIdx + 1, {
        category        = SSPO_CATEGORY,
        name            = ReadText(PAGE, 3),
        icon            = "stationbuildst_production",
        helpOverlayID   = "chem_sector_prod_overview",
        helpOverlayText = ReadText(PAGE, 4),
      })
    end
  end

  menu.registerCallback("info_sub_menu_to_show", spo.onInfoSubMenuToShow)
  menu.registerCallback("info_sub_menu_is_valid_for", spo.onInfoSubMenuIsValidFor)
  menu.registerCallback("info_sub_menu_create", spo.onInfoSubMenuCreate)
  menu.registerCallback("info_sub_menu_to_show", spo.onSectorInfoSubMenuToShow)
  menu.registerCallback("info_sub_menu_is_valid_for", spo.onSectorInfoSubMenuIsValidFor)
  menu.registerCallback("info_sub_menu_create", spo.onSectorInfoSubMenuCreate)

  spo.playerId = ConvertStringTo64Bit(tostring(C.GetPlayerID()))
  RegisterEvent("SPO.ConfigChanged", spoOnConfigChanged)
  spoOnConfigChanged()
  spo.Debug("initialised, game version 9: %s", tostring(spo.isV9))
end

Register_OnLoad_Init(init)
