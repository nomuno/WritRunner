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
local bagOwned, bagSkipped = {}, {}
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
    useBagWrits = db.useBagWrits and true or false,
    rankByNet = db.rankByNet and true or false,
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

-- Shopping-list lock (1.2.3). Once the player makes the Auctionator list in
-- #4, the plan is frozen: Auctionator price updates (every AH search updates
-- its database) never re-pick writs or rewrite the Auctionator list. Only the
-- Re-plan button (with a confirm popup) or the daily reset changes it.
local lockDrift = false -- fresh prices/limits would pick a different plan

local function CopyPrice(price)
  local out = {}
  if type(price) == "table" then
    local k, v
    for k, v in pairs(price) do
      if type(v) == "number" or type(v) == "boolean" then
        out[k] = v
      end
    end
  end
  return out
end

local function ActiveLock()
  local db = WR.db
  if not db or type(db.shopLock) ~= "table" then
    return nil
  end
  local lock = db.shopLock
  -- The lock belongs to one daily cycle; a new day starts a fresh plan.
  if lock.resetAt and db.resetAt and math.abs(lock.resetAt - db.resetAt) > 120 then
    db.shopLock = nil
    return nil
  end
  return lock
end
UI.ActiveLock = ActiveLock

function UI.IsShopLocked()
  return ActiveLock() ~= nil
end

function UI.ClearShopLock()
  if WR.db then
    WR.db.shopLock = nil
  end
  lockDrift = false
end

local function MakeLock(pickedRows, shopItems, spentCopper)
  local lock = {
    resetAt = WR.db and WR.db.resetAt or nil,
    createdAt = (GetServerTime and GetServerTime()) or time(),
    budgetGold = WR.db and WR.db.budgetGold or nil,
    maxGold = WR.db and WR.db.maxGold or nil,
    spent = spentCopper or 0,
    writs = {},
    prices = {},
  }
  local i
  for i = 1, #(pickedRows or {}) do
    local row = pickedRows[i]
    if row.writ and row.writ.questId then
      lock.writs[#lock.writs + 1] = { questId = row.writ.questId, price = CopyPrice(row.price) }
    end
  end
  for i = 1, #(shopItems or {}) do
    local item = shopItems[i]
    if item.itemId then
      lock.prices[item.itemId] = item.copperEach
    end
  end
  return lock
end

-- Rows for the frozen plan: same writs, same prices as when it was locked.
-- Writs turned in or removed today drop out of the route, but nothing is
-- ever added and the Auctionator list is not touched.
local function LockedPicked(lock)
  local rows, total = {}, 0
  local i
  for i = 1, #(lock.writs or {}) do
    local entry = lock.writs[i]
    local w = WR.Daily and WR.Daily.WritByQuestId and WR.Daily.WritByQuestId(entry.questId)
    if w and not (WR.Daily and WR.Daily.IsCompleted and WR.Daily.IsCompleted(w)) then
      local price = CopyPrice(entry.price)
      if price.known == nil then
        price.known = price.totalCopper ~= nil
      end
      rows[#rows + 1] = { writ = w, price = price }
      total = total + (price.totalCopper or 0)
    end
  end
  return rows, total
end

local function QuestSet(rows)
  local set, n = {}, 0
  local i
  for i = 1, #(rows or {}) do
    local w = rows[i].writ
    if w and w.questId and not set[w.questId] then
      set[w.questId] = true
      n = n + 1
    end
  end
  return set, n
end

local function SameQuests(a, b)
  local sa, na = QuestSet(a)
  local sb, nb = QuestSet(b)
  if na ~= nb then
    return false
  end
  local q
  for q in pairs(sa) do
    if not sb[q] then
      return false
    end
  end
  return true
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
  WR.db.shopListSig = nil -- 1.2.2 auto-sync marker, no longer used
  local opts = Options()
  if opts.useBagWrits and WR.CollectBagWrits then
    opts.bagOwned, opts.bagSkipped = WR.CollectBagWrits()
  end
  bagOwned, bagSkipped = opts.bagOwned or {}, opts.bagSkipped or {}
  ranked = WR.RankWrits(opts)
  local budget = WR.GoldToCopper(WR.db.budgetGold)
  local freshPicked, freshSpent = WR.PickWithinBudget(ranked, budget)
  local lock = ActiveLock()
  if lock then
    -- Frozen: keep the locked writs and prices; only note whether a fresh
    -- plan would differ so #4 can offer Re-plan. Never rewrite Auctionator.
    picked, spent = LockedPicked(lock)
    local freshOpen = {}
    local i
    for i = 1, #freshPicked do
      local w = freshPicked[i].writ
      if not (WR.Daily and WR.Daily.IsCompleted and WR.Daily.IsCompleted(w)) then
        freshOpen[#freshOpen + 1] = freshPicked[i]
      end
    end
    lockDrift = not SameQuests(picked, freshOpen)
  else
    picked, spent = freshPicked, freshSpent
    lockDrift = false
  end
  if WR.Route then
    plan = WR.Route.Build(picked)
  else
    plan = { shop = {}, route = {} }
  end
  if lock and plan.shop then
    local i
    for i = 1, #plan.shop do
      local item = plan.shop[i]
      local frozen = lock.prices and lock.prices[item.itemId]
      if frozen then
        item.copperEach = frozen
      end
    end
  end
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
      if p.ownedWrit then
        local tag = p.ownedBank and " |cff66cc66in bank|r" or " |cff66cc66owned|r"
        row.name:SetText(nameColor .. Truncate(writName, 26) .. "|r" .. tag)
      else
        row.name:SetText(nameColor .. Truncate(writName, 34) .. "|r")
      end
      local tierShort = (w.tier == "Journeyman") and "Journey" or (w.tier or "")
      row.tier:SetText(tierShort .. "  |cff40c0ff" .. (w.rep or 0) .. "|r")
      row.zone:SetText(Truncate(w.zone or "—", 20))
      if p.known then
        row.cost:SetText(WR.MoneyText(p.totalCopper))
      else
        row.cost:SetText("|cffcc6666unknown|r")
      end
      row.rpg:SetText(WR.FormatRepPerGold(p, w, WR.db and WR.db.rankByNet))
      local function NetString(copper, approx)
        local prefix = approx and "~" or ""
        if copper < 0 then
          return "|cff40ff40" .. prefix .. "+" .. WR.MoneyText(-copper) .. "|r"
        end
        return prefix .. WR.MoneyText(copper)
      end
      if p.estNetKnown then
        row.net:SetText(NetString(p.estNetCopper, true))
      elseif p.netCopper then
        row.net:SetText(NetString(p.netCopper, false))
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
    local ownedN = 0
    local i
    for i = 1, #picked do
      if picked[i].price and picked[i].price.ownedWrit then
        ownedN = ownedN + 1
      end
    end
    if ownedN > 0 then
      q = q .. string.format("  |cff66cc66%d from your bags.|r", ownedN)
    end
    if bagSkipped and #bagSkipped > 0 then
      local bits = {}
      local sk
      for sk = 1, math.min(3, #bagSkipped) do
        local w = bagSkipped[sk].writ
        local name = (w.writItemName or "Writ"):gsub("^Craftsman's Writ: ", "")
        bits[#bits + 1] = name .. " (" .. (bagSkipped[sk].reason or "unroutable") .. ")"
      end
      q = q .. string.format("  |cffcc6666Skipped %d bag writ%s: %s%s.|r",
        #bagSkipped, #bagSkipped == 1 and "" or "s",
        table.concat(bits, ", "),
        #bagSkipped > 3 and (", +" .. (#bagSkipped - 3) .. " more") or "")
    end
    local estSum, estKnown, estMissing = 0, 0, 0
    for i = 1, #picked do
      local pr = picked[i].price
      if pr and pr.estNetKnown then
        estSum = estSum + (pr.estNetCopper or 0)
        estKnown = estKnown + 1
      elseif pr and pr.known then
        estMissing = estMissing + 1
      end
    end
    if estKnown > 0 then
      if estSum < 0 then
        q = q .. "  Est. net |cff40ff40~+" .. WR.MoneyText(-estSum) .. "|r"
      else
        q = q .. "  Est. net ~" .. WR.MoneyText(estSum)
      end
      if estMissing > 0 then
        q = q .. string.format(" (pouch avg unknown for %d)", estMissing)
      end
      q = q .. "."
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
  local locked = ActiveLock() ~= nil
  if locked then
    if lockDrift then
      shopLines[#shopLines + 1] = "|cffffd100Locked.|r Prices or limits changed since you made this list. It will not change on its own; click Re-plan to rebuild it."
    else
      shopLines[#shopLines + 1] = "|cff66cc66Locked.|r Price updates will not change this list. Click Re-plan to rebuild it."
    end
  end
  local nShop, nHave = 0, 0
  for t = 1, #plan.shop do
    local item = plan.shop[t]
    local price = item.copperEach and (WR.MoneyText(item.copperEach * item.count)) or "unknown"
    local name = item.name or ("item " .. item.itemId)
    nShop = nShop + 1
    if locked and WR.GetBagCount then
      local have = WR.GetBagCount(item.itemId) or 0
      local tag = ""
      if WR.ItemLocations and WR.LocationTag then
        local loc = WR.ItemLocations(item.itemId)
        local locTag = WR.LocationTag(loc)
        if locTag then
          tag = " (" .. locTag .. ")"
        end
      end
      if have >= item.count then
        nHave = nHave + 1
        shopLines[#shopLines + 1] = string.format("|cff66cc66[x] %dx %s  (%s)|r", item.count, name, price)
      else
        shopLines[#shopLines + 1] = string.format("[  ] %dx %s  (%s)  have %d%s", item.count, name, price, have, tag)
      end
    else
      shopLines[#shopLines + 1] = string.format("%dx %s  (%s)", item.count, name, price)
    end
  end
  if nShop == 0 then
    if locked then
      shopLines[#shopLines + 1] = "Nothing left to buy for the locked plan."
    else
      local anyOwned, i = false
      for i = 1, #picked do
        if picked[i].price and picked[i].price.ownedWrit then
          anyOwned = true
          break
        end
      end
      if anyOwned then
        shopLines[#shopLines + 1] = "Nothing to buy — every writ and fill item is already in your bags (or the bank)."
      else
        shopLines[#shopLines + 1] = "No priced writs in the current plan. Set a budget or wait for Auctionator prices."
      end
    end
  elseif locked then
    shopLines[#shopLines + 1] = string.format("Have: %d of %d in bags. Bank and mail are noted on the line; take them out before Start run.", nHave, nShop)
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
  if WR.Buyer and WR.Buyer.RefreshAHButton then
    WR.Buyer.RefreshAHButton()
  end
end

-- When the plan is locked, a price-scan should only flip the #4 banner.
-- Do not re-rank or re-route (that hitch is why the window felt laggy
-- during an Auctionator rescan).
function UI.NotePriceDrift()
  if not ActiveLock() then
    return
  end
  lockDrift = true
  if frame and frame:IsShown() then
    RefreshRows()
  end
end

function UI.SaveFilters()
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
  if frame.useBags then
    WR.db.useBagWrits = frame.useBags:GetChecked() and true or false
  end
  if frame.rankByNet then
    WR.db.rankByNet = frame.rankByNet:GetChecked() and true or false
  end
  if frame.allowStartMissing then
    WR.db.allowStartMissing = frame.allowStartMissing:GetChecked() and true or false
  end
end

-- Fresh pick from current prices and limits, without touching the locked plan.
function UI.PreviewPick()
  local opts = Options()
  if opts.useBagWrits and WR.CollectBagWrits then
    opts.bagOwned, opts.bagSkipped = WR.CollectBagWrits()
  end
  local rankedNow = WR.RankWrits(opts)
  local budget = WR.GoldToCopper(WR.db and WR.db.budgetGold)
  local fresh, freshSpent = WR.PickWithinBudget(rankedNow, budget)
  return fresh, freshSpent, rankedNow
end

local function OnFilterChanged()
  UI.SaveFilters()
  UI.Refresh()
  if ActiveLock() and lockDrift then
    WR.Print("The shopping list is locked, so new limits do not change it. Click Apply limits or Re-plan to rebuild it.")
  end
end

-- Deliberate apply: if the list is locked and the new limits would change
-- the plan, ask to re-plan (same confirm as Re-plan). Otherwise rebuild now.
function UI.ApplyLimits()
  if frame then
    if frame.maxBox then frame.maxBox:ClearFocus() end
    if frame.budgetBox then frame.budgetBox:ClearFocus() end
  end
  UI.SaveFilters()
  if ActiveLock() then
    local fresh, freshSpent = UI.PreviewPick()
    local lockedRows = picked
    if not lockedRows then
      lockedRows = LockedPicked(ActiveLock())
    end
    if not SameQuests(lockedRows, fresh) then
      UI.ConfirmReplan({ fromApply = true, freshPicked = fresh, freshSpent = freshSpent })
      return
    end
  end
  UI.Refresh()
  WR.Print(string.format("Limits applied: %d writs qualify, spend %s.",
    #picked, WR.MoneyText(spent)))
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
    UI.ApplyLimits()
  end)
  edit:SetScript("OnEditFocusLost", function()
    UI.SaveFilters()
    if ActiveLock() then
      return
    end
    UI.Refresh()
  end)
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
    "Budget gold is the most to spend on the whole run. Max per writ hides any single writ that costs more. Blank means no limit. Tick Use writs in my bags to add ones you already have.", 18, -116)
  frame.maxBox = CreateGoldBox(frame, "Max per writ", 32, -148, db.maxGold)
  frame.budgetBox = CreateGoldBox(frame, "Budget gold", 200, -148, db.budgetGold)
  frame.hideUnconf = CreateCheck(frame, "Hide unconfirmed", 340, -146, db.hideUnconfirmed ~= false)
  frame.hideDone = CreateCheck(frame, "Hide done today", 480, -146, db.hideCompleted ~= false)
  frame.showSealed = CreateCheck(frame, "Sealed envelopes", 610, -146, db.showSealed ~= false)

  frame.sealed = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  frame.applyBtn = MakeButton("Apply limits", 32, -170, function()
    UI.ApplyLimits()
  end, 120)
  frame.applyBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText("Apply limits")
    GameTooltip:AddLine("Saves Max per writ and Budget gold and rebuilds the plan in #3, #4 and #5. Same as pressing Enter in either box. If the shopping list is locked, you will be asked to re-plan so the new limits actually take effect.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  frame.applyBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

  frame.useBags = CreateCheck(frame, "Use writs in my bags", 160, -168, db.useBagWrits and true or false)
  frame.useBags:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("Use writs in my bags")
    GameTooltip:AddLine("Adds named writs already in your bags (and the bank) to the plan at no writ cost. If the fill item is also on hand, nothing is added to the shopping list; otherwise only that item is. Writs whose turn-in NPC has no known path are listed as skipped under #3, and are not added.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  frame.useBags:SetScript("OnLeave", function() GameTooltip:Hide() end)

  frame.sealed:SetPoint("TOPLEFT", 340, -175)
  frame.sealed:SetPoint("TOPRIGHT", -18, -175)
  frame.sealed:SetJustifyH("LEFT")

  -- 3. Plan
  Section(frame, "3. Check the plan",
    "Tick writs to remove, then Confirm — #4 and #5 update after you confirm. Reset restores ones you removed, not turn-ins.", 18, -206, 580)
  frame.rankByNet = CreateCheck(frame, "Rank by net gold", 455, -204, WR.db and WR.db.rankByNet)
  frame.rankByNet:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("Rank by net gold")
    GameTooltip:AddLine("Off: rank by reputation per gold of cost (writ + fill). On: rank by reputation per estimated net gold (cost minus the expected Coin Pouch). Pouch averages are learned from every pouch you open (saved across runs). Until a tier has a sample, Artisan uses the Wowhead Looter average and Journeyman/Expert show ? and keep ranking by cost. Estimates are marked ~. See /writs pouches.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  frame.rankByNet:SetScript("OnLeave", function() GameTooltip:Hide() end)

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
    { "Cost", 440, 80 }, { "Net", 522, 82, "Estimated net: cost minus the expected Coin Pouch (and any direct quest gold). ~ means an estimate. ? means that tier has no pouch average yet (open pouches after a turn-in to learn it). Green means you come out ahead. Artisan starts from the Wowhead Looter average until you have your own samples." },
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
      if p.estPouch then
        local src
        if p.estPouchKind == "learned" then
          src = string.format("from %d of your pouches", p.estPouchN or 0)
        else
          src = p.estPouchSource or "seeded average"
        end
        GameTooltip:AddLine("Coin Pouch est.: ~" .. WR.MoneyText(p.estPouch) .. " (" .. src .. ")", 0.9, 0.85, 0.5)
      elseif w.tier then
        GameTooltip:AddLine("Coin Pouch average for " .. w.tier .. " not learned yet. /writs pouches", 0.6, 0.6, 0.6)
      end
      local rpgTip = WR.RepPerGoldTooltipLine(p, w, WR.db and WR.db.rankByNet)
      if rpgTip then
        if rpgTip == "Already owned" then
          GameTooltip:AddLine(rpgTip, 0.4, 1, 0.4)
        else
          GameTooltip:AddLine(rpgTip, 0.7, 1, 0.7)
        end
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
    "At the Auction House, click AH shopping list (locks the plan), then buy below or use Buy step by step.", 18, panelY, 340)

  local shopScroll = CreateFrame("ScrollFrame", "WritRunnerShopScroll", frame, "UIPanelScrollFrameTemplate")
  shopScroll:SetPoint("TOPLEFT", 32, panelY - 52)
  shopScroll:SetSize(320, 92)
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

  frame.buyBtn = MakeButton("Buy step by step", 32, panelY - 148, function()
    if WR.Buyer and WR.Buyer.Start then
      WR.Buyer.Start()
    end
  end, 150)
  frame.buyBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("Buy step by step")
    GameTooltip:AddLine("With the Auction House open and the list locked, walks the list one item at a time: live price vs the scanned price, then Accept, Reject (drops its writs), Skip or Stop. Also /writs buy.", 1, 1, 1, true)
    if not (WR.Buyer and WR.Buyer.IsAHOpen and WR.Buyer.IsAHOpen()) then
      GameTooltip:AddLine("Open the Auction House first.", 1, 0.3, 0.3, true)
    end
    if not ActiveLock() then
      GameTooltip:AddLine("Click AH shopping list first to lock the plan.", 1, 0.3, 0.3, true)
    end
    GameTooltip:Show()
  end)
  frame.buyBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

  local divider = frame:CreateTexture(nil, "ARTWORK")
  divider:SetColorTexture(0.6, 0.5, 0.2, 0.5)
  divider:SetPoint("TOPLEFT", 384, panelY + 2)
  divider:SetSize(1, 204)

  Section(frame, "5. Run the route",
    "Start run checks bags only. Collect mail and withdraw from the bank first. Open each writ only at its NPC.", 400, panelY, 330)

  local routeScroll = CreateFrame("ScrollFrame", "WritRunnerRouteScroll", frame, "UIPanelScrollFrameTemplate")
  routeScroll:SetPoint("TOPLEFT", 414, panelY - 52)
  routeScroll:SetSize(300, 102)
  local routeChild = CreateFrame("Frame", nil, routeScroll)
  routeChild:SetSize(280, 102)
  routeScroll:SetScrollChild(routeChild)
  local routeText = routeChild:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  routeText:SetPoint("TOPLEFT", 0, 0)
  routeText:SetWidth(280)
  routeText:SetJustifyH("LEFT")
  routeText:SetJustifyV("TOP")
  frame.routeText = routeText
  frame.routeChild = routeChild

  frame.allowStartMissing = CreateCheck(frame, "Allow starting with missing items", 400, panelY - 160, WR.db and WR.db.allowStartMissing)
  frame.allowStartMissing:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("Allow starting with missing items")
    GameTooltip:AddLine("Off (default): Start run will not open the tracker until every writ and fill item is in your bags. The popup lists anything still in the bank or mailbox, with Check again and Close. On: the popup also offers Start anyway, as before.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  frame.allowStartMissing:SetScript("OnLeave", function() GameTooltip:Hide() end)

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

  frame.shopBtn = MakeButton("AH shopping list", 32, btnY, function()
    UI.MakeShoppingList()
  end, 150)
  frame.shopBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("AH shopping list")
    GameTooltip:AddLine("Creates the Auctionator \"WritRunner\" list and locks the plan, so price changes while you shop cannot change it. If it is already locked, this re-sends the same list.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  frame.shopBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

  frame.replanBtn = MakeButton("Re-plan", 186, btnY, function()
    UI.ConfirmReplan()
  end, 82)
  frame.replanBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("Re-plan")
    GameTooltip:AddLine("Unlocks the shopping list, re-picks writs with current prices and limits, and replaces the Auctionator list. Asks first.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  frame.replanBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

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
    GameTooltip:AddLine("Confirms every writ and required item for the current plan (or remaining run steps) is in your bags. The popup says whether a missing item is in the bank, in the mailbox, or not owned.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  frame.checkBagsBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

  frame.startBtn = MakeButton("Start run", 400, btnY, function()
    UI.StartRunFromPlan()
  end, 105)
  frame.startBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("Start run")
    GameTooltip:AddLine("Checks bags only, then opens the tracker. If anything is still in the bank or mailbox, the run does not start (unless you tick Allow starting with missing items). Visit the bank or mailbox, then Start run again.", 1, 1, 1, true)
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
      if frame.useBags then
        frame.useBags:SetChecked(WR.db.useBagWrits and true or false)
      end
      if frame.rankByNet then
        frame.rankByNet:SetChecked(WR.db.rankByNet and true or false)
      end
      if frame.showAll then
        frame.showAll:SetChecked(WR.db.showAllWrits and true or false)
      end
      if frame.allowStartMissing then
        frame.allowStartMissing:SetChecked(WR.db.allowStartMissing and true or false)
      end
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
  UI.ClearShopLock()
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
    WR.Run.ShowBagReport(report, "check", nil, source)
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

-- Step buyer Reject: drop writs from the locked plan, rebuild the route, and
-- replace the Auctionator list to match. Returns true if Auctionator was
-- updated (only with CreateShoppingList; the MultiSearch fallback would start
-- a search and fight the buyer's own searches).
function UI.RemoveLockedWrits(questIds)
  local lock = ActiveLock()
  if not lock or not questIds or #questIds == 0 then
    return false
  end
  local drop = {}
  local i
  for i = 1, #questIds do
    drop[questIds[i]] = true
  end
  local keep = {}
  for i = 1, #(lock.writs or {}) do
    if not drop[lock.writs[i].questId] then
      keep[#keep + 1] = lock.writs[i]
    end
  end
  lock.writs = keep
  lock.rejected = lock.rejected or {}
  for i = 1, #questIds do
    lock.rejected[#lock.rejected + 1] = questIds[i]
  end
  Rebuild()
  if frame and frame:IsShown() then
    RefreshRows()
  end
  if WR.Run and WR.Run.IsActive and WR.Run.IsActive() then
    WR.Print("A run is active; /writs reroute or Restart run to drop the rejected writs from it.")
  end
  local api = Auctionator and Auctionator.API and Auctionator.API.v1
  if api and api.CreateShoppingList then
    local terms = ShopTerms()
    if #terms > 0 then
      local ok = WR.TryAuctionatorShopping(terms, "WritRunner")
      return ok and true or false
    end
  end
  return false
end

-- #4 button: make the Auctionator list from the current plan and lock it.
-- If already locked, re-send the same frozen list without re-planning.
function UI.MakeShoppingList()
  local wasLocked = ActiveLock() ~= nil
  Rebuild()
  if frame and frame:IsShown() then
    RefreshRows()
  end
  local terms = ShopTerms()
  if #terms == 0 then
    WR.Print(wasLocked and "Nothing left to buy for the locked plan." or "The shopping list is empty.")
    return
  end
  local ok, msg = WR.TryAuctionatorShopping(terms, "WritRunner")
  if ok and WR.db then
    if not wasLocked then
      WR.db.shopLock = MakeLock(picked, plan.shop, spent)
      lockDrift = false
      msg = msg .. ". Plan locked: price updates will not change it (Re-plan to rebuild)."
    else
      msg = msg .. ". Same locked plan re-sent."
    end
  end
  WR.Print(msg)
  if frame and frame:IsShown() then
    RefreshRows()
  end
  UI.UpdateRunButtons()
end

function UI.ConfirmReplan(opts)
  opts = opts or {}
  if frame then
    if frame.maxBox then frame.maxBox:ClearFocus() end
    if frame.budgetBox then frame.budgetBox:ClearFocus() end
  end
  UI.SaveFilters()
  local lock = ActiveLock()
  if not lock then
    UI.ShowConfirm({
      title = "WritRunner",
      message = "The shopping list is not locked, so the plan already follows current prices and limits. Click AH shopping list to make and lock it.",
      accept = "OK",
    })
    return
  end
  -- Preview what a fresh plan would be without changing anything yet.
  -- Always use the budget/limits currently in the boxes, not the locked ones.
  local freshPicked, freshSpent = opts.freshPicked, opts.freshSpent
  if not freshPicked then
    freshPicked, freshSpent = UI.PreviewPick()
  end
  local oldSet = QuestSet(picked)
  local newSet = QuestSet(freshPicked)
  local lines = {}
  local i
  for i = 1, #freshPicked do
    local w = freshPicked[i].writ
    if w and w.questId and not oldSet[w.questId] then
      lines[#lines + 1] = "  |cff66cc66+|r " .. ShortWritName(w.writItemName)
    end
  end
  for i = 1, #picked do
    local w = picked[i].writ
    if w and w.questId and not newSet[w.questId] then
      lines[#lines + 1] = "  |cffcc6666-|r " .. ShortWritName(w.writItemName)
    end
  end
  local message
  local verb = opts.fromApply and "Apply these limits and re-plan" or "Re-plan with current prices"
  if #lines == 0 then
    message = string.format("%s? Same writs, estimated cost %s.", verb, WR.MoneyText(freshSpent))
  else
    message = string.format("%s? %d writ change%s, estimated cost %s (was %s).",
      verb, #lines, #lines == 1 and "" or "s", WR.MoneyText(freshSpent), WR.MoneyText(spent))
  end
  UI.ShowConfirm({
    title = opts.fromApply and "Apply limits" or "Re-plan shopping list",
    message = message,
    lines = lines,
    footer = "This replaces the Auctionator \"WritRunner\" list and locks the new plan. Items already in your bags still count.",
    accept = opts.fromApply and "Apply and re-plan" or "Re-plan",
    cancel = "Cancel",
    OnAccept = function()
      UI.ClearShopLock()
      UI.Refresh()
      UI.MakeShoppingList()
    end,
  })
end

function UI.UpdateRunButtons()
  if WR.Buyer and WR.Buyer.RefreshAHButton then
    WR.Buyer.RefreshAHButton()
  end
  if not frame then
    return
  end
  if frame.buyBtn then
    if ActiveLock() and WR.Buyer and WR.Buyer.IsAHOpen and WR.Buyer.IsAHOpen() then
      frame.buyBtn:Enable()
    else
      frame.buyBtn:Disable()
    end
  end
  if frame.replanBtn then
    if ActiveLock() then
      frame.replanBtn:Enable()
    else
      frame.replanBtn:Disable()
    end
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
    -- Auctionator fires this on every AH search. Coalesce bursts; a locked
    -- plan only refreshes its display and the "prices changed" notice.
    local pending
    local ok = pcall(Auctionator.API.v1.RegisterForDBUpdate, WR.CALLER_ID, function()
      if not frame or not frame:IsShown() then
        return
      end
      if C_Timer and C_Timer.After then
        if pending then
          return
        end
        pending = true
        -- Locked: only flip the #4 banner, no re-rank or re-route.
        -- Unlocked: debounce a full refresh; 1s so a scan does not hitch.
        local delay = ActiveLock() and 0.3 or 1.0
        C_Timer.After(delay, function()
          pending = false
          if not (frame and frame:IsShown()) then
            return
          end
          if ActiveLock() then
            UI.NotePriceDrift()
          else
            UI.Refresh()
          end
        end)
      else
        if ActiveLock() then
          UI.NotePriceDrift()
        else
          UI.Refresh()
        end
      end
    end)
    hookRegistered = ok and true or false
  end
end)


-- If "Use writs in my bags" is on and the plan is not locked, rebuild
-- when bags change so newly looted writs appear. Locked plans stay frozen.
local bagWatch = CreateFrame("Frame")
local bagPending
bagWatch:RegisterEvent("BAG_UPDATE_DELAYED")
bagWatch:RegisterEvent("BAG_UPDATE")
bagWatch:SetScript("OnEvent", function()
  if not WR.db or not WR.db.useBagWrits then
    return
  end
  if not frame or not frame:IsShown() then
    return
  end
  if ActiveLock() then
    if RefreshRows then
      RefreshRows()
    end
    if WR.Buyer and WR.Buyer.RefreshAHButton then
      WR.Buyer.RefreshAHButton()
    end
    return
  end
  if bagPending then
    return
  end
  bagPending = true
  local function flush()
    bagPending = nil
    if frame and frame:IsShown() and WR.db and WR.db.useBagWrits and not ActiveLock() then
      UI.Refresh()
    end
  end
  if C_Timer and C_Timer.After then
    C_Timer.After(0.3, flush)
  else
    flush()
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
