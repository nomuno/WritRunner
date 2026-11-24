-- WritRunner core: saved variables, slash commands, and event wiring.

WritRunner = WritRunner or {}
local WR = WritRunner

WR.ADDON_NAME = "WritRunner"
WR.CALLER_ID = "WritRunner"

local defaults = {
  version = 1,
  maxGold = nil,
  budgetGold = nil,
  hideUnconfirmed = true,
  hideCompleted = true,
  showSealed = true,
  frame = { point = "CENTER", relativePoint = "CENTER", x = 0, y = 0 },
  completed = {},
  resetAt = 0,
}

local function CopyDefaults(src, dest)
  dest = dest or {}
  for k, v in pairs(src) do
    if type(v) == "table" then
      dest[k] = CopyDefaults(v, dest[k])
    elseif dest[k] == nil then
      dest[k] = v
    end
  end
  return dest
end

function WR.Print(msg)
  DEFAULT_CHAT_FRAME:AddMessage("|cffd4a017WritRunner|r: " .. tostring(msg))
end

function WR.HasAuctionator()
  return Auctionator
    and Auctionator.API
    and Auctionator.API.v1
    and Auctionator.API.v1.GetAuctionPriceByItemID
end

function WR.PlayerFaction()
  local faction = UnitFactionGroup("player")
  if faction == "Alliance" then
    return "Alliance", "Azeroth Commerce Authority"
  end
  if faction == "Horde" then
    return "Horde", "Durotar Supply and Logistics"
  end
  return faction, nil
end

function WR.Confirmed(writ)
  return writ and writ.confirmation == "cc" and writ.zone and writ.npc
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("QUEST_TURNED_IN")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("QUEST_DETAIL")
events:RegisterEvent("QUEST_COMPLETE")

local writQuest
local function IsWritQuest(questId)
  if not questId or questId == 0 or not WritRunnerData then
    return false
  end
  if not writQuest then
    writQuest = {}
    for _, w in ipairs(WritRunnerData.writs or {}) do
      if w.questId then writQuest[w.questId] = true end
    end
  end
  return writQuest[questId]
end

-- Learn each writ's gold reward from the game (no database publishes it).
function WR.RecordReward(questId, copper)
  if not WR.db or not IsWritQuest(questId) or type(copper) ~= "number" or copper <= 0 then
    return
  end
  WR.db.rewardMoney = WR.db.rewardMoney or {}
  if WR.db.rewardMoney[questId] ~= copper then
    WR.db.rewardMoney[questId] = copper
    if WR.UI and WR.UI.Refresh and WR.UI.frame and WR.UI.frame:IsShown() then
      WR.UI.Refresh()
    end
  end
end

events:SetScript("OnEvent", function(_, event, arg1, arg2, arg3)
  if event == "ADDON_LOADED" and arg1 == WR.ADDON_NAME then
    WritRunnerDB = CopyDefaults(defaults, WritRunnerDB)
    WR.db = WritRunnerDB
    if WR.Daily then
      WR.Daily.EnsureReset()
    end
  elseif event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
    if WR.db and WR.Daily then
      WR.Daily.EnsureReset()
      if event == "PLAYER_LOGIN" and WR.Daily.ScheduleResetWatch then
        WR.Daily.ScheduleResetWatch()
      end
    end
    if WR.Route and WR.Route.BuildMapIndex then
      WR.Route.BuildMapIndex()
    end
    if WR.Pins and WR.Pins.Install then
      WR.Pins.Install()
    end
    if event == "PLAYER_LOGIN" and WR.Run and WR.Run.Restore then
      WR.Run.Restore()
    end
    if event == "PLAYER_LOGIN" and not WR.warnedMissingAH and not WR.HasAuctionator() then
      WR.warnedMissingAH = true
      WR.Print("Auctionator is not loaded. Install a Forever-tagged Auctionator build (interface 16001) to price writs. The list still works, but every cost will show as unknown.")
    end
  elseif event == "QUEST_DETAIL" or event == "QUEST_COMPLETE" then
    local okId, qid = pcall(GetQuestID)
    local okM, money = pcall(GetRewardMoney)
    if okId and okM then
      WR.RecordReward(qid, money)
    end
  elseif event == "QUEST_TURNED_IN" then
    WR.RecordReward(arg1, arg3)
    if WR.Daily then
      WR.Daily.OnQuestTurnedIn(arg1)
    end
    if WR.Run and WR.Run.OnQuestTurnedIn then
      WR.Run.OnQuestTurnedIn(arg1)
    end
  end
end)

SLASH_WRITRUNNER1 = "/writs"
SLASH_WRITRUNNER2 = "/writrunner"
SlashCmdList.WRITRUNNER = function(msg)
  msg = (msg or ""):lower():match("^%s*(.-)%s*$")
  if msg == "help" then
    WR.Print("Commands: /writs toggles the window. /writs start, /writs check, /writs track, /writs end, /writs minimap, /writs reset (clears today's completed writs after a confirm popup).")
    return
  end
  if msg == "reset" then
    local function doReset()
      if WR.UI and WR.UI.ResetAllToday then
        WR.UI.ResetAllToday()
        return
      end
      if WR.Daily and WR.Daily.ClearCompleted then
        WR.Daily.ClearCompleted()
        WR.Print("Cleared today's completed-writ list.")
      end
      if WR.Run and WR.Run.IsActive and WR.Run.IsActive() then
        WR.Run.End()
      end
    end
    if WR.UI and WR.UI.ShowConfirm then
      WR.UI.ShowConfirm({
        title = "Reset today's writs",
        message = "Clear all of today's completed writs? This includes both turn-ins and writs you removed in #3, and it will end any active run.",
        accept = "Confirm",
        cancel = "Cancel",
        OnAccept = doReset,
      })
    else
      doReset()
    end
    return
  end
  if msg == "minimap" then
    if WR.UI and WR.UI.ToggleMinimapButton then
      WR.UI.ToggleMinimapButton()
    end
    return
  end
  if msg == "track" then
    if WR.Tracker and WR.Tracker.Toggle then
      WR.Tracker.Toggle()
    end
    return
  end
  if msg == "check" then
    if WR.UI and WR.UI.CheckBags then
      WR.UI.CheckBags()
    elseif WR.Run and WR.Run.CheckBags then
      local source
      if WR.Run.IsActive and WR.Run.IsActive() then
        source = WR.Run.Steps and WR.Run.Steps()
      end
      local report = WR.Run.CheckBags(source)
      if WR.Run.ShowBagReport then
        WR.Run.ShowBagReport(report, "check")
      end
    end
    return
  end
  if msg == "start" then
    if WR.UI and WR.UI.StartRunFromPlan then
      WR.UI.StartRunFromPlan()
    end
    return
  end
  if msg == "end" then
    if WR.Run and WR.Run.End then
      WR.Run.End()
    end
    return
  end
  if WR.UI and WR.UI.Toggle then
    WR.UI.Toggle()
  end
end
