-- Active turn-in run: snapshot of the plan, progress, bag fallback, persistence.

local WR = WritRunner
WR.Run = WR.Run or {}
local Run = WR.Run

local function Now()
  return (GetServerTime and GetServerTime()) or time()
end

function WR.GetItemCount(itemId, includeBank)
  if not itemId then
    return 0
  end
  includeBank = includeBank and true or false
  if C_Item and C_Item.GetItemCount then
    local ok, n = pcall(C_Item.GetItemCount, itemId, includeBank)
    if ok and type(n) == "number" then
      return n
    end
  end
  if GetItemCount then
    local ok, n = pcall(GetItemCount, itemId, includeBank)
    if ok and type(n) == "number" then
      return n
    end
  end
  return 0
end

function WR.GetBagCount(itemId)
  return WR.GetItemCount(itemId, false)
end

-- bags first, then any extra sitting in the bank (cheap: one GetItemCount).
function WR.GetOwnedCount(itemId)
  local bags = WR.GetItemCount(itemId, false)
  local all = WR.GetItemCount(itemId, true)
  if all < bags then
    all = bags
  end
  return bags, all - bags, all
end

------------------------------------------------------------------------
-- Mailbox cache: only scanned while the mailbox UI is open, so an empty
-- GetInboxNumItems when it is closed cannot wipe what we last saw.
-- Counts are keyed by item id and stamped with the time last seen.
-- Today's buy log fills in purchases that have not been collected yet
-- and are not already in the cache, bags, or bank.
------------------------------------------------------------------------

local function MailboxOpen()
  if MailFrame and MailFrame.IsShown and MailFrame:IsShown() then
    return true
  end
  if InboxFrame and InboxFrame.IsShown and InboxFrame:IsShown() then
    return true
  end
  return false
end

local function BankOpen()
  if BankFrame and BankFrame.IsShown and BankFrame:IsShown() then
    return true
  end
  return false
end

local function BoughtToday(itemId)
  if WR.Ledger and WR.Ledger.Log then
    local lg = WR.Ledger.Log()
    if lg and lg.bought then
      return lg.bought[itemId] or 0
    end
  end
  if WR.Buyer and WR.Buyer.Bought then
    return WR.Buyer.Bought(itemId) or 0
  end
  return 0
end

function Run.ScanMailbox()
  if not GetInboxNumItems then
    return nil
  end
  if not MailboxOpen() then
    return nil
  end
  local n = GetInboxNumItems() or 0
  local counts = {}
  local maxAttach = ATTACHMENTS_MAX_RECEIVE or 16
  local i, a
  for i = 1, n do
    for a = 1, maxAttach do
      local id, count
      if GetInboxItemLink then
        local ok, link = pcall(GetInboxItemLink, i, a)
        if ok and type(link) == "string" then
          id = tonumber(string.match(link, "item:(%d+)"))
        end
      end
      if GetInboxItem then
        -- Retail returns 6 values (name, itemID, texture, count, quality, canUse);
        -- classic returns 5 (name, texture, count, quality, canUse).
        local ok, r1, r2, r3, r4, r5, r6 = pcall(GetInboxItem, i, a)
        if ok then
          if r6 ~= nil then
            count = r4
            if not id and type(r2) == "number" then
              id = r2
            end
          else
            count = r3
          end
        end
      end
      if id then
        if not count or count < 1 then
          count = 1
        end
        counts[id] = (counts[id] or 0) + count
      end
    end
  end
  if WR.db then
    WR.db.mailCache = { at = Now(), counts = counts }
  end
  return counts
end

-- Returns total mail estimate, cached inbox count, pending from today's
-- buy log, and the time the inbox was last scanned.
function WR.GetMailCount(itemId)
  if not itemId then
    return 0, 0, 0, nil
  end
  local cache = WR.db and WR.db.mailCache
  local cached = 0
  local seen = cache and cache.at
  if cache and type(cache.counts) == "table" then
    cached = cache.counts[itemId] or 0
  end
  local bags, bank = 0, 0
  if WR.GetOwnedCount then
    bags, bank = WR.GetOwnedCount(itemId)
  else
    bags = WR.GetBagCount and WR.GetBagCount(itemId) or 0
  end
  local bought = BoughtToday(itemId)
  local pending = bought - bags - bank - cached
  if pending < 0 then
    pending = 0
  end
  return cached + pending, cached, pending, seen
end

function WR.ItemLocations(itemId)
  local bags, bank = 0, 0
  if WR.GetOwnedCount then
    bags, bank = WR.GetOwnedCount(itemId)
  else
    bags = WR.GetBagCount and WR.GetBagCount(itemId) or 0
  end
  local mail, mailCached, mailPending, seen = WR.GetMailCount(itemId)
  return {
    bags = bags,
    bank = bank,
    mail = mail,
    mailCached = mailCached,
    mailPending = mailPending,
    seen = seen,
  }
end

local function FormatSeen(at)
  if not at then
    return nil
  end
  local ok, text = pcall(date, "%I:%M %p", at)
  if ok and type(text) == "string" then
    text = text:gsub("^0", "")
    return text
  end
  return nil
end

-- Long phrase for the popup: "in bank 1, in mailbox 2 (seen 3:10 PM)" or "not owned".
function WR.LocationPhrase(loc)
  loc = loc or {}
  local bank, mail = loc.bank or 0, loc.mail or 0
  if bank <= 0 and mail <= 0 then
    return "not owned"
  end
  local parts = {}
  if bank > 0 then
    parts[#parts + 1] = "in bank " .. bank
  end
  if mail > 0 then
    local bit = "in mailbox " .. mail
    if (loc.mailPending or 0) > 0 and (loc.mailCached or 0) == 0 then
      bit = bit .. " (from today's purchases)"
    elseif loc.seen then
      local when = FormatSeen(loc.seen)
      if when then
        bit = bit .. " (seen " .. when .. ")"
      end
    end
    parts[#parts + 1] = bit
  end
  return table.concat(parts, ", ")
end

-- Compact tags for #4: "bank 1, mail 1" or nil if neither.
function WR.LocationTag(loc)
  loc = loc or {}
  local parts = {}
  if (loc.bank or 0) > 0 then
    parts[#parts + 1] = "bank " .. loc.bank
  end
  if (loc.mail or 0) > 0 then
    parts[#parts + 1] = "mail " .. loc.mail
  end
  if #parts == 0 then
    return nil
  end
  return table.concat(parts, ", ")
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
    local loc = WR.ItemLocations(rec.itemId)
    rec.have = loc.bags or 0
    rec.bags = loc.bags or 0
    rec.bank = loc.bank or 0
    rec.mail = loc.mail or 0
    rec.mailCached = loc.mailCached or 0
    rec.mailPending = loc.mailPending or 0
    rec.seen = loc.seen
    rec.where = WR.LocationPhrase(loc)
    rec.tag = WR.LocationTag(loc)
    rec.label = ItemLabel(rec.itemId, rec.name)
    -- Start run and Check bags only count what is in bags, not bank or mail.
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
    local where = rec.where or "not owned"
    lines[#lines + 1] = string.format("%s  |cffff8080%d/%d|r  %s%s", rec.label or "item", rec.have or 0, rec.need or 1, where, forWrit)
  end
  return lines
end

-- buttons is a list of { text = "...", onClick = fn }.
local function PlaceButtons(buttons)
  local dlg = bagDlg
  if not dlg.btn3 then
    local btn = CreateFrame("Button", nil, dlg, "UIPanelButtonTemplate")
    btn:SetSize(120, 22)
    dlg.btn3 = btn
  end
  local slots = { dlg.btn1, dlg.btn2, dlg.btn3 }
  local i
  for i = 1, #slots do
    slots[i]:Hide()
    slots[i]:SetScript("OnClick", nil)
    slots[i]:ClearAllPoints()
  end
  local n = #buttons
  local width = n >= 3 and 118 or 120
  local gap = n >= 3 and 126 or 140
  local start = -((n - 1) * gap) / 2
  for i = 1, n do
    local b = slots[i]
    b:SetWidth(width)
    b:SetText(buttons[i].text)
    b:SetScript("OnClick", buttons[i].onClick)
    b:SetPoint("BOTTOM", dlg, "BOTTOM", start + (i - 1) * gap, 14)
    b:Show()
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

local lastBagSource, lastBagMode

local function RecheckBags()
  local source = lastBagSource
  local mode = lastBagMode or "check"
  if not source then
    return
  end
  local report = Run.CheckBags(source)
  if bagDlg then
    bagDlg.keepPending = true
  end
  Run.ShowBagReport(report, mode, pendingStart or source)
end

local function MissingHint(report)
  local hasBank, hasMail = false, false
  local i
  for i = 1, #(report.missing or {}) do
    local rec = report.missing[i]
    if (rec.bank or 0) > 0 then
      hasBank = true
    end
    if (rec.mail or 0) > 0 then
      hasMail = true
    end
  end
  if hasBank and hasMail then
    return "Visit the bank or mailbox, then Start run again."
  end
  if hasBank then
    return "Visit the bank, then Start run again."
  end
  if hasMail then
    return "Visit the mailbox, then Start run again."
  end
  return "Get the missing items into your bags, then Start run again."
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
  footer:SetText("Start run counts bags only. Items in the bank or mailbox do not count until you take them out.")
  dlg.footer = footer

  local function MakeBtn()
    local btn = CreateFrame("Button", nil, dlg, "UIPanelButtonTemplate")
    btn:SetSize(120, 22)
    return btn
  end
  dlg.btn1 = MakeBtn()
  dlg.btn2 = MakeBtn()
  dlg.btn3 = MakeBtn()

  dlg:SetScript("OnHide", function()
    -- ESC / close: drop a pending start so a later Start anyway cannot fire stale.
    if dlg.keepPending then
      dlg.keepPending = nil
      return
    end
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

-- mode is "check" or "start". Start run requires bags; missing items do
-- not start the tracker unless "Allow starting with missing items" is on.
function Run.ShowBagReport(report, mode, picked, source)
  if not report then
    return
  end
  mode = mode or "check"
  lastBagMode = mode
  lastBagSource = source or picked or lastBagSource
  local dlg = EnsureBagDialog()
  -- Keep a pending start across a refresh (Check again).
  local keep = pendingStart
  if dlg:IsShown() then
    dlg.keepPending = true
    dlg:Hide()
  end
  pendingStart = keep
  local allow = WR.db and WR.db.allowStartMissing and true or false
  if mode == "start" and report.missingCount and report.missingCount > 0 then
    pendingStart = picked or source or pendingStart
    dlg.mode = "startMissing"
    local lines = FormatMissingLines(report)
    LayoutList(dlg, "Missing items",
      string.format("|cffff4040Missing %d item%s in your bags:|r",
        report.missingCount, report.missingCount == 1 and "" or "s"),
      lines)
    dlg.footer:SetText(MissingHint(report))
    local buttons = {
      { text = "Check again", onClick = RecheckBags },
      { text = "Close", onClick = CancelPendingStart },
    }
    if allow then
      buttons = {
        { text = "Check again", onClick = RecheckBags },
        { text = "Start anyway", onClick = AcceptStartAnyway },
        { text = "Close", onClick = CancelPendingStart },
      }
    end
    PlaceButtons(buttons)
  elseif mode == "start" and (not report.missingCount or report.missingCount == 0)
      and not report.empty and not report.allDone then
    -- Recheck found everything: offer to start, do not auto-start.
    pendingStart = picked or source or pendingStart
    dlg.mode = "startReady"
    LayoutMessage(dlg, "WritRunner",
      string.format("|cff40ff40All %d items are in your bags. Good to go.|r", report.checkedCount or 0))
    PlaceButtons({
      { text = "Start run", onClick = AcceptStartAnyway },
      { text = "Close", onClick = CancelPendingStart },
    })
  else
    if mode ~= "start" then
      pendingStart = nil
    end
    dlg.mode = "check"
    if report.empty then
      LayoutMessage(dlg, "WritRunner", "Nothing to check. Set a budget so the plan has writs, then try again.")
      PlaceButtons({ { text = "OK", onClick = CancelPendingStart } })
    elseif report.allDone or report.checkedCount == 0 then
      LayoutMessage(dlg, "WritRunner", "Nothing left to check: every writ in the plan is already done today.")
      PlaceButtons({ { text = "OK", onClick = CancelPendingStart } })
    elseif report.missingCount and report.missingCount > 0 then
      local lines = FormatMissingLines(report)
      LayoutList(dlg, "Missing items",
        string.format("|cffff4040Missing %d item%s in your bags:|r",
          report.missingCount, report.missingCount == 1 and "" or "s"),
        lines)
      dlg.footer:SetText(MissingHint(report))
      PlaceButtons({
        { text = "Check again", onClick = RecheckBags },
        { text = "Close", onClick = CancelPendingStart },
      })
    else
      LayoutMessage(dlg, "WritRunner",
        string.format("|cff40ff40All %d items are in your bags. Good to go.|r", report.checkedCount or 0))
      PlaceButtons({ { text = "OK", onClick = CancelPendingStart } })
    end
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
    plannedCost = 0,
    actualSpent = 0,
    pouchGold = 0,
    pouchOpened = 0,
    questGold = 0,
  }
  if WR.Ledger and WR.Ledger.OnRunStart then
    WR.Ledger.OnRunStart(picked)
  end
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

-- Finish a run: save history, show the summary (unless silent / daily
-- reset), then clear. End() is the player-facing entry: it warns first
-- when Coin Pouches are still unopened.
function Run.Finish(reason)
  local db = DB()
  if not db or not db.run or not db.run.active then
    if db then
      db.run = { active = false, trackerShown = false }
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
  if WR.Ledger and WR.Ledger.FinishRun then
    WR.Ledger.FinishRun(reason)
  end
  db.run.active = false
  db.run.watch = nil
  -- Clear fully so /reload does not restore a finished run. History lives
  -- in WritRunnerDB.runHistory.
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

function Run.End(reason)
  local db = DB()
  if not db or not db.run or not db.run.active then
    return Run.Finish(reason)
  end
  if reason ~= "daily reset" and reason ~= "silent" then
    if WR.Ledger and WR.Ledger.ConfirmEnd and WR.Ledger.ConfirmEnd(reason) then
      return
    end
  end
  return Run.Finish(reason)
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
    if WR.Ledger and WR.Ledger.OnRunComplete then
      WR.Ledger.OnRunComplete()
    end
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


------------------------------------------------------------------------
-- Mail cache and a one-line hint when the bank or mailbox is open and
-- a plan item is sitting there. Own frame + events only; no secure hooks.
------------------------------------------------------------------------

local function PlanNeed()
  local need = {}
  local source
  if Run.IsActive and Run.IsActive() and Run.Steps then
    source = Run.Steps()
  elseif WR.UI and WR.UI.GetPicked then
    source = WR.UI.GetPicked()
  end
  if type(source) ~= "table" then
    return need
  end
  local i
  for i = 1, #source do
    local entry = source[i]
    local w = entry
    if type(entry) == "table" and entry.writ then
      w = entry.writ
    end
    if type(w) == "table" then
      if w.writItemId then
        need[w.writItemId] = (need[w.writItemId] or 0) + 1
      end
      if w.requiredItemId then
        need[w.requiredItemId] = (need[w.requiredItemId] or 0) + (w.requiredCount or 1)
      end
    end
  end
  return need
end

local lastHintAt, lastHintKey = 0, nil

local function HintPlanItems(place)
  local need = PlanNeed()
  local names, n, id = {}, 0
  for id in pairs(need) do
    local loc = WR.ItemLocations(id)
    local short = (loc.bags or 0) < (need[id] or 1)
    local there = 0
    if place == "mailbox" then
      there = loc.mail or 0
    else
      there = loc.bank or 0
    end
    if short and there > 0 then
      n = n + 1
      if #names < 3 then
        names[#names + 1] = ItemLabel(id)
      end
    end
  end
  if n == 0 then
    return
  end
  local key = place .. ":" .. n
  local now = Now()
  if lastHintKey == key and (now - lastHintAt) < 2 then
    return
  end
  lastHintKey, lastHintAt = key, now
  local list = table.concat(names, ", ")
  if n > 3 then
    list = list .. ", +" .. (n - 3) .. " more"
  end
  local verb = n == 1 and "is" or "are"
  WR.Print(string.format("%d plan item%s %s in the %s (%s). Take %s out, then Start run.",
    n, n == 1 and "" or "s", verb, place, list, n == 1 and "it" or "them"))
end

local locEv = CreateFrame("Frame")
local LOC_EVENTS = {
  "MAIL_SHOW", "MAIL_INBOX_UPDATE", "MAIL_CLOSED",
  "BANKFRAME_OPENED", "BANKFRAME_CLOSED",
  "PLAYER_INTERACTION_MANAGER_FRAME_SHOW",
}
local ei
for ei = 1, #LOC_EVENTS do
  pcall(locEv.RegisterEvent, locEv, LOC_EVENTS[ei])
end
locEv:SetScript("OnEvent", function(_, event, a1)
  if event == "MAIL_SHOW" or event == "MAIL_INBOX_UPDATE" then
    Run.ScanMailbox()
    if event == "MAIL_SHOW" then
      HintPlanItems("mailbox")
    end
    return
  end
  if event == "BANKFRAME_OPENED" then
    HintPlanItems("bank")
    return
  end
  if event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" then
    local t = Enum and Enum.PlayerInteractionType
    if t then
      if a1 == t.MailInfo or (t.Mailbox and a1 == t.Mailbox) then
        Run.ScanMailbox()
        HintPlanItems("mailbox")
      elseif a1 == t.Banker or (t.AccountBanker and a1 == t.AccountBanker) then
        HintPlanItems("bank")
      end
    end
  end
end)
