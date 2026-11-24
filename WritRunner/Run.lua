-- Active turn-in run: snapshot of the plan, progress, bag fallback, persistence.

local WR = WritRunner
WR.Run = WR.Run or {}
local Run = WR.Run

local function Now()
  return (GetServerTime and GetServerTime()) or time()
end

function WR.GetBagCount(itemId)
  if not itemId then
    return 0
  end
  if C_Item and C_Item.GetItemCount then
    local ok, n = pcall(C_Item.GetItemCount, itemId, false)
    if ok and type(n) == "number" then
      return n
    end
  end
  if GetItemCount then
    local ok, n = pcall(GetItemCount, itemId, false)
    if ok and type(n) == "number" then
      return n
    end
  end
  return 0
end

local function DB()
  return WR.db
end

function Run.IsActive()
  local db = DB()
  return db and db.run and db.run.active and true or false
end

function Run.Get()
  local db = DB()
  return db and db.run
end

function Run.Steps()
  local run = Run.Get()
  return (run and run.steps) or {}
end

function Run.CurrentIndex()
  local steps = Run.Steps()
  local i
  for i = 1, #steps do
    if not steps[i].done then
      return i
    end
  end
  return nil
end

function Run.CurrentStep()
  local i = Run.CurrentIndex()
  if not i then
    return nil
  end
  return Run.Steps()[i], i
end

function Run.Counts()
  local steps = Run.Steps()
  local done, total = 0, #steps
  local i
  for i = 1, total do
    if steps[i].done then
      done = done + 1
    end
  end
  return done, total
end

local function SnapshotWatch(step)
  if not step then
    return nil
  end
  return {
    questId = step.questId,
    writItemId = step.writItemId,
    requiredItemId = step.requiredItemId,
    requiredCount = step.requiredCount or 1,
    requiredAtStart = WR.GetBagCount(step.requiredItemId),
    writAtStart = WR.GetBagCount(step.writItemId),
  }
end

local function RefreshWatch()
  local run = Run.Get()
  if not run or not run.active then
    return
  end
  local step = Run.CurrentStep()
  run.watch = SnapshotWatch(step)
  if step and WR.Rep and WR.Rep.Snapshot then
    WR.Rep.Snapshot(step)
  end
end

local function AfterAdvance(reason)
  if WR.Tracker and WR.Tracker.Refresh then
    WR.Tracker.Refresh()
  end
  if WR.Pins and WR.Pins.Refresh then
    WR.Pins.Refresh()
  end
  Run.UpdateWaypoint()
  if WR.UI and WR.UI.UpdateRunButtons then
    WR.UI.UpdateRunButtons()
  end
  if reason then
    -- optional chatter handled by callers
  end
end

function Run.UpdateWaypoint()
  if not Run.IsActive() then
    return
  end
  local step = Run.CurrentStep()
  if not step then
    return
  end
  if not step.coords or not step.zone then
    return
  end
  -- Build a writ-shaped table for the existing waypoint helper.
  local writ = {
    zone = step.zone,
    npc = step.npc,
    coords = step.coords,
    writItemName = step.writItemName,
  }
  if WR.Route and WR.Route.SetWaypointForWrit then
    local ok, msg = WR.Route.SetWaypointForWrit(writ)
    if not ok and msg then
      WR.Print(msg)
    end
  end
end

local function StepFromPicked(ordered)
  local steps = {}
  local i
  for i = 1, #ordered do
    local s = ordered[i]
    local w = s.writ
    steps[#steps + 1] = {
      questId = w.questId,
      writItemId = w.writItemId,
      writItemName = w.writItemName,
      requiredItemId = w.requiredItemId,
      requiredItemName = w.requiredItemName,
      requiredCount = w.requiredCount or 1,
      zone = w.zone,
      npc = w.npc,
      coords = w.coords and { x = w.coords.x, y = w.coords.y } or nil,
      mapId = s.mapId or (WR.Route and WR.Route.MapIdForZone and WR.Route.MapIdForZone(w.zone)) or nil,
      continent = s.continent,
      travel = s.travel,
      rep = w.rep,
      done = false,
    }
  end
  return steps
end

local function ShortWritName(name)
  name = name or "Writ"
  return (name:gsub("^Craftsman's Writ: ", ""))
end

local function ItemLabel(itemId, fallback)
  local name = fallback
  if (not name or name == "") and itemId and C_Item and C_Item.GetItemNameByID then
    local ok, n = pcall(C_Item.GetItemNameByID, itemId)
    if ok and type(n) == "string" and n ~= "" then
      name = n
    end
  end
  if not name or name == "" then
    name = itemId and ("item " .. tostring(itemId)) or "unknown item"
  end
  if itemId and GetItemInfo then
    local link
    pcall(function()
      local _, l = GetItemInfo(itemId)
      if type(l) == "string" and l ~= "" then
        link = l
      end
    end)
    if link then
      return link
    end
  end
  return name
end

local function EntryWrit(entry)
  if not entry then
    return nil, true
  end
  if entry.done then
    return entry.writ or entry, true
  end
  local w = entry.writ or entry
  if w and WR.Daily and WR.Daily.IsCompleted and WR.Daily.IsCompleted(w) then
    return w, true
  end
  return w, false
end

-- Count every writ item and required item the plan (or remaining run steps)
-- still needs, aggregating duplicates. Bag counts are bags only, not bank
-- or mailbox.
function Run.CheckBags(source)
  local entries = source
  if type(entries) ~= "table" then
    return {
      empty = true,
      items = {},
      missing = {},
      missingCount = 0,
      checkedCount = 0,
      writs = 0,
    }
  end
  local byId = {}
  local items = {}
  local writs = 0
  local i
  for i = 1, #entries do
    local w, skip = EntryWrit(entries[i])
    if not skip and w then
      writs = writs + 1
      local label = ShortWritName(w.writItemName or entries[i].writItemName)
      local function add(itemId, name, count)
        if not itemId then
          return
        end
        count = count or 1
        local rec = byId[itemId]
        if not rec then
          rec = { itemId = itemId, name = name, need = 0, writList = {} }
          byId[itemId] = rec
          items[#items + 1] = rec
        elseif name and (not rec.name or rec.name == "") then
          rec.name = name
        end
        rec.need = rec.need + count
        local seen, k
        for k = 1, #rec.writList do
          if rec.writList[k] == label then
            seen = true
            break
          end
        end
        if not seen then
          rec.writList[#rec.writList + 1] = label
        end
      end
      add(w.writItemId, w.writItemName, 1)
      add(w.requiredItemId, w.requiredItemName, w.requiredCount or 1)
    end
  end
  local missing = {}
  for i = 1, #items do
    local rec = items[i]
    rec.have = WR.GetBagCount(rec.itemId)
    rec.label = ItemLabel(rec.itemId, rec.name)
    if rec.have < rec.need then
      missing[#missing + 1] = rec
    end
  end
  return {
    empty = (#entries == 0),
    allDone = (#entries > 0 and writs == 0),
    items = items,
    missing = missing,
    missingCount = #missing,
    checkedCount = #items,
    writs = writs,
  }
end

local pendingStart
local bagDlg

local DLG_WIDTH = 480
local LINE_H = 16
local MAX_VISIBLE = 12

local function FormatMissingLines(report)
  local lines = {}
  local i
  for i = 1, #(report.missing or {}) do
    local rec = report.missing[i]
    local forWrit = ""
    if rec.writList and #rec.writList > 0 then
      forWrit = "  (" .. table.concat(rec.writList, ", ") .. ")"
    end
    lines[#lines + 1] = string.format("%s  |cffff8080%d/%d|r%s", rec.label or "item", rec.have or 0, rec.need or 1, forWrit)
  end
  return lines
end

local function PlaceButtons(one, two)
  local dlg = bagDlg
  dlg.btn1:ClearAllPoints()
  dlg.btn2:ClearAllPoints()
  if two then
    dlg.btn1:SetText(one)
    dlg.btn2:SetText(two)
    dlg.btn1:SetPoint("BOTTOM", dlg, "BOTTOM", -70, 14)
    dlg.btn2:SetPoint("BOTTOM", dlg, "BOTTOM", 70, 14)
    dlg.btn1:Show()
    dlg.btn2:Show()
  else
    dlg.btn1:SetText(one)
    dlg.btn1:SetPoint("BOTTOM", dlg, "BOTTOM", 0, 14)
    dlg.btn1:Show()
    dlg.btn2:Hide()
  end
end

local function HideBagDialog()
  if bagDlg then
    bagDlg:Hide()
  end
end

local function AcceptStartAnyway()
  local src = pendingStart
  pendingStart = nil
  HideBagDialog()
  if src and Run.Start then
    local ok, msg = Run.Start(src)
    if not ok and msg then
      WR.Print(msg)
    end
    if WR.UI and WR.UI.UpdateRunButtons then
      WR.UI.UpdateRunButtons()
    end
  end
end

local function CancelPendingStart()
  pendingStart = nil
  HideBagDialog()
end

local function EnsureBagDialog()
  if bagDlg then
    return bagDlg
  end
  local dlg = CreateFrame("Frame", "WritRunnerBagDialog", UIParent, "BackdropTemplate")
  dlg:SetSize(DLG_WIDTH, 220)
  dlg:SetPoint("CENTER")
  dlg:SetFrameStrata("DIALOG")
  pcall(function() dlg:SetToplevel(true) end)
  dlg:SetMovable(true)
  dlg:EnableMouse(true)
  dlg:RegisterForDrag("LeftButton")
  dlg:SetScript("OnDragStart", dlg.StartMoving)
  dlg:SetScript("OnDragStop", dlg.StopMovingOrSizing)
  dlg:SetClampedToScreen(true)
  dlg:Hide()
  if dlg.SetBackdrop then
    dlg:SetBackdrop({
      bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
      edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
      tile = true, tileSize = 32, edgeSize = 16,
      insets = { left = 6, right = 6, top = 6, bottom = 6 },
    })
    dlg:SetBackdropColor(0, 0, 0, 0.92)
  else
    local bg = dlg:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.92)
  end
  if UISpecialFrames then
    tinsert(UISpecialFrames, "WritRunnerBagDialog")
  end

  local title = dlg:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOP", 0, -14)
  title:SetText("WritRunner")
  dlg.title = title

  local close = CreateFrame("Button", nil, dlg, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -2, -2)
  close:SetScript("OnClick", function()
    CancelPendingStart()
  end)

  local header = dlg:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  header:SetPoint("TOPLEFT", 20, -42)
  header:SetWidth(DLG_WIDTH - 40)
  header:SetJustifyH("LEFT")
  header:SetJustifyV("TOP")
  dlg.header = header

  local scroll = CreateFrame("ScrollFrame", "WritRunnerBagDialogScroll", dlg, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 20, -68)
  scroll:SetSize(DLG_WIDTH - 54, MAX_VISIBLE * LINE_H)
  dlg.scroll = scroll

  local child = CreateFrame("Frame", nil, scroll)
  child:SetSize(DLG_WIDTH - 74, MAX_VISIBLE * LINE_H)
  scroll:SetScrollChild(child)
  dlg.child = child
  pcall(function()
    child:EnableMouse(true)
    if child.SetHyperlinksEnabled then
      child:SetHyperlinksEnabled(true)
    end
    child:SetScript("OnHyperlinkClick", function(_, link, text, button)
      if SetItemRef then
        SetItemRef(link, text, button)
      end
    end)
    child:SetScript("OnHyperlinkEnter", function(self, link)
      if GameTooltip and link then
        GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
        GameTooltip:SetHyperlink(link)
        GameTooltip:Show()
      end
    end)
    child:SetScript("OnHyperlinkLeave", function()
      if GameTooltip then
        GameTooltip:Hide()
      end
    end)
  end)

  local listText = child:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  listText:SetPoint("TOPLEFT", 0, 0)
  listText:SetWidth(DLG_WIDTH - 74)
  listText:SetJustifyH("LEFT")
  listText:SetJustifyV("TOP")
  dlg.listText = listText

  local footer = dlg:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  footer:SetPoint("BOTTOMLEFT", 20, 44)
  footer:SetPoint("BOTTOMRIGHT", -20, 44)
  footer:SetJustifyH("LEFT")
  footer:SetText("Items still in the mailbox do not count — take them out first.")
  dlg.footer = footer

  local function MakeBtn()
    local btn = CreateFrame("Button", nil, dlg, "UIPanelButtonTemplate")
    btn:SetSize(120, 22)
    return btn
  end
  dlg.btn1 = MakeBtn()
  dlg.btn2 = MakeBtn()
  dlg.btn1:SetScript("OnClick", function()
    if dlg.mode == "startMissing" then
      AcceptStartAnyway()
    else
      CancelPendingStart()
    end
  end)
  dlg.btn2:SetScript("OnClick", function()
    CancelPendingStart()
  end)

  dlg:SetScript("OnHide", function()
    -- ESC / close: drop a pending start so a later Start anyway cannot fire stale.
    pendingStart = nil
  end)
  dlg:SetScript("OnMouseWheel", function() end)
  scroll:EnableMouseWheel(true)
  scroll:SetScript("OnMouseWheel", function(self, delta)
    local sb = _G["WritRunnerBagDialogScrollScrollBar"]
    if not sb then
      return
    end
    local minV, maxV = sb:GetMinMaxValues()
    sb:SetValue((sb:GetValue() or 0) - delta * LINE_H * 3)
  end)

  bagDlg = dlg
  return dlg
end

local function LayoutMessage(dlg, title, message)
  dlg.title:SetText(title or "WritRunner")
  dlg.header:SetText(message or "")
  dlg.header:SetPoint("TOPLEFT", 20, -48)
  dlg.scroll:Hide()
  dlg.footer:Hide()
  local bodyH = dlg.header:GetStringHeight() or 20
  if bodyH < 20 then
    bodyH = 20
  end
  dlg:SetSize(DLG_WIDTH, 48 + bodyH + 60)
end

local function LayoutList(dlg, title, header, lines)
  dlg.title:SetText(title or "WritRunner")
  dlg.header:SetText(header or "")
  dlg.header:SetPoint("TOPLEFT", 20, -42)
  dlg.listText:SetText(table.concat(lines, "\n"))
  local n = #lines
  local visible = n
  if visible < 1 then
    visible = 1
  elseif visible > MAX_VISIBLE then
    visible = MAX_VISIBLE
  end
  local scrollH = visible * LINE_H + 6
  dlg.scroll:Show()
  dlg.scroll:SetHeight(scrollH)
  local contentH = dlg.listText:GetStringHeight() or (n * LINE_H)
  if contentH < scrollH then
    contentH = scrollH
  end
  dlg.child:SetHeight(contentH + 4)
  dlg.footer:Show()
  -- header (~20) + scroll + footer (~16) + buttons + padding
  dlg:SetSize(DLG_WIDTH, 68 + scrollH + 70)
  dlg.scroll:SetVerticalScroll(0)
end

-- mode is "check" (OK only) or "start" (Start anyway / Cancel when items are missing).
function Run.ShowBagReport(report, mode, picked)
  if not report then
    return
  end
  mode = mode or "check"
  local dlg = EnsureBagDialog()
  -- Clear first so a previous OnHide does not wipe a new pending start.
  if dlg:IsShown() then
    pendingStart = nil
    dlg:Hide()
  end
  if mode == "start" and report.missingCount and report.missingCount > 0 then
    pendingStart = picked
    dlg.mode = "startMissing"
    local lines = FormatMissingLines(report)
    LayoutList(dlg, "Missing items",
      string.format("|cffff4040Missing %d item%s for this run:|r",
        report.missingCount, report.missingCount == 1 and "" or "s"),
      lines)
    PlaceButtons("Start anyway", "Cancel")
  else
    pendingStart = nil
    dlg.mode = "check"
    if report.empty then
      LayoutMessage(dlg, "WritRunner", "Nothing to check. Set a budget so the plan has writs, then try again.")
    elseif report.allDone or report.checkedCount == 0 then
      LayoutMessage(dlg, "WritRunner", "Nothing left to check: every writ in the plan is already done today.")
    elseif report.missingCount and report.missingCount > 0 then
      local lines = FormatMissingLines(report)
      LayoutList(dlg, "Missing items",
        string.format("|cffff4040Missing %d item%s for this run:|r",
          report.missingCount, report.missingCount == 1 and "" or "s"),
        lines)
    else
      LayoutMessage(dlg, "WritRunner",
        string.format("|cff40ff40All %d items are in your bags. Good to go.|r", report.checkedCount or 0))
    end
    PlaceButtons("OK")
  end
  dlg:Show()
  if dlg.Raise then
    dlg:Raise()
  end
end

-- Kept for older callers; shows the check-bags dialog (OK to close).
function Run.PrintBagReport(report)
  Run.ShowBagReport(report, "check")
end

function Run.PromptStartDespiteMissing(picked, report)
  Run.ShowBagReport(report, "start", picked)
end

function Run.Start(picked)
  if not WR.db then
    return false, "Saved variables are not ready."
  end
  if not picked or #picked == 0 then
    return false, "Nothing to run. Set a budget (or clear it to include all priced writs) and make sure Auctionator has prices."
  end
  if not WR.Route or not WR.Route.OrderStops then
    return false, "Route module is not loaded."
  end
  local ordered = WR.Route.OrderStops(picked)
  if #ordered == 0 then
    return false, "The current plan is empty."
  end
  local replacing = Run.IsActive()
  WR.db.run = {
    active = true,
    startedAt = Now(),
    steps = StepFromPicked(ordered),
    trackerShown = true,
    repGained = 0,
    elapsed = 0,
    distance = 0,
    clockStarted = false, -- time and distance start at the first real turn-in
    splitElapsed = 0,
    splitDist = 0,
    repAtStart = WR.Rep and WR.Rep.Value and WR.Rep.Value() or nil,
  }
  RefreshWatch()
  if WR.Tracker and WR.Tracker.Show then
    WR.Tracker.Show()
  end
  AfterAdvance()
  local msg = string.format("Started a run with %d turn-in%s.", #ordered, #ordered == 1 and "" or "s")
  if replacing then
    msg = "Replaced the current run. " .. msg
  end
  WR.Print(msg)
  local step = Run.CurrentStep()
  if step and step.travel then
    WR.Print(step.travel)
  end
  if step and (not step.coords or not step.zone) then
    WR.Print("Next step has no published coordinates: " .. (step.zone or "unknown zone") .. (step.npc and (", " .. step.npc) or "") .. ".")
  end
  return true
end

function Run.End(reason)
  local db = DB()
  if not db or not db.run or not db.run.active then
    if db then
      db.run = nil
    end
    if WR.Tracker and WR.Tracker.Hide then
      WR.Tracker.Hide()
    end
    if WR.Pins and WR.Pins.Refresh then
      WR.Pins.Refresh()
    end
    if WR.UI and WR.UI.UpdateRunButtons then
      WR.UI.UpdateRunButtons()
    end
    return
  end
  db.run.active = false
  db.run.watch = nil
  -- Keep steps around until the next start so the user can glance back?
  -- Clear fully so /reload does not restore a finished run.
  db.run = { active = false, trackerShown = false }
  if WR.Tracker and WR.Tracker.Hide then
    WR.Tracker.Hide()
  end
  if WR.Pins and WR.Pins.Refresh then
    WR.Pins.Refresh()
  end
  if WR.UI and WR.UI.UpdateRunButtons then
    WR.UI.UpdateRunButtons()
  end
  if reason == "daily reset" then
    WR.Print("Daily reset: ended the current writ run.")
  elseif reason ~= "silent" then
    WR.Print("Ended the writ run.")
  end
end

function Run.Restore()
  if not Run.IsActive() then
    return
  end
  -- Re-resolve map IDs in case the live C_Map walk now knows them.
  if WR.Route and WR.Route.MapIdForZone then
    local steps = Run.Steps()
    local i
    for i = 1, #steps do
      if not steps[i].mapId and steps[i].zone then
        steps[i].mapId = WR.Route.MapIdForZone(steps[i].zone)
      end
    end
  end
  RefreshWatch()
  -- Rebuild the remaining tour with the current travel model (faction
  -- flight points, runs, boats/zeppelins) without touching completed steps.
  if Run.Reroute then
    Run.Reroute(true)
  end
  local run = Run.Get()
  if WR.Tracker then
    if run.trackerShown ~= false then
      WR.Tracker.Show()
    else
      WR.Tracker.Refresh()
    end
  end
  AfterAdvance()
end

local function LookupWrit(step)
  if not step or not WritRunnerData then
    return nil
  end
  local writs = WritRunnerData.writs or {}
  local i
  for i = 1, #writs do
    if step.questId and writs[i].questId == step.questId then
      return writs[i]
    end
  end
  return nil
end

-- Start the clock on the first real turn-in. "daily" is used both for a
-- QUEST_TURNED_IN that Daily recorded first (source "turnin") and for a
-- #3 Confirm removal (source "manual") — only the former should start it.
-- Skip / Mark done also starts it: the tracker button is often clicked
-- right after a hand-in if detection missed the quest event.
local function IsClockStart(how, dailySource)
  if how == "quest" or how == "bags" or how == "skip" or how == "manual" then
    return true
  end
  return how == "daily" and dailySource ~= "manual"
end

local function CompleteStep(index, how, dailySource)
  local run = Run.Get()
  if not run or not run.steps or not run.steps[index] then
    return
  end
  local step = run.steps[index]
  if step.done then
    return
  end
  step.done = true
  if not run.clockStarted then
    if IsClockStart(how, dailySource) then
      -- First real turn-in: start the clock here, so waiting at the AH or
      -- the trip before it doesn't count. clockStarted lives in
      -- WritRunnerDB.run, so a /reload mid-run keeps the state.
      run.clockStarted = true
      run.elapsed, run.distance = 0, 0
      run.splitElapsed, run.splitDist = 0, 0
      step.clockStart = true
      WR.Print("First turn-in done. Run timer and distance started.")
    end
  else
    step.splitTime = (run.elapsed or 0) - (run.splitElapsed or 0)
    step.splitDist = (run.distance or 0) - (run.splitDist or 0)
    run.splitElapsed = run.elapsed or 0
    run.splitDist = run.distance or 0
  end
  local writ = LookupWrit(step)
  if (how == "quest" or how == "bags" or (how == "daily" and dailySource ~= "manual")) and WR.Rep and WR.Rep.VerifyTurnIn then
    WR.Rep.VerifyTurnIn(step, step.rep or (writ and writ.rep))
  elseif how == "skip" or how == "manual" or (how == "daily" and dailySource == "manual") then
    step.repStatus = "skipped"
  end
  -- "daily" means #3 already recorded the source (manual or turn-in).
  -- Don't call SetCompleted again — a default would upgrade a manual
  -- removal to a turn-in and Reset could no longer restore it.
  if how ~= "daily" and writ and WR.Daily and WR.Daily.SetCompleted then
    WR.Daily.SetCompleted(writ, true, false, "turnin")
  end
  local done, total = Run.Counts()
  local nextStep, nextIndex = Run.CurrentStep()
  if not nextStep then
    local secs = math.floor(run.elapsed or 0)
    WR.Print(string.format("Step %d/%d done. Run complete — all %d turn-ins finished in %d:%02d, %d yards traveled.",
      index, total, total, math.floor(secs / 60), secs % 60, math.floor((run.distance or 0) + 0.5)))
  else
    local hint = nextStep.travel and (" " .. nextStep.travel .. ".") or ""
    WR.Print(string.format("Step %d/%d done. Next: %s, %s.%s", index, total, nextStep.zone or "?", nextStep.npc or "unknown NPC", hint))
  end
  RefreshWatch()
  AfterAdvance()
end

function Run.Reroute(silent)
  if not Run.IsActive() then
    return false, "No active run."
  end
  if not WR.Route or not WR.Route.OrderStops then
    return false, "Route module is not loaded."
  end
  local run = Run.Get()
  local steps = run.steps or {}
  local doneSteps, remain = {}, {}
  local i
  for i = 1, #steps do
    if steps[i].done then
      doneSteps[#doneSteps + 1] = steps[i]
    else
      remain[#remain + 1] = steps[i]
    end
  end
  if #remain == 0 then
    return false, "No remaining steps to reroute."
  end
  local picked = {}
  for i = 1, #remain do
    local step = remain[i]
    local writ = LookupWrit(step)
    if not writ then
      writ = {
        questId = step.questId,
        writItemId = step.writItemId,
        writItemName = step.writItemName,
        requiredItemId = step.requiredItemId,
        requiredItemName = step.requiredItemName,
        requiredCount = step.requiredCount,
        zone = step.zone,
        npc = step.npc,
        coords = step.coords,
        rep = step.rep,
      }
    end
    picked[#picked + 1] = { writ = writ }
  end
  local startPos
  if WR.Route.GetPlayerWorldPos then
    startPos = WR.Route.GetPlayerWorldPos()
  end
  if not startPos and #doneSteps > 0 and WR.Route.WritWorldPos then
    startPos = WR.Route.WritWorldPos(doneSteps[#doneSteps])
  end
  local ordered = WR.Route.OrderStops(picked, { startPos = startPos })
  local newSteps = {}
  for i = 1, #doneSteps do
    newSteps[#newSteps + 1] = doneSteps[i]
  end
  local rebuilt = StepFromPicked(ordered)
  for i = 1, #rebuilt do
    newSteps[#newSteps + 1] = rebuilt[i]
  end
  run.steps = newSteps
  RefreshWatch()
  if WR.Tracker and WR.Tracker.Refresh then
    WR.Tracker.Refresh()
  end
  if WR.Pins and WR.Pins.Refresh then
    WR.Pins.Refresh()
  end
  AfterAdvance()
  if not silent then
    WR.Print(string.format("Rerouted %d remaining turn-in%s. Completed steps were left as they were.",
      #rebuilt, #rebuilt == 1 and "" or "s"))
    local step = Run.CurrentStep()
    if step and step.travel then
      WR.Print(step.travel)
    end
  end
  return true
end


function Run.MarkIndexDone(index)
  CompleteStep(index, "manual")
end

function Run.SkipCurrent()
  local _, index = Run.CurrentStep()
  if not index then
    WR.Print("No remaining steps in this run.")
    return
  end
  CompleteStep(index, "skip")
end

function Run.OnQuestTurnedIn(questId)
  if not Run.IsActive() or not questId then
    return
  end
  local steps = Run.Steps()
  local i
  for i = 1, #steps do
    if not steps[i].done and steps[i].questId == questId then
      CompleteStep(i, "quest")
      return
    end
  end
end

-- If the main window's daily checkbox is ticked for a writ in this run, sync.
function Run.OnDailyCompleted(writ, done, source)
  if not Run.IsActive() or not writ or not writ.questId or not done then
    return
  end
  local steps = Run.Steps()
  local i
  for i = 1, #steps do
    if not steps[i].done and steps[i].questId == writ.questId then
      CompleteStep(i, "daily", source)
      return
    end
  end
end

function Run.CheckBagFallback()
  if not Run.IsActive() then
    return
  end
  local run = Run.Get()
  local watch = run and run.watch
  local step, index = Run.CurrentStep()
  if not watch or not step or not index then
    return
  end
  if watch.questId ~= step.questId or watch.requiredItemId ~= step.requiredItemId then
    RefreshWatch()
    return
  end
  local writCount = WR.GetBagCount(step.writItemId)
  local reqCount = WR.GetBagCount(step.requiredItemId)
  local need = step.requiredCount or 1
  -- Opening the writ consumes the writ item but not the required item, so
  -- both conditions must be true to treat this as a turn-in.
  if writCount == 0 and watch.requiredAtStart ~= nil and reqCount <= (watch.requiredAtStart - need) then
    CompleteStep(index, "bags")
  end
end

-- Event frame for bags, combat, and login restore (core also calls Restore).
local events = CreateFrame("Frame")
events:RegisterEvent("BAG_UPDATE_DELAYED")
events:RegisterEvent("BAG_UPDATE")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:RegisterEvent("PLAYER_ENTERING_WORLD")

local bagPending
events:SetScript("OnEvent", function(_, event)
  if event == "PLAYER_REGEN_ENABLED" then
    if WR.Tracker and WR.Tracker.ApplyPendingSecure then
      WR.Tracker.ApplyPendingSecure()
    end
    return
  end
  if event == "PLAYER_ENTERING_WORLD" then
    if Run.IsActive() then
      RefreshWatch()
      AfterAdvance()
    end
    return
  end
  if event == "BAG_UPDATE" or event == "BAG_UPDATE_DELAYED" then
    if bagPending then
      return
    end
    bagPending = true
    local function flush()
      bagPending = nil
      Run.CheckBagFallback()
      if WR.Tracker and WR.Tracker.Refresh then
        WR.Tracker.Refresh()
      elseif WR.Tracker and WR.Tracker.RefreshItem then
        WR.Tracker.RefreshItem()
      end
    end
    if C_Timer and C_Timer.After then
      C_Timer.After(0.15, flush)
    else
      flush()
    end
  end
end)

-- Time and distance tracking. Time counts only while logged in; distance sums
-- player movement in yards, ignoring teleports, hearths, and zone changes.
local MAX_STEP_YARDS = 120 -- per 0.5s sample; flight paths stay under this
local lastY, lastX, lastInst
local acc = 0
local ticker = CreateFrame("Frame")
ticker:SetScript("OnUpdate", function(_, dt)
  local run = WR.db and WR.db.run
  if not run or not run.active or not Run.CurrentIndex() then
    lastY = nil
    return
  end
  if not run.clockStarted then
    lastY = nil
    acc = acc + dt
    if acc >= 0.5 then
      acc = 0
      if WR.Tracker and WR.Tracker.RefreshStats then
        WR.Tracker.RefreshStats()
      end
    end
    return
  end
  run.elapsed = (run.elapsed or 0) + dt
  acc = acc + dt
  if acc < 0.5 then
    return
  end
  acc = 0
  local ok, y, x, _, inst = pcall(UnitPosition, "player")
  if ok and y and x then
    if lastY and inst == lastInst then
      local d = math.sqrt((y - lastY) ^ 2 + (x - lastX) ^ 2)
      if d > 0.05 and d < MAX_STEP_YARDS then
        run.distance = (run.distance or 0) + d
      end
    end
    lastY, lastX, lastInst = y, x, inst
  else
    lastY = nil
  end
  if WR.Tracker and WR.Tracker.RefreshStats then
    WR.Tracker.RefreshStats()
  end
end)
