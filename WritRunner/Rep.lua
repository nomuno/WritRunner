-- Writ faction reputation: live standing for the tracker, and per-turn-in
-- verification (did the turn-in actually award the expected reputation?).

local WR = WritRunner
WR.Rep = WR.Rep or {}
local Rep = WR.Rep

local CHECK_DELAY = 3     -- seconds after a turn-in before judging the gain
local CHAT_WINDOW = 8     -- seconds a chat rep message counts toward a turn-in

local cachedFactionId
local recentGains = {}    -- { t = GetTime(), amount = n }

local function FactionName()
  local _, name = WR.PlayerFaction()
  return name
end

local function Normalize(info)
  if not info then return nil end
  return info
end

-- Returns name, reaction (1-8), barMin, barMax, barValue, factionID
local function ReadByIndex(i)
  if C_Reputation and C_Reputation.GetFactionDataByIndex then
    local ok, d = pcall(C_Reputation.GetFactionDataByIndex, i)
    if ok and d then
      return d.name, d.reaction, d.currentReactionThreshold, d.nextReactionThreshold,
        d.currentStanding, d.factionID, d.isHeader, d.isCollapsed
    end
  end
  if GetFactionInfo then
    local ok, name, _, standing, bMin, bMax, val, _, _, isHeader, isCollapsed, _, _, _, fid = pcall(GetFactionInfo, i)
    if ok then
      return name, standing, bMin, bMax, val, fid, isHeader, isCollapsed
    end
  end
  return nil
end

local function ReadById(id)
  if not id then return nil end
  if C_Reputation and C_Reputation.GetFactionDataByID then
    local ok, d = pcall(C_Reputation.GetFactionDataByID, id)
    if ok and d and d.name then
      return d.name, d.reaction, d.currentReactionThreshold, d.nextReactionThreshold, d.currentStanding, d.factionID
    end
  end
  if GetFactionInfoByID then
    local ok, name, _, standing, bMin, bMax, val = pcall(GetFactionInfoByID, id)
    if ok and name then
      return name, standing, bMin, bMax, val, id
    end
  end
  return nil
end

local function NumFactions()
  if C_Reputation and C_Reputation.GetNumFactions then
    local ok, n = pcall(C_Reputation.GetNumFactions)
    if ok and n then return n end
  end
  if GetNumFactions then
    local ok, n = pcall(GetNumFactions)
    if ok and n then return n end
  end
  return 0
end

local function Expand(i)
  if C_Reputation and C_Reputation.ExpandFactionHeader then
    return pcall(C_Reputation.ExpandFactionHeader, i)
  elseif ExpandFactionHeader then
    return pcall(ExpandFactionHeader, i)
  end
end

local function FindFactionId()
  local want = FactionName()
  if not want then return nil end
  if WR.db and WR.db.repFactionId and WR.db.repFactionName == want then
    return WR.db.repFactionId
  end
  local function scan()
    local n = NumFactions()
    for i = 1, n do
      local name, _, _, _, _, fid = ReadByIndex(i)
      if name == want and fid then
        return fid
      end
    end
  end
  local fid = scan()
  if not fid then
    -- The faction may sit under a collapsed header; open headers and look again.
    local n = NumFactions()
    for i = n, 1, -1 do
      local _, _, _, _, _, _, isHeader, isCollapsed = ReadByIndex(i)
      if isHeader and isCollapsed then
        Expand(i)
      end
    end
    fid = scan()
  end
  if fid and WR.db then
    WR.db.repFactionId = fid
    WR.db.repFactionName = want
  end
  return fid
end

-- Public: current standing, or nil if the faction is not discovered yet.
function Rep.Get()
  local name = FactionName()
  if not name then return nil end
  cachedFactionId = cachedFactionId or FindFactionId()
  local n, reaction, bMin, bMax, val, fid = ReadById(cachedFactionId)
  if not n then
    cachedFactionId = nil
    return { name = name, missing = true }
  end
  local label = reaction and (_G["FACTION_STANDING_LABEL" .. reaction]) or "?"
  return {
    name = n, factionId = fid, reaction = reaction, standing = label,
    value = val or 0, min = bMin or 0, max = bMax or 0,
  }
end

function Rep.Value()
  local r = Rep.Get()
  return r and not r.missing and r.value or nil
end

-- Chat: "Reputation with Durotar Supply and Logistics increased by 75."
local function OnFactionChat(msg)
  local name = FactionName()
  if not msg or not name or not msg:find(name, 1, true) then return end
  local amount = tonumber(msg:match("increased by (%d+)") or msg:match("(%d+)"))
  if not amount then return end
  if msg:find("decreased", 1, true) then amount = -amount end
  recentGains[#recentGains + 1] = { t = GetTime(), amount = amount }
  if WR.db and WR.db.run and WR.db.run.active then
    WR.db.run.repGained = (WR.db.run.repGained or 0) + amount
  end
end

local function ChatGainSince(t0)
  local sum, seen = 0, false
  local keep = {}
  local now = GetTime()
  for _, g in ipairs(recentGains) do
    if g.t >= t0 then
      sum = sum + g.amount
      seen = true
    end
    if now - g.t < 60 then keep[#keep + 1] = g end
  end
  recentGains = keep
  return seen and sum or nil
end

-- Called by Run when a step is completed by an actual turn-in.
function Rep.VerifyTurnIn(step, expected)
  if not step then return end
  step.repExpected = expected
  step.repStatus = "checking"
  local t0 = GetTime() - CHAT_WINDOW
  local before = step.repBefore
  local function judge()
    local gained = ChatGainSince(t0)
    if gained == nil and before then
      local now = Rep.Value()
      if now then gained = now - before end
    end
    step.repGained = gained or 0
    if (gained or 0) <= 0 then
      step.repStatus = "missing"
      WR.db.repMissed = WR.db.repMissed or {}
      table.insert(WR.db.repMissed, {
        at = (GetServerTime and GetServerTime()) or time(),
        questId = step.questId, writ = step.writItemName, expected = expected,
      })
      WR.Print(string.format("|cffff4040No %s rep detected for %s (expected %s).|r Screenshot it for a bug report.",
        FactionName() or "writ", step.writItemName or "this writ", tostring(expected or "?")))
    elseif expected and gained < expected then
      step.repStatus = "short"
      WR.Print(string.format("|cffffa040Only +%d rep for %s (expected %d).|r", gained, step.writItemName or "writ", expected))
    else
      step.repStatus = "ok"
    end
    if WR.Tracker and WR.Tracker.Refresh then WR.Tracker.Refresh() end
  end
  if C_Timer and C_Timer.After then
    C_Timer.After(CHECK_DELAY, judge)
  else
    judge()
  end
end

-- Snapshot the bar value when a step becomes current (fallback measurement).
function Rep.Snapshot(step)
  if step and not step.done then
    step.repBefore = Rep.Value()
  end
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("CHAT_MSG_COMBAT_FACTION_CHANGE")
ev:RegisterEvent("UPDATE_FACTION")
ev:SetScript("OnEvent", function(_, event, msg)
  if event == "CHAT_MSG_COMBAT_FACTION_CHANGE" then
    OnFactionChat(msg)
  end
  if WR.Tracker and WR.Tracker.RefreshRep then
    WR.Tracker.RefreshRep()
  end
end)
