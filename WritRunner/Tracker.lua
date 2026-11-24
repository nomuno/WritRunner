-- Compact quest-like objective tracker for the active run.

local WR = WritRunner
WR.Tracker = WR.Tracker or {}
local Tracker = WR.Tracker

local FRAME_WIDTH = 300
local FRAME_HEIGHT = 470
local VISIBLE = 30 -- max row widgets; rows are variable height and clipped
local lastCurrent = nil

local frame
local stepRows = {}
local listOffset = 0
local pendingItemId -- queued SecureActionButton attribute (combat lockdown)

local function SavePosition()
  if not WR.db or not frame then
    return
  end
  local point, _, relativePoint, x, y = frame:GetPoint(1)
  WR.db.trackerFrame = { point = point, relativePoint = relativePoint, x = x, y = y }
end

local function ApplyPosition()
  if not frame then
    return
  end
  frame:ClearAllPoints()
  local f = WR.db and WR.db.trackerFrame
  if f and f.point then
    frame:SetPoint(f.point, UIParent, f.relativePoint or f.point, f.x or 0, f.y or 0)
  else
    frame:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -180, -220)
  end
end

local function ShortWrit(name)
  name = name or "Writ"
  return (name:gsub("^Craftsman's Writ: ", ""))
end

local function CoordText(step)
  if step.coords then
    return string.format("%.1f, %.1f", step.coords.x, step.coords.y)
  end
  return "no coords"
end

local function SetUseItem(itemId)
  if not frame or not frame.itemBtn then
    return
  end
  if InCombatLockdown and InCombatLockdown() then
    pendingItemId = itemId or false
    return
  end
  pendingItemId = nil
  local btn = frame.itemBtn
  if itemId then
    btn:SetAttribute("type", "item")
    btn:SetAttribute("item", "item:" .. itemId)
  else
    btn:SetAttribute("type", nil)
    btn:SetAttribute("item", nil)
  end
end

function Tracker.ApplyPendingSecure()
  if pendingItemId == nil then
    return
  end
  local id = pendingItemId
  if id == false then
    id = nil
  end
  SetUseItem(id)
end

local function ItemIcon(itemId)
  if not itemId then
    return nil
  end
  if C_Item and C_Item.GetItemIconByID then
    local ok, icon = pcall(C_Item.GetItemIconByID, itemId)
    if ok and icon then
      return icon
    end
  end
  if GetItemIcon then
    local ok, icon = pcall(GetItemIcon, itemId)
    if ok then
      return icon
    end
  end
  return nil
end

function Tracker.RefreshItem()
  if not frame then
    return
  end
  local step = WR.Run and WR.Run.CurrentStep and WR.Run.CurrentStep()
  local btn = frame.itemBtn
  if not step then
    SetUseItem(nil)
    btn.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
    btn.icon:SetDesaturated(true)
    btn.count:SetText("")
    frame.itemHint:SetText("Run complete — all steps finished.")
    btn:Disable()
    return
  end
  local icon = ItemIcon(step.writItemId)
  btn.icon:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")
  local count = WR.GetBagCount and WR.GetBagCount(step.writItemId) or 0
  btn.count:SetText(count > 0 and tostring(count) or "0")
  if count > 0 then
    btn.icon:SetDesaturated(false)
    btn.count:SetTextColor(1, 1, 1)
    frame.itemHint:SetText("Click the writ to open it when you reach the NPC. (In bags: " .. count .. ")")
    SetUseItem(step.writItemId)
    if not (InCombatLockdown and InCombatLockdown()) then
      btn:Enable()
    end
  else
    btn.icon:SetDesaturated(true)
    btn.count:SetTextColor(1, 0.3, 0.3)
    frame.itemHint:SetText("Writ not in bags — loot or buy it before this step.")
    SetUseItem(nil)
    if not (InCombatLockdown and InCombatLockdown()) then
      btn:Disable()
    end
  end
  btn.step = step
end


local function FmtTime(sec)
  sec = math.floor(sec or 0)
  local h = math.floor(sec / 3600)
  local m = math.floor((sec % 3600) / 60)
  local s = sec % 60
  if h > 0 then
    return string.format("%d:%02d:%02d", h, m, s)
  end
  return string.format("%d:%02d", m, s)
end

local function FmtYards(y)
  y = math.floor((y or 0) + 0.5)
  if y >= 1000 then
    return string.format("%d,%03d yd", math.floor(y / 1000), y % 1000)
  end
  return y .. " yd"
end

local function WorldPos(mapId, x, y)
  if not (C_Map and C_Map.GetWorldPosFromMapPos and CreateVector2D) then
    return nil
  end
  local ok, cont, pos = pcall(C_Map.GetWorldPosFromMapPos, mapId, CreateVector2D(x, y))
  if ok and cont and pos then
    local px, py = pos:GetXY()
    return cont, px, py
  end
  return nil
end

-- Straight-line yards from the player to a step's NPC (same continent only).
local function DistanceToStep(step)
  if not step or not step.coords or not step.mapId or not C_Map then
    return nil
  end
  local okMap, pMap = pcall(C_Map.GetBestMapForUnit, "player")
  if not okMap or not pMap then
    return nil
  end
  local okPos, pPos = pcall(C_Map.GetPlayerMapPosition, pMap, "player")
  if not okPos or not pPos then
    return nil
  end
  local pc, px, py = WorldPos(pMap, pPos:GetXY())
  local tc, tx, ty = WorldPos(step.mapId, step.coords.x / 100, step.coords.y / 100)
  if not pc or not tc or pc ~= tc then
    return nil
  end
  return math.sqrt((px - tx) ^ 2 + (py - ty) ^ 2)
end

function Tracker.RefreshStats()
  if not frame or not frame.stats or not frame:IsShown() then
    return
  end
  local run = WR.db and WR.db.run
  if not run or not run.active then
    frame.stats:SetText("")
    return
  end
  local parts
  if run.clockStarted == false then
    parts = { "|cffffd100Timer starts at first turn-in|r" }
  else
    parts = {
      "Time " .. FmtTime(run.elapsed),
      "Traveled " .. FmtYards(run.distance),
    }
  end
  local step = WR.Run and WR.Run.CurrentStep and WR.Run.CurrentStep()
  local d = DistanceToStep(step)
  if d then
    parts[#parts + 1] = "Next " .. FmtYards(d)
  end
  frame.stats:SetText(table.concat(parts, "   "))
end

local function RefreshSteps()
  if not frame then
    return
  end
  local steps = (WR.Run and WR.Run.Steps and WR.Run.Steps()) or {}
  local current = WR.Run and WR.Run.CurrentIndex and WR.Run.CurrentIndex()
  local done, total = 0, #steps
  if WR.Run and WR.Run.Counts then
    done, total = WR.Run.Counts()
  end
  if total == 0 then
    frame.title:SetText("Writ run")
  else
    frame.title:SetText(string.format("Writ run  %d/%d", math.min(done + 1, total), total))
  end

  -- Build a display list: travel hint + step, in order.
  local lines = {}
  local i
  for i = 1, #steps do
    local s = steps[i]
    if s.travel and not s.done then
      lines[#lines + 1] = { kind = "travel", text = s.travel, index = i, current = (current == i) }
    end
    lines[#lines + 1] = { kind = "step", step = s, index = i, current = (current == i) }
  end

  -- Format every line, then measure it at the list's real width.
  local listW = frame.list:GetWidth() or (FRAME_WIDTH - 32)
  local listH = frame.list:GetHeight() or (FRAME_HEIGHT - 108)
  if listW < 50 then listW = FRAME_WIDTH - 32 end
  if listH < 50 then listH = FRAME_HEIGHT - 108 end
  local measure = frame.measure
  measure:SetWidth(listW - 12)
  local l
  for l = 1, #lines do
    local line = lines[l]
    if line.kind == "travel" then
      line.text2 = "|cff99ccff" .. line.text .. "|r"
    else
      local s = line.step
      local mark, color
      if s.done then
        mark, color = "[x]", "|cff888888"
      elseif line.current then
        mark, color = ">", "|cffffd100"
      else
        mark, color = "-", "|cffffffff"
        -- Only upcoming steps: the current one may have just opened the writ,
        -- which consumes it before the turn-in.
        if WR.GetBagCount then
          local short
          if s.writItemId and WR.GetBagCount(s.writItemId) < 1 then
            short = true
          elseif s.requiredItemId and WR.GetBagCount(s.requiredItemId) < (s.requiredCount or 1) then
            short = true
          end
          if short then
            color = "|cffff4040"
          end
        end
      end
      line.text2 = string.format("%s%s %d/%d: %s, %s (%s)|r\n%s    Hand in: %s|r",
        color, mark, line.index, total, s.zone or "unknown zone", s.npc or "unknown NPC", CoordText(s),
        color, s.requiredItemName or "item")
      if color == "|cffff4040" and not s.done then
        line.text2 = line.text2 .. "  |cffff4040missing items|r"
      end
      if s.done and s.clockStart then
        line.text2 = line.text2 .. "\n|cff888888    timer started here|r"
      elseif s.done and s.splitTime then
        line.text2 = line.text2 .. string.format("\n|cff888888    %s, %s|r", FmtTime(s.splitTime), FmtYards(s.splitDist))
      end
      if s.done then
        local st = s.repStatus
        if st == "ok" then
          line.text2 = line.text2 .. string.format("  |cff40ff40+%d rep|r", s.repGained or 0)
        elseif st == "short" then
          line.text2 = line.text2 .. string.format("  |cffffa040+%d rep (exp %d)|r", s.repGained or 0, s.repExpected or 0)
        elseif st == "missing" then
          line.text2 = line.text2 .. string.format("  |cffff4040NO REP (exp %s)|r", tostring(s.repExpected or "?"))
        elseif st == "checking" then
          line.text2 = line.text2 .. "  |cffccccccchecking rep...|r"
        elseif st == "skipped" then
          line.text2 = line.text2 .. "  |cff888888skipped|r"
        end
      end
    end
    measure:SetText(line.text2)
    line.h = math.max(18, math.ceil(measure:GetStringHeight() or 14) + 8)
  end

  -- Largest offset that still fills the list down to the last line.
  local maxOffset = 0
  local acc = 0
  for l = #lines, 1, -1 do
    acc = acc + lines[l].h
    if acc > listH then
      maxOffset = l
      break
    end
  end
  if maxOffset > 0 then
    maxOffset = math.min(maxOffset, #lines - 1)
  end

  -- Only jump to the current step when it changes, so manual scrolling sticks.
  if current ~= lastCurrent then
    lastCurrent = current
    for l = 1, #lines do
      if lines[l].index == current then
        listOffset = l - 1
        break
      end
    end
  end
  if listOffset > maxOffset then listOffset = maxOffset end
  if listOffset < 0 then listOffset = 0 end

  frame.updatingSlider = true
  frame.slider:SetMinMaxValues(0, maxOffset)
  frame.slider:SetValue(listOffset)
  frame.updatingSlider = false
  if maxOffset == 0 then frame.slider:Hide() else frame.slider:Show() end

  local y = 0
  local r
  for r = 1, VISIBLE do
    local row = stepRows[r]
    local line = lines[listOffset + r]
    if not line or y >= listH then
      row:Hide()
      row.line = nil
    else
      row:ClearAllPoints()
      row:SetPoint("TOPLEFT", frame.list, "TOPLEFT", 0, -y)
      row:SetPoint("TOPRIGHT", frame.list, "TOPRIGHT", -4, -y)
      row:SetHeight(line.h)
      row.body:SetText(line.text2)
      row.line = line
      if line.kind == "travel" then
        row.bg:SetColorTexture(1, 0.82, 0, line.current and 0.12 or 0)
      elseif line.current then
        row.bg:SetColorTexture(1, 0.82, 0, 0.18)
      elseif line.step.done then
        row.bg:SetColorTexture(0, 0, 0, 0.15)
      else
        row.bg:SetColorTexture(0, 0, 0, 0)
      end
      row:Show()
      y = y + line.h
    end
  end
end

function Tracker.RefreshRep()
  if not frame or not frame.repBar then
    return
  end
  local bar = frame.repBar
  local r = WR.Rep and WR.Rep.Get and WR.Rep.Get()
  if not r then
    bar:SetValue(0)
    bar.text:SetText("No writ faction")
    return
  end
  local short = r.name:gsub(" Supply and Logistics", " S&L"):gsub("Azeroth Commerce Authority", "Commerce Auth.")
  if r.missing then
    bar:SetValue(0)
    bar.text:SetText(short .. ": not discovered")
    return
  end
  local span = math.max(1, r.max - r.min)
  bar:SetMinMaxValues(0, span)
  bar:SetValue(r.value - r.min)
  local run = WR.db and WR.db.run
  local gained
  if run and run.active then
    if run.repAtStart then
      gained = r.value - run.repAtStart
    else
      gained = run.repGained
    end
  end
  local txt = string.format("%s: %s %d/%d", short, r.standing or "?", r.value - r.min, span)
  if gained then
    txt = txt .. string.format("  (+%d run)", gained)
  end
  bar.text:SetText(txt)
end

function Tracker.Refresh()
  if not frame then
    return
  end
  Tracker.RefreshRep()
  Tracker.RefreshStats()
  RefreshSteps()
  Tracker.RefreshItem()
end

local function BuildFrame()
  if frame then
    return frame
  end

  frame = CreateFrame("Frame", "WritRunnerTrackerFrame", UIParent, "BackdropTemplate")
  frame:SetSize(FRAME_WIDTH, FRAME_HEIGHT)
  frame:SetFrameStrata("HIGH")
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", frame.StartMoving)
  frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    SavePosition()
  end)
  frame:SetClampedToScreen(true)
  if frame.SetBackdrop then
    frame:SetBackdrop({
      bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
      tile = true, tileSize = 16, edgeSize = 12,
      insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    frame:SetBackdropColor(0, 0, 0, 0.85)
    frame:SetBackdropBorderColor(0.6, 0.5, 0.2, 0.9)
  end
  -- Not in UISpecialFrames: Escape should not dismiss an active run tracker.

  local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  title:SetPoint("TOPLEFT", 10, -8)
  title:SetText("Writ run")
  frame.title = title

  local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", 2, 2)
  close:SetScale(0.8)
  close:SetScript("OnClick", function()
    Tracker.Hide()
  end)

  -- Secure item button for the NEXT writ only.
  local btn = CreateFrame("Button", "WritRunnerUseWritButton", frame, "SecureActionButtonTemplate")
  btn:SetSize(36, 36)
  btn:SetPoint("TOPLEFT", 10, -28)
  pcall(btn.RegisterForClicks, btn, "AnyUp", "AnyDown")
  btn.icon = btn:CreateTexture(nil, "ARTWORK")
  btn.icon:SetAllPoints()
  btn.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
  local border = btn:CreateTexture(nil, "OVERLAY")
  border:SetAllPoints()
  border:SetTexture("Interface\\Buttons\\UI-Quickslot2")
  border:SetPoint("TOPLEFT", -8, 8)
  border:SetPoint("BOTTOMRIGHT", 8, -8)
  btn.count = btn:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
  btn.count:SetPoint("BOTTOMRIGHT", 0, 0)
  btn:SetScript("OnEnter", function(self)
    local step = self.step
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    if step and step.writItemId and GameTooltip.SetItemByID then
      GameTooltip:SetItemByID(step.writItemId)
      GameTooltip:AddLine(" ")
    else
      GameTooltip:SetText(step and step.writItemName or "Next writ")
    end
    GameTooltip:AddLine("Click to open this writ and accept its quest when you reach the turn-in NPC. Opening it early fills a quest-log slot.", 0.8, 0.8, 0.8, true)
    if step then
      local n = WR.GetBagCount and WR.GetBagCount(step.writItemId) or 0
      if n <= 0 then
        GameTooltip:AddLine("Not in bags.", 1, 0.3, 0.3)
      end
    end
    if InCombatLockdown and InCombatLockdown() then
      GameTooltip:AddLine("In combat — the button updates when you leave combat.", 1, 0.6, 0.2)
    end
    GameTooltip:Show()
  end)
  btn:SetScript("OnLeave", function()
    GameTooltip:Hide()
  end)
  frame.itemBtn = btn

  local itemName = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  itemName:SetPoint("TOPLEFT", btn, "TOPRIGHT", 8, 0)
  itemName:SetPoint("RIGHT", frame, "RIGHT", -10, 0)
  itemName:SetJustifyH("LEFT")
  frame.itemName = itemName

  local itemHint = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  itemHint:SetPoint("TOPLEFT", btn, "TOPRIGHT", 8, -14)
  itemHint:SetPoint("RIGHT", frame, "RIGHT", -10, 0)
  itemHint:SetJustifyH("LEFT")
  itemHint:SetWordWrap(true)
  frame.itemHint = itemHint

  -- Hook RefreshItem to also set the name label.
  local oldRefreshItem = Tracker.RefreshItem
  function Tracker.RefreshItem()
    oldRefreshItem()
    if not frame then
      return
    end
    local step = WR.Run and WR.Run.CurrentStep and WR.Run.CurrentStep()
    if step then
      frame.itemName:SetText(ShortWrit(step.writItemName))
    else
      frame.itemName:SetText("")
    end
  end

  local list = CreateFrame("Frame", nil, frame)
  -- Writ faction reputation bar.
  local repBar = CreateFrame("StatusBar", nil, frame)
  repBar:SetPoint("TOPLEFT", 10, -74)
  repBar:SetPoint("TOPRIGHT", -10, -74)
  repBar:SetHeight(14)
  repBar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
  repBar:SetStatusBarColor(0, 0.6, 0.1)
  repBar:SetMinMaxValues(0, 1)
  repBar:SetValue(0)
  local repBg = repBar:CreateTexture(nil, "BACKGROUND")
  repBg:SetAllPoints()
  repBg:SetColorTexture(0, 0, 0, 0.5)
  repBar.text = repBar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  repBar.text:SetPoint("CENTER")
  repBar:EnableMouse(true)
  repBar:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    local r = WR.Rep and WR.Rep.Get and WR.Rep.Get()
    GameTooltip:SetText(r and r.name or "Writ reputation")
    if r and not r.missing then
      GameTooltip:AddLine(string.format("%s  %d / %d", r.standing or "?", r.value - r.min, r.max - r.min), 1, 1, 1)
    elseif r then
      GameTooltip:AddLine("Not discovered yet. Turn in a writ to unlock it.", 1, 0.6, 0.2, true)
    end
    local run = WR.db and WR.db.run
    if run and run.active then
      local ok, miss = 0, 0
      for _, st in ipairs(run.steps or {}) do
        if st.repStatus == "ok" then ok = ok + 1 elseif st.repStatus == "missing" or st.repStatus == "short" then miss = miss + 1 end
      end
      GameTooltip:AddLine(string.format("This run: %d turn-ins gave rep, %d gave none or too little.", ok, miss), 0.8, 0.8, 0.8, true)
    end
    local missed = WR.db and WR.db.repMissed
    if missed and #missed > 0 then
      GameTooltip:AddLine(" ")
      GameTooltip:AddLine("Recent turn-ins with no rep:", 1, 0.3, 0.3)
      for i = #missed, math.max(1, #missed - 4), -1 do
        local m = missed[i]
        GameTooltip:AddLine(string.format("%s  %s", date("%m/%d %H:%M", m.at), ShortWrit(m.writ)), 1, 0.6, 0.6)
      end
    end
    GameTooltip:Show()
  end)
  repBar:SetScript("OnLeave", function() GameTooltip:Hide() end)
  frame.repBar = repBar

  local stats = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  stats:SetPoint("TOPLEFT", 10, -92)
  stats:SetPoint("TOPRIGHT", -10, -92)
  stats:SetJustifyH("LEFT")
  stats:SetWordWrap(false)
  frame.stats = stats

  list:SetPoint("TOPLEFT", 8, -110)
  list:SetPoint("BOTTOMRIGHT", -26, 36)
  if list.SetClipsChildren then list:SetClipsChildren(true) end
  frame.list = list

  local measure = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  measure:SetJustifyH("LEFT")
  measure:SetWordWrap(true)
  measure:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -2000, 2000)
  measure:SetAlpha(0)
  frame.measure = measure

  local slider = CreateFrame("Slider", "WritRunnerTrackerScroll", frame, "UIPanelScrollBarTemplate")
  slider:SetPoint("TOPRIGHT", list, "TOPRIGHT", 16, -12)
  slider:SetPoint("BOTTOMRIGHT", list, "BOTTOMRIGHT", 16, 12)
  slider:SetMinMaxValues(0, 0)
  slider:SetValueStep(1)
  if slider.SetObeyStepOnDrag then
    slider:SetObeyStepOnDrag(true)
  end
  slider:SetScript("OnValueChanged", function(_, value)
    if frame.updatingSlider then return end
    local v = math.floor(value + 0.5)
    if v == listOffset then return end
    listOffset = v
    RefreshSteps()
  end)
  frame.slider = slider

  list:EnableMouseWheel(true)
  list:SetScript("OnMouseWheel", function(_, delta)
    local lo, hi = frame.slider:GetMinMaxValues()
    local v = math.max(lo, math.min(hi, listOffset - delta))
    frame.slider:SetValue(v)
  end)

  local rowH = 36
  local r
  for r = 1, VISIBLE do
    local row = CreateFrame("Button", nil, list)
    row:SetHeight(rowH)
    row:SetPoint("TOPLEFT", 0, 0)
    row:SetPoint("TOPRIGHT", -4, 0)
    row:Hide()
    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints()
    row.body = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.body:SetPoint("TOPLEFT", 6, -4)
    row.body:SetPoint("TOPRIGHT", -6, -4)
    row.body:SetJustifyH("LEFT")
    row.body:SetJustifyV("TOP")
    row.body:SetWordWrap(true)
    row:SetScript("OnClick", function(self)
      local line = self.line
      if not line or line.kind ~= "step" or not line.step or not WR.Route then
        return
      end
      if not line.step.coords then
        WR.Print("No published coordinates for this step.")
        return
      end
      local writ = {
        zone = line.step.zone,
        npc = line.step.npc,
        coords = line.step.coords,
        writItemName = line.step.writItemName,
      }
      local ok, msg = WR.Route.SetWaypointForWrit(writ)
      if msg then
        WR.Print(msg)
      end
    end)
    stepRows[r] = row
  end

  local skip = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  skip:SetSize(110, 20)
  skip:SetPoint("BOTTOMLEFT", 8, 8)
  skip:SetText("Skip / Mark done")
  skip:SetScript("OnClick", function()
    if WR.Run and WR.Run.SkipCurrent then
      WR.Run.SkipCurrent()
    end
  end)

  local endBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  endBtn:SetSize(80, 20)
  endBtn:SetPoint("BOTTOMRIGHT", -8, 8)
  endBtn:SetText("End run")
  endBtn:SetScript("OnClick", function()
    if WR.Run and WR.Run.End then
      WR.Run.End()
    end
  end)

  frame:Hide()
  Tracker.frame = frame
  return frame
end

function Tracker.Show()
  BuildFrame()
  ApplyPosition()
  if WR.db and WR.db.run then
    WR.db.run.trackerShown = true
  end
  Tracker.Refresh()
  frame:Show()
end

function Tracker.Hide()
  if WR.db and WR.db.run then
    WR.db.run.trackerShown = false
  end
  if frame then
    frame:Hide()
  end
end

function Tracker.Toggle()
  if not WR.Run or not WR.Run.IsActive() then
    WR.Print("No run is active. In /writs, set a budget and click Start run (or type /writs start).")
    return
  end
  BuildFrame()
  if frame:IsShown() then
    Tracker.Hide()
  else
    Tracker.Show()
  end
end

function Tracker.IsShown()
  return frame and frame:IsShown() and true or false
end
