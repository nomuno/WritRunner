-- Step-through buyer at the Auction House (1.3.0).
--
-- WoW: Forever (interface 16001) runs the modern auction house: C_AuctionHouse
-- with all its functions, and the legacy QueryAuctionItems /
-- GetAuctionItemInfo / PlaceAuctionBid events never fire. So this uses:
--   search:    C_AuctionHouse.SendSearchQuery(itemKey, sorts, true)
--              -> COMMODITY_SEARCH_RESULTS_UPDATED or ITEM_SEARCH_RESULTS_UPDATED
--   commodity: StartCommoditiesPurchase(itemID, qty)  [hardware event: Accept]
--              -> COMMODITY_PRICE_UPDATED -> ConfirmCommoditiesPurchase
--              -> COMMODITY_PURCHASE_SUCCEEDED / _FAILED
--   item:      PlaceBid(auctionID, buyoutAmount)       [hardware event: Accept]
--              one listing (stack) per click
--              -> AUCTION_HOUSE_PURCHASE_COMPLETED / AUCTION_HOUSE_SHOW_ERROR
-- The popup is the addon's own frame (no StaticPopupDialogs), and nothing
-- here registers the combat log.

local WR = WritRunner
WR.Buyer = WR.Buyer or {}
local B = WR.Buyer

local SEARCH_TIMEOUT = 8
local BUY_TIMEOUT = 6
local THROTTLE_RETRY = 1

local ahOpen = false
local ahBtn
local manualConfirm = false -- set if the client refuses an automatic confirm
local frame
local token = 0
local st = { state = "idle" }

local function API()
  return C_AuctionHouse
end

local function Money()
  return (GetMoney and GetMoney()) or 0
end

local function After(secs, fn)
  if C_Timer and C_Timer.After then
    C_Timer.After(secs, fn)
  end
end

-- Forever shows the classic AuctionFrame (Blizzard_AuctionUI: title
-- "Browse Auctions", Search, bottom tabs) even though purchases go
-- through C_AuctionHouse. Retail-style AuctionHouseFrame may be absent.
local function IsFrame(obj)
  if type(obj) ~= "table" then
    return false
  end
  local ok, typ = pcall(function()
    return obj.GetObjectType and obj:GetObjectType()
  end)
  return ok and typ ~= nil
end

local function Shown(f)
  return f and f.IsShown and f:IsShown() and true or false
end

function B.AHFrame()
  local ah = rawget(_G, "AuctionHouseFrame") or AuctionHouseFrame
  local af = rawget(_G, "AuctionFrame") or AuctionFrame
  if Shown(af) then
    return af, "AuctionFrame"
  end
  if Shown(ah) then
    return ah, "AuctionHouseFrame"
  end
  if af then
    return af, "AuctionFrame"
  end
  if ah then
    return ah, "AuctionHouseFrame"
  end
  return nil, nil
end

local function Color(text, hex)
  return "|cff" .. hex .. text .. "|r"
end

-- Purchases are tracked per daily cycle, so they survive Re-plan and /reload.
-- Bought items may arrive by mail, so "have" = bags, or the bag count when we
-- first bought plus what we bought, whichever is larger (no double count if
-- the client puts them straight into bags).
local function Log()
  local db = WR.db
  if not db then
    return nil
  end
  local lg = db.buyLog
  if type(lg) ~= "table" or (lg.resetAt and db.resetAt and math.abs(lg.resetAt - db.resetAt) > 120) then
    lg = { resetAt = db.resetAt, bought = {}, base = {}, spent = 0 }
    db.buyLog = lg
  end
  lg.bought = lg.bought or {}
  lg.base = lg.base or {}
  lg.spent = lg.spent or 0
  return lg
end

function B.Bought(itemId)
  local lg = Log()
  return lg and lg.bought[itemId] or 0
end

function B.Have(itemId)
  local bags = WR.GetBagCount and WR.GetBagCount(itemId) or 0
  local lg = Log()
  if not lg or not lg.bought[itemId] then
    return bags
  end
  return math.max(bags, (lg.base[itemId] or 0) + lg.bought[itemId])
end

function B.Spent()
  local lg = Log()
  return lg and lg.spent or 0
end

local function NoteBase(itemId)
  local lg = Log()
  if lg and not lg.bought[itemId] then
    lg.base[itemId] = WR.GetBagCount and WR.GetBagCount(itemId) or 0
  end
end

local function RecordBuy(itemId, qty, copper, cover)
  st.sessionSpent = (st.sessionSpent or 0) + (copper or 0)
  if WR.Ledger and WR.Ledger.RecordPurchase then
    WR.Ledger.RecordPurchase(itemId, qty, copper, "buyer", cover)
    return
  end
  local lg = Log()
  if not lg then
    return
  end
  if not lg.base[itemId] then
    lg.base[itemId] = 0
  end
  lg.bought[itemId] = (lg.bought[itemId] or 0) + (qty or 0)
  lg.costs = lg.costs or {}
  lg.costs[itemId] = (lg.costs[itemId] or 0) + (copper or 0)
  lg.spent = lg.spent + (copper or 0)
end

function B.IsAHOpen()
  if ahOpen then
    return true
  end
  local f = B.AHFrame and select(1, B.AHFrame())
  return Shown(f)
end

function B.IsActive()
  return st.state ~= "idle"
end

-- Current locked plan: shop items and which writs use them.
local function Plan()
  local picked, plan = {}, { shop = {} }
  if WR.UI and WR.UI.GetPicked then
    picked, plan = WR.UI.GetPicked()
  end
  local shop = {}
  local i
  for i = 1, #((plan and plan.shop) or {}) do
    local item = plan.shop[i]
    shop[item.itemId] = item
  end
  return picked or {}, shop
end

local function Need(itemId)
  local _, shop = Plan()
  local item = shop[itemId]
  if not item then
    return 0, 0, nil
  end
  local have = B.Have(itemId)
  local need = item.count - have
  if need < 0 then
    need = 0
  end
  return need, item.count, item
end

local function OriginalUnit(itemId)
  local lock = WR.UI and WR.UI.ActiveLock and WR.UI.ActiveLock()
  local _, shop = Plan()
  return (lock and lock.prices and lock.prices[itemId]) or (shop[itemId] and shop[itemId].copperEach)
end

local function WritsUsing(itemId)
  local picked = Plan()
  local out = {}
  local i
  for i = 1, #picked do
    local w = picked[i].writ
    if w and (w.writItemId == itemId or w.requiredItemId == itemId) then
      out[#out + 1] = w
    end
  end
  return out
end

local function ItemName(itemId)
  local _, shop = Plan()
  if shop[itemId] and shop[itemId].name then
    return shop[itemId].name
  end
  if C_Item and C_Item.GetItemNameByID then
    local ok, n = pcall(C_Item.GetItemNameByID, itemId)
    if ok and n then
      return n
    end
  end
  return "item " .. tostring(itemId)
end

local function ItemIcon(itemId)
  if C_Item and C_Item.GetItemIconByID then
    local ok, icon = pcall(C_Item.GetItemIconByID, itemId)
    if ok and icon then
      return icon
    end
  end
  if GetItemIcon then
    local ok, icon = pcall(GetItemIcon, itemId)
    if ok and icon then
      return icon
    end
  end
  return "Interface\\Icons\\INV_Misc_QuestionMark"
end

local function PlannedTotal()
  -- Scanned unit x the quantity the plan needs. Never a listing's stack size.
  local _, shop = Plan()
  local total = 0
  local id, item
  for id, item in pairs(shop) do
    total = total + (OriginalUnit(id) or 0) * item.count
  end
  return total
end

-- Out-of-pocket for this plan (full listing buyouts, no proration of extras),
-- not the daily buy log which may include earlier purchases.
local function PlanSpent()
  if WR.Ledger and WR.Ledger.SpentForShop then
    local _, shop = Plan()
    local n = WR.Ledger.SpentForShop(shop)
    if n and n > 0 then
      return n
    end
  end
  return st.sessionSpent or 0
end

-- Queue: writ by writ in plan order, each writ's item followed by the item
-- it pairs with, so buying one keeps its partner right behind it.
local function BuildQueue()
  local picked = Plan()
  local queue, seen = {}, {}
  local i
  for i = 1, #picked do
    local w = picked[i].writ
    local ids = { w.writItemId, w.requiredItemId }
    local k
    for k = 1, 2 do
      local id = ids[k]
      if id and not seen[id] then
        seen[id] = true
        queue[#queue + 1] = id
      end
    end
  end
  return queue
end

------------------------------------------------------------------------
-- Popup
------------------------------------------------------------------------

local Render

local function MakeBtn(parent, text, w, onClick)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetSize(w, 22)
  b:SetText(text)
  b:SetScript("OnClick", onClick)
  return b
end

local function EnsureFrame()
  if frame then
    return frame
  end
  local f = CreateFrame("Frame", "WritRunnerBuyerFrame", UIParent, "BackdropTemplate")
  f:SetSize(440, 360)
  f:SetPoint("CENTER", UIParent, "CENTER", 260, 60)
  f:SetFrameStrata("DIALOG")
  pcall(function() f:SetToplevel(true) end)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", f.StopMovingOrSizing)
  f:SetClampedToScreen(true)
  if f.SetBackdrop then
    f:SetBackdrop({
      bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
      edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
      tile = true, tileSize = 32, edgeSize = 16,
      insets = { left = 6, right = 6, top = 6, bottom = 6 },
    })
    f:SetBackdropColor(0, 0, 0, 0.94)
  end
  f:Hide()

  f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  f.title:SetPoint("TOP", 0, -14)
  f.title:SetText("WritRunner: buy step by step")

  f.progress = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  f.progress:SetPoint("TOP", 0, -34)

  f.icon = f:CreateTexture(nil, "ARTWORK")
  f.icon:SetSize(36, 36)
  f.icon:SetPoint("TOPLEFT", 20, -54)

  f.name = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
  f.name:SetPoint("TOPLEFT", f.icon, "TOPRIGHT", 10, -2)
  f.name:SetPoint("RIGHT", f, "RIGHT", -20, 0)
  f.name:SetJustifyH("LEFT")

  f.qty = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  f.qty:SetPoint("TOPLEFT", f.name, "BOTTOMLEFT", 0, -4)
  f.qty:SetPoint("RIGHT", f, "RIGHT", -20, 0)
  f.qty:SetJustifyH("LEFT")

  f.body = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  f.body:SetPoint("TOPLEFT", 20, -100)
  f.body:SetPoint("RIGHT", f, "RIGHT", -20, 0)
  f.body:SetJustifyH("LEFT")
  f.body:SetJustifyV("TOP")
  f.body:SetSpacing(3)

  f.status = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  f.status:SetPoint("BOTTOMLEFT", 20, 44)
  f.status:SetPoint("RIGHT", f, "RIGHT", -20, 0)
  f.status:SetJustifyH("LEFT")

  f.accept = MakeBtn(f, "Accept", 110, function() B.OnAccept() end)
  f.accept:SetPoint("BOTTOMLEFT", 16, 14)
  f.reject = MakeBtn(f, "Reject", 96, function() B.OnReject() end)
  f.reject:SetPoint("LEFT", f.accept, "RIGHT", 6, 0)
  f.skip = MakeBtn(f, "Skip", 80, function() B.OnSkip() end)
  f.skip:SetPoint("LEFT", f.reject, "RIGHT", 6, 0)
  f.stop = MakeBtn(f, "Stop", 80, function() B.Stop() end)
  f.stop:SetPoint("LEFT", f.skip, "RIGHT", 6, 0)

  local tip = function(btn, title, text)
    btn:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_TOP")
      GameTooltip:SetText(title)
      GameTooltip:AddLine(text, 1, 1, 1, true)
      GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
  end
  tip(f.accept, "Accept", "Buys at the live price shown. Commodities buy the whole amount in one click; separate listings take one click each.")
  tip(f.reject, "Reject", "Do not buy this. Every writ that needs it (and the item it pairs with) is dropped from the locked plan, the route is rebuilt and the Auctionator list updated. Click twice to confirm.")
  tip(f.skip, "Skip", "Decide later. The item comes back after the rest of the list.")
  tip(f.stop, "Stop", "Close the buyer. What you bought is kept; /writs buy picks up where you left off.")

  if UISpecialFrames then
    tinsert(UISpecialFrames, "WritRunnerBuyerFrame")
  end
  f:SetScript("OnHide", function()
    if st.state ~= "idle" then
      B.Stop(true)
    end
  end)
  frame = f
  return f
end

local function Diff(live, orig)
  if not live or not orig then
    return Color("no scanned price to compare", "999999")
  end
  local d = live - orig
  if math.abs(d) < 1 then
    return Color("same as scanned", "cccccc")
  end
  local pct = orig > 0 and math.floor(math.abs(d) * 100 / orig + 0.5) or 0
  if d > 0 then
    return Color(string.format("%s higher (+%d%%)", WR.MoneyText(d), pct), "ff5555")
  end
  return Color(string.format("%s lower (-%d%%)", WR.MoneyText(-d), pct), "55ff55")
end

local function ProgressText()
  local queue = st.queue or {}
  local n = #queue
  local pos = math.min(st.pos or 1, math.max(n, 1))
  local skipped = st.skipped and #st.skipped or 0
  local extra = skipped > 0 and string.format("  ·  %d skipped", skipped) or ""
  return string.format("Item %d of %d%s  ·  Spent %s of planned %s", pos, n, extra,
    WR.MoneyText(PlanSpent()), WR.MoneyText(PlannedTotal()))
end

local function NextCost()
  local q = st.quote
  if not q then
    return nil, 0
  end
  if q.kind == "item" then
    local s = q.stacks[1]
    return s and s.buyout, s and s.qty or 0
  end
  return q.total, q.qty
end

function Render()
  local f = EnsureFrame()
  local id = st.itemId
  f.progress:SetText(ProgressText())
  f.reject:SetText(st.rejectArmed and "Confirm reject" or "Reject")
  f.accept:Enable()
  f.reject:Show()
  f.skip:Show()
  f.stop:SetText("Stop")

  if st.state == "done" then
    f.icon:SetTexture("Interface\\Icons\\INV_Misc_Coin_01")
    f.name:SetText("Shopping done")
    f.qty:SetText("")
    local lines = {
      string.format("Spent %s of planned %s.", WR.MoneyText(PlanSpent()), WR.MoneyText(PlannedTotal())),
    }
    if st.removed and #st.removed > 0 then
      lines[#lines + 1] = string.format("Removed from the plan: %s.", table.concat(st.removed, ", "))
    end
    lines[#lines + 1] = "Collect your purchases from the mailbox, then Start run in #5."
    f.body:SetText(table.concat(lines, "\n"))
    f.status:SetText(st.msg or "")
    f.accept:SetText("Close")
    f.reject:Hide()
    f.skip:Hide()
    f.stop:SetText("Close")
    return
  end

  local need, count = Need(id)
  local have = B.Have(id)
  f.icon:SetTexture(ItemIcon(id))
  f.name:SetText(ItemName(id))
  f.qty:SetText(string.format("Need %d  (plan %d, have %d%s)", need, count, have,
    B.Bought(id) > 0 and string.format(", %d bought today", B.Bought(id)) or ""))

  local orig = OriginalUnit(id)
  local lines = {}
  local plannedNeed = math.max(need, 1)
  lines[#lines + 1] = string.format("Scanned: %s each  ·  planned %s for %d needed",
    WR.MoneyText(orig), orig and WR.MoneyText(orig * plannedNeed) or "unknown", plannedNeed)

  local writs = WritsUsing(id)
  local names, partners, seen = {}, {}, {}
  local i
  for i = 1, #writs do
    local w = writs[i]
    names[#names + 1] = (w.writItemName or "Writ"):gsub("^Craftsman's Writ: ", "")
    local other = (w.writItemId == id) and w.requiredItemId or w.writItemId
    if other and not seen[other] then
      seen[other] = true
      partners[#partners + 1] = ItemName(other)
    end
  end

  if st.state == "searching" then
    lines[#lines + 1] = Color("Searching the Auction House...", "cccccc")
    f.accept:SetText("Accept")
    f.accept:Disable()
  elseif st.state == "notfound" or st.state == "error" then
    lines[#lines + 1] = Color(st.state == "notfound" and "None listed on the Auction House right now." or "The search did not finish.", "ff5555")
    lines[#lines + 1] = "Reject to drop its writs, Skip to come back later, or search again."
    f.accept:SetText("Search again")
  elseif st.state == "quoted" or st.state == "pricechanged" or st.state == "confirming" or st.state == "buying" then
    local q = st.quote
    local cost, qty = NextCost()
    if st.state == "pricechanged" and st.pending then
      cost, qty = st.pending.newTotal, st.pending.qty
    end
    -- Out-of-pocket vs planned for the needed quantity this payment fills,
    -- never scanned unit x the listing's stack size.
    local cover = (q and q.clickCover) or 0
    if st.state == "pricechanged" and st.pending and st.pending.cover then
      cover = st.pending.cover
    elseif cover == 0 and qty and qty > 0 then
      cover = qty
      if q and q.kind == "item" and need < qty then
        cover = need
      end
    end
    local extras = (q and q.clickExtras) or ((qty and cover) and math.max(0, qty - cover)) or 0
    local plannedClick = orig and cover > 0 and (orig * cover) or nil
    lines[#lines + 1] = string.format("Live: pay %s for %d   %s",
      WR.MoneyText(cost), qty or 0, Diff(cost, plannedClick))
    local liveUnit = (cost and qty and qty > 0) and (cost / qty) or nil
    if liveUnit then
      local extraTxt = extras > 0 and string.format("  ·  extra %d (not counted as savings)", extras) or ""
      lines[#lines + 1] = Color(string.format("%s each%s", WR.MoneyText(liveUnit), extraTxt), "aaaaaa")
    end
    if q and q.kind == "item" then
      local nStacks = #q.stacks
      if nStacks > 1 then
        lines[#lines + 1] = string.format("Separate listings: %d to cover %d (one click each). This click buys %d.", nStacks, need, qty or 0)
        local plannedAll = orig and (orig * need) or nil
        lines[#lines + 1] = string.format("To cover %d needed: pay %s vs planned %s   %s",
          need, WR.MoneyText(q.total), plannedAll and WR.MoneyText(plannedAll) or "unknown",
          Diff(q.total, plannedAll))
      end
      if q.got and q.got > need then
        lines[#lines + 1] = Color(string.format("You will receive %d (%d extra, not counted as savings).", q.got, q.got - need), "cccccc")
      end
    end
    if q and q.short then
      lines[#lines + 1] = Color(string.format("Only %d on the AH. Accept buys those; the rest stays on the list.", q.avail), "ffd100")
    end
    if st.state == "pricechanged" then
      if st.pending and st.pending.newTotal and st.pending.newTotal > st.pending.total then
        lines[#lines + 1] = Color(string.format("The price went up from %s to %s while confirming. Accept pays the new price.",
          WR.MoneyText(st.pending.total), WR.MoneyText(cost)), "ff5555")
        f.accept:SetText("Pay new price")
      else
        lines[#lines + 1] = Color(string.format("Final price %s. Click Confirm to pay it.", WR.MoneyText(cost)), "ffd100")
        f.accept:SetText("Confirm")
      end
    elseif st.state == "confirming" or st.state == "buying" then
      lines[#lines + 1] = Color("Buying...", "cccccc")
      f.accept:SetText("Buying...")
      f.accept:Disable()
    else
      if q and q.kind == "item" and #q.stacks > 1 then
        f.accept:SetText("Buy 1 of " .. #q.stacks)
      else
        f.accept:SetText("Accept")
      end
    end
    local money = Money()
    if cost and money < cost and (st.state == "quoted" or st.state == "pricechanged") then
      lines[#lines + 1] = Color(string.format("Not enough gold: need %s, you have %s.", WR.MoneyText(cost), WR.MoneyText(money)), "ff5555")
      f.accept:Disable()
    end
  end

  if #names > 0 then
    lines[#lines + 1] = Color("For: " .. table.concat(names, ", "), "d4a017")
  end
  if #partners > 0 then
    lines[#lines + 1] = Color("Pairs with: " .. table.concat(partners, ", "), "aaaaaa")
  end
  if st.rejectArmed then
    lines[#lines + 1] = Color(string.format("Reject drops %d writ%s: %s. Click Confirm reject.", #names, #names == 1 and "" or "s", table.concat(names, ", ")), "ff8800")
  end
  f.body:SetText(table.concat(lines, "\n"))
  f.status:SetText(st.msg or "")
end

------------------------------------------------------------------------
-- Search and quote
------------------------------------------------------------------------

local Search, NextStep

-- Compare out-of-pocket `paid` to planned (scanned unit x cover), never
-- scanned unit x stack size. `cover` is how many of the needed quantity
-- this payment actually fills. Extras are not savings.
function B.CompareOffer(paid, origUnit, cover)
  cover = cover or 0
  if cover < 0 then
    cover = 0
  end
  local planned = (origUnit and cover > 0) and (origUnit * cover) or nil
  if not paid or not planned then
    return nil, planned, nil
  end
  return paid - planned, planned, planned > 0 and math.floor(math.abs(paid - planned) * 100 / planned + 0.5) or 0
end

-- Pick unsplittable item listings that minimize total buyout to cover `need`.
-- A cheap 22-stack only wins a single if its full buyout is lower, and vice versa.
function B.SelectItemListings(listings, need)
  listings = listings or {}
  need = need or 0
  local avail, i = 0
  for i = 1, #listings do
    avail = avail + (listings[i].qty or 0)
  end
  local function pack(stacks, total, got, short)
    local cover = got
    if cover > need then
      cover = need
    end
    if cover < 0 then
      cover = 0
    end
    local extras = got - need
    if extras < 0 then
      extras = 0
    end
    return {
      stacks = stacks,
      total = total,
      got = got,
      cover = cover,
      extras = extras,
      short = short and true or false,
      avail = avail,
    }
  end
  if need <= 0 or avail <= 0 then
    return pack({}, 0, 0, need > 0)
  end
  if avail < need then
    local stacks, total, got = {}, 0, 0
    for i = 1, #listings do
      stacks[#stacks + 1] = listings[i]
      total = total + (listings[i].buyout or 0)
      got = got + (listings[i].qty or 0)
    end
    return pack(stacks, total, got, true)
  end
  -- 0-1 DP: min cost to reach at least `need`. State is capped at need;
  -- the listing's full buyout is always paid (extras do not reduce cost).
  local dp = {}
  dp[0] = { cost = 0, got = 0, n = 0, take = nil, from = nil }
  for i = 1, #listings do
    local L = listings[i]
    local q, b = L.qty or 1, L.buyout or 0
    local keys, k = {}
    for k = 0, need do
      if dp[k] then
        keys[#keys + 1] = k
      end
    end
    local ki
    for ki = 1, #keys do
      k = keys[ki]
      if k < need then
        local rec = dp[k]
        local nk = k + q
        if nk > need then
          nk = need
        end
        local newCost = rec.cost + b
        local newGot = rec.got + q
        local newN = rec.n + 1
        local cur = dp[nk]
        local better = not cur
        if cur then
          if newCost < cur.cost then
            better = true
          elseif newCost == cur.cost then
            if newGot < cur.got then
              better = true
            elseif newGot == cur.got and newN < cur.n then
              better = true
            end
          end
        end
        if better then
          dp[nk] = { cost = newCost, got = newGot, n = newN, take = i, from = rec }
        end
      end
    end
  end
  local best = dp[need]
  if not best then
    return pack({}, 0, 0, true)
  end
  local used = {}
  local node = best
  while node and node.take do
    used[#used + 1] = listings[node.take]
    node = node.from
  end
  local stacks = {}
  for i = #used, 1, -1 do
    stacks[#stacks + 1] = used[i]
  end
  return pack(stacks, best.cost, best.got, false)
end

local function Quote()
  local id = st.itemId
  local need = Need(id)
  local listings = st.listings or {}
  local q = { kind = st.kind, qty = 0, total = 0, avail = 0, stacks = {}, got = 0, cover = 0, extras = 0 }
  local i
  for i = 1, #listings do
    q.avail = q.avail + listings[i].qty
  end
  if st.kind == "commodity" then
    local left = need
    for i = 1, #listings do
      if left <= 0 then
        break
      end
      local take = math.min(left, listings[i].qty)
      q.qty = q.qty + take
      q.total = q.total + take * listings[i].unit
      left = left - take
    end
    q.got = q.qty
    q.cover = q.qty
    q.extras = 0
    q.clickCover = q.qty
    q.clickExtras = 0
  else
    local sel = B.SelectItemListings(listings, need)
    q.stacks = sel.stacks
    q.total = sel.total
    q.got = sel.got
    q.cover = sel.cover
    q.extras = sel.extras
    q.avail = sel.avail > 0 and sel.avail or q.avail
    local first = q.stacks[1]
    q.qty = first and first.qty or 0
    q.clickCover = first and math.min(need, first.qty) or 0
    if q.clickCover < 0 then
      q.clickCover = 0
    end
    q.clickExtras = q.qty - q.clickCover
    if q.clickExtras < 0 then
      q.clickExtras = 0
    end
  end
  q.short = q.avail < need
  st.quote = q
  if q.avail <= 0 then
    st.state = "notfound"
  else
    st.state = "quoted"
  end
end

local function ReadCommodity(itemId)
  local A = API()
  local out = {}
  local n = (A.GetNumCommoditySearchResults and A.GetNumCommoditySearchResults(itemId)) or 0
  local i
  for i = 1, n do
    local ok, r = pcall(A.GetCommoditySearchResultInfo, itemId, i)
    if ok and type(r) == "table" and r.unitPrice and r.quantity then
      local qty = r.quantity - (r.numOwnerItems or 0)
      if qty > 0 then
        out[#out + 1] = { unit = r.unitPrice, qty = qty }
      end
    end
  end
  table.sort(out, function(a, b) return a.unit < b.unit end)
  st.kind, st.listings = "commodity", out
end

local function ReadItems(itemKey)
  local A = API()
  local out = {}
  local n = (A.GetNumItemSearchResults and A.GetNumItemSearchResults(itemKey)) or 0
  local i
  for i = 1, n do
    local ok, r = pcall(A.GetItemSearchResultInfo, itemKey, i)
    if ok and type(r) == "table" and r.auctionID and r.buyoutAmount and r.buyoutAmount > 0 and not r.containsOwnerItem then
      local qty = r.quantity or 1
      out[#out + 1] = { auctionID = r.auctionID, qty = qty, buyout = r.buyoutAmount, unit = r.buyoutAmount / qty }
    end
  end
  table.sort(out, function(a, b)
    if a.unit ~= b.unit then
      return a.unit < b.unit
    end
    return a.buyout < b.buyout
  end)
  st.kind, st.listings = "item", out
end

function Search(itemId)
  token = token + 1
  local my = token
  st.itemId = itemId
  st.state = "searching"
  st.quote, st.listings, st.kind, st.pending = nil, nil, nil, nil
  st.rejectArmed = false
  local A = API()
  if not A or not A.SendSearchQuery or not A.MakeItemKey then
    st.state = "error"
    st.msg = "This client has no C_AuctionHouse search API."
    Render()
    return
  end
  if not B.IsAHOpen() then
    st.state = "error"
    st.msg = "Open the Auction House first."
    Render()
    return
  end
  if A.IsThrottledMessageSystemReady and not A.IsThrottledMessageSystemReady() then
    st.waitThrottle = (st.waitThrottle or 0) + 1
    Render()
    if st.waitThrottle <= SEARCH_TIMEOUT then
      After(THROTTLE_RETRY, function()
        if my == token and st.state == "searching" then
          Search(itemId)
        end
      end)
      return
    end
  end
  st.waitThrottle = 0
  local sorts = { { sortOrder = (Enum and Enum.AuctionHouseSortOrder and Enum.AuctionHouseSortOrder.Price) or 0, reverseSort = false } }
  local okKey, key = pcall(A.MakeItemKey, itemId)
  local ok, err = false, "no item key"
  if okKey and key then
    st.itemKey = key
    ok, err = pcall(A.SendSearchQuery, key, sorts, true)
  end
  if not ok then
    st.state = "error"
    st.msg = "Search failed: " .. tostring(err)
    Render()
    return
  end
  Render()
  After(SEARCH_TIMEOUT, function()
    if my == token and st.state == "searching" then
      -- No results event at all: treat as nothing listed, but say so.
      st.state = "notfound"
      st.msg = "No answer from the Auction House for this item (nothing listed, or the search was throttled)."
      Render()
    end
  end)
end

function NextStep()
  local queue = st.queue or {}
  while true do
    while st.pos <= #queue and Need(queue[st.pos]) <= 0 do
      st.pos = st.pos + 1
    end
    if st.pos <= #queue then
      Search(queue[st.pos])
      return
    end
    -- End of the list: bring skipped items back once more.
    local back = {}
    local i
    for i = 1, #(st.skipped or {}) do
      if Need(st.skipped[i]) > 0 then
        back[#back + 1] = st.skipped[i]
      end
    end
    st.skipped = {}
    if #back == 0 then
      st.state = "done"
      st.itemId = nil
      Render()
      if WR.UI and WR.UI.Refresh and WR.UI.frame and WR.UI.frame:IsShown() then
        WR.UI.Refresh()
      end
      return
    end
    st.queue = back
    queue = back
    st.pos = 1
    st.msg = "Back to the items you skipped."
  end
end

------------------------------------------------------------------------
-- Purchase
------------------------------------------------------------------------

local function Finish(success, cost, why)
  local p = st.pending
  if not p then
    return
  end
  st.pending = nil
  token = token + 1
  local id = st.itemId
  if success then
    RecordBuy(id, p.qty, cost or p.total, p.cover)
    st.msg = Color(string.format("Bought %d x %s for %s.", p.qty, ItemName(id), WR.MoneyText(cost or p.total)), "55ff55")
    if WR.UI and WR.UI.Refresh and WR.UI.frame and WR.UI.frame:IsShown() then
      WR.UI.Refresh()
    end
    if B.RefreshAHButton then
      B.RefreshAHButton()
    end
    if Need(id) > 0 then
      Search(id)
    else
      st.pos = st.pos + 1
      NextStep()
    end
  else
    st.msg = Color(why or "The purchase did not go through.", "ff5555") .. " Searching again."
    Search(id)
  end
end

local function ArmBuyTimeout()
  token = token + 1
  local my = token
  After(BUY_TIMEOUT, function()
    if my ~= token or not st.pending then
      return
    end
    local spent = (st.pending.money0 or 0) - Money()
    if spent > 0 then
      Finish(true, spent)
    else
      if st.pending.kind == "commodity" and st.pending.auto then
        -- The automatic confirm went nowhere: confirm by click from now on.
        manualConfirm = true
      end
      if st.pending.kind == "commodity" and API() and API().CancelCommoditiesPurchase then
        pcall(API().CancelCommoditiesPurchase)
      end
      Finish(false, nil, "No answer from the Auction House.")
    end
  end)
end

function B.OnAccept()
  if st.state == "done" then
    B.Stop()
    return
  end
  local A = API()
  local id = st.itemId
  if st.state == "notfound" or st.state == "error" then
    st.msg = nil
    Search(id)
    return
  end
  if st.state == "pricechanged" and st.pending then
    local ok, err = pcall(A.ConfirmCommoditiesPurchase, id, st.pending.qty)
    if not ok then
      Finish(false, nil, "Confirm failed: " .. tostring(err))
      return
    end
    st.pending.total = st.pending.newTotal or st.pending.total
    st.state = "buying"
    ArmBuyTimeout()
    Render()
    return
  end
  if st.state ~= "quoted" or not st.quote then
    return
  end
  local cost, qty = NextCost()
  if not cost or qty <= 0 then
    return
  end
  if Money() < cost then
    st.msg = Color("Not enough gold for this purchase.", "ff5555")
    Render()
    return
  end
  NoteBase(id)
  st.msg = nil
  st.rejectArmed = false
  if st.quote.kind == "commodity" then
    local cover = (st.quote and st.quote.clickCover) or qty
    st.pending = { kind = "commodity", qty = qty, total = cost, money0 = Money(), cover = cover }
    local ok, err = pcall(A.StartCommoditiesPurchase, id, qty)
    if not ok then
      st.pending = nil
      st.msg = Color("Could not start the purchase: " .. tostring(err), "ff5555")
      Render()
      return
    end
    st.state = "confirming"
  else
    local s = st.quote.stacks[1]
    local cover = (st.quote and st.quote.clickCover) or math.min(Need(id), s.qty or 0)
    st.pending = { kind = "item", qty = s.qty, total = s.buyout, auctionID = s.auctionID, money0 = Money(), cover = cover }
    local ok, err = pcall(A.PlaceBid, s.auctionID, s.buyout)
    if not ok then
      st.pending = nil
      st.msg = Color("Could not buy that listing: " .. tostring(err), "ff5555")
      Render()
      return
    end
    st.state = "buying"
  end
  ArmBuyTimeout()
  Render()
end

function B.OnSkip()
  if st.state == "confirming" or st.state == "buying" then
    return
  end
  if st.state == "pricechanged" and API() and API().CancelCommoditiesPurchase then
    pcall(API().CancelCommoditiesPurchase)
    st.pending = nil
  end
  st.skipped = st.skipped or {}
  st.skipped[#st.skipped + 1] = st.itemId
  st.msg = "Skipped " .. ItemName(st.itemId) .. "."
  st.pos = st.pos + 1
  NextStep()
end

function B.OnReject()
  if st.state == "confirming" or st.state == "buying" or st.state == "done" then
    return
  end
  if not st.rejectArmed then
    st.rejectArmed = true
    Render()
    return
  end
  st.rejectArmed = false
  if st.state == "pricechanged" and API() and API().CancelCommoditiesPurchase then
    pcall(API().CancelCommoditiesPurchase)
    st.pending = nil
  end
  local id = st.itemId
  local writs = WritsUsing(id)
  local qids, names = {}, {}
  local wasted = {}
  local i
  for i = 1, #writs do
    local w = writs[i]
    qids[#qids + 1] = w.questId
    names[#names + 1] = (w.writItemName or "Writ"):gsub("^Craftsman's Writ: ", "")
    local other = (w.writItemId == id) and w.requiredItemId or w.writItemId
    if other and B.Bought(other) > 0 then
      wasted[#wasted + 1] = ItemName(other)
    end
  end
  local synced = false
  if WR.UI and WR.UI.RemoveLockedWrits then
    synced = WR.UI.RemoveLockedWrits(qids)
  end
  st.removed = st.removed or {}
  for i = 1, #names do
    st.removed[#st.removed + 1] = names[i]
  end
  local msg = string.format("Removed %s. Route rebuilt%s.", table.concat(names, ", "),
    synced and ", Auctionator list updated" or "")
  if #wasted > 0 then
    msg = msg .. " Already bought for it: " .. table.concat(wasted, ", ") .. "."
  end
  st.msg = Color(msg, "ff8800")
  WR.Print(msg)
  st.pos = st.pos + 1
  NextStep()
end

function B.Stop(fromHide)
  if st.pending and st.pending.kind == "commodity" and st.state ~= "buying" and API() and API().CancelCommoditiesPurchase then
    pcall(API().CancelCommoditiesPurchase)
  end
  token = token + 1
  local wasActive = st.state ~= "idle" and st.state ~= "done"
  st = { state = "idle" }
  if frame and not fromHide and frame:IsShown() then
    frame:Hide()
  end
  if wasActive then
    WR.Print("Step-by-step buying stopped. What you bought is kept; /writs buy continues.")
  end
  if WR.UI and WR.UI.UpdateRunButtons then
    WR.UI.UpdateRunButtons()
  end
end

function B.Start()
  if not (WR.UI and WR.UI.IsShopLocked and WR.UI.IsShopLocked()) then
    WR.Print("Lock a plan first: click AH shopping list in #4.")
    return false
  end
  if not B.IsAHOpen() then
    WR.Print("Open the Auction House first, then click Buy step by step (or /writs buy).")
    return false
  end
  local A = API()
  if not A or not A.SendSearchQuery then
    WR.Print("This client has no C_AuctionHouse API, so step-by-step buying is not available.")
    return false
  end
  if WR.UI and WR.UI.Refresh then
    WR.UI.Refresh()
  end
  st = { state = "searching", queue = BuildQueue(), pos = 1, skipped = {}, removed = {}, sessionSpent = 0 }
  EnsureFrame():Show()
  NextStep()
  if WR.UI and WR.UI.UpdateRunButtons then
    WR.UI.UpdateRunButtons()
  end
  return true
end

------------------------------------------------------------------------
-- Events (all optional; registering an unknown event is caught)
------------------------------------------------------------------------

local ev = CreateFrame("Frame")
local EVENTS = {
  "ADDON_LOADED",
  "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED",
  "PLAYER_INTERACTION_MANAGER_FRAME_SHOW", "PLAYER_INTERACTION_MANAGER_FRAME_HIDE",
  "COMMODITY_SEARCH_RESULTS_UPDATED", "ITEM_SEARCH_RESULTS_UPDATED",
  "COMMODITY_PRICE_UPDATED", "COMMODITY_PRICE_UNAVAILABLE", "COMMODITY_PURCHASE_SUCCEEDED", "COMMODITY_PURCHASE_FAILED", "COMMODITY_PURCHASED",
  "AUCTION_HOUSE_PURCHASE_COMPLETED", "AUCTION_HOUSE_SHOW_ERROR",
  "UI_ERROR_MESSAGE", "PLAYER_MONEY", "ADDON_ACTION_BLOCKED",
}
local i
for i = 1, #EVENTS do
  pcall(ev.RegisterEvent, ev, EVENTS[i])
end

local function IsAuctioneerInteraction(kind)
  local t = Enum and Enum.PlayerInteractionType
  if t and t.Auctioneer ~= nil then
    return kind == t.Auctioneer
  end
  return true
end

local function IsAHUIAddon(name)
  return name == "Blizzard_AuctionUI" or name == "Blizzard_AuctionHouseUI"
end

local function TryAHButton()
  B.EnsureAHButton()
  B.RefreshAHButton()
  if not select(1, B.AHFrame()) then
    After(0, function()
      B.EnsureAHButton()
      B.RefreshAHButton()
    end)
    After(0.15, function()
      B.EnsureAHButton()
      B.RefreshAHButton()
    end)
  end
  if WR.UI and WR.UI.UpdateRunButtons then
    WR.UI.UpdateRunButtons()
  end
end

ev:SetScript("OnEvent", function(_, event, a1, a2)
  if event == "ADDON_LOADED" then
    if IsAHUIAddon(a1) then
      TryAHButton()
    end
    return
  end
  if event == "AUCTION_HOUSE_SHOW" then
    ahOpen = true
    TryAHButton()
    return
  end
  if event == "AUCTION_HOUSE_CLOSED" then
    ahOpen = false
    if st.state ~= "idle" then
      B.Stop()
    end
    if WR.UI and WR.UI.UpdateRunButtons then
      WR.UI.UpdateRunButtons()
    end
    if ahBtn and ahBtn.Hide then
      ahBtn:Hide()
    end
    return
  end
  if event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" then
    if IsAuctioneerInteraction(a1) then
      ahOpen = true
      TryAHButton()
    end
    return
  end
  if event == "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" then
    if IsAuctioneerInteraction(a1) then
      ahOpen = false
      if st.state ~= "idle" then
        B.Stop()
      end
      if WR.UI and WR.UI.UpdateRunButtons then
        WR.UI.UpdateRunButtons()
      end
    end
    return
  end
  if st.state == "idle" or st.state == "done" then
    return
  end
  if event == "COMMODITY_SEARCH_RESULTS_UPDATED" then
    if a1 == st.itemId and (st.state == "searching" or st.state == "quoted" or st.state == "notfound") then
      token = token + 1
      ReadCommodity(a1)
      Quote()
      Render()
    end
  elseif event == "ITEM_SEARCH_RESULTS_UPDATED" then
    local key = a1
    if type(key) == "table" and key.itemID == st.itemId and (st.state == "searching" or st.state == "quoted" or st.state == "notfound") then
      token = token + 1
      ReadItems(key)
      Quote()
      Render()
    end
  elseif event == "COMMODITY_PRICE_UPDATED" then
    if st.state == "confirming" and st.pending then
      local total = a2 or (a1 and a1 * st.pending.qty)
      st.pending.newTotal = total
      if total and total <= st.pending.total and not manualConfirm then
        local ok, err = pcall(API().ConfirmCommoditiesPurchase, st.itemId, st.pending.qty)
        if ok then
          st.pending.total = total
          st.pending.auto = true
          st.state = "buying"
          ArmBuyTimeout()
        else
          Finish(false, nil, "Confirm failed: " .. tostring(err))
          return
        end
      else
        token = token + 1 -- the player decides; no timeout
        st.state = "pricechanged"
      end
      Render()
    end
  elseif event == "COMMODITY_PRICE_UNAVAILABLE" then
    if st.pending and st.pending.kind == "commodity" and (st.state == "confirming" or st.state == "pricechanged") then
      if API() and API().CancelCommoditiesPurchase then
        pcall(API().CancelCommoditiesPurchase)
      end
      Finish(false, nil, "That price is no longer available.")
    end
  elseif event == "COMMODITY_PURCHASE_SUCCEEDED" or event == "COMMODITY_PURCHASED" then
    if st.pending and st.pending.kind == "commodity" and (event ~= "COMMODITY_PURCHASED" or a1 == st.itemId) then
      local spent = (st.pending.money0 or 0) - Money()
      Finish(true, spent > 0 and spent or nil)
    end
  elseif event == "COMMODITY_PURCHASE_FAILED" then
    if st.pending and st.pending.kind == "commodity" then
      Finish(false, nil, "The purchase failed (listings sold or the price changed).")
    end
  elseif event == "AUCTION_HOUSE_PURCHASE_COMPLETED" then
    if st.pending and st.pending.kind == "item" and (not a1 or a1 == st.pending.auctionID) then
      local spent = (st.pending.money0 or 0) - Money()
      Finish(true, spent > 0 and spent or nil)
    end
  elseif event == "AUCTION_HOUSE_SHOW_ERROR" then
    if st.pending then
      Finish(false, nil, "Auction House error (" .. tostring(a1) .. ").")
    end
  elseif event == "ADDON_ACTION_BLOCKED" then
    if st.pending and a1 == WR.ADDON_NAME then
      if st.pending.kind == "commodity" and st.pending.auto then
        manualConfirm = true
        st.pending.auto = nil
        st.state = "pricechanged"
        token = token + 1
        st.msg = "The game wants a click to confirm commodity buys. Click Confirm."
        Render()
      else
        Finish(false, nil, "The game blocked the purchase (" .. tostring(a2) .. ").")
      end
    end
  elseif event == "UI_ERROR_MESSAGE" then
    if st.pending then
      Finish(false, nil, tostring(a2 or a1 or "Error"))
    end
  elseif event == "PLAYER_MONEY" then
    if st.pending and st.state == "buying" then
      local spent = (st.pending.money0 or 0) - Money()
      if spent > 0 and spent >= (st.pending.total or 0) * 0.9 then
        Finish(true, spent)
      end
    elseif st.state == "quoted" then
      Render()
    end
  end
end)

-- Test hooks (read-only).
function B._State()
  return st
end
function B._Frame()
  return EnsureFrame()
end



------------------------------------------------------------------------
-- Compact Buy-step-by-step button on the Auction House frame.
-- Forever uses the classic AuctionFrame (Blizzard_AuctionUI). The
-- button is parented to AuctionFrame or AuctionHouseFrame, whichever
-- exists, created on AUCTION_HOUSE_SHOW, on ADDON_LOADED of
-- Blizzard_AuctionUI / Blizzard_AuctionHouseUI, and via HookScript
-- OnShow. Anchored left of the close button (AuctionFrameCloseButton)
-- in the title bar, above the Browse "Search" button and away from
-- Auctionator's bottom tabs. HookScript only; no secure hooks.
------------------------------------------------------------------------

local function ShopRemaining()
  local n = 0
  if not (WR.UI and WR.UI.GetPicked) then
    return 0
  end
  local _, plan = WR.UI.GetPicked()
  local i
  for i = 1, #((plan and plan.shop) or {}) do
    local item = plan.shop[i]
    local need = item.count or 0
    local have = 0
    if WR.Buyer and WR.Buyer.Have then
      have = WR.Buyer.Have(item.itemId) or 0
    elseif WR.GetBagCount then
      have = WR.GetBagCount(item.itemId) or 0
    end
    if have < need then
      n = n + 1
    end
  end
  return n
end

local function CloseButton(parent)
  if not parent then
    return nil
  end
  local name
  if parent.GetName then
    local ok, n = pcall(parent.GetName, parent)
    if ok and type(n) == "string" then
      name = n
    end
  end
  local titleClose
  if type(parent.TitleContainer) == "table" then
    titleClose = parent.TitleContainer.CloseButton
  end
  local namedClose = name and _G[name .. "CloseButton"]
  local candidates = {
    _G.AuctionFrameCloseButton,
    _G.AuctionHouseFrameCloseButton,
    parent.CloseButton,
    titleClose,
    namedClose,
  }
  local i
  for i = 1, #candidates do
    local c = candidates[i]
    -- parent.Close is often a method (function), not a frame — skip those.
    if IsFrame(c) then
      return c
    end
  end
  return nil
end

local function AnchorButton(btn, parent)
  btn:ClearAllPoints()
  local close = CloseButton(parent)
  if close then
    -- Title-bar, left of the X, above Browse's Search button.
    btn:SetPoint("RIGHT", close, "LEFT", -8, 0)
    return "RIGHT", close, "LEFT", -8, 0
  end
  btn:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -30, -8)
  return "TOPRIGHT", parent, "TOPRIGHT", -30, -8
end

local function PaintButton(btn)
  if type(btn.icon) ~= "table" then
    local tex = btn:CreateTexture(nil, "ARTWORK")
    tex:SetPoint("TOPLEFT", 3, -3)
    tex:SetPoint("BOTTOMRIGHT", -3, 3)
    btn.icon = tex
  end
  local icons = {
    "Interface\\Icons\\INV_Misc_Note_01",
    "Interface\\Icons\\INV_Scroll_03",
    "Interface\\Icons\\INV_Inscription_Parchment",
  }
  local i
  for i = 1, #icons do
    btn.icon:SetTexture(icons[i])
    if not btn.icon.GetTexture or btn.icon:GetTexture() then
      break
    end
  end
  if btn.SetBackdrop then
    pcall(btn.SetBackdrop, btn, {
      bgFile = "Interface\\Buttons\\WHITE8X8",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
      edgeSize = 8,
      insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    if btn.SetBackdropColor then
      pcall(btn.SetBackdropColor, btn, 0.12, 0.32, 0.08, 0.95)
    end
  elseif type(btn.bg) ~= "table" then
    local bg = btn:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    if bg.SetColorTexture then
      pcall(bg.SetColorTexture, bg, 0.12, 0.32, 0.08, 0.95)
    else
      pcall(bg.SetTexture, bg, 0.12, 0.32, 0.08, 0.95)
    end
    btn.bg = bg
  end
end

function B.EnsureAHButton()
  local parent, parentName = B.AHFrame()
  if not parent then
    return nil
  end
  if ahBtn then
    if ahBtn.GetParent and ahBtn:GetParent() ~= parent then
      ahBtn:SetParent(parent)
      AnchorButton(ahBtn, parent)
    end
    return ahBtn
  end
  local btn = CreateFrame("Button", "WritRunnerAHBuyButton", parent)
  btn:SetSize(28, 28)
  btn:EnableMouse(true)
  AnchorButton(btn, parent)
  pcall(function()
    btn:SetFrameStrata("HIGH")
    local pl = 0
    if parent.GetFrameLevel then
      pl = parent:GetFrameLevel() or 0
    end
    btn:SetFrameLevel(pl + 100)
    if btn.Raise then
      btn:Raise()
    end
  end)
  PaintButton(btn)

  local badge = btn:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
  badge:SetPoint("BOTTOMRIGHT", 2, -1)
  badge:SetText("")
  btn.badge = badge

  btn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
    GameTooltip:SetText("WritRunner")
    if not (WR.UI and WR.UI.IsShopLocked and WR.UI.IsShopLocked()) then
      GameTooltip:AddLine("Lock a plan first: open WritRunner and click AH shopping list in #4.", 1, 0.3, 0.3, true)
    elseif self.disabledReason then
      GameTooltip:AddLine(self.disabledReason, 1, 0.3, 0.3, true)
    else
      local left = ShopRemaining()
      GameTooltip:AddLine("Buy step by step — walks the locked shopping list, one item at a time.", 1, 1, 1, true)
      if left > 0 then
        GameTooltip:AddLine(string.format("%d item%s left to buy.", left, left == 1 and "" or "s"), 0.4, 1, 0.4)
      else
        GameTooltip:AddLine("The locked list is already in your bags.", 0.4, 1, 0.4)
      end
    end
    GameTooltip:AddLine("Or type /writs buy.", 0.8, 0.8, 0.8)
    GameTooltip:Show()
  end)
  btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
  btn:SetScript("OnClick", function()
    if WR.Buyer and WR.Buyer.IsActive and WR.Buyer.IsActive() then
      if WR.Buyer._Frame then
        local f = WR.Buyer._Frame()
        if f then
          f:Show()
          if f.Raise then f:Raise() end
        end
      end
      return
    end
    if WR.Buyer and WR.Buyer.Start then
      WR.Buyer.Start()
    end
  end)

  if not parent._wrAHBtnHooked and parent.HookScript then
    parent._wrAHBtnHooked = true
    parent:HookScript("OnShow", function()
      ahOpen = true
      B.EnsureAHButton()
      B.RefreshAHButton()
    end)
    parent:HookScript("OnHide", function()
      if ahBtn then
        ahBtn:Hide()
      end
    end)
  end

  ahBtn = btn
  btn:Show()
  return btn
end

function B.RefreshAHButton()
  local parent = select(1, B.AHFrame())
  if not parent then
    return
  end
  if not ahBtn then
    if Shown(parent) or ahOpen then
      B.EnsureAHButton()
    else
      return
    end
  end
  if not ahBtn then
    return
  end
  local locked = WR.UI and WR.UI.IsShopLocked and WR.UI.IsShopLocked()
  local left = ShopRemaining()
  if locked then
    ahBtn:Enable()
    ahBtn.disabledReason = nil
    if ahBtn.icon then
      ahBtn.icon:SetDesaturated(false)
      ahBtn.icon:SetVertexColor(1, 1, 1)
    end
    if left > 0 then
      ahBtn.badge:SetText(tostring(left))
    else
      ahBtn.badge:SetText("")
    end
  else
    ahBtn:Disable()
    ahBtn.disabledReason = "Lock a plan first (AH shopping list in #4)."
    if ahBtn.icon then
      ahBtn.icon:SetDesaturated(true)
      ahBtn.icon:SetVertexColor(0.6, 0.6, 0.6)
    end
    ahBtn.badge:SetText("")
  end
  -- Disabled raw Buttons can end up hidden on some clients; keep it visible.
  if Shown(parent) or ahOpen then
    ahBtn:Show()
  else
    ahBtn:Hide()
  end
end

function B.DebugAHButton()
  local function P(msg)
    if WR.Print then
      WR.Print(msg)
    else
      print(msg)
    end
  end
  local ah = rawget(_G, "AuctionHouseFrame") or AuctionHouseFrame
  local af = rawget(_G, "AuctionFrame") or AuctionFrame
  P("AuctionHouseFrame=" .. (ah and (Shown(ah) and "shown" or "hidden") or "nil"))
  P("AuctionFrame=" .. (af and (Shown(af) and "shown" or "hidden") or "nil"))
  local parent, pname = B.AHFrame()
  P("using " .. (pname or "none") .. (parent and (" (" .. (Shown(parent) and "shown" or "hidden") .. ")") or ""))
  P("ahOpen flag=" .. (ahOpen and "true" or "false"))
  local created = ahBtn ~= nil
  TryAHButton()
  if not created and ahBtn then
    P("button was missing; created now")
  end
  if not ahBtn then
    P("button not created (no AH frame yet). Open the Auction House and run /writs ahbutton again. /writs buy still works when the AH is open.")
    return
  end
  local relName = "?"
  local point, rel, relPoint, x, y = "?", nil, "?", 0, 0
  if ahBtn.GetPoint then
    local ok, a, b, c, d, e = pcall(ahBtn.GetPoint, ahBtn, 1)
    if ok then
      point, rel, relPoint, x, y = a, b, c, d, e
    end
  end
  if type(rel) == "table" and rel.GetName then
    relName = rel:GetName() or pname or "frame"
  elseif rel == parent then
    relName = pname or "AH"
  end
  local strata, level = "?", "?"
  if ahBtn.GetFrameStrata then
    local ok, v = pcall(ahBtn.GetFrameStrata, ahBtn)
    if ok then strata = tostring(v) end
  end
  if ahBtn.GetFrameLevel then
    local ok, v = pcall(ahBtn.GetFrameLevel, ahBtn)
    if ok then level = tostring(v) end
  end
  local parName = pname or "?"
  if ahBtn.GetParent then
    local okp, par = pcall(ahBtn.GetParent, ahBtn)
    if okp and type(par) == "table" and par.GetName then
      local okn, n = pcall(par.GetName, par)
      if okn and type(n) == "string" and n ~= "" then
        parName = n
      end
    end
  end
  P(string.format("button shown=%s parent=%s anchor=%s of %s %s (%.1f, %.1f) strata=%s level=%s",
    Shown(ahBtn) and "yes" or "no",
    tostring(parName),
    tostring(point), tostring(relName), tostring(relPoint),
    tonumber(x) or 0, tonumber(y) or 0,
    tostring(strata), tostring(level)))
end

function B._ResetAHButton()
  if ahBtn and ahBtn.Hide then
    ahBtn:Hide()
  end
  ahBtn = nil
end
