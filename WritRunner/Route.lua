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
  ["Tirisfal Glades"] = "Eastern Kingdoms",
  ["Silverpine Forest"] = "Eastern Kingdoms",
  ["Undercity"] = "Eastern Kingdoms",
  ["Westfall"] = "Eastern Kingdoms",
  ["Redridge Mountains"] = "Eastern Kingdoms",
  ["Elwynn Forest"] = "Eastern Kingdoms",
  ["Stormwind"] = "Eastern Kingdoms",
  ["Loch Modan"] = "Eastern Kingdoms",
  ["Dun Morogh"] = "Eastern Kingdoms",
  ["Ironforge"] = "Eastern Kingdoms",
  ["The Barrens"] = "Kalimdor",
  ["Durotar"] = "Kalimdor",
  ["Orgrimmar"] = "Kalimdor",
  ["Mulgore"] = "Kalimdor",
  ["Thunder Bluff"] = "Kalimdor",
  ["Darkshore"] = "Kalimdor",
  ["Teldrassil"] = "Kalimdor",
  ["Darnassus"] = "Kalimdor",
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
      local pos = { continentID = continentID, x = worldPos.x, y = worldPos.y, continent = Route.ContinentForZone(zone) }
      zoneWorld[key] = pos
      return pos
    end
  end
  if Route.FallbackWorldPos then
    return Route.FallbackWorldPos(zone, 50, 50)
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
    return { continentID = continentID, x = worldPos.x, y = worldPos.y, mapId = mapId, continent = Route.PlayerContinentName() }
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
        return { continentID = continentID, x = worldPos.x, y = worldPos.y, precise = true, continent = Route.ContinentForZone(writ.zone) }
      end
    end
  end
  if writ.coords and Route.FallbackWorldPos then
    local fp = Route.FallbackWorldPos(writ.zone, writ.coords.x, writ.coords.y)
    if fp then
      return fp
    end
  end
  local zp = Route.ZoneWorldPos(writ.zone)
  if zp then
    return { continentID = zp.continentID, x = zp.x, y = zp.y, precise = false, continent = zp.continent or Route.ContinentForZone(writ.zone) }
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

-- Classic 1.12 WorldMapArea rects (locLeft, locRight, locTop, locBottom,
-- continent). Used when C_Map world positions are not available. +X is
-- north, +Y is west.
local ZONE_RECT = {
  ["Alterac Mountains"] = { 783.3333, -2016.6666, 1500.0000, -366.6667, "Eastern Kingdoms" },
  ["Arathi Highlands"] = { -866.6666, -4466.6665, -133.3333, -2533.3333, "Eastern Kingdoms" },
  ["Badlands"] = { -2079.1665, -4566.6665, -5889.5830, -7547.9165, "Eastern Kingdoms" },
  ["Blasted Lands"] = { -1241.6666, -4591.6665, -10566.6660, -12800.0000, "Eastern Kingdoms" },
  ["Burning Steppes"] = { -266.6667, -3195.8333, -7031.2495, -8983.3330, "Eastern Kingdoms" },
  ["Deadwind Pass"] = { -833.3333, -3333.3333, -9866.6660, -11533.3330, "Eastern Kingdoms" },
  ["Dun Morogh"] = { 1802.0833, -3122.9165, -3877.0833, -7160.4165, "Eastern Kingdoms" },
  ["Duskwood"] = { 833.3333, -1866.6666, -9716.6660, -11516.6660, "Eastern Kingdoms" },
  ["Eastern Plaguelands"] = { -2185.4165, -6056.2500, 3799.9998, 1218.7500, "Eastern Kingdoms" },
  ["Elwynn Forest"] = { 1535.4166, -1935.4166, -7939.5830, -10254.1660, "Eastern Kingdoms" },
  ["Hillsbrad Foothills"] = { 1066.6666, -2133.3333, 400.0000, -1733.3333, "Eastern Kingdoms" },
  ["Ironforge"] = { -713.5914, -1504.2164, -4569.2410, -5096.8457, "Eastern Kingdoms" },
  ["Loch Modan"] = { -1993.7499, -4752.0830, -4487.5000, -6327.0830, "Eastern Kingdoms" },
  ["Redridge Mountains"] = { -1570.8333, -3741.6665, -8575.0000, -10022.9160, "Eastern Kingdoms" },
  ["Searing Gorge"] = { -322.9167, -2554.1665, -6100.0000, -7587.4995, "Eastern Kingdoms" },
  ["Silverpine Forest"] = { 3449.9998, -750.0000, 1666.6666, -1133.3333, "Eastern Kingdoms" },
  ["Stormwind"] = { 1380.9714, 36.7006, -8278.8510, -9175.2050, "Eastern Kingdoms" },
  ["Stranglethorn Vale"] = { 2220.8333, -4160.4165, -11168.7500, -15422.9160, "Eastern Kingdoms" },
  ["Swamp of Sorrows"] = { -2222.9165, -4516.6665, -9620.8330, -11150.0000, "Eastern Kingdoms" },
  ["The Hinterlands"] = { -1575.0000, -5425.0000, 1466.6666, -1100.0000, "Eastern Kingdoms" },
  ["Tirisfal Glades"] = { 3033.3333, -1485.4166, 3837.4998, 824.9999, "Eastern Kingdoms" },
  ["Undercity"] = { 873.1926, -86.1824, 1877.9453, 1237.8412, "Eastern Kingdoms" },
  ["Western Plaguelands"] = { 416.6667, -3883.3333, 3366.6665, 500.0000, "Eastern Kingdoms" },
  ["Westfall"] = { 3016.6665, -483.3333, -9400.0000, -11733.3330, "Eastern Kingdoms" },
  ["Wetlands"] = { -389.5833, -4525.0000, -2147.9165, -4904.1665, "Eastern Kingdoms" },
  ["Riverglades"] = { -4516.6665, -6800.0000, -9620.8330, -11150.0000, "Eastern Kingdoms" },
  ["Ashenvale"] = { 1699.9999, -4066.6665, 4672.9165, 829.1666, "Kalimdor" },
  ["Azshara"] = { -3277.0833, -8347.9160, 5341.6665, 1960.4166, "Kalimdor" },
  ["Darkshore"] = { 2941.6665, -3608.3333, 8333.3330, 3966.6665, "Kalimdor" },
  ["Darnassus"] = { 2938.3628, 1880.0295, 10238.3160, 9532.5870, "Kalimdor" },
  ["Desolace"] = { 4233.3330, -262.5000, 452.0833, -2545.8333, "Kalimdor" },
  ["Durotar"] = { -1962.4999, -7249.9995, 1808.3333, -1716.6666, "Kalimdor" },
  ["Dustwallow Marsh"] = { -974.9999, -6225.0000, -2033.3333, -5533.3330, "Kalimdor" },
  ["Felwood"] = { 1641.6666, -4108.3330, 7133.3330, 3299.9998, "Kalimdor" },
  ["Feralas"] = { 5441.6665, -1508.3333, -2366.6665, -6999.9995, "Kalimdor" },
  ["Moonglade"] = { -1381.2500, -3689.5833, 8491.6660, 6952.0830, "Kalimdor" },
  ["Mulgore"] = { 2047.9166, -3089.5833, -272.9167, -3697.9165, "Kalimdor" },
  ["Orgrimmar"] = { -3680.6010, -5083.2056, 2273.8772, 1338.4606, "Kalimdor" },
  ["Silithus"] = { 4641.6665, -2308.3333, -5800.0000, -10433.3330, "Kalimdor" },
  ["Stonetalon Mountains"] = { 3245.8333, -1637.4999, 2916.6665, -339.5833, "Kalimdor" },
  ["Tanaris"] = { -218.7500, -7118.7495, -5875.0000, -10475.0000, "Kalimdor" },
  ["Teldrassil"] = { 3814.5833, -1277.0833, 11831.2500, 8437.5000, "Kalimdor" },
  ["The Barrens"] = { 2622.9165, -7510.4165, 1612.4999, -5143.7500, "Kalimdor" },
  ["Thousand Needles"] = { -433.3333, -4833.3330, -3966.6665, -6899.9995, "Kalimdor" },
  ["Thunder Bluff"] = { 516.6666, -527.0833, -849.9999, -1545.8333, "Kalimdor" },
  ["Un'Goro Crater"] = { 533.3333, -3166.6665, -5966.6665, -8433.3330, "Kalimdor" },
  ["Winterspring"] = { -316.6667, -7416.6665, 8533.3330, 3799.9998, "Kalimdor" },
}

local FLIGHT_POINTS = {
  { id = 10, name = "The Sepulcher", zone = "Silverpine Forest", mx = 45.6, my = 42.6, faction = "Horde" },
  { id = 11, name = "Undercity", zone = "Tirisfal Glades", mx = 61.5, my = 48.9, faction = "Horde" },
  { id = 13, name = "Tarren Mill", zone = "Hillsbrad Foothills", mx = 60.2, my = 18.7, faction = "Horde" },
  { id = 17, name = "Hammerfall", zone = "Arathi Highlands", mx = 73.1, my = 32.6, faction = "Horde" },
  { id = 20, name = "Grom'gol", zone = "Stranglethorn Vale", mx = 32.5, my = 29.4, faction = "Horde" },
  { id = 21, name = "Kargath", zone = "Badlands", mx = 4.0, my = 44.8, faction = "Horde" },
  { id = 56, name = "Stonard", zone = "Swamp of Sorrows", mx = 46.1, my = 54.8, faction = "Horde" },
  { id = 70, name = "Flame Crest", zone = "Burning Steppes", mx = 65.6, my = 24.2, faction = "Horde" },
  { id = 76, name = "Revantusk Village", zone = "The Hinterlands", mx = 81.7, my = 81.8, faction = "Horde" },
  { id = 2, name = "Stormwind", zone = "Stormwind", mx = 70.9, my = 72.7, faction = "Alliance" },
  { id = 4, name = "Sentinel Hill", zone = "Westfall", mx = 56.6, my = 52.6, faction = "Alliance" },
  { id = 5, name = "Lakeshire", zone = "Redridge Mountains", mx = 30.6, my = 59.4, faction = "Alliance" },
  { id = 6, name = "Ironforge", zone = "Ironforge", mx = 55.5, my = 47.8, faction = "Alliance" },
  { id = 7, name = "Menethil Harbor", zone = "Wetlands", mx = 9.5, my = 59.7, faction = "Alliance" },
  { id = 8, name = "Thelsamar", zone = "Loch Modan", mx = 33.9, my = 50.9, faction = "Alliance" },
  { id = 12, name = "Darkshire", zone = "Duskwood", mx = 77.5, my = 44.3, faction = "Alliance" },
  { id = 14, name = "Southshore", zone = "Hillsbrad Foothills", mx = 49.3, my = 52.3, faction = "Alliance" },
  { id = 16, name = "Refuge Pointe", zone = "Arathi Highlands", mx = 45.8, my = 46.1, faction = "Alliance" },
  { id = 43, name = "Aerie Peak", zone = "The Hinterlands", mx = 11.1, my = 46.1, faction = "Alliance" },
  { id = 45, name = "Nethergarde Keep", zone = "Blasted Lands", mx = 65.5, my = 24.3, faction = "Alliance" },
  { id = 66, name = "Chillwind Camp", zone = "Western Plaguelands", mx = 42.8, my = 85.0, faction = "Alliance" },
  { id = 71, name = "Morgan's Vigil", zone = "Burning Steppes", mx = 84.3, my = 68.3, faction = "Alliance" },
  { id = 195, name = "Rebel Camp", zone = "Stranglethorn Vale", mx = 38.2, my = 4.1, faction = "Alliance" },
  { id = 22, name = "Thunder Bluff", zone = "Thunder Bluff", mx = 47.0, my = 49.8, faction = "Horde" },
  { id = 23, name = "Orgrimmar", zone = "Orgrimmar", mx = 45.3, my = 63.9, faction = "Horde" },
  { id = 25, name = "Crossroads", zone = "The Barrens", mx = 51.5, my = 30.3, faction = "Horde" },
  { id = 29, name = "Sun Rock Retreat", zone = "Stonetalon Mountains", mx = 45.1, my = 59.8, faction = "Horde" },
  { id = 30, name = "Freewind Post", zone = "Thousand Needles", mx = 45.0, my = 49.1, faction = "Horde" },
  { id = 38, name = "Shadowprey Village", zone = "Desolace", mx = 21.6, my = 74.1, faction = "Horde" },
  { id = 42, name = "Camp Mojache", zone = "Feralas", mx = 75.4, my = 44.3, faction = "Horde" },
  { id = 44, name = "Valormok", zone = "Azshara", mx = 21.9, my = 49.6, faction = "Horde" },
  { id = 48, name = "Bloodvenom Post", zone = "Felwood", mx = 34.4, my = 53.9, faction = "Horde" },
  { id = 55, name = "Brackenwall Village", zone = "Dustwallow Marsh", mx = 35.6, my = 31.8, faction = "Horde" },
  { id = 58, name = "Zoram'gar Outpost", zone = "Ashenvale", mx = 12.2, my = 33.8, faction = "Horde" },
  { id = 61, name = "Splintertree Post", zone = "Ashenvale", mx = 73.2, my = 61.6, faction = "Horde" },
  { id = 77, name = "Camp Taurajo", zone = "The Barrens", mx = 44.4, my = 59.1, faction = "Horde" },
  { id = 26, name = "Auberdine", zone = "Darkshore", mx = 36.3, my = 45.6, faction = "Alliance" },
  { id = 27, name = "Rut'theran Village", zone = "Teldrassil", mx = 58.4, my = 94.0, faction = "Alliance" },
  { id = 28, name = "Astranaar", zone = "Ashenvale", mx = 34.4, my = 48.0, faction = "Alliance" },
  { id = 31, name = "Thalanaar", zone = "Feralas", mx = 89.5, my = 45.9, faction = "Alliance" },
  { id = 32, name = "Theramore", zone = "Dustwallow Marsh", mx = 67.5, my = 51.3, faction = "Alliance" },
  { id = 33, name = "Stonetalon Peak", zone = "Stonetalon Mountains", mx = 36.4, my = 7.2, faction = "Alliance" },
  { id = 37, name = "Nijel's Point", zone = "Desolace", mx = 64.7, my = 10.5, faction = "Alliance" },
  { id = 41, name = "Feathermoon Stronghold", zone = "Feralas", mx = 30.2, my = 43.2, faction = "Alliance" },
  { id = 64, name = "Talrendis Point", zone = "Azshara", mx = 11.9, my = 77.6, faction = "Alliance" },
  { id = 65, name = "Talonbranch Glade", zone = "Felwood", mx = 62.5, my = 24.2, faction = "Alliance" },
  { name = "Booty Bay", zone = "Stranglethorn Vale", mx = 26.8, my = 77.1, faction = "Neutral", hid = 18, aid = 19 },
  { name = "Thorium Point", zone = "Searing Gorge", mx = 34.8, my = 30.9, faction = "Neutral", hid = 75, aid = 74 },
  { name = "Light's Hope Chapel", zone = "Eastern Plaguelands", mx = 81.6, my = 59.3, faction = "Neutral", hid = 68, aid = 67 },
  { id = 80, name = "Ratchet", zone = "The Barrens", mx = 63.1, my = 37.2, faction = "Neutral" },
  { name = "Gadgetzan", zone = "Tanaris", mx = 51.6, my = 25.4, faction = "Neutral", hid = 40, aid = 39 },
  { id = 79, name = "Marshal's Refuge", zone = "Un'Goro Crater", mx = 45.2, my = 5.8, faction = "Neutral" },
  { name = "Cenarion Hold", zone = "Silithus", mx = 50.6, my = 34.5, faction = "Neutral", hid = 72, aid = 73 },
  { name = "Everlook", zone = "Winterspring", mx = 60.5, my = 36.3, faction = "Neutral", hid = 53, aid = 52 },
  { id = 69, name = "Nighthaven", zone = "Moonglade", mx = 32.2, my = 66.4, faction = "Horde" },
  { id = 49, name = "Nighthaven", zone = "Moonglade", mx = 48.1, my = 67.3, faction = "Alliance" },
}

local HORDE_FLIGHT = {
  [10] = { [11] = 112, [13] = 95, [17] = 212, [18] = 863, [20] = 782, [21] = 471, [56] = 751, [68] = 299, [70] = 556, [75] = 526, [76] = 289 },
  [11] = { [10] = 106, [13] = 141, [17] = 301, [18] = 880, [20] = 800, [21] = 488, [56] = 768, [68] = 261, [70] = 573, [75] = 543, [76] = 284 },
  [13] = { [10] = 99, [11] = 139, [17] = 118, [18] = 768, [20] = 688, [21] = 376, [56] = 656, [68] = 329, [70] = 462, [75] = 431, [76] = 195 },
  [17] = { [10] = 215, [11] = 259, [13] = 117, [18] = 651, [20] = 571, [21] = 259, [56] = 539, [68] = 229, [70] = 344, [75] = 314, [76] = 91 },
  [18] = { [10] = 882, [11] = 903, [13] = 783, [17] = 668, [20] = 102, [21] = 406, [56] = 267, [68] = 896, [70] = 464, [75] = 462, [76] = 757 },
  [20] = { [10] = 802, [11] = 823, [13] = 704, [17] = 588, [18] = 81, [21] = 327, [56] = 205, [68] = 816, [70] = 402, [75] = 382, [76] = 677 },
  [21] = { [10] = 477, [11] = 497, [13] = 379, [17] = 263, [18] = 417, [20] = 313, [56] = 280, [68] = 491, [70] = 87, [75] = 56, [76] = 352 },
  [22] = { [23] = 207, [25] = 159, [29] = 182, [30] = 204, [38] = 159, [40] = 290, [42] = 252, [44] = 269, [48] = 411, [53] = 398, [55] = 239, [58] = 389, [61] = 296, [69] = 532, [72] = 381, [77] = 87, [79] = 397, [80] = 210 },
  [23] = { [22] = 224, [25] = 110, [29] = 260, [30] = 294, [38] = 385, [40] = 417, [42] = 361, [44] = 99, [48] = 252, [53] = 319, [55] = 229, [58] = 250, [61] = 89, [69] = 361, [72] = 492, [77] = 200, [79] = 494, [80] = 161 },
  [25] = { [22] = 182, [23] = 142, [29] = 150, [30] = 184, [38] = 292, [40] = 303, [42] = 252, [44] = 168, [48] = 253, [53] = 297, [55] = 162, [58] = 231, [61] = 162, [72] = 382, [77] = 90, [79] = 384, [80] = 52 },
  [29] = { [22] = 175, [23] = 290, [25] = 150, [30] = 333, [38] = 143, [40] = 426, [42] = 339, [44] = 318, [48] = 403, [53] = 447, [55] = 312, [58] = 380, [61] = 311, [72] = 469, [77] = 240, [80] = 200 },
  [30] = { [22] = 225, [23] = 335, [25] = 194, [29] = 343, [38] = 323, [40] = 93, [42] = 124, [44] = 362, [55] = 315, [58] = 424, [61] = 356, [72] = 252, [77] = 137, [79] = 200, [80] = 245 },
  [38] = { [22] = 178, [23] = 385, [25] = 337, [29] = 199, [30] = 382, [40] = 395, [42] = 196, [44] = 447, [48] = 590, [53] = 576, [55] = 416, [58] = 566, [61] = 474, [69] = 709, [72] = 326, [77] = 265, [79] = 417, [80] = 388 },
  [40] = { [22] = 304, [23] = 350, [25] = 301, [29] = 429, [30] = 87, [38] = 400, [42] = 200, [44] = 448, [48] = 532, [53] = 577, [55] = 222, [58] = 510, [61] = 439, [69] = 653, [72] = 233, [77] = 223, [79] = 108, [80] = 331 },
  [42] = { [22] = 259, [23] = 406, [25] = 263, [29] = 400, [30] = 107, [38] = 201, [40] = 201, [44] = 432, [48] = 517, [55] = 421, [58] = 494, [61] = 426, [72] = 130, [77] = 244, [79] = 222, [80] = 315 },
  [44] = { [22] = 257, [23] = 121, [25] = 172, [29] = 322, [30] = 357, [38] = 416, [42] = 423, [48] = 232, [53] = 131, [55] = 335, [58] = 253, [61] = 94, [69] = 264, [72] = 553, [77] = 263, [79] = 556, [80] = 223 },
  [48] = { [22] = 423, [23] = 259, [25] = 241, [29] = 390, [38] = 533, [40] = 518, [42] = 493, [44] = 241, [53] = 190, [55] = 404, [58] = 471, [61] = 333, [69] = 166, [72] = 623, [77] = 331, [79] = 625, [80] = 292 },
  [53] = { [22] = 392, [23] = 304, [25] = 307, [29] = 456, [38] = 550, [40] = 584, [42] = 558, [44] = 135, [48] = 195, [55] = 470, [58] = 388, [61] = 228, [69] = 134, [72] = 688, [77] = 397, [79] = 691, [80] = 357 },
  [55] = { [22] = 224, [23] = 217, [25] = 162, [29] = 311, [30] = 309, [38] = 383, [40] = 222, [42] = 414, [44] = 316, [48] = 415, [53] = 445, [61] = 306, [72] = 430, [77] = 252, [79] = 329, [80] = 214 },
  [56] = { [10] = 761, [11] = 782, [13] = 663, [17] = 547, [18] = 260, [20] = 189, [21] = 285, [68] = 774, [70] = 197, [75] = 267, [76] = 636 },
  [58] = { [22] = 410, [23] = 256, [25] = 228, [29] = 378, [30] = 412, [40] = 504, [44] = 256, [48] = 481, [53] = 384, [55] = 391, [61] = 167, [77] = 318, [79] = 611, [80] = 279 },
  [61] = { [22] = 321, [23] = 96, [25] = 160, [29] = 310, [30] = 345, [38] = 453, [40] = 436, [42] = 412, [44] = 96, [48] = 327, [53] = 224, [55] = 323, [58] = 166, [69] = 356, [72] = 541, [77] = 250, [79] = 544, [80] = 212 },
  [68] = { [10] = 294, [11] = 262, [13] = 301, [17] = 234, [18] = 884, [20] = 804, [21] = 492, [56] = 773, [70] = 578, [75] = 547, [76] = 141 },
  [69] = { [22] = 543, [23] = 370, [25] = 353, [29] = 502, [30] = 537, [38] = 645, [40] = 629, [42] = 604, [44] = 275, [48] = 157, [53] = 142, [55] = 515, [58] = 528, [61] = 369, [72] = 734, [77] = 443, [79] = 736, [80] = 404 },
  [70] = { [10] = 576, [11] = 597, [13] = 477, [17] = 361, [18] = 472, [20] = 401, [21] = 99, [56] = 213, [68] = 589, [75] = 72, [76] = 451 },
  [72] = { [22] = 389, [23] = 535, [25] = 394, [30] = 236, [38] = 330, [40] = 241, [42] = 129, [44] = 562, [55] = 425, [69] = 768, [77] = 373, [79] = 97, [80] = 445 },
  [75] = { [10] = 545, [11] = 566, [13] = 447, [17] = 331, [18] = 462, [20] = 382, [21] = 70, [56] = 350, [68] = 559, [70] = 77, [76] = 420 },
  [76] = { [10] = 257, [11] = 284, [13] = 159, [17] = 93, [18] = 743, [20] = 663, [21] = 351, [56] = 631, [68] = 139, [70] = 437, [75] = 407 },
  [77] = { [22] = 114, [23] = 221, [25] = 79, [29] = 229, [30] = 125, [38] = 273, [40] = 218, [42] = 248, [55] = 242, [61] = 242, [72] = 378, [79] = 325, [80] = 130 },
  [79] = { [22] = 416, [23] = 462, [25] = 392, [29] = 542, [30] = 200, [38] = 424, [40] = 113, [42] = 224, [44] = 559, [48] = 645, [53] = 689, [55] = 333, [61] = 551, [69] = 766, [72] = 100, [77] = 336, [80] = 443 },
  [80] = { [22] = 250, [23] = 210, [25] = 69, [29] = 218, [30] = 252, [38] = 360, [40] = 345, [42] = 320, [44] = 236, [53] = 366, [55] = 231, [58] = 299, [61] = 231, [72] = 450, [77] = 158, [79] = 452 },
}

local ALLIANCE_FLIGHT = {
  [2] = { [4] = 78, [5] = 113, [6] = 259, [7] = 343, [8] = 317, [12] = 116, [14] = 443, [16] = 450, [19] = 245, [43] = 508, [45] = 176, [66] = 506, [67] = 563, [71] = 157, [74] = 247, [195] = 210 },
  [4] = { [2] = 86, [5] = 130, [6] = 331, [7] = 414, [8] = 389, [12] = 97, [19] = 185, [45] = 186, [74] = 282, [195] = 160 },
  [5] = { [2] = 113, [4] = 133, [6] = 357, [7] = 441, [8] = 415, [12] = 60, [19] = 227, [67] = 540, [71] = 61, [74] = 153, [195] = 140 },
  [6] = { [2] = 210, [4] = 274, [5] = 201, [7] = 128, [8] = 101, [12] = 260, [14] = 265, [16] = 253, [19] = 440, [43] = 298, [45] = 373, [66] = 294, [67] = 349, [71] = 173, [74] = 87 },
  [7] = { [2] = 261, [4] = 324, [5] = 250, [6] = 89, [8] = 163, [12] = 309, [14] = 107, [16] = 113, [19] = 490, [43] = 176, [45] = 423, [66] = 186, [67] = 324, [71] = 221, [74] = 135 },
  [8] = { [2] = 279, [4] = 342, [5] = 267, [6] = 109, [7] = 153, [12] = 326, [14] = 250, [16] = 164, [19] = 508, [45] = 441, [66] = 285, [74] = 152 },
  [12] = { [2] = 88, [4] = 93, [5] = 60, [6] = 333, [7] = 417, [8] = 391, [14] = 517, [16] = 524, [19] = 171, [43] = 582, [45] = 97, [74] = 212, [195] = 90 },
  [14] = { [2] = 367, [4] = 430, [6] = 206, [7] = 110, [8] = 244, [12] = 468, [16] = 74, [19] = 597, [43] = 71, [66] = 81, [67] = 219 },
  [16] = { [6] = 271, [7] = 126, [8] = 171, [12] = 485, [14] = 86, [19] = 614, [43] = 72, [45] = 547, [66] = 122, [67] = 233 },
  [19] = { [2] = 220, [4] = 181, [5] = 230, [6] = 464, [7] = 548, [8] = 523, [12] = 175, [14] = 649, [16] = 655, [45] = 266, [66] = 712, [71] = 291, [195] = 180 },
  [26] = { [27] = 84, [28] = 176, [32] = 675, [33] = 181, [37] = 291, [39] = 689, [41] = 473, [49] = 151, [52] = 281, [64] = 301, [65] = 190, [80] = 435 },
  [27] = { [26] = 86, [28] = 261, [31] = 711, [32] = 617, [33] = 267, [37] = 376, [39] = 774, [41] = 557, [49] = 236, [52] = 365, [64] = 385, [65] = 274, [73] = 714, [79] = 797, [80] = 519 },
  [28] = { [26] = 148, [27] = 231, [32] = 381, [33] = 153, [37] = 279, [41] = 511, [64] = 150, [65] = 337, [80] = 283 },
  [31] = { [27] = 729, [32] = 159, [37] = 405, [39] = 171, [41] = 179, [79] = 274, [80] = 274 },
  [32] = { [26] = 620, [27] = 619, [28] = 387, [31] = 162, [33] = 801, [37] = 334, [39] = 157, [41] = 341, [49] = 535, [52] = 414, [64] = 235, [65] = 518, [73] = 354, [79] = 261, [80] = 115 },
  [33] = { [26] = 177, [27] = 261, [28] = 154, [32] = 434, [37] = 126 },
  [37] = { [26] = 282, [27] = 367, [28] = 273, [31] = 472, [32] = 308, [33] = 120, [39] = 464, [41] = 232, [80] = 422 },
  [39] = { [27] = 772, [28] = 540, [31] = 177, [32] = 154, [33] = 692, [37] = 480, [41] = 354, [52] = 566, [64] = 388, [65] = 670, [73] = 197, [79] = 104, [80] = 262 },
  [41] = { [26] = 468, [27] = 551, [28] = 500, [31] = 155, [32] = 314, [33] = 648, [37] = 227, [39] = 326, [49] = 619, [52] = 748 },
  [43] = { [2] = 429, [4] = 492, [6] = 256, [7] = 176, [8] = 245, [12] = 531, [14] = 68, [16] = 75, [19] = 658, [45] = 591, [66] = 54, [67] = 164 },
  [45] = { [2] = 189, [5] = 150, [6] = 382, [7] = 467, [12] = 91, [19] = 260, [66] = 631, [67] = 687, [71] = 207, [74] = 300, [195] = 150 },
  [49] = { [26] = 142, [27] = 226, [28] = 318, [32] = 537, [37] = 433, [39] = 694, [41] = 614, [52] = 131, [64] = 305, [65] = 61, [73] = 771 },
  [52] = { [26] = 262, [27] = 346, [28] = 327, [31] = 572, [32] = 408, [37] = 553, [39] = 564, [41] = 734, [49] = 122, [64] = 176, [65] = 122, [80] = 309 },
  [64] = { [26] = 301, [28] = 153, [32] = 241, [39] = 391, [52] = 178, [65] = 283, [73] = 588, [79] = 494, [80] = 135 },
  [65] = { [26] = 188, [27] = 272, [28] = 363, [37] = 478, [39] = 671, [41] = 660, [52] = 121, [64] = 282, [79] = 776 },
  [66] = { [2] = 432, [4] = 495, [6] = 261, [7] = 193, [14] = 85, [16] = 138, [19] = 662, [43] = 66, [67] = 147, [71] = 395, [74] = 309 },
  [67] = { [6] = 369, [7] = 333, [12] = 591, [14] = 226, [43] = 163, [45] = 704, [66] = 150, [71] = 503, [74] = 417 },
  [71] = { [2] = 151, [4] = 195, [5] = 64, [6] = 187, [7] = 270, [8] = 245, [12] = 121, [16] = 378, [19] = 288, [43] = 436, [45] = 210, [66] = 435, [67] = 491, [74] = 104 },
  [73] = { [27] = 726, [31] = 329, [32] = 342, [41] = 175, [64] = 576, [65] = 831, [79] = 92 },
  [74] = { [6] = 94, [7] = 178, [8] = 152, [45] = 265, [66] = 342, [67] = 398, [71] = 96 },
  [79] = { [27] = 809, [28] = 856, [32] = 257, [39] = 104, [41] = 258, [52] = 670, [65] = 774, [73] = 94, [80] = 364 },
  [80] = { [27] = 805, [28] = 284, [31] = 268, [32] = 106, [33] = 437, [37] = 439, [39] = 261, [41] = 446, [52] = 310, [64] = 132, [65] = 415, [73] = 459, [79] = 366 },
  [195] = { [2] = 210, [4] = 160, [5] = 140, [12] = 90, [19] = 180, [45] = 150 },
}

-- Classic-era travel: faction flight points, ground runs, and boat/zeppelin
-- crossings. Costs are seconds. Emerald Sanctuary is TBC and is not included.

local MOUNT_YDS = 14 -- 100% ground mount
local FLY_BOARD = 5
local MIN_LEG = 3
local RUN_DETROUR = 1.25
local RUN_NEAR_YDS = 1200

-- Classic zone adjacency (including a short Deadwind pass treated as
-- Duskwood--Swamp of Sorrows). Runs are only allowed in the same zone,
-- between adjacent zones, or when the two points are very close.
local ADJACENT_SRC = {
  ["Tirisfal Glades"] = { "Silverpine Forest", "Western Plaguelands", "Undercity" },
  ["Undercity"] = { "Tirisfal Glades" },
  ["Silverpine Forest"] = { "Tirisfal Glades", "Hillsbrad Foothills", "Alterac Mountains" },
  ["Hillsbrad Foothills"] = { "Silverpine Forest", "Alterac Mountains", "Arathi Highlands", "Western Plaguelands", "The Hinterlands" },
  ["Alterac Mountains"] = { "Hillsbrad Foothills", "Western Plaguelands", "Silverpine Forest" },
  ["Arathi Highlands"] = { "Hillsbrad Foothills", "The Hinterlands", "Wetlands" },
  ["The Hinterlands"] = { "Arathi Highlands", "Hillsbrad Foothills" },
  ["Western Plaguelands"] = { "Tirisfal Glades", "Eastern Plaguelands", "Alterac Mountains", "Hillsbrad Foothills" },
  ["Eastern Plaguelands"] = { "Western Plaguelands" },
  ["Wetlands"] = { "Arathi Highlands", "Loch Modan", "Dun Morogh" },
  ["Loch Modan"] = { "Wetlands", "Dun Morogh", "Badlands", "Searing Gorge" },
  ["Dun Morogh"] = { "Loch Modan", "Ironforge", "Wetlands", "Searing Gorge" },
  ["Ironforge"] = { "Dun Morogh" },
  ["Searing Gorge"] = { "Badlands", "Burning Steppes", "Dun Morogh", "Loch Modan" },
  ["Badlands"] = { "Searing Gorge", "Loch Modan" },
  ["Burning Steppes"] = { "Searing Gorge", "Redridge Mountains" },
  ["Redridge Mountains"] = { "Burning Steppes", "Elwynn Forest", "Duskwood" },
  ["Elwynn Forest"] = { "Redridge Mountains", "Duskwood", "Westfall", "Stormwind" },
  ["Stormwind"] = { "Elwynn Forest" },
  ["Westfall"] = { "Elwynn Forest", "Duskwood" },
  ["Duskwood"] = { "Elwynn Forest", "Westfall", "Redridge Mountains", "Deadwind Pass", "Stranglethorn Vale", "Swamp of Sorrows" },
  ["Deadwind Pass"] = { "Duskwood", "Swamp of Sorrows" },
  ["Swamp of Sorrows"] = { "Deadwind Pass", "Blasted Lands", "Riverglades", "Duskwood" },
  ["Riverglades"] = { "Swamp of Sorrows" },
  ["Blasted Lands"] = { "Swamp of Sorrows" },
  ["Stranglethorn Vale"] = { "Duskwood" },
  ["Durotar"] = { "The Barrens", "Orgrimmar" },
  ["Orgrimmar"] = { "Durotar" },
  ["The Barrens"] = { "Durotar", "Mulgore", "Stonetalon Mountains", "Ashenvale", "Dustwallow Marsh", "Thousand Needles" },
  ["Mulgore"] = { "The Barrens", "Thunder Bluff" },
  ["Thunder Bluff"] = { "Mulgore" },
  ["Stonetalon Mountains"] = { "The Barrens", "Ashenvale", "Desolace" },
  ["Ashenvale"] = { "The Barrens", "Stonetalon Mountains", "Felwood", "Azshara", "Darkshore" },
  ["Azshara"] = { "Ashenvale" },
  ["Desolace"] = { "Stonetalon Mountains", "Feralas" },
  ["Feralas"] = { "Desolace", "Thousand Needles" },
  ["Thousand Needles"] = { "The Barrens", "Feralas", "Tanaris" },
  ["Dustwallow Marsh"] = { "The Barrens" },
  ["Tanaris"] = { "Thousand Needles", "Un'Goro Crater", "Silithus" },
  ["Un'Goro Crater"] = { "Tanaris", "Silithus" },
  ["Silithus"] = { "Un'Goro Crater", "Tanaris" },
  ["Felwood"] = { "Ashenvale", "Moonglade", "Winterspring" },
  ["Moonglade"] = { "Felwood", "Winterspring" },
  ["Winterspring"] = { "Moonglade", "Felwood" },
  ["Darkshore"] = { "Ashenvale" },
  ["Teldrassil"] = { "Darnassus" },
  ["Darnassus"] = { "Teldrassil" },
}

local ADJACENT = {}
local function LinkZones(a, b)
  if not a or not b or a == b then
    return
  end
  ADJACENT[a] = ADJACENT[a] or {}
  if not ADJACENT[a][b] then
    ADJACENT[a][b] = true
    ADJACENT[a][#ADJACENT[a] + 1] = b
  end
end
do
  local z, list, i
  for z, list in pairs(ADJACENT_SRC) do
    for i = 1, #list do
      LinkZones(z, list[i])
      LinkZones(list[i], z)
    end
  end
end

local function ZonesLinked(a, b)
  if not a or not b then
    return false
  end
  if a == b then
    return true
  end
  return ADJACENT[a] and ADJACENT[a][b] and true or false
end

local function ContinentIdName(id)
  if id == 0 or id == 13 then
    return "Eastern Kingdoms"
  end
  if id == 1 or id == 12 then
    return "Kalimdor"
  end
  return nil
end

local function PosContinent(pos)
  if not pos then
    return nil
  end
  if pos.continent and pos.continent ~= "Unknown" then
    return pos.continent
  end
  return ContinentIdName(pos.continentID)
end

local function SameContinent(a, b)
  if not a or not b then
    return false
  end
  if a.continentID and b.continentID and a.continentID == b.continentID then
    return true
  end
  local ca, cb = PosContinent(a), PosContinent(b)
  return ca and cb and ca == cb
end

local function Yards(a, b)
  if not a or not b or not SameContinent(a, b) then
    return nil
  end
  local dx = (a.x or 0) - (b.x or 0)
  local dy = (a.y or 0) - (b.y or 0)
  return math.sqrt(dx * dx + dy * dy)
end

local function RunSeconds(a, b, aZone, bZone)
  local d = Yards(a, b)
  if not d then
    return nil
  end
  if d < 20 then
    return MIN_LEG
  end
  local detour = RUN_DETROUR
  local extra = 0
  if aZone and bZone and aZone ~= bZone then
    detour = 1.6
    extra = 20
  end
  local t = (d * detour) / MOUNT_YDS + extra
  if t < MIN_LEG then
    return MIN_LEG
  end
  return t
end

local function Compass(fromPos, toPos)
  if not fromPos or not toPos or not SameContinent(fromPos, toPos) then
    return nil
  end
  -- Fallback/GPS space: +X is north, +Y is west.
  local north = (toPos.x or 0) - (fromPos.x or 0)
  local west = (toPos.y or 0) - (fromPos.y or 0)
  local absN, absW = math.abs(north), math.abs(west)
  if absN < 40 and absW < 40 then
    return nil
  end
  if absN >= absW * 2 then
    if north >= 0 then return "north" else return "south" end
  end
  if absW >= absN * 2 then
    if west >= 0 then return "west" else return "east" end
  end
  local ns = (north >= 0) and "north" or "south"
  local ew = (west >= 0) and "west" or "east"
  return ns .. ew
end

function Route.FallbackWorldPos(zone, mx, my)
  local r = ZONE_RECT[zone]
  if not r or type(mx) ~= "number" or type(my) ~= "number" then
    return nil
  end
  local left, right, top, bottom, cont = r[1], r[2], r[3], r[4], r[5]
  local y = left - (mx / 100) * (left - right)
  local x = top - (my / 100) * (top - bottom)
  local cid = (cont == "Kalimdor") and 1 or 0
  return { continentID = cid, continent = cont, x = x, y = y, precise = true }
end

function Route.PlayerFaction()
  if Route._testFaction == "Horde" or Route._testFaction == "Alliance" then
    return Route._testFaction
  end
  if UnitFactionGroup then
    local ok, f = pcall(UnitFactionGroup, "player")
    if ok and (f == "Horde" or f == "Alliance") then
      if WR.db then
        WR.db.faction = f
      end
      return f
    end
  end
  if WR.db and (WR.db.faction == "Horde" or WR.db.faction == "Alliance") then
    return WR.db.faction
  end
  return "Horde"
end

local function FpId(fp, faction)
  if not fp then
    return nil
  end
  if fp.faction == "Neutral" then
    if fp.hid or fp.aid then
      if faction == "Alliance" then
        return fp.aid or fp.hid
      end
      return fp.hid or fp.aid
    end
    return fp.id
  end
  if fp.faction == faction then
    return fp.id
  end
  return nil
end

local function ResolvePos(zone, mx, my, useCMap)
  if useCMap and C_Map and C_Map.GetWorldPosFromMapPos then
    local mapId = Route.MapIdForZone(zone)
    if mapId and mx and my then
      local vec = Route.Vec2(mx / 100, my / 100)
      if vec then
        local ok, continentID, worldPos = pcall(C_Map.GetWorldPosFromMapPos, mapId, vec)
        if ok and worldPos and type(worldPos.x) == "number" and type(worldPos.y) == "number" then
          return {
            continentID = continentID,
            continent = Route.ContinentForZone(zone),
            x = worldPos.x,
            y = worldPos.y,
            precise = true,
          }
        end
      end
    end
  end
  return Route.FallbackWorldPos(zone, mx, my)
end

local function CanUseCMap()
  return C_Map and C_Map.GetWorldPosFromMapPos and CreateVector2D and true or false
end

-- Crossings: zeppelins and boats. Times include a typical wait.
-- Horde: UC <-> Org, Grom'gol <-> Org, UC <-> Grom'gol; Booty Bay <-> Ratchet.
-- Alliance: Menethil <-> Auberdine, Menethil <-> Theramore; Booty Bay <-> Ratchet.
local CROSSINGS = {
  { aH = 11, bH = 23, kind = "zep", seconds = 330 },
  { aH = 20, bH = 23, kind = "zep", seconds = 360 },
  { aH = 11, bH = 20, kind = "zep", seconds = 390 },
  { aH = 18, aA = 19, bH = 80, bA = 80, kind = "boat", seconds = 330 },
  { aA = 7, bA = 26, kind = "boat", seconds = 360 },
  { aA = 7, bA = 32, kind = "boat", seconds = 480 },
}

local function CrossingIds(cross, faction)
  local a, b
  if faction == "Alliance" then
    a, b = cross.aA, cross.bA
  else
    a, b = cross.aH, cross.bH
  end
  if a and b then
    return a, b
  end
  return nil
end

local function BuildGraph(faction, extraNodes)
  local times = (faction == "Alliance") and ALLIANCE_FLIGHT or HORDE_FLIGHT
  local useCMap = CanUseCMap()
  local fps = {}
  local fpById = {}
  local i
  for i = 1, #FLIGHT_POINTS do
    local fp = FLIGHT_POINTS[i]
    local id = FpId(fp, faction)
    if id then
      local pos = ResolvePos(fp.zone, fp.mx, fp.my, useCMap)
      if pos then
        local node = {
          key = "fp:" .. id,
          kind = "fp",
          id = id,
          name = fp.name,
          zone = fp.zone,
          pos = pos,
        }
        fps[#fps + 1] = node
        fpById[id] = node
      end
    end
  end

  local nodes = {}
  local edges = {}

  local function addNode(node)
    nodes[node.key] = node
    edges[node.key] = edges[node.key] or {}
  end

  local function addEdge(a, b, seconds, kind, meta)
    if not a or not b or a == b or not seconds then
      return
    end
    edges[a] = edges[a] or {}
    edges[a][#edges[a] + 1] = { to = b, seconds = seconds, kind = kind, meta = meta }
  end

  for i = 1, #fps do
    addNode(fps[i])
  end

  local src, dests, dst, sec
  for src, dests in pairs(times) do
    if fpById[src] then
      for dst, sec in pairs(dests) do
        if fpById[dst] and type(sec) == "number" then
          addEdge("fp:" .. src, "fp:" .. dst, sec + FLY_BOARD, "fly")
        end
      end
    end
  end

  for i = 1, #CROSSINGS do
    local c = CROSSINGS[i]
    local a, b = CrossingIds(c, faction)
    if a and b and fpById[a] and fpById[b] then
      addEdge("fp:" .. a, "fp:" .. b, c.seconds, c.kind, c)
      addEdge("fp:" .. b, "fp:" .. a, c.seconds, c.kind, c)
    end
  end

  local function CanRun(aZone, bZone, aPos, bPos)
    if not SameContinent(aPos, bPos) then
      return false
    end
    if ZonesLinked(aZone, bZone) then
      return true
    end
    local d = Yards(aPos, bPos)
    return d and d <= RUN_NEAR_YDS
  end

  for i = 1, #(extraNodes or {}) do
    local n = extraNodes[i]
    addNode(n)
    local added = 0
    local nearest, nearestD = nil, nil
    local j
    for j = 1, #fps do
      local d = Yards(n.pos, fps[j].pos)
      if d and (not nearestD or d < nearestD) then
        nearest, nearestD = fps[j], d
      end
      if CanRun(n.zone, fps[j].zone, n.pos, fps[j].pos) then
        local t = RunSeconds(n.pos, fps[j].pos, n.zone, fps[j].zone)
        if t then
          addEdge(n.key, fps[j].key, t, "run")
          addEdge(fps[j].key, n.key, t, "run")
          added = added + 1
        end
      end
    end
    -- Always hook the closest same-continent FP so an isolated stop stays on the graph.
    if added == 0 and nearest then
      local t = RunSeconds(n.pos, nearest.pos, n.zone, nearest.zone)
      if t then
        addEdge(n.key, nearest.key, t, "run")
        addEdge(nearest.key, n.key, t, "run")
      end
    end
    local k
    for k = 1, #extraNodes do
      if k ~= i then
        local o = extraNodes[k]
        if CanRun(n.zone, o.zone, n.pos, o.pos) then
          local t = RunSeconds(n.pos, o.pos, n.zone, o.zone)
          if t then
            addEdge(n.key, o.key, t, "run")
          end
        end
      end
    end
  end

  return { nodes = nodes, edges = edges, fpById = fpById }
end

local function Dijkstra(graph, source)
  local dist, prev, pkind, pmeta = {}, {}, {}, {}
  local seen = {}
  dist[source] = 0
  while true do
    local best, bestD = nil, nil
    local k, d
    for k, d in pairs(dist) do
      if not seen[k] and (not bestD or d < bestD) then
        best, bestD = k, d
      end
    end
    if not best then
      break
    end
    seen[best] = true
    local list = graph.edges[best]
    if list then
      local i
      for i = 1, #list do
        local e = list[i]
        if not seen[e.to] then
          local nd = bestD + e.seconds
          if not dist[e.to] or nd < dist[e.to] then
            dist[e.to] = nd
            prev[e.to] = best
            pkind[e.to] = e.kind
            pmeta[e.to] = e.meta
          end
        end
      end
    end
  end
  return dist, prev, pkind, pmeta
end

local function Reconstruct(graph, prev, pkind, pmeta, source, dest)
  if source == dest then
    return { { key = source, node = graph.nodes[source] } }
  end
  if not prev[dest] then
    return nil
  end
  local keys = { dest }
  local cur = dest
  local guard = 0
  while cur ~= source and guard < 80 do
    cur = prev[cur]
    if not cur then
      return nil
    end
    keys[#keys + 1] = cur
    guard = guard + 1
  end
  if keys[#keys] ~= source then
    return nil
  end
  local path = {}
  local i
  for i = #keys, 1, -1 do
    local key = keys[i]
    path[#path + 1] = {
      key = key,
      node = graph.nodes[key],
      kind = (i > 1) and pkind[key] or nil,
      meta = (i > 1) and pmeta[key] or nil,
    }
  end
  return path
end

local function PathSeconds(graph, source, dest, cache)
  if source == dest then
    return 0, { { key = source, node = graph.nodes[source] } }
  end
  local pack = cache[source]
  if not pack then
    local dist, prev, pkind, pmeta = Dijkstra(graph, source)
    pack = { dist = dist, prev = prev, pkind = pkind, pmeta = pmeta }
    cache[source] = pack
  end
  local d = pack.dist[dest]
  if not d then
    return nil, nil
  end
  return d, Reconstruct(graph, pack.prev, pack.pkind, pack.pmeta, source, dest)
end

local function DescribePath(path, destZone, destPos)
  if not path or #path == 0 then
    return nil
  end
  local firstNode = path[1].node
  -- Already at (or a short ride from) the turn-in: stay quiet.
  if #path <= 2 and firstNode and firstNode.pos and destPos then
    local d = Yards(firstNode.pos, destPos)
    local startZone = firstNode.zone
    if d and d < 250 and (not startZone or not destZone or startZone == destZone) then
      return nil
    end
  end
  local lastFp, lastFly, firstRunTo, finalRunFrom, crossing, crossingPrev
  local postFly, postFp, postFirstRun
  local seenCrossing = false
  local i
  for i = 2, #path do
    local step = path[i]
    local kind = step.kind
    if kind == "zep" or kind == "boat" then
      crossing = step
      crossingPrev = path[i - 1]
      seenCrossing = true
    elseif kind == "fly" then
      lastFly = step
      lastFp = step.node
      if seenCrossing then
        postFly = step
        postFp = step.node
      end
    elseif kind == "run" then
      if not lastFly and not crossing then
        firstRunTo = step
      end
      if seenCrossing and not postFly and not postFirstRun then
        postFirstRun = step
      end
      finalRunFrom = path[i - 1]
    end
  end
  -- After a continent crossing, describe only the arrival-side fly/run.
  if crossing and postFp then
    lastFly, lastFp = postFly, postFp
    firstRunTo = postFirstRun
  end

  local dest = destZone or (path[#path].node and (path[#path].node.zone or path[#path].node.name))
  local bits = {}

  if crossing then
    local aName = crossingPrev and crossingPrev.node and crossingPrev.node.name
    local bName = crossing.node and crossing.node.name
    local verb
    if crossing.kind == "zep" then
      bits[#bits + 1] = "Take the " .. (aName or "zeppelin") .. " zeppelin to " .. (bName or "the other continent")
    else
      bits[#bits + 1] = "Take the " .. (aName or "boat") .. " boat to " .. (bName or "the other continent")
    end
  end

  if lastFly and lastFp then
    local flyDest = (lastFp.zone or dest or lastFp.name) .. " (" .. lastFp.name .. ")"
    local flyBit
    if #bits > 0 then
      flyBit = "then fly to " .. flyDest
    else
      flyBit = "Fly to " .. flyDest
    end
    if firstRunTo and firstRunTo.node and firstRunTo.node.kind == "fp" then
      local runZone = firstRunTo.node.zone
      local startZone = firstNode and firstNode.zone
      local t = RunSeconds(firstNode and firstNode.pos, firstRunTo.node.pos)
      if runZone and runZone ~= startZone and t and t >= 45 then
        local dir = Compass(firstNode and firstNode.pos, firstRunTo.node.pos)
        local runBit = "Run"
        if dir then
          runBit = "Run " .. dir
        end
        runBit = runBit .. " to " .. firstRunTo.node.zone .. " (" .. firstRunTo.node.name .. "), then fly to " .. flyDest
        if #bits > 0 then
          bits[#bits + 1] = "then " .. string.lower(runBit:sub(1, 1)) .. runBit:sub(2)
        else
          bits[#bits + 1] = runBit
        end
        flyBit = nil
      end
    end
    if flyBit then
      bits[#bits + 1] = flyBit
    end
  end

  local landZone = lastFp and lastFp.zone
  if (not lastFly and not crossing) or (dest and landZone and dest ~= landZone) then
    local fromPos
    if finalRunFrom and finalRunFrom.node then
      fromPos = finalRunFrom.node.pos
    elseif firstNode then
      fromPos = firstNode.pos
    end
    local dir = Compass(fromPos, destPos)
    if not lastFly and not crossing then
      local runBit = "Run"
      if dir then
        runBit = "Run " .. dir
      end
      bits[#bits + 1] = runBit .. " to " .. (dest or "the turn-in")
    elseif dest and landZone and dest ~= landZone then
      local runBit = "then run"
      if dir then
        runBit = "then run " .. dir
      end
      bits[#bits + 1] = runBit .. " to " .. dest
    end
  end

  if #bits == 0 then
    return nil
  end
  local out = bits[1]
  for i = 2, #bits do
    local b = bits[i]
    if b:sub(1, 5) == "then " then
      out = out .. ", " .. b
    else
      out = out .. ", then " .. b
    end
  end
  return out
end

local function StopKey(i)
  return "stop:" .. i
end

local function ItemContinent(it)
  if it.continent and it.continent ~= "Unknown" then
    return it.continent
  end
  return PosContinent(it.worldPos) or "Unknown"
end

local CONTINENT_RANK = {
  ["Eastern Kingdoms"] = 1,
  ["Kalimdor"] = 2,
  Unknown = 9,
}

local function OrderGroup(items, startPos, startKeyHint, faction, graph, cache, tailKeys)
  local extrasAlreadyInGraph = true
  local function cost(aKey, bKey)
    return PathSeconds(graph, aKey, bKey, cache)
  end

  local indexOf = {}
  local i
  for i = 1, #items do
    indexOf[items[i]] = i
  end

  -- items here are the original item tables; their graph keys were assigned
  -- by OrderByGraph as stop:<globalIndex>. We store .gkey on each item.
  local function pathCost(seq)
    if #seq == 0 then
      return 0
    end
    local total = 0
    if startKeyHint then
      local d = cost(startKeyHint, seq[1].gkey)
      if not d then
        return 1e12
      end
      total = total + d
    end
    local j
    for j = 1, #seq - 1 do
      local d = cost(seq[j].gkey, seq[j + 1].gkey)
      if not d then
        return 1e12
      end
      total = total + d
    end
    if tailKeys and #tailKeys > 0 and #seq > 0 then
      local best
      local k
      for k = 1, #tailKeys do
        local d = cost(seq[#seq].gkey, tailKeys[k])
        if d and (not best or d < best) then
          best = d
        end
      end
      total = total + (best or 1e12)
    end
    return total
  end

  local function nnFrom(startItem)
    local remaining = {}
    local k
    for k = 1, #items do
      if items[k] ~= startItem then
        remaining[#remaining + 1] = items[k]
      end
    end
    local seq = {}
    local currentKey
    if startItem then
      seq[1] = startItem
      currentKey = startItem.gkey
    else
      currentKey = startKeyHint
    end
    while #remaining > 0 do
      local best, bestD, bestTie = 1, nil, remaining[1].sortKey or ""
      local j
      for j = 1, #remaining do
        local it = remaining[j]
        local d
        if currentKey then
          d = cost(currentKey, it.gkey)
        else
          d = 0
        end
        local key = it.sortKey or ""
        if d and (not bestD or d < bestD or (d == bestD and key < bestTie)) then
          best, bestD, bestTie = j, d, key
        elseif not d and not bestD and key < bestTie then
          best, bestTie = j, key
        end
      end
      local it = table.remove(remaining, best)
      seq[#seq + 1] = it
      currentKey = it.gkey
    end
    return seq
  end

  local seq
  if startKeyHint then
    seq = nnFrom(nil)
  else
    seq = nnFrom(items[1])
    local bestTotal = pathCost(seq)
    local s
    for s = 2, #items do
      local cand = nnFrom(items[s])
      local t = pathCost(cand)
      if t < bestTotal then
        seq, bestTotal = cand, t
      end
    end
  end

  local improved, round = true, 0
  while improved and round < 24 do
    improved = false
    round = round + 1
    local current = pathCost(seq)
    local a
    for a = 1, #seq - 1 do
      local b
      for b = a + 1, #seq do
        local cand = {}
        local k
        for k = 1, #seq do
          cand[k] = seq[k]
        end
        local u, v = a, b
        while u < v do
          cand[u], cand[v] = cand[v], cand[u]
          u = u + 1
          v = v - 1
        end
        local t = pathCost(cand)
        if t + 0.5 < current then
          seq = cand
          current = t
          improved = true
        end
      end
    end
  end
  -- Relocate (Or-opt of length 1): pull one stop out and try every slot.
  -- Catches cases 2-opt misses, e.g. Hinterlands stuffed between Searing
  -- Gorge and Badlands instead of after the nearby Badlands turn-in.
  improved, round = true, 0
  while improved and round < 12 do
    improved = false
    round = round + 1
    local current = pathCost(seq)
    local i
    for i = 1, #seq do
      local item = seq[i]
      local rest = {}
      local k
      for k = 1, #seq do
        if k ~= i then
          rest[#rest + 1] = seq[k]
        end
      end
      local dest
      for dest = 1, #rest + 1 do
        local cand = {}
        local r
        for r = 1, dest - 1 do
          cand[r] = rest[r]
        end
        cand[dest] = item
        for r = dest, #rest do
          cand[r + 1] = rest[r]
        end
        local t = pathCost(cand)
        if t + 0.5 < current then
          seq = cand
          current = t
          improved = true
        end
      end
    end
  end
  return seq
end

local function OrderByGraph(items, startPos, faction)
  local extras = {}
  local i
  for i = 1, #items do
    local it = items[i]
    it.gkey = "stop:" .. i
    extras[#extras + 1] = {
      key = it.gkey,
      kind = "stop",
      index = i,
      zone = it.writ and it.writ.zone,
      name = it.writ and (it.writ.npc or it.writ.zone),
      pos = it.worldPos,
    }
  end
  local startKey = nil
  if startPos then
    startKey = "start"
    extras[#extras + 1] = {
      key = startKey,
      kind = "start",
      zone = startPos.zone,
      name = "You",
      pos = startPos,
    }
  end

  local graph = BuildGraph(faction, extras)
  local cache = {}

  -- Group by continent and finish one continent at a time so a zeppelin
  -- crossing is not followed by a return trip for a leftover EK stop.
  local byCont = {}
  local continents = {}
  for i = 1, #items do
    local c = ItemContinent(items[i])
    if not byCont[c] then
      byCont[c] = {}
      continents[#continents + 1] = c
    end
    local list = byCont[c]
    list[#list + 1] = items[i]
  end
  local startCont = PosContinent(startPos)
  table.sort(continents, function(a, b)
    if startCont then
      if a == startCont and b ~= startCont then
        return true
      end
      if b == startCont and a ~= startCont then
        return false
      end
    end
    local oa, ob = CONTINENT_RANK[a] or 5, CONTINENT_RANK[b] or 5
    if oa ~= ob then
      return oa < ob
    end
    return a < b
  end)

  local ordered = {}
  local paths = {}
  local fromKey = startKey
  local g
  for g = 1, #continents do
    local group = byCont[continents[g]]
    local tailKeys = nil
    if g < #continents then
      tailKeys = {}
      local nxt = byCont[continents[g + 1]]
      local t
      for t = 1, #nxt do
        tailKeys[#tailKeys + 1] = nxt[t].gkey
      end
    end
    local seq = OrderGroup(group, startPos, fromKey, faction, graph, cache, tailKeys)
    local j
    for j = 1, #seq do
      ordered[#ordered + 1] = seq[j]
      if fromKey then
        local _, p = PathSeconds(graph, fromKey, seq[j].gkey, cache)
        paths[#ordered] = p
      end
      fromKey = seq[j].gkey
    end
  end
  return ordered, paths, graph
end

local function FillTravel(steps, paths)
  local i
  for i = 1, #steps do
    local destZone = steps[i].writ and steps[i].writ.zone
    local destPos = steps[i].worldPos
    local hint = DescribePath(paths and paths[i], destZone, destPos)
    if not hint then
      local prevZone = steps[i - 1] and steps[i - 1].writ and steps[i - 1].writ.zone
      if destZone and prevZone and destZone ~= prevZone then
        hint = "Go to " .. destZone
      end
    end
    steps[i].travel = hint
  end
end

-- Zone tour using the same faction travel graph (zone centers).
function Route.OrderZones(zones)
  local picked = {}
  local i
  for i = 1, #zones do
    local z = zones[i]
    local seen = false
    local j
    for j = 1, #picked do
      if picked[j].writ.zone == z then
        seen = true
        break
      end
    end
    if not seen then
      picked[#picked + 1] = {
        writ = { zone = z, writItemName = z, coords = { x = 50, y = 50 } },
      }
    end
  end
  local steps = Route.OrderStops(picked)
  local out = {}
  for i = 1, #steps do
    out[#out + 1] = steps[i].writ.zone
  end
  return out
end

-- Flatten a picked set into a tour that minimizes travel time on the
-- faction flight / run / zeppelin / boat graph (nearest-neighbor + 2-opt).
function Route.OrderStops(picked, opts)
  opts = opts or {}
  local faction = opts.faction or Route.PlayerFaction()
  local startPos = opts.startPos
  if startPos == nil then
    startPos = Route.GetPlayerWorldPos()
  end
  local items = {}
  local i
  for i = 1, #(picked or {}) do
    local row = picked[i]
    local w = row.writ
    items[#items + 1] = {
      writ = w,
      price = row.price,
      continent = Route.ContinentForZone(w.zone),
      mapId = Route.MapIdForZone(w.zone),
      worldPos = Route.WritWorldPos(w),
      sortKey = (w.zone or "") .. "\0" .. (w.writItemName or ""),
    }
  end
  if #items == 0 then
    return items
  end
  local ordered, paths = OrderByGraph(items, startPos, faction)
  FillTravel(ordered, paths)
  return ordered
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
