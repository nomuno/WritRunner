-- Movable main frame, ranked list, filters, shopping list, and route.

local WR = WritRunner
WR.UI = WR.UI or {}
local UI = WR.UI

local ROW_HEIGHT = 18
local VISIBLE_ROWS = 14
local FRAME_WIDTH = 760
local FRAME_HEIGHT = 810

local frame
local rows = {}
local ranked = {}
local shown = {} -- what section 3 lists: the plan, or every writ when Show all is on
local picked = {}
local spent = 0
local plan = { shop = {}, route = {} }
local listOffset = 0
local selectedIndex = nil
local staged = {} -- [questId] = desired checked state (true = remove, false = restore)
local RefreshRows

local function GoldFromBox(edit)
  local text = edit:GetText()
  if not text or text == "" then
    return nil
  end
  return WR.GoldToCopper(text)
end

local function SaveFramePosition()
  if not WR.db or not frame then
    return
  end
  local point, _, relativePoint, x, y = frame:GetPoint(1)
  WR.db.frame = { point = point, relativePoint = relativePoint, x = x, y = y }
end

local function ApplySavedPosition()
  if not WR.db or not WR.db.frame or not frame then
    return
  end
  local f = WR.db.frame
  frame:ClearAllPoints()
  frame:SetPoint(f.point or "CENTER", UIParent, f.relativePoint or "CENTER", f.x or 0, f.y or 0)
end

local function Options()
  local db = WR.db or {}
  return {
    maxCopper = WR.GoldToCopper(db.maxGold),
    budgetCopper = WR.GoldToCopper(db.budgetGold),
    hideUnconfirmed = db.hideUnconfirmed ~= false,
    hideCompleted = db.hideCompleted ~= false,
  }
end

local function Truncate(text, maxLen)
  text = text or ""
  if #text <= maxLen then
    return text
  end
  return string.sub(text, 1, maxLen - 1) .. "…"
end

local function ConfLabel(conf)
  if conf == "cc" then
    return "|cff66cc66cc|r"
  end
  if conf == "cc-partial" then
    return "|cffcccc66cc-partial|r"
  end
  if conf == "wowhead-comment" or conf == "wowhead-guide" then
    return "|cffccaa66" .. (conf or "") .. "|r"
  end
  return "|cffcc6666unmapped|r"
end

local function ShopTerms()
  local terms = {}
  for i = 1, #(plan.shop or {}) do
    if plan.shop[i].name then
      terms[#terms + 1] = plan.shop[i].name
    end
  end
  return terms, table.concat(terms, "\31")
end

-- Keep Auctionator's "WritRunner" list matching the plan. Only runs after the
-- player has created the list once with the button, and only when it changed.
local function SyncShoppingList()
  if not WR.db or not WR.db.shopListSig then
    return
  end
  local terms, sig = ShopTerms()
  if sig == WR.db.shopListSig or #terms == 0 then
    return
  end
  local ok = WR.TryAuctionatorShopping(terms, "WritRunner")
  if ok then
    WR.db.shopListSig = sig
    WR.Print(string.format("Plan changed, so the Auctionator \"WritRunner\" shopping list was updated (%d items).", #terms))
  end
end

local function ShortWritName(name)
  name = name or "Writ"
  return (name:gsub("^Craftsman's Writ: ", ""))
end

local function WritByQuestId(questId)
  if not questId then
    return nil
  end
  local lists = { shown, picked, ranked }
  local i, j
  for i = 1, #lists do
    local list = lists[i] or {}
    for j = 1, #list do
      local w = list[j] and list[j].writ
      if w and w.questId == questId then
        return w
      end
    end
  end
  if WR.Daily and WR.Daily.WritByQuestId then
    return WR.Daily.WritByQuestId(questId)
  end
  return nil
end

local function CompletedCounts()
  if WR.Daily and WR.Daily.CountBySource then
    return WR.Daily.CountBySource()
  end
  return 0, 0
end

local function CollectStaged()
  local remove, restore = {}, {}
  local qid, want
  for qid, want in pairs(staged) do
    local w = WritByQuestId(qid)
    local name = ShortWritName(w and w.writItemName)
    local rec = { questId = qid, writ = w, name = name }
    if want then
      remove[#remove + 1] = rec
    elseif not (WR.Daily and WR.Daily.IsTurnedIn and WR.Daily.IsTurnedIn(w or qid)) then
      restore[#restore + 1] = rec
    end
  end
  local function byName(a, b)
    return (a.name or "") < (b.name or "")
  end
  table.sort(remove, byName)
  table.sort(restore, byName)
  return remove, restore
end

local function StageCount()
  local n = 0
  local _k
  for _k in pairs(staged) do
    n = n + 1
  end
  return n
end

function UI.ClearStaging()
  staged = {}
end

function UI.NoteCompletedChange(questId)
  if questId then
    staged[questId] = nil
  end
end

local function UpdatePlanButtons()
  if not frame then
    return
  end
  local nStage = StageCount()
  local nTurned, nRemoved = CompletedCounts()
  if frame.confirmBtn then
    if nStage == 0 then
      frame.confirmBtn:Disable()
    else
      frame.confirmBtn:Enable()
    end
  end
  if frame.resetBtn then
    if nStage == 0 and nRemoved == 0 then
      frame.resetBtn:Disable()
    else
      frame.resetBtn:Enable()
    end
  end
  if frame.stageHint then
    if nStage > 0 then
      local remove, restore = CollectStaged()
      local bits = {}
      if #remove > 0 then
        bits[#bits + 1] = string.format("%d to remove", #remove)
      end
      if #restore > 0 then
        bits[#bits + 1] = string.format("%d to restore", #restore)
      end
      frame.stageHint:SetText("Staged: " .. table.concat(bits, ", ") .. "  (Confirm to apply)")
    elseif nTurned > 0 or nRemoved > 0 then
      local bits = {}
      if nTurned > 0 then
        bits[#bits + 1] = string.format("%d turned in", nTurned)
      end
      if nRemoved > 0 then
        bits[#bits + 1] = string.format("%d removed", nRemoved)
      end
      local s = table.concat(bits, ", ")
      if nRemoved > 0 then
        s = s .. ". Reset restores the ones you removed."
      end
      frame.stageHint:SetText(s)
    else
      frame.stageHint:SetText("")
    end
  end
end

-- Reuses the bag-check dialog look: movable, DIALOG strata, ESC via UISpecialFrames.
local promptDlg
local PROMPT_WIDTH = 480
local PROMPT_LINE_H = 16
local PROMPT_MAX = 12

local function HidePrompt()
  if promptDlg then
    promptDlg:Hide()
  end
end

local function EnsurePrompt()
  if promptDlg then
    return promptDlg
  end
  local dlg = CreateFrame("Frame", "WritRunnerPromptDialog", UIParent, "BackdropTemplate")
  dlg:SetSize(PROMPT_WIDTH, 220)
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
    tinsert(UISpecialFrames, "WritRunnerPromptDialog")
  end

  local title = dlg:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOP", 0, -14)
  title:SetText("WritRunner")
  dlg.title = title

  local function CancelPrompt()
    local fn = dlg.onCancel
    dlg.onAccept, dlg.onCancel = nil, nil
    HidePrompt()
    if fn then
      fn()
    end
  end
  dlg.CancelPrompt = CancelPrompt

  local close = CreateFrame("Button", nil, dlg, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -2, -2)
  close:SetScript("OnClick", CancelPrompt)

  local header = dlg:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  header:SetPoint("TOPLEFT", 20, -42)
  header:SetWidth(PROMPT_WIDTH - 40)
  header:SetJustifyH("LEFT")
  header:SetJustifyV("TOP")
  dlg.header = header

  local scroll = CreateFrame("ScrollFrame", "WritRunnerPromptScroll", dlg, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 20, -68)
  scroll:SetSize(PROMPT_WIDTH - 54, PROMPT_MAX * PROMPT_LINE_H)
  dlg.scroll = scroll
  local child = CreateFrame("Frame", nil, scroll)
  child:SetSize(PROMPT_WIDTH - 74, PROMPT_MAX * PROMPT_LINE_H)
  scroll:SetScrollChild(child)
  dlg.child = child
  local listText = child:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  listText:SetPoint("TOPLEFT", 0, 0)
  listText:SetWidth(PROMPT_WIDTH - 74)
  listText:SetJustifyH("LEFT")
  listText:SetJustifyV("TOP")
  dlg.listText = listText
  scroll:EnableMouseWheel(true)
  scroll:SetScript("OnMouseWheel", function(_, delta)
    local sb = _G["WritRunnerPromptScrollScrollBar"]
    if sb then
      sb:SetValue((sb:GetValue() or 0) - delta * PROMPT_LINE_H * 3)
    end
  end)

  local footer = dlg:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  footer:SetPoint("BOTTOMLEFT", 20, 44)
  footer:SetPoint("BOTTOMRIGHT", -20, 44)
  footer:SetJustifyH("LEFT")
  dlg.footer = footer

  local function MakeBtn()
    local btn = CreateFrame("Button", nil, dlg, "UIPanelButtonTemplate")
    btn:SetSize(120, 22)
    return btn
  end
  dlg.btn1 = MakeBtn()
  dlg.btn2 = MakeBtn()
  dlg.btn1:SetScript("OnClick", function()
    local fn = dlg.onAccept
    dlg.onAccept, dlg.onCancel = nil, nil
    HidePrompt()
    if fn then
      fn()
    end
  end)
  dlg.btn2:SetScript("OnClick", CancelPrompt)
  dlg:SetScript("OnHide", function()
    if dlg.onCancel then
      local fn = dlg.onCancel
      dlg.onAccept, dlg.onCancel = nil, nil
      fn()
    else
      dlg.onAccept, dlg.onCancel = nil, nil
    end
  end)

  promptDlg = dlg
  return dlg
end

function UI.ShowConfirm(opts)
  opts = opts or {}
  local dlg = EnsurePrompt()
  if dlg:IsShown() then
    dlg.onAccept, dlg.onCancel = nil, nil
    dlg:Hide()
  end
  dlg.onAccept = opts.OnAccept
  dlg.onCancel = opts.OnCancel
  dlg.title:SetText(opts.title or "WritRunner")
  dlg.header:SetText(opts.message or "")
  local lines = opts.lines or {}
  if #lines > 0 then
    dlg.header:SetPoint("TOPLEFT", 20, -42)
    dlg.listText:SetText(table.concat(lines, "\n"))
    local n = #lines
    local visible = n
    if visible < 1 then
      visible = 1
    elseif visible > PROMPT_MAX then
      visible = PROMPT_MAX
    end
    local scrollH = visible * PROMPT_LINE_H + 6
    dlg.scroll:Show()
    dlg.scroll:SetHeight(scrollH)
    local contentH = dlg.listText:GetStringHeight() or (n * PROMPT_LINE_H)
    if contentH < scrollH then
      contentH = scrollH
    end
    dlg.child:SetHeight(contentH + 4)
    dlg.scroll:SetVerticalScroll(0)
    if opts.footer and opts.footer ~= "" then
      dlg.footer:SetText(opts.footer)
      dlg.footer:Show()
      dlg:SetSize(PROMPT_WIDTH, 68 + scrollH + 70)
    else
      dlg.footer:SetText("")
      dlg.footer:Hide()
      dlg:SetSize(PROMPT_WIDTH, 68 + scrollH + 50)
    end
  else
    dlg.header:SetPoint("TOPLEFT", 20, -48)
    dlg.scroll:Hide()
    local bodyH = dlg.header:GetStringHeight() or 20
    if bodyH < 20 then
      bodyH = 20
    end
    if opts.footer and opts.footer ~= "" then
      dlg.footer:SetText(opts.footer)
      dlg.footer:Show()
      dlg:SetSize(PROMPT_WIDTH, 48 + bodyH + 80)
    else
      dlg.footer:SetText("")
      dlg.footer:Hide()
      dlg:SetSize(PROMPT_WIDTH, 48 + bodyH + 60)
    end
  end
  dlg.btn1:ClearAllPoints()
  dlg.btn2:ClearAllPoints()
  dlg.btn1:SetText(opts.accept or "Confirm")
  if opts.cancel then
    dlg.btn1:SetPoint("BOTTOM", dlg, "BOTTOM", -70, 14)
    dlg.btn2:SetText(opts.cancel)
    dlg.btn2:SetPoint("BOTTOM", dlg, "BOTTOM", 70, 14)
    dlg.btn2:Show()
  else
    dlg.btn1:SetPoint("BOTTOM", dlg, "BOTTOM", 0, 14)
    dlg.btn2:Hide()
  end
  dlg.btn1:Show()
  dlg:Show()
  if dlg.Raise then
    dlg:Raise()
  end
end

local function ApplyStaged()
  local remove, restore = CollectStaged()
  staged = {}
  local i
  for i = 1, #remove do
    local w = remove[i].writ or WritByQuestId(remove[i].questId)
    if w and WR.Daily and WR.Daily.SetCompleted then
      WR.Daily.SetCompleted(w, true, true, "manual")
    end
  end
  for i = 1, #restore do
    local w = restore[i].writ or WritByQuestId(restore[i].questId)
    if w and WR.Daily and WR.Daily.SetCompleted then
      WR.Daily.SetCompleted(w, false, true, "manual")
    end
  end
  UI.Refresh()
end

local function OnConfirmClicked()
  local remove, restore = CollectStaged()
  if #remove == 0 and #restore == 0 then
    UI.ShowConfirm({
      title = "WritRunner",
      message = "Nothing is staged. Tick writs in #3, then click Confirm to remove them from the plan.",
      accept = "OK",
    })
    return
  end
  local lines = {}
  local i
  for i = 1, #remove do
    lines[#lines + 1] = "  " .. (remove[i].name or "Writ")
  end
  if #restore > 0 then
    if #lines > 0 then
      lines[#lines + 1] = ""
    end
    lines[#lines + 1] = string.format("%d writ%s will be restored:", #restore, #restore == 1 and "" or "s")
    for i = 1, #restore do
      lines[#lines + 1] = "  " .. (restore[i].name or "Writ")
    end
  end
  local message
  if #remove > 0 then
    message = string.format("%d writ%s checked will be removed from the list.", #remove, #remove == 1 and "" or "s")
  else
    message = string.format("%d writ%s will be restored to the list.", #restore, #restore == 1 and "" or "s")
    lines = {}
    for i = 1, #restore do
      lines[#lines + 1] = "  " .. (restore[i].name or "Writ")
    end
  end
  UI.ShowConfirm({
    title = "Confirm plan",
    message = message,
    lines = lines,
    footer = "#4 and #5 will update to the remaining plan.",
    accept = "Confirm",
    cancel = "Cancel",
    OnAccept = ApplyStaged,
  })
end

local function OnResetClicked()
  local nStage = StageCount()
  local nTurned, nRemoved = CompletedCounts()
  if nStage == 0 and nRemoved == 0 then
    UI.ShowConfirm({
      title = "WritRunner",
      message = nTurned > 0
        and "Nothing to reset. Turned-in writs stay completed. To clear those too, type /writs reset in chat."
        or "There are no staged selections or removed writs to reset.",
      accept = "OK",
    })
    return
  end
  if nRemoved == 0 then
    UI.ShowConfirm({
      title = "Reset selections",
      message = string.format("Clear %d staged selection%s? The confirmed plan will not change. Turned-in writs stay completed (use /writs reset to clear those too).", nStage, nStage == 1 and "" or "s"),
      accept = "Confirm",
      cancel = "Cancel",
      OnAccept = function()
        staged = {}
        RefreshRows()
        UpdatePlanButtons()
      end,
    })
    return
  end
  UI.ShowConfirm({
    title = "Reset selections",
    message = string.format("Restore %d writ%s you removed?", nRemoved, nRemoved == 1 and "" or "s"),
    footer = "Turned-in writs stay completed. Staged checkboxes will also be cleared. To clear turn-ins too, type /writs reset in chat.",
    accept = "Confirm",
    cancel = "Cancel",
    OnAccept = function()
      staged = {}
      if WR.Daily and WR.Daily.ClearManual then
        WR.Daily.ClearManual()
      end
      UI.Refresh()
    end,
  })
end

local function Rebuild()
  if not WR.db then
    return
  end
  if WR.Daily then
    WR.Daily.EnsureReset()
  end
  ranked = WR.RankWrits(Options())
  local budget = WR.GoldToCopper(WR.db.budgetGold)
  picked, spent = WR.PickWithinBudget(ranked, budget)
  if WR.Route then
    plan = WR.Route.Build(picked)
  else
    plan = { shop = {}, route = {} }
  end
  SyncShoppingList()
  if WR.db.showAllWrits then
    shown = ranked
  else
    shown = picked
  end
  if selectedIndex and selectedIndex > #shown then
    selectedIndex = nil
  end
end

function RefreshRows()
  if not frame then
    return
  end
  local maxOffset = math.max(0, #shown - VISIBLE_ROWS)
  if listOffset > maxOffset then
    listOffset = maxOffset
  end
  if listOffset < 0 then
    listOffset = 0
  end
  frame.slider:SetMinMaxValues(0, maxOffset)
  frame.slider:SetValue(listOffset)

  local i
  for i = 1, VISIBLE_ROWS do
    local row = rows[i]
    local idx = listOffset + i
    local data = shown[idx]
    if not data then
      row:Hide()
    else
      row:Show()
      row.index = idx
      local w = data.writ
      local p = data.price
      local done = WR.Daily and WR.Daily.IsCompleted(w)
      local turnedIn = WR.Daily and WR.Daily.IsTurnedIn and WR.Daily.IsTurnedIn(w)
      if turnedIn and w.questId then
        staged[w.questId] = nil
      end
      local pendingRemove, pendingRestore
      local checked = done and true or false
      if (not turnedIn) and w.questId and staged[w.questId] ~= nil then
        checked = staged[w.questId] and true or false
        if checked and not done then
          pendingRemove = true
        elseif (not checked) and done then
          pendingRestore = true
        end
      end
      row.check:SetChecked(checked)
      if turnedIn then
        row.check:Disable()
      else
        row.check:Enable()
      end
      local nameColor = "|cffffffff"
      if pendingRemove then
        nameColor = "|cffffb080"
      elseif pendingRestore then
        nameColor = "|cff80ffb0"
      elseif turnedIn then
        nameColor = "|cff7f9aa8"
      elseif done then
        nameColor = "|cff888888"
      end
      local writName = w.writItemName or ""
      writName = writName:gsub("^Craftsman's Writ: ", "")
      row.name:SetText(nameColor .. Truncate(writName, 34) .. "|r")
      local tierShort = (w.tier == "Journeyman") and "Journey" or (w.tier or "")
      row.tier:SetText(tierShort .. "  |cff40c0ff" .. (w.rep or 0) .. "|r")
      row.zone:SetText(Truncate(w.zone or "—", 20))
      if p.known then
        row.cost:SetText(WR.MoneyText(p.totalCopper))
        row.rpg:SetText(string.format("%.1f", p.repPerGold))
      else
        row.cost:SetText("|cffcc6666unknown|r")
        row.rpg:SetText("—")
      end
      if p.netCopper then
        if p.netCopper < 0 then
          row.net:SetText("|cff40ff40+" .. WR.MoneyText(-p.netCopper) .. "|r")
        else
          row.net:SetText(WR.MoneyText(p.netCopper))
        end
      elseif p.known then
        row.net:SetText("|cff888888?|r")
      else
        row.net:SetText("—")
      end
      row.conf:SetText(ConfLabel(w.confirmation))
      if pendingRemove then
        row.bg:SetColorTexture(0.75, 0.28, 0.08, idx == selectedIndex and 0.50 or 0.38)
      elseif pendingRestore then
        row.bg:SetColorTexture(0.12, 0.50, 0.22, idx == selectedIndex and 0.45 or 0.32)
      elseif turnedIn then
        row.bg:SetColorTexture(0.15, 0.28, 0.40, idx == selectedIndex and 0.45 or 0.32)
      elseif idx == selectedIndex then
        row.bg:SetColorTexture(1, 0.82, 0, 0.25)
      else
        row.bg:SetColorTexture(0, 0, 0, idx % 2 == 0 and 0.25 or 0.10)
      end
    end
  end

  local faction, repName = WR.PlayerFaction()
  local ah = WR.HasAuctionator() and "|cff66cc66Auctionator loaded|r" or "|cffcc6666Auctionator missing — prices unknown|r"
  local pickedCount = #picked
  local status = string.format(
    "%s  ·  %s  ·  %d listed  ·  %d in plan  ·  spend %s",
    faction or "?",
    repName or "Craftsman's Writs",
    #ranked,
    pickedCount,
    WR.MoneyText(spent)
  )
  local resetTxt = ""
  local okR, secs = pcall(function()
    if C_DateAndTime and C_DateAndTime.GetSecondsUntilDailyReset then
      return C_DateAndTime.GetSecondsUntilDailyReset()
    end
    return GetQuestResetTime and GetQuestResetTime()
  end)
  if okR and type(secs) == "number" and secs > 0 then
    resetTxt = string.format("  ·  reset in %dh %02dm", math.floor(secs / 3600), math.floor((secs % 3600) / 60))
  end
  frame.status:SetText(status .. "  ·  " .. ah .. resetTxt)

  if frame.qualify then
    local q
    if #picked == 0 then
      q = "|cffff6060No writs qualify based on your limits in #2.|r Raise Max per writ or Budget gold, or refresh prices."
    else
      local estRep = 0
      for k = 1, #picked do
        estRep = estRep + ((picked[k].writ and picked[k].writ.rep) or 0)
      end
      q = string.format("The following writs qualify based on #2: |cff40ff40%d writ%s found|r, %s total, |cff40c0ffest. +%d rep|r.",
        #picked, #picked == 1 and "" or "s", WR.MoneyText(spent), estRep)
      local okRep, info = pcall(function() return WR.Rep and WR.Rep.Get and WR.Rep.Get() end)
      if okRep and type(info) == "table" and not info.missing and info.value and info.max and info.max > (info.min or 0) then
        local cur = info.value - (info.min or 0)
        local span = info.max - (info.min or 0)
        local after = cur + estRep
        if after >= span then
          q = q .. string.format("  |cff40ff40Reaches next standing (+%d over).|r", after - span)
        else
          q = q .. string.format("  %s %d/%d after.", info.standing or "", after, span)
        end
      end
    end
    if WR.db and WR.db.showAllWrits then
      q = string.format("Showing all %d writs. ", #ranked) .. string.format("%d qualify based on your limits in #2.", #picked)
    end
    frame.qualify:SetText(q)
  end

  -- Sealed envelope strip
  if WR.db.showSealed and WritRunnerData and WritRunnerData.sealed then
    local bits = {}
    local s
    for s = 1, #WritRunnerData.sealed do
      local info = WritRunnerData.sealed[s]
      local exp = WR.SealedExpectation(info)
      if exp.known then
        bits[#bits + 1] = string.format(
          "%s expected %s (%.1f rep/g, n=%d)",
          info.tier,
          WR.MoneyText(exp.expectedCopper),
          exp.repPerGold,
          exp.fillSamples
        )
      else
        bits[#bits + 1] = info.tier .. " expected unknown"
      end
    end
    frame.sealed:SetText("|cffd4a017Sealed envelopes:|r " .. table.concat(bits, "  ·  "))
    frame.sealed:Show()
  else
    frame.sealed:SetText("")
  end

  -- Shopping list
  local shopLines = {}
  local t
  for t = 1, #plan.shop do
    local item = plan.shop[t]
    local price = item.copperEach and (WR.MoneyText(item.copperEach * item.count)) or "unknown"
    shopLines[#shopLines + 1] = string.format("%dx %s  (%s)", item.count, item.name or ("item " .. item.itemId), price)
  end
  if #shopLines == 0 then
    shopLines[1] = "No priced writs in the current plan. Set a budget or wait for Auctionator prices."
  end
  frame.shopText:SetText(table.concat(shopLines, "\n"))

  -- Route (flat tour order, with simple travel hints)
  local routeLines = {}
  local r
  if plan.steps and #plan.steps > 0 then
    for r = 1, #plan.steps do
      local step = plan.steps[r]
      local w = step.writ
      if step.travel then
        routeLines[#routeLines + 1] = "    " .. step.travel
      end
      local coord = "no coords"
      if w.coords then
        coord = string.format("%.1f, %.1f", w.coords.x, w.coords.y)
      end
      local npc = w.npc or "unknown NPC"
      local mark = (WR.Daily and WR.Daily.IsCompleted(w)) and " [done]" or ""
      local writName = (w.writItemName or ""):gsub("^Craftsman's Writ: ", "")
      routeLines[#routeLines + 1] = string.format("%d. %s — %s (%s)  %s%s", r, w.zone or "?", npc, coord, writName, mark)
    end
  else
    for r = 1, #plan.route do
      local stop = plan.route[r]
      routeLines[#routeLines + 1] = string.format("%d. %s (%s)", r, stop.zone, stop.continent or "?")
      local k
      for k = 1, #stop.stops do
        local row = stop.stops[k]
        local w = row.writ
        local coord = "no coords"
        if w.coords then
          coord = string.format("%.1f, %.1f", w.coords.x, w.coords.y)
        end
        local npc = w.npc or "unknown NPC"
        local mark = (WR.Daily and WR.Daily.IsCompleted(w)) and " [done]" or ""
        local writName = (w.writItemName or ""):gsub("^Craftsman's Writ: ", "")
        routeLines[#routeLines + 1] = string.format("    %s — %s (%s)%s", npc, writName, coord, mark)
      end
    end
  end
  if #routeLines == 0 then
    routeLines[1] = "No turn-ins in the current plan."
  end
  frame.routeText:SetText(table.concat(routeLines, "\n"))

  -- Resize scroll children so the nested scroll frames can move.
  frame.shopChild:SetHeight(math.max(120, #shopLines * 14 + 8))
  frame.routeChild:SetHeight(math.max(160, #routeLines * 14 + 8))
  UpdatePlanButtons()
end

function UI.RefreshRep()
  if not frame or not frame.repBar then
    return
  end
  local bar = frame.repBar
  local r = WR.Rep and WR.Rep.Get and WR.Rep.Get()
  if not r then
    bar:SetValue(0)
    bar.text:SetText("No writ faction")
  elseif r.missing then
    bar:SetValue(0)
    bar.text:SetText(r.name .. ": not discovered")
  else
    local span = math.max(1, r.max - r.min)
    bar:SetMinMaxValues(0, span)
    bar:SetValue(r.value - r.min)
    local short = r.name:gsub(" Supply and Logistics", " S&L"):gsub("Azeroth Commerce Authority", "Commerce Auth.")
    bar.text:SetText(string.format("%s: %s %d/%d", short, r.standing or "?", r.value - r.min, span))
  end
end

function UI.Refresh()
  UI.RefreshRep()
  Rebuild()
  RefreshRows()
  UI.UpdateRunButtons()
end

local function OnFilterChanged()
  if not WR.db or not frame then
    return
  end
  WR.db.maxGold = frame.maxBox:GetText()
  if WR.db.maxGold == "" then
    WR.db.maxGold = nil
  end
  WR.db.budgetGold = frame.budgetBox:GetText()
  if WR.db.budgetGold == "" then
    WR.db.budgetGold = nil
  end
  WR.db.hideUnconfirmed = frame.hideUnconf:GetChecked() and true or false
  WR.db.hideCompleted = frame.hideDone:GetChecked() and true or false
  WR.db.showSealed = frame.showSealed:GetChecked() and true or false
  WR.db.showAllWrits = frame.showAll:GetChecked() and true or false
  UI.Refresh()
end

local function CreateCheck(parent, label, x, y, checked)
  local box = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
  box:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
  box:SetSize(24, 24)
  box:SetChecked(checked)
  local text = box:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  text:SetPoint("LEFT", box, "RIGHT", 0, 0)
  text:SetText(label)
  box:SetScript("OnClick", OnFilterChanged)
  return box
end

local function CreateGoldBox(parent, label, x, y, initial)
  local caption = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  caption:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y - 4)
  caption:SetText(label)
  local edit = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
  edit:SetAutoFocus(false)
  edit:SetSize(60, 20)
  edit:SetPoint("LEFT", caption, "RIGHT", 8, 0)
  edit:SetNumeric(false)
  edit:SetMaxLetters(10)
  edit:SetText(initial or "")
  edit:SetScript("OnEnterPressed", function(self)
    self:ClearFocus()
    OnFilterChanged()
  end)
  edit:SetScript("OnEditFocusLost", OnFilterChanged)
  edit:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:SetText(label)
    if label == "Max per writ" then
      GameTooltip:AddLine("Hide any single writ whose total cost (writ + required item) is above this many gold. Leave blank for no limit.", 1, 1, 1, true)
    else
      GameTooltip:AddLine("Most gold to spend on the whole run. The plan picks the best rep-per-gold writs until this is used up. Leave blank to include every priced writ.", 1, 1, 1, true)
    end
    GameTooltip:Show()
  end)
  edit:SetScript("OnLeave", function() GameTooltip:Hide() end)
  return edit
end

local function Section(parent, text, hint, x, y, width)
  local h = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  h:SetPoint("TOPLEFT", x, y)
  h:SetText(text)
  local sub = parent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  sub:SetPoint("TOPLEFT", x + 14, y - 15)
  sub:SetWidth(width or 700)
  sub:SetJustifyH("LEFT")
  sub:SetText(hint)
  return h, sub
end

local function BuildFrame()
  if frame then
    return frame
  end

  frame = CreateFrame("Frame", "WritRunnerFrame", UIParent, "BackdropTemplate")
  frame:SetSize(FRAME_WIDTH, FRAME_HEIGHT)
  frame:SetPoint("CENTER")
  frame:SetFrameStrata("HIGH")
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", frame.StartMoving)
  frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    SaveFramePosition()
  end)
  frame:SetClampedToScreen(true)
  if frame.SetBackdrop then
    frame:SetBackdrop({
      bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
      edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
      tile = true, tileSize = 32, edgeSize = 16,
      insets = { left = 6, right = 6, top = 6, bottom = 6 },
    })
    frame:SetBackdropColor(0, 0, 0, 0.9)
  end
  tinsert(UISpecialFrames, "WritRunnerFrame")

  local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOP", 0, -14)
  title:SetText("WritRunner")

  -- Writ faction rep, top-left beside the title.
  local repBar = CreateFrame("StatusBar", nil, frame)
  repBar:SetPoint("TOPLEFT", 18, -14)
  repBar:SetSize(240, 14)
  repBar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
  repBar:SetStatusBarColor(0, 0.6, 0.1)
  repBar:SetMinMaxValues(0, 1)
  repBar:SetValue(0)
  local repBg = repBar:CreateTexture(nil, "BACKGROUND")
  repBg:SetAllPoints()
  repBg:SetColorTexture(0, 0, 0, 0.5)
  repBar.text = repBar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  repBar.text:SetPoint("CENTER")
  frame.repBar = repBar

  local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -4, -4)
  close:SetScript("OnClick", function()
    frame:Hide()
  end)

  local function MakeButton(text, x, y, onClick, width)
    local btn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    btn:SetSize(width or 160, 22)
    btn:SetPoint("TOPLEFT", x, y)
    btn:SetText(text)
    btn:SetScript("OnClick", onClick)
    return btn
  end

  local db = WR.db or {}

  -- 1. Prices
  Section(frame, "1. Update prices",
    "Go to the Auction House and run an Auctionator full scan (or search the writs), then click Refresh prices.", 18, -52)
  MakeButton("Refresh prices", 32, -84, function()
    UI.Refresh()
  end, 130)
  frame.status = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  frame.status:SetPoint("TOP", 0, -34)
  frame.status:SetWidth(FRAME_WIDTH - 40)
  frame.status:SetJustifyH("CENTER")

  -- 2. Limits
  Section(frame, "2. Set your limits",
    "Budget gold is the most to spend on the whole run. Max per writ hides any single writ that costs more. Blank means no limit.", 18, -116)
  frame.maxBox = CreateGoldBox(frame, "Max per writ", 32, -148, db.maxGold)
  frame.budgetBox = CreateGoldBox(frame, "Budget gold", 200, -148, db.budgetGold)
  frame.hideUnconf = CreateCheck(frame, "Hide unconfirmed", 340, -146, db.hideUnconfirmed ~= false)
  frame.hideDone = CreateCheck(frame, "Hide done today", 480, -146, db.hideCompleted ~= false)
  frame.showSealed = CreateCheck(frame, "Sealed envelopes", 610, -146, db.showSealed ~= false)

  frame.sealed = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  frame.applyBtn = MakeButton("Apply limits", 32, -170, function()
    if frame.maxBox then frame.maxBox:ClearFocus() end
    if frame.budgetBox then frame.budgetBox:ClearFocus() end
    OnFilterChanged()
    WR.Print(string.format("Limits applied: %d writs qualify.", #picked))
  end, 120)
  frame.applyBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText("Apply limits")
    GameTooltip:AddLine("Saves Max per writ and Budget gold and updates the lists in 3, 4 and 5. Same as pressing Enter in either box.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  frame.applyBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
  frame.sealed:SetPoint("TOPLEFT", 166, -175)
  frame.sealed:SetPoint("TOPRIGHT", -18, -175)
  frame.sealed:SetJustifyH("LEFT")

  -- 3. Plan
  Section(frame, "3. Check the plan",
    "Tick writs to remove, then Confirm — #4 and #5 update after you confirm. Reset restores ones you removed, not turn-ins.", 18, -206, 580)
  frame.showAll = CreateCheck(frame, "Show all writs", 620, -204, WR.db and WR.db.showAllWrits)
  frame.showAll:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("Show all writs")
    GameTooltip:AddLine("Off: list only the writs in your plan (the cheapest ones that fit Max per writ and Budget).\nOn: list every writ that passes the filters, including ones over budget.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  frame.showAll:SetScript("OnLeave", function() GameTooltip:Hide() end)

  frame.qualify = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  frame.qualify:SetPoint("TOPLEFT", 32, -238)
  frame.qualify:SetWidth(FRAME_WIDTH - 60)
  frame.qualify:SetJustifyH("LEFT")

  -- Column headers
  -- One header per column, at the same x offsets as the row cells below
  -- (list is at x=14, cells are offset inside each row).
  local headerCols = {
    { "Writ", 22, 200 }, { "Tier / Rep", 226, 80, "Writ tier and the rep its turn-in gives (Journeyman 75, Expert 125, Artisan 200)." }, { "Zone", 308, 130 },
    { "Cost", 440, 80 }, { "Net", 522, 82, "Net cost after the turn-in pays you back:\nwrit + item - gold reward.\n\nThe reward is learned the first time you view or turn in that writ's quest; until then Net shows ?. Green means the turn-in pays more than it cost." },
    { "Rep/g", 606, 46 }, { "Src", 654, 50, "Where the turn-in NPC and location came from.\ncc = confirmed by the ConquestCapped writ guide.\ncc-partial = guide lists it but details are incomplete.\nunmapped = no confirmed turn-in yet." },
  }
  for _, col in ipairs(headerCols) do
    local hb = CreateFrame("Frame", nil, frame)
    hb:SetPoint("TOPLEFT", 14 + col[2], -256)
    hb:SetSize(col[3], 14)
    local h = hb:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    h:SetAllPoints()
    h:SetJustifyH("LEFT")
    h:SetText(col[1])
    if col[4] then
      hb:EnableMouse(true)
      hb:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(col[1])
        GameTooltip:AddLine(col[4], 1, 1, 1, true)
        GameTooltip:Show()
      end)
      hb:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
  end

  local list = CreateFrame("Frame", nil, frame)
  list:SetPoint("TOPLEFT", 14, -270)
  list:SetSize(FRAME_WIDTH - 44, VISIBLE_ROWS * ROW_HEIGHT)
  frame.list = list

  local slider = CreateFrame("Slider", "WritRunnerScrollSlider", frame, "UIPanelScrollBarTemplate")
  slider:SetPoint("TOPRIGHT", list, "TOPRIGHT", 22, -16)
  slider:SetPoint("BOTTOMRIGHT", list, "BOTTOMRIGHT", 22, 16)
  slider:SetMinMaxValues(0, 0)
  slider:SetValueStep(1)
  if slider.SetObeyStepOnDrag then
    slider:SetObeyStepOnDrag(true)
  end
  slider:SetScript("OnValueChanged", function(_, value)
    listOffset = math.floor(value + 0.5)
    RefreshRows()
  end)
  frame.slider = slider

  list:EnableMouseWheel(true)
  list:SetScript("OnMouseWheel", function(_, delta)
    frame.slider:SetValue(listOffset - delta)
  end)

  local r
  for r = 1, VISIBLE_ROWS do
    local row = CreateFrame("Button", nil, list)
    row:SetSize(FRAME_WIDTH - 50, ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 0, -((r - 1) * ROW_HEIGHT))
    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints()
    row.check = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
    row.check:SetSize(18, 18)
    row.check:SetPoint("LEFT", 0, 0)
    row.check:SetScript("OnClick", function(self)
      local data = shown[row.index]
      local w = data and data.writ
      if not w or not w.questId then
        self:SetChecked(false)
        return
      end
      if WR.Daily and WR.Daily.IsTurnedIn and WR.Daily.IsTurnedIn(w) then
        self:SetChecked(true)
        return
      end
      local done = WR.Daily and WR.Daily.IsCompleted(w)
      local checked = self:GetChecked() and true or false
      if checked == (done and true or false) then
        staged[w.questId] = nil
      else
        staged[w.questId] = checked
      end
      RefreshRows()
    end)
    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.name:SetPoint("LEFT", 22, 0)
    row.name:SetWidth(200)
    row.name:SetJustifyH("LEFT")
    row.tier = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.tier:SetPoint("LEFT", 226, 0)
    row.tier:SetWidth(80)
    row.tier:SetJustifyH("LEFT")
    row.zone = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.zone:SetPoint("LEFT", 308, 0)
    row.zone:SetWidth(130)
    row.zone:SetJustifyH("LEFT")
    row.cost = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.cost:SetPoint("LEFT", 440, 0)
    row.cost:SetWidth(80)
    row.cost:SetJustifyH("LEFT")
    row.net = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.net:SetPoint("LEFT", 522, 0)
    row.net:SetWidth(82)
    row.net:SetJustifyH("LEFT")
    row.rpg = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.rpg:SetPoint("LEFT", 606, 0)
    row.rpg:SetWidth(46)
    row.rpg:SetJustifyH("LEFT")
    row.conf = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.conf:SetPoint("LEFT", 654, 0)
    row.conf:SetWidth(50)
    row.conf:SetJustifyH("LEFT")
    row:SetScript("OnClick", function()
      selectedIndex = row.index
      RefreshRows()
    end)
    row:SetScript("OnEnter", function(self)
      local data = shown[self.index]
      if not data then
        return
      end
      local w, p = data.writ, data.price
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetText(w.writItemName or "Writ")
      GameTooltip:AddLine(string.format("%s  ·  %s  ·  %d rep", w.profession or "?", w.tier or "?", w.rep or 0), 1, 1, 1)
      GameTooltip:AddLine("Required: " .. (w.requiredCount or 1) .. "x " .. (w.requiredItemName or "?"), 0.9, 0.9, 0.9)
      GameTooltip:AddLine("Writ: " .. WR.MoneyText(p.writCopper) .. "  +  item: " .. WR.MoneyText(p.itemCopper) .. "  =  " .. WR.MoneyText(p.totalCopper), 0.9, 0.9, 0.6)
      if p.rewardCopper then
        GameTooltip:AddLine("Turn-in pays: " .. WR.MoneyText(p.rewardCopper), 0.9, 0.9, 0.6)
        if p.netCopper then
          if p.netCopper < 0 then
            GameTooltip:AddLine("Net: you come out " .. WR.MoneyText(-p.netCopper) .. " ahead", 0.4, 1, 0.4)
          else
            GameTooltip:AddLine("Net cost: " .. WR.MoneyText(p.netCopper), 0.9, 0.9, 0.6)
          end
        end
      else
        GameTooltip:AddLine("Turn-in gold reward not learned yet (view or turn in this writ once).", 0.6, 0.6, 0.6, true)
      end
      if p.repPerGold then
        GameTooltip:AddLine(string.format("%.2f reputation per gold", p.repPerGold), 0.7, 1, 0.7)
      end
      local dest = (w.npc or "unknown NPC") .. " — " .. (w.zone or "unknown zone")
      if w.coords then
        dest = dest .. string.format(" (%.1f, %.1f)", w.coords.x, w.coords.y)
      end
      GameTooltip:AddLine("Turn-in: " .. dest, 0.8, 0.8, 1)
      GameTooltip:AddLine("Source: " .. (w.confirmation or "unmapped"), 0.7, 0.7, 0.7)
      local done = WR.Daily and WR.Daily.IsCompleted(w)
      local turnedIn = WR.Daily and WR.Daily.IsTurnedIn and WR.Daily.IsTurnedIn(w)
      local st = w.questId and staged[w.questId]
      if turnedIn then
        GameTooltip:AddLine("Turned in today. This box is locked, and Reset will not restore this writ.", 0.6, 0.75, 0.95, true)
      elseif st == true and not done then
        GameTooltip:AddLine("Staged for removal. Click Confirm under the list to take it out of #4 and #5, or tick the box again to undo.", 1, 0.7, 0.4, true)
      elseif st == false and done then
        GameTooltip:AddLine("Staged to restore. Click Confirm to put it back in the plan.", 0.5, 1, 0.6, true)
      elseif done then
        GameTooltip:AddLine("Removed from the plan in #3. Untick and Confirm to restore this one, or use Reset to restore all you removed.", 1, 0.6, 0.4, true)
      else
        GameTooltip:AddLine("Tick to stage this writ for removal, then click Confirm. #4 and #5 stay put until you confirm.", 0.7, 0.7, 0.7, true)
      end
      GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function()
      GameTooltip:Hide()
    end)
    rows[r] = row
  end

  -- Confirm / Reset under #3, then shopping list (left) and route (right)
  local listBottom = -270 - VISIBLE_ROWS * ROW_HEIGHT
  local planBtnY = listBottom - 8
  local panelY = planBtnY - 32

  frame.confirmBtn = MakeButton("Confirm", 32, planBtnY, function()
    OnConfirmClicked()
  end, 90)
  frame.confirmBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("Confirm")
    GameTooltip:AddLine("Removes the writs you ticked in #3 from the plan and updates #4 and #5. Nothing changes until you confirm.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  frame.confirmBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

  frame.resetBtn = MakeButton("Reset", 128, planBtnY, function()
    OnResetClicked()
  end, 80)
  frame.resetBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("Reset")
    GameTooltip:AddLine("Clears staged checkboxes and restores writs you removed in #3, then rebuilds the plan. Writs you already turned in stay completed. To clear turn-ins too, type /writs reset in chat.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  frame.resetBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

  frame.stageHint = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  frame.stageHint:SetPoint("LEFT", frame.resetBtn, "RIGHT", 12, 0)
  frame.stageHint:SetWidth(500)
  frame.stageHint:SetJustifyH("LEFT")
  frame.stageHint:SetText("")
  UpdatePlanButtons()

  Section(frame, "4. Buy writs and items",
    "At the Auction House, click AH shopping list and buy everything below.", 18, panelY, 340)

  local shopScroll = CreateFrame("ScrollFrame", "WritRunnerShopScroll", frame, "UIPanelScrollFrameTemplate")
  shopScroll:SetPoint("TOPLEFT", 32, panelY - 52)
  shopScroll:SetSize(320, 120)
  local shopChild = CreateFrame("Frame", nil, shopScroll)
  shopChild:SetSize(300, 120)
  shopScroll:SetScrollChild(shopChild)
  local shopText = shopChild:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  shopText:SetPoint("TOPLEFT", 0, 0)
  shopText:SetWidth(300)
  shopText:SetJustifyH("LEFT")
  shopText:SetJustifyV("TOP")
  frame.shopText = shopText
  frame.shopChild = shopChild

  local divider = frame:CreateTexture(nil, "ARTWORK")
  divider:SetColorTexture(0.6, 0.5, 0.2, 0.5)
  divider:SetPoint("TOPLEFT", 384, panelY + 2)
  divider:SetSize(1, 204)

  Section(frame, "5. Run the route",
    "Collect mail, then Start run (it checks bags). Open each writ only at its NPC.", 400, panelY, 330)

  local routeScroll = CreateFrame("ScrollFrame", "WritRunnerRouteScroll", frame, "UIPanelScrollFrameTemplate")
  routeScroll:SetPoint("TOPLEFT", 414, panelY - 52)
  routeScroll:SetSize(300, 120)
  local routeChild = CreateFrame("Frame", nil, routeScroll)
  routeChild:SetSize(280, 120)
  routeScroll:SetScrollChild(routeChild)
  local routeText = routeChild:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  routeText:SetPoint("TOPLEFT", 0, 0)
  routeText:SetWidth(280)
  routeText:SetJustifyH("LEFT")
  routeText:SetJustifyV("TOP")
  frame.routeText = routeText
  frame.routeChild = routeChild

  local btnY = panelY - 182

  MakeButton("Waypoint next", 620, btnY, function()
    local zoneInfo, row = nil, nil
    if selectedIndex and shown[selectedIndex] then
      row = shown[selectedIndex]
    else
      zoneInfo, row = WR.Route.NextUndoneStop(plan.route)
    end
    if not row then
      WR.Print("Nothing to waypoint. Pick a writ with coordinates, or add priced writs to the plan.")
      return
    end
    local ok, msg = WR.Route.SetWaypointForWrit(row.writ)
    WR.Print(msg)
  end, 110)

  MakeButton("AH shopping list", 32, btnY, function()
    UI.Refresh()
    local terms, sig = ShopTerms()
    if #terms == 0 then
      WR.Print("The shopping list is empty.")
      return
    end
    local ok, msg = WR.TryAuctionatorShopping(terms, "WritRunner")
    if ok then
      WR.db.shopListSig = sig
    end
    WR.Print(msg)
  end, 150)

  -- Footer tip: full daily wipe is a slash command, not a button
  local footY = btnY - 26
  local tip = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  tip:SetPoint("TOPLEFT", 18, footY)
  tip:SetPoint("TOPRIGHT", -18, footY)
  tip:SetJustifyH("LEFT")
  tip:SetText("Tip: to reset all of today's completed writs, type /writs reset in chat. The list also clears on its own at the daily reset.")

  frame.checkBagsBtn = MakeButton("Check bags", 272, btnY, function()
    UI.CheckBags()
  end, 108)
  frame.checkBagsBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("Check bags")
    GameTooltip:AddLine("Confirms every writ and required item for the current plan (or remaining run steps) is in your bags. Items still in the mailbox do not count — take them out first.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  frame.checkBagsBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

  frame.startBtn = MakeButton("Start run", 400, btnY, function()
    UI.StartRunFromPlan()
  end, 105)
  frame.startBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("Start run")
    GameTooltip:AddLine("Checks your bags for every item in the plan, then opens the tracker. If something is missing, a popup lists it and you can start anyway or cancel. Take mailbox items out first.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  frame.startBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

  frame.trackBtn = MakeButton("Show tracker", 510, btnY, function()
    if WR.Tracker and WR.Tracker.Toggle then
      WR.Tracker.Toggle()
    end
  end, 105)

  UI.UpdateRunButtons()

  frame:Hide()
  UI.frame = frame
  return frame
end

function UI.Toggle()
  BuildFrame()
  ApplySavedPosition()
  if frame:IsShown() then
    frame:Hide()
  else
    if frame.maxBox and WR.db then
      frame.maxBox:SetText(WR.db.maxGold or "")
      frame.budgetBox:SetText(WR.db.budgetGold or "")
      frame.hideUnconf:SetChecked(WR.db.hideUnconfirmed ~= false)
      frame.hideDone:SetChecked(WR.db.hideCompleted ~= false)
      frame.showSealed:SetChecked(WR.db.showSealed ~= false)
    end
    UI.Refresh()
    frame:Show()
  end
end

function UI.Show()
  BuildFrame()
  ApplySavedPosition()
  UI.Refresh()
  frame:Show()
end

function UI.GetPicked()
  return picked, plan, spent
end

function UI.ResetAllToday()
  if WR.Daily and WR.Daily.ClearCompleted then
    WR.Daily.ClearCompleted()
    WR.Print("Cleared today's completed-writ list.")
  end
  if WR.Run and WR.Run.IsActive and WR.Run.IsActive() then
    WR.Run.End()
  end
  UI.Refresh()
end

function UI.CheckBags()
  Rebuild()
  if not WR.Run or not WR.Run.CheckBags then
    WR.Print("Run module is not loaded.")
    return
  end
  local source = picked
  if WR.Run.IsActive and WR.Run.IsActive() and WR.Run.Steps then
    source = WR.Run.Steps()
  end
  local report = WR.Run.CheckBags(source)
  if WR.Run.ShowBagReport then
    WR.Run.ShowBagReport(report, "check")
  end
end

function UI.StartRunFromPlan()
  Rebuild()
  if not WR.Run or not WR.Run.Start then
    WR.Print("Run module is not loaded.")
    return
  end
  if WR.Run.CheckBags then
    local report = WR.Run.CheckBags(picked)
    if report and report.missingCount and report.missingCount > 0 then
      if WR.Run.ShowBagReport then
        WR.Run.ShowBagReport(report, "start", picked)
      elseif WR.Run.PromptStartDespiteMissing then
        WR.Run.PromptStartDespiteMissing(picked, report)
      end
      return
    end
  end
  local ok, msg = WR.Run.Start(picked)
  if not ok and msg then
    WR.Print(msg)
  end
  UI.UpdateRunButtons()
end

function UI.UpdateRunButtons()
  if not frame then
    return
  end
  if frame.startBtn then
    if WR.Run and WR.Run.IsActive and WR.Run.IsActive() then
      frame.startBtn:SetText("Restart run")
    else
      frame.startBtn:SetText("Start run")
    end
  end
  if frame.trackBtn then
    if WR.Tracker and WR.Tracker.IsShown and WR.Tracker.IsShown() then
      frame.trackBtn:SetText("Hide tracker")
    else
      frame.trackBtn:SetText("Show tracker")
    end
  end
end

-- Refresh prices when Auctionator's database updates, if the API exists.
local hookRegistered
local login = CreateFrame("Frame")
login:RegisterEvent("PLAYER_LOGIN")
login:SetScript("OnEvent", function()
  if hookRegistered then
    return
  end
  if Auctionator and Auctionator.API and Auctionator.API.v1 and Auctionator.API.v1.RegisterForDBUpdate then
    local ok = pcall(Auctionator.API.v1.RegisterForDBUpdate, WR.CALLER_ID, function()
      if frame and frame:IsShown() then
        UI.Refresh()
      end
    end)
    hookRegistered = ok and true or false
  end
end)


-- Minimap button: left-click opens WritRunner, right-click toggles the run
-- tracker, drag to move it around the minimap edge.
local function MinimapAngleToPos(angle)
  local r = (Minimap:GetWidth() / 2) + 5
  return math.cos(math.rad(angle)) * r, math.sin(math.rad(angle)) * r
end

function UI.CreateMinimapButton()
  if UI.minimapButton or not Minimap then
    return
  end
  WR.db.minimap = WR.db.minimap or { angle = 200, hide = false }
  local b = CreateFrame("Button", "WritRunnerMinimapButton", Minimap)
  b:SetSize(31, 31)
  b:SetFrameStrata("MEDIUM")
  b:SetFrameLevel(8)
  b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  b:RegisterForDrag("LeftButton")
  b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
  local icon = b:CreateTexture(nil, "BACKGROUND")
  icon:SetSize(20, 20)
  icon:SetPoint("TOPLEFT", 7, -6)
  icon:SetTexture("Interface\\Icons\\INV_Scroll_03")
  icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  local border = b:CreateTexture(nil, "OVERLAY")
  border:SetSize(53, 53)
  border:SetPoint("TOPLEFT")
  border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

  local function Place()
    local x, y = MinimapAngleToPos(WR.db.minimap.angle or 200)
    b:ClearAllPoints()
    b:SetPoint("CENTER", Minimap, "CENTER", x, y)
  end
  b:SetScript("OnDragStart", function(self)
    self:SetScript("OnUpdate", function()
      local mx, my = Minimap:GetCenter()
      local cx, cy = GetCursorPosition()
      local scale = Minimap:GetEffectiveScale()
      cx, cy = cx / scale, cy / scale
      WR.db.minimap.angle = math.deg(math.atan2(cy - my, cx - mx)) % 360
      Place()
    end)
  end)
  b:SetScript("OnDragStop", function(self)
    self:SetScript("OnUpdate", nil)
  end)
  b:SetScript("OnClick", function(_, button)
    if button == "RightButton" then
      if WR.Tracker and WR.Tracker.Toggle then
        WR.Tracker.Toggle()
      end
    else
      UI.Toggle()
    end
  end)
  b:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:SetText("WritRunner")
    local r = WR.Rep and WR.Rep.Get and WR.Rep.Get()
    if r and not r.missing then
      GameTooltip:AddLine(string.format("%s: %s %d/%d", r.name, r.standing or "?", r.value - r.min, r.max - r.min), 0.4, 1, 0.4)
    end
    local ok, secs = pcall(function()
      if C_DateAndTime and C_DateAndTime.GetSecondsUntilDailyReset then
        return C_DateAndTime.GetSecondsUntilDailyReset()
      end
      return GetQuestResetTime and GetQuestResetTime()
    end)
    if ok and type(secs) == "number" then
      GameTooltip:AddLine(string.format("Daily reset in %dh %02dm", math.floor(secs / 3600), math.floor((secs % 3600) / 60)), 1, 1, 1)
    end
    if WR.Run and WR.Run.IsActive and WR.Run.IsActive() then
      local done, total = WR.Run.Counts()
      GameTooltip:AddLine(string.format("Run: %d/%d turn-ins done", done, total), 1, 0.82, 0)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Left-click: open WritRunner", 0.8, 0.8, 0.8)
    GameTooltip:AddLine("Right-click: show/hide run tracker", 0.8, 0.8, 0.8)
    GameTooltip:AddLine("Drag: move button. /writs minimap: hide/show", 0.8, 0.8, 0.8)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  Place()
  if WR.db.minimap.hide then b:Hide() end
  UI.minimapButton = b
end

function UI.ToggleMinimapButton()
  UI.CreateMinimapButton()
  local b = UI.minimapButton
  if not b then return end
  WR.db.minimap.hide = not WR.db.minimap.hide
  if WR.db.minimap.hide then
    b:Hide()
    WR.Print("Minimap button hidden. Type /writs minimap to show it again.")
  else
    b:Show()
  end
end

-- Keep the open window's rep bar live.
local repEv = CreateFrame("Frame")
repEv:RegisterEvent("UPDATE_FACTION")
repEv:RegisterEvent("PLAYER_LOGIN")
repEv:SetScript("OnEvent", function(_, event)
  if event == "PLAYER_LOGIN" then
    if WR.db then UI.CreateMinimapButton() end
    return
  end
  if frame and frame:IsShown() then
    UI.RefreshRep()
  end
end)
