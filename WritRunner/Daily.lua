-- Daily completion tracking. Resets when the daily reset rolls over.

local WR = WritRunner
WR.Daily = WR.Daily or {}
local Daily = WR.Daily

local function SecondsUntilReset()
  if C_DateAndTime and C_DateAndTime.GetSecondsUntilDailyReset then
    return C_DateAndTime.GetSecondsUntilDailyReset()
  end
  if GetQuestResetTime then
    return GetQuestResetTime()
  end
  return nil
end

function Daily.NextResetTime()
  local secs = SecondsUntilReset()
  if not secs then
    return nil
  end
  return (GetServerTime and GetServerTime() or time()) + secs
end

function Daily.EnsureReset()
  local db = WR.db
  if not db then
    return
  end
  local nextReset = Daily.NextResetTime()
  if not nextReset then
    return
  end
  -- A stored reset timestamp in the past, or a stored time that no longer
  -- matches today's upcoming reset, means the daily boundary has passed.
  local now = (GetServerTime and GetServerTime() or time())
  local rolledOver = false
  if not db.resetAt or db.resetAt == 0 or now >= db.resetAt then
    -- resetAt == 0 is first init, not a real rollover.
    if db.resetAt and db.resetAt ~= 0 and now >= db.resetAt then
      rolledOver = true
    end
    db.completed = {}
    if WR.UI and WR.UI.ClearStaging then
      WR.UI.ClearStaging()
    end
    db.resetAt = nextReset
  elseif math.abs((db.resetAt or 0) - nextReset) > 120 then
    -- Clock skew or a missed rollover: trust the fresh API value.
    rolledOver = true
    db.completed = {}
    if WR.UI and WR.UI.ClearStaging then
      WR.UI.ClearStaging()
    end
    db.resetAt = nextReset
  end
  if rolledOver and WR.Run and WR.Run.IsActive and WR.Run.IsActive() then
    WR.Run.End("daily reset")
  end
end

-- db.completed[questId] is "manual" (removed in #3), "turnin" (real
-- turn-in or run step), or a legacy boolean true (treated as "turnin").
local function QuestIdOf(writOrId)
  if type(writOrId) == "table" then
    return writOrId.questId
  end
  return writOrId
end

local function QuestIsFlagged(questId)
  if not questId then
    return false
  end
  if C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted then
    local ok, flagged = pcall(C_QuestLog.IsQuestFlaggedCompleted, questId)
    if ok and flagged then
      return true
    end
  end
  if IsQuestFlaggedCompleted then
    local ok, flagged = pcall(IsQuestFlaggedCompleted, questId)
    if ok and flagged then
      return true
    end
  end
  return false
end

-- Returns "manual", "turnin", or nil. Flagged quests upgrade a stored
-- manual mark to turnin so a later real turn-in cannot be reset.
function Daily.Source(writOrId)
  Daily.EnsureReset()
  local questId = QuestIdOf(writOrId)
  if not questId or not WR.db then
    return nil
  end
  WR.db.completed = WR.db.completed or {}
  local stored = WR.db.completed[questId]
  if QuestIsFlagged(questId) then
    if stored ~= "turnin" then
      WR.db.completed[questId] = "turnin"
    end
    return "turnin"
  end
  if stored == "manual" then
    return "manual"
  end
  if stored then
    return "turnin"
  end
  return nil
end

function Daily.IsCompleted(writ)
  return Daily.Source(writ) ~= nil
end

function Daily.IsTurnedIn(writ)
  return Daily.Source(writ) == "turnin"
end

function Daily.IsManual(writ)
  return Daily.Source(writ) == "manual"
end

function Daily.CountBySource()
  Daily.EnsureReset()
  local turned, removed = 0, 0
  if not WR.db or not WR.db.completed then
    return 0, 0
  end
  local id, v
  for id, v in pairs(WR.db.completed) do
    if v then
      if Daily.Source(id) == "manual" then
        removed = removed + 1
      else
        turned = turned + 1
      end
    end
  end
  return turned, removed
end

-- source is "manual" or "turnin". Omitted source is treated as "turnin"
-- so Reset cannot accidentally restore an unmarked completion.
-- A turn-in never downgrades to manual. Clearing (done=false) is refused
-- for turned-in writs; use ClearCompleted for a full wipe (/writs reset).
function Daily.SetCompleted(writ, done, silent, source)
  Daily.EnsureReset()
  if not WR.db or not writ or not writ.questId then
    return
  end
  WR.db.completed = WR.db.completed or {}
  local current = Daily.Source(writ)
  if done then
    local want = source or "turnin"
    if want ~= "manual" then
      want = "turnin"
    end
    if current == "turnin" then
      want = "turnin"
    end
    WR.db.completed[writ.questId] = want
  else
    if current == "turnin" then
      return
    end
    WR.db.completed[writ.questId] = nil
  end
  if WR.UI and WR.UI.NoteCompletedChange then
    WR.UI.NoteCompletedChange(writ.questId)
  end
  if not silent and WR.UI and WR.UI.Refresh then
    WR.UI.Refresh()
  end
  if done and WR.Run and WR.Run.OnDailyCompleted then
    WR.Run.OnDailyCompleted(writ, true)
  end
end

function Daily.Toggle(writ)
  Daily.SetCompleted(writ, not Daily.IsCompleted(writ), false, "manual")
end

function Daily.ClearCompleted()
  if not WR.db then
    return
  end
  WR.db.completed = {}
  WR.db.resetAt = Daily.NextResetTime() or 0
  if WR.UI and WR.UI.ClearStaging then
    WR.UI.ClearStaging()
  end
end

-- Restore only #3 checkbox removals. Turned-in writs stay completed.
function Daily.ClearManual()
  Daily.EnsureReset()
  if not WR.db or not WR.db.completed then
    if WR.UI and WR.UI.ClearStaging then
      WR.UI.ClearStaging()
    end
    return
  end
  local id
  local ids = {}
  for id in pairs(WR.db.completed) do
    ids[#ids + 1] = id
  end
  local i
  for i = 1, #ids do
    id = ids[i]
    if Daily.Source(id) == "manual" then
      WR.db.completed[id] = nil
    end
  end
  if WR.UI and WR.UI.ClearStaging then
    WR.UI.ClearStaging()
  end
end

function Daily.OnQuestTurnedIn(questId)
  if not questId then
    return
  end
  Daily.EnsureReset()
  local writs = WritRunnerData and WritRunnerData.writs or {}
  local i
  for i = 1, #writs do
    if writs[i].questId == questId then
      Daily.SetCompleted(writs[i], true, false, "turnin")
      WR.Print("Recorded turn-in: " .. (writs[i].writItemName or ("quest " .. questId)))
      return
    end
  end
end

function Daily.WritByQuestId(questId)
  local writs = WritRunnerData and WritRunnerData.writs or {}
  local i
  for i = 1, #writs do
    if writs[i].questId == questId then
      return writs[i]
    end
  end
  return nil
end

-- Recheck the daily boundary even if the window stays open across reset.
local scheduled
function Daily.ScheduleResetWatch()
  if scheduled or not C_Timer or not C_Timer.After then
    return
  end
  scheduled = true
  local function tick()
    Daily.EnsureReset()
    if WR.UI and WR.UI.Refresh and WR.UI.frame and WR.UI.frame:IsShown() then
      WR.UI.Refresh()
    end
    local secs = SecondsUntilReset()
    if secs and secs > 0 then
      C_Timer.After(secs + 2, tick)
    else
      C_Timer.After(60, tick)
    end
  end
  local secs = SecondsUntilReset()
  if secs and secs > 0 then
    C_Timer.After(secs + 2, tick)
  else
    C_Timer.After(60, tick)
  end
end
