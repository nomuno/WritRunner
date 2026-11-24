-- Turn-in routing: continent/zone grouping, nearest-neighbor order,
-- shopping list, and map waypoints (C_Map + optional TomTom).

local WR = WritRunner
WR.Route = WR.Route or {}
local Route = WR.Route

-- Fallback continents for Forever when C_Map has not been walked yet.
-- Riverglades is treated as Eastern Kingdoms (it borders Swamp of Sorrows).
local FALLBACK_CONTINENT = {
  ["Alterac Mountains"] = "Eastern Kingdoms",
  ["Arathi Highlands"] = "Eastern Kingdoms",
  ["Badlands"] = "Eastern Kingdoms",
  ["Blasted Lands"] = "Eastern Kingdoms",
  ["Burning Steppes"] = "Eastern Kingdoms",
  ["Deadwind Pass"] = "Eastern Kingdoms",
  ["Duskwood"] = "Eastern Kingdoms",
  ["Eastern Plaguelands"] = "Eastern Kingdoms",
  ["Hillsbrad Foothills"] = "Eastern Kingdoms",
  ["Riverglades"] = "Eastern Kingdoms",
  ["Searing Gorge"] = "Eastern Kingdoms",
  ["Stranglethorn Vale"] = "Eastern Kingdoms",
  ["Swamp of Sorrows"] = "Eastern Kingdoms",
  ["The Hinterlands"] = "Eastern Kingdoms",
  ["Western Plaguelands"] = "Eastern Kingdoms",
  ["Wetlands"] = "Eastern Kingdoms",
  ["Ashenvale"] = "Kalimdor",
  ["Azshara"] = "Kalimdor",
  ["Desolace"] = "Kalimdor",
  ["Dustwallow Marsh"] = "Kalimdor",
  ["Felwood"] = "Kalimdor",
  ["Feralas"] = "Kalimdor",
  ["Moonglade"] = "Kalimdor",
  ["Silithus"] = "Kalimdor",
  ["Stonetalon Mountains"] = "Kalimdor",
  ["Tanaris"] = "Kalimdor",
  ["Thousand Needles"] = "Kalimdor",
  ["Un'Goro Crater"] = "Kalimdor",
  ["Winterspring"] = "Kalimdor",
}

-- Classic-era map IDs used only as a last-resort lookup when the live
-- C_Map walk does not find a name. Forever map IDs may differ; test in-game.
local FALLBACK_MAP_ID = {
  ["Alterac Mountains"] = 1416,
  ["Arathi Highlands"] = 1417,
  ["Badlands"] = 1418,
  ["Blasted Lands"] = 1419,
  ["Burning Steppes"] = 1428,
  ["Deadwind Pass"] = 1430,
  ["Duskwood"] = 1431,
  ["Eastern Plaguelands"] = 1423,
  ["Hillsbrad Foothills"] = 1424,
  ["Searing Gorge"] = 1427,
  ["Stranglethorn Vale"] = 1434,
  ["Swamp of Sorrows"] = 1435,
  ["The Hinterlands"] = 1425,
  ["Western Plaguelands"] = 1422,
  ["Wetlands"] = 1437,
  ["Ashenvale"] = 1440,
  ["Azshara"] = 1447,
  ["Desolace"] = 1443,
  ["Dustwallow Marsh"] = 1445,
  ["Felwood"] = 1448,
  ["Feralas"] = 1444,
  ["Moonglade"] = 1450,
  ["Silithus"] = 1451,
  ["Stonetalon Mountains"] = 1442,
  ["Tanaris"] = 1446,
  ["Thousand Needles"] = 1441,
  ["Un'Goro Crater"] = 1449,
  ["Winterspring"] = 1452,
}

local zoneToMapId = {}
local zoneToContinent = {}
local zoneWorld = {}
local mapBuilt = false

local function NormalizeName(name)
  if not name then
    return nil
  end
  return string.lower((name:gsub("^%s+", ""):gsub("%s+$", "")))
end

local function WalkMaps(mapId, continentName, depth)
  if not mapId or not C_Map or not C_Map.GetMapInfo or depth > 8 then
    return
  end
  local info = C_Map.GetMapInfo(mapId)
  if not info then
    return
  end
  local name = info.name
  local mapType = info.mapType
  local thisContinent = continentName
  -- mapType 2 is typically a continent on Mainline.
  if mapType == 2 then
    thisContinent = name
  end
  if name then
    local key = NormalizeName(name)
    zoneToMapId[key] = mapId
    if thisContinent then
      zoneToContinent[key] = thisContinent
    end
    if C_Map.GetWorldPosFromMapPos then
      local ok, continentID, worldPos = pcall(C_Map.GetWorldPosFromMapPos, mapId, CreateVector2D and CreateVector2D(0.5, 0.5) or { x = 0.5, y = 0.5 })
      if ok and worldPos and worldPos.x and worldPos.y then
        zoneWorld[key] = { continentID = continentID, x = worldPos.x, y = worldPos.y }
      end
    end
  end
  if C_Map.GetMapChildrenInfo then
    local children = C_Map.GetMapChildrenInfo(mapId, nil, true)
    if children then
      local i
      for i = 1, #children do
        WalkMaps(children[i].mapID, thisContinent, depth + 1)
      end
    end
  end
end

function Route.BuildMapIndex()
  if mapBuilt then
    return
  end
  if not C_Map or not C_Map.GetMapInfo then
    return
  end
  -- Cosmic (947) and Azeroth (947/946 variants) plus the player's map tree.
  local roots = { 947, 946, 0 }
  if C_Map.GetBestMapForUnit then
    local playerMap = C_Map.GetBestMapForUnit("player")
    if playerMap then
      local cursor = playerMap
      local guard = 0
      while cursor and guard < 12 do
        roots[#roots + 1] = cursor
        local info = C_Map.GetMapInfo(cursor)
        cursor = info and info.parentMapID
        guard = guard + 1
      end
    end
  end
  local seen = {}
  local i
  for i = 1, #roots do
    local id = roots[i]
    if id and not seen[id] then
      seen[id] = true
      WalkMaps(id, nil, 0)
    end
  end
  mapBuilt = true
end

function Route.ContinentForZone(zone)
  if not zone then
    return "Unknown"
  end
  Route.BuildMapIndex()
  local key = NormalizeName(zone)
  return zoneToContinent[key] or FALLBACK_CONTINENT[zone] or "Unknown"
end

function Route.MapIdForZone(zone)
  if not zone then
    return nil
  end
  Route.BuildMapIndex()
  local key = NormalizeName(zone)
  return zoneToMapId[key] or FALLBACK_MAP_ID[zone]
end

function Route.ZoneWorldPos(zone)
  if not zone then
    return nil
  end
  Route.BuildMapIndex()
  local key = NormalizeName(zone)
  if zoneWorld[key] then
    return zoneWorld[key]
  end
  local mapId = Route.MapIdForZone(zone)
  if mapId and C_Map and C_Map.GetWorldPosFromMapPos then
    local ok, continentID, worldPos = pcall(C_Map.GetWorldPosFromMapPos, mapId, CreateVector2D and CreateVector2D(0.5, 0.5) or { x = 0.5, y = 0.5 })
    if ok and worldPos and worldPos.x and worldPos.y then
      local pos = { continentID = continentID, x = worldPos.x, y = worldPos.y }
      zoneWorld[key] = pos
      return pos
    end
  end
  return nil
end

local function Dist2(a, b)
  if not a or not b then
    return nil
  end
  if a.continentID and b.continentID and a.continentID ~= b.continentID then
    return nil
  end
  local dx = a.x - b.x
  local dy = a.y - b.y
  return dx * dx + dy * dy
end

-- Forever's C_Map APIs are mainline-strict about argument types. Always
-- pcall, and pass a real Vector2D when the API wants a position.
function Route.Vec2(x, y)
  if type(x) ~= "number" or type(y) ~= "number" then
    return nil
  end
  if CreateVector2D then
    local ok, v = pcall(CreateVector2D, x, y)
    if ok and v then
      return v
    end
  end
  return nil
end

function Route.GetPlayerWorldPos()
  if not C_Map or not C_Map.GetBestMapForUnit or not C_Map.GetPlayerMapPosition then
    return nil
  end
  local mapId = C_Map.GetBestMapForUnit("player")
  if not mapId or type(mapId) ~= "number" then
    return nil
  end
  -- Confirmed in-game: GetPlayerMapPosition requires (mapId, "player").
  local okPos, pos = pcall(C_Map.GetPlayerMapPosition, mapId, "player")
  if not okPos or not pos or type(pos.x) ~= "number" or type(pos.y) ~= "number" then
    return nil
  end
  if not C_Map.GetWorldPosFromMapPos then
    return nil
  end
  local ok, continentID, worldPos = pcall(C_Map.GetWorldPosFromMapPos, mapId, pos)
  if ok and worldPos and type(worldPos.x) == "number" and type(worldPos.y) == "number" then
    return { continentID = continentID, x = worldPos.x, y = worldPos.y, mapId = mapId }
  end
  return nil
end

function Route.PlayerContinentName()
  if not C_Map or not C_Map.GetBestMapForUnit or not C_Map.GetMapInfo then
    return nil
  end
  local mapId = C_Map.GetBestMapForUnit("player")
  local guard = 0
  while mapId and guard < 12 do
    local ok, info = pcall(C_Map.GetMapInfo, mapId)
    if not ok or not info then
      break
    end
    if info.mapType == 2 and info.name then
      return info.name
    end
    mapId = info.parentMapID
    guard = guard + 1
  end
  return nil
end

function Route.WritWorldPos(writ)
  if not writ then
    return nil
  end
  local mapId = Route.MapIdForZone(writ.zone)
  if writ.coords and mapId and C_Map and C_Map.GetWorldPosFromMapPos then
    local vec = Route.Vec2(writ.coords.x / 100, writ.coords.y / 100)
    if vec then
      local ok, continentID, worldPos = pcall(C_Map.GetWorldPosFromMapPos, mapId, vec)
      if ok and worldPos and type(worldPos.x) == "number" and type(worldPos.y) == "number" then
        return { continentID = continentID, x = worldPos.x, y = worldPos.y, precise = true }
      end
    end
  end
  local zp = Route.ZoneWorldPos(writ.zone)
  if zp then
    return { continentID = zp.continentID, x = zp.x, y = zp.y, precise = false }
  end
  return nil
end

-- Convert a 0-1 point on fromMapId onto toMapId, or nil if it is not on that map.
function Route.MapPosOnMap(fromMapId, x, y, toMapId)
  if type(fromMapId) ~= "number" or type(toMapId) ~= "number" then
    return nil
  end
  if type(x) ~= "number" or type(y) ~= "number" then
    return nil
  end
  if fromMapId == toMapId then
    return x, y
  end
  if not C_Map or not C_Map.GetWorldPosFromMapPos or not C_Map.GetMapPosFromWorldPos then
    return nil
  end
  local vec = Route.Vec2(x, y)
  if not vec then
    return nil
  end
  local ok, continentID, worldPos = pcall(C_Map.GetWorldPosFromMapPos, fromMapId, vec)
  if not ok or not worldPos then
    return nil
  end
  local ok2, uiMapID, mapPos = pcall(C_Map.GetMapPosFromWorldPos, continentID, worldPos, toMapId)
  if not ok2 or not mapPos or type(mapPos.x) ~= "number" or type(mapPos.y) ~= "number" then
    return nil
  end
  if mapPos.x < -0.02 or mapPos.x > 1.02 or mapPos.y < -0.02 or mapPos.y > 1.02 then
    return nil
  end
  if uiMapID and uiMapID ~= toMapId then
    return nil
  end
  return mapPos.x, mapPos.y
end

local CONTINENT_ORDER = {
  ["Eastern Kingdoms"] = 1,
  ["Kalimdor"] = 2,
  Unknown = 9,
}

-- Nearest-neighbor over zones on the same continent. Continents themselves
-- are visited in a fixed Alliance-friendly EK-then-Kalimdor order; Horde
-- players still get a valid tour, just not a faction-optimized start.
function Route.OrderZones(zones)
  local byContinent = {}
  local i
  for i = 1, #zones do
    local z = zones[i]
    local c = Route.ContinentForZone(z)
    byContinent[c] = byContinent[c] or {}
    local list = byContinent[c]
    local seen = false
    local j
    for j = 1, #list do
      if list[j] == z then
        seen = true
        break
      end
    end
    if not seen then
      list[#list + 1] = z
    end
  end

  local continents = {}
  for c in pairs(byContinent) do
    continents[#continents + 1] = c
  end
  table.sort(continents, function(a, b)
    local oa, ob = CONTINENT_ORDER[a] or 5, CONTINENT_ORDER[b] or 5
    if oa ~= ob then
      return oa < ob
    end
    return a < b
  end)

  local ordered = {}
  for i = 1, #continents do
    local remaining = {}
    local src = byContinent[continents[i]]
    local j
    for j = 1, #src do
      remaining[j] = src[j]
    end
    -- Prefer starting at the zone closest to the player when we have a
    -- world position, otherwise keep alphabetical start then NN.
    local startIndex = 1
    local playerPos = Route.GetPlayerWorldPos()
    if playerPos then
      local best, bestD = 1, nil
      for j = 1, #remaining do
        local wp = Route.ZoneWorldPos(remaining[j])
        local d = Dist2(playerPos, wp)
        if d and (not bestD or d < bestD) then
          best, bestD = j, d
        end
      end
      startIndex = best
    else
      table.sort(remaining)
    end

    local current = table.remove(remaining, startIndex)
    ordered[#ordered + 1] = current
    while #remaining > 0 do
      local curPos = Route.ZoneWorldPos(current)
      local best, bestD, bestName = 1, nil, remaining[1]
      for j = 1, #remaining do
        local d = Dist2(curPos, Route.ZoneWorldPos(remaining[j]))
        if d and (not bestD or d < bestD) then
          best, bestD, bestName = j, d, remaining[j]
        elseif not d and not bestD and remaining[j] < bestName then
          best, bestName = j, remaining[j]
        end
      end
      current = table.remove(remaining, best)
      ordered[#ordered + 1] = current
    end
  end
  return ordered
end

local function NearestNeighbor(items, startPos)
  local remaining = {}
  local i
  for i = 1, #items do
    remaining[i] = items[i]
  end
  local ordered = {}
  local currentPos = startPos
  while #remaining > 0 do
    local best, bestD, bestKey = 1, nil, remaining[1].sortKey or ""
    local j
    for j = 1, #remaining do
      local d = Dist2(currentPos, remaining[j].worldPos)
      if d and (not bestD or d < bestD) then
        best, bestD, bestKey = j, d, remaining[j].sortKey or ""
      elseif not d and not bestD then
        local key = remaining[j].sortKey or ""
        if key < bestKey then
          best, bestKey = j, key
        end
      end
    end
    local item = table.remove(remaining, best)
    ordered[#ordered + 1] = item
    if item.worldPos then
      currentPos = item.worldPos
    end
  end
  return ordered
end

local function PlayerZoneName()
  if not C_Map or not C_Map.GetBestMapForUnit or not C_Map.GetMapInfo then
    return nil
  end
  local mapId = C_Map.GetBestMapForUnit("player")
  if not mapId then
    return nil
  end
  local ok, info = pcall(C_Map.GetMapInfo, mapId)
  return (ok and info and info.name) or nil
end

local function TravelHint(prev, curr, isFirst)
  local zone = curr.writ and curr.writ.zone
  local continent = curr.continent
  if isFirst then
    local playerCont = Route.PlayerContinentName()
    local playerZone = PlayerZoneName()
    if continent and playerCont and playerCont ~= continent and continent ~= "Unknown" then
      if zone then
        return "Take a boat or zeppelin to " .. continent .. ", then go to " .. zone
      end
      return "Take a boat or zeppelin to " .. continent
    end
    if zone and playerZone and playerZone ~= zone then
      return "Fly to " .. zone
    end
    return nil
  end
  if not prev then
    return nil
  end
  if prev.continent ~= continent and continent and continent ~= "Unknown" then
    if zone then
      return "Take a boat or zeppelin to " .. continent .. ", then go to " .. zone
    end
    return "Take a boat or zeppelin to " .. continent
  end
  local prevZone = prev.writ and prev.writ.zone
  if zone and prevZone ~= zone then
    return "Fly to " .. zone
  end
  return nil
end

-- Flatten a picked set into a tour: finish one continent at a time
-- (player's continent first), nearest-neighbor on actual turn-in world
-- positions when known, otherwise the zone center.
function Route.OrderStops(picked)
  local byContinent = {}
  local i
  for i = 1, #(picked or {}) do
    local row = picked[i]
    local w = row.writ
    local continent = Route.ContinentForZone(w.zone)
    local item = {
      writ = w,
      price = row.price,
      continent = continent,
      mapId = Route.MapIdForZone(w.zone),
      worldPos = Route.WritWorldPos(w),
      sortKey = (w.zone or "") .. "\0" .. (w.writItemName or ""),
    }
    byContinent[continent] = byContinent[continent] or {}
    local list = byContinent[continent]
    list[#list + 1] = item
  end

  local continents = {}
  for c in pairs(byContinent) do
    continents[#continents + 1] = c
  end
  local playerCont = Route.PlayerContinentName()
  table.sort(continents, function(a, b)
    if playerCont then
      if a == playerCont and b ~= playerCont then
        return true
      end
      if b == playerCont and a ~= playerCont then
        return false
      end
    end
    local oa, ob = CONTINENT_ORDER[a] or 5, CONTINENT_ORDER[b] or 5
    if oa ~= ob then
      return oa < ob
    end
    return a < b
  end)

  local playerPos = Route.GetPlayerWorldPos()
  local steps = {}
  for i = 1, #continents do
    local group = byContinent[continents[i]]
    local startPos = nil
    if i == 1 and playerPos then
      startPos = playerPos
    elseif #steps > 0 then
      startPos = steps[#steps].worldPos
    end
    local ordered = NearestNeighbor(group, startPos)
    local j
    for j = 1, #ordered do
      steps[#steps + 1] = ordered[j]
    end
  end

  for i = 1, #steps do
    steps[i].travel = TravelHint(steps[i - 1], steps[i], i == 1)
  end
  return steps
end

-- Group a picked set of ranked rows into a shopping list and a route.
function Route.Build(picked)
  local shop = {}
  local shopIndex = {}
  local i
  for i = 1, #(picked or {}) do
    local row = picked[i]
    local w = row.writ
    local function addShop(itemId, name, count, copperEach)
      if not itemId then
        return
      end
      local rec = shopIndex[itemId]
      if not rec then
        rec = { itemId = itemId, name = name, count = 0, copperEach = copperEach }
        shopIndex[itemId] = rec
        shop[#shop + 1] = rec
      end
      rec.count = rec.count + (count or 1)
      if copperEach and not rec.copperEach then
        rec.copperEach = copperEach
      end
    end
    addShop(w.writItemId, w.writItemName, 1, row.price and row.price.writCopper)
    addShop(w.requiredItemId, w.requiredItemName, w.requiredCount or 1, row.price and row.price.unitCopper)
  end

  table.sort(shop, function(a, b)
    return (a.name or "") < (b.name or "")
  end)

  local steps = Route.OrderStops(picked or {})
  -- Keep a zone-grouped view for existing callers, in tour order. A zone
  -- can appear more than once if the tour leaves and comes back.
  local route = {}
  local last
  for i = 1, #steps do
    local step = steps[i]
    local zone = (step.writ and step.writ.zone) or "Unknown zone"
    if not last or last.zone ~= zone then
      last = {
        zone = zone,
        continent = step.continent,
        mapId = step.mapId,
        stops = {},
      }
      route[#route + 1] = last
    end
    last.stops[#last.stops + 1] = { writ = step.writ, price = step.price, travel = step.travel }
  end

  return { shop = shop, route = route, steps = steps }
end

function Route.NextUndoneStop(route)
  if not route then
    return nil, nil
  end
  local i, j
  for i = 1, #route do
    local stops = route[i].stops
    for j = 1, #stops do
      local row = stops[j]
      if not (WR.Daily and WR.Daily.IsCompleted(row.writ)) then
        return route[i], row
      end
    end
  end
  return nil, nil
end

function Route.SetWaypointForWrit(writ)
  if not writ then
    return false, "No writ selected."
  end
  if not writ.coords or not writ.zone then
    return false, "No published coordinates for " .. (writ.writItemName or "this writ") .. "."
  end
  local mapId = Route.MapIdForZone(writ.zone)
  if not mapId then
    return false, "No map ID is known for " .. writ.zone .. " on this client (Forever map IDs may differ from Classic). Set the waypoint by hand."
  end

  local x = writ.coords.x / 100
  local y = writ.coords.y / 100
  local title = (writ.npc or "Turn-in") .. " – " .. (writ.writItemName or "")

  local tomtomOk = false
  if TomTom and TomTom.AddWaypoint then
    local ok = pcall(TomTom.AddWaypoint, TomTom, mapId, x, y, { title = title })
    tomtomOk = ok and true or false
  end

  local blizzOk = false
  local reason
  if C_Map and C_Map.SetUserWaypoint and UiMapPoint and UiMapPoint.CreateFromCoordinates then
    local canSet = true
    if C_Map.CanSetUserWaypointOnMap then
      canSet = C_Map.CanSetUserWaypointOnMap(mapId)
    end
    if canSet then
      local ok, err = pcall(function()
        C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(mapId, x, y))
        if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
          C_SuperTrack.SetSuperTrackedUserWaypoint(true)
        end
      end)
      blizzOk = ok
      if not ok then
        reason = tostring(err)
      end
    else
      reason = "Blizzard waypoints are not allowed on this map."
    end
  else
    reason = "Blizzard waypoint API is not available."
  end

  if blizzOk or tomtomOk then
    local bits = {}
    if blizzOk then
      bits[#bits + 1] = "map waypoint"
    end
    if tomtomOk then
      bits[#bits + 1] = "TomTom"
    end
    return true, "Waypoint set (" .. table.concat(bits, " + ") .. "): " .. title
  end
  return false, reason or "Could not set a waypoint."
end
