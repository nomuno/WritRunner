-- Pricing via Auctionator.API.v1. Never invents a price.

local WR = WritRunner

local function GetAPI()
  if Auctionator and Auctionator.API and Auctionator.API.v1 then
    return Auctionator.API.v1
  end
  return nil
end

function WR.GetAuctionPrice(itemId)
  if not itemId then
    return nil
  end
  local api = GetAPI()
  if not api or not api.GetAuctionPriceByItemID then
    return nil
  end
  local ok, price = pcall(api.GetAuctionPriceByItemID, WR.CALLER_ID, itemId)
  if ok and type(price) == "number" and price >= 0 then
    return price
  end
  return nil
end

function WR.PriceWrit(writ)
  local writCopper = WR.GetAuctionPrice(writ.writItemId)
  local unitCopper = WR.GetAuctionPrice(writ.requiredItemId)
  local count = writ.requiredCount or 1
  local itemCopper = nil
  if unitCopper ~= nil then
    itemCopper = unitCopper * count
  end
  local total = nil
  if writCopper ~= nil and itemCopper ~= nil then
    total = writCopper + itemCopper
  end
  local repPerGold = nil
  if total and total > 0 and writ.rep then
    repPerGold = writ.rep / (total / 10000)
  end
  local rewardCopper = WR.db and WR.db.rewardMoney and writ.questId and WR.db.rewardMoney[writ.questId] or nil
  local netCopper = nil
  if total and rewardCopper then
    netCopper = total - rewardCopper
  end
  return {
    writCopper = writCopper,
    itemCopper = itemCopper,
    rewardCopper = rewardCopper,
    netCopper = netCopper,
    unitCopper = unitCopper,
    totalCopper = total,
    repPerGold = repPerGold,
    known = total ~= nil,
  }
end

-- Expected cost of opening a sealed envelope of this tier, then filling
-- the random named order: sealed AH price + average known fill (item) cost
-- for writs of that tier. Returns nil fields when a piece is unknown.
function WR.SealedExpectation(tierInfo)
  local sealedCopper = WR.GetAuctionPrice(tierInfo.itemId)
  local sum, n = 0, 0
  local writs = WritRunnerData and WritRunnerData.writs or {}
  local i
  for i = 1, #writs do
    local w = writs[i]
    if w.tier == tierInfo.tier then
      local unit = WR.GetAuctionPrice(w.requiredItemId)
      if unit ~= nil then
        sum = sum + unit * (w.requiredCount or 1)
        n = n + 1
      end
    end
  end
  local avgFill = nil
  if n > 0 then
    avgFill = sum / n
  end
  local expected = nil
  if sealedCopper ~= nil and avgFill ~= nil then
    expected = sealedCopper + avgFill
  end
  local repPerGold = nil
  if expected and expected > 0 then
    repPerGold = tierInfo.rep / (expected / 10000)
  end
  return {
    sealedCopper = sealedCopper,
    avgFillCopper = avgFill,
    fillSamples = n,
    expectedCopper = expected,
    repPerGold = repPerGold,
    known = expected ~= nil,
  }
end

function WR.MoneyText(copper)
  if copper == nil then
    return "unknown"
  end
  copper = math.floor(copper + 0.5)
  if GetCoinTextureString then
    return GetCoinTextureString(copper)
  end
  local g = math.floor(copper / 10000)
  local s = math.floor((copper % 10000) / 100)
  local c = copper % 100
  if g > 0 then
    return string.format("%dg %ds %dc", g, s, c)
  end
  if s > 0 then
    return string.format("%ds %dc", s, c)
  end
  return string.format("%dc", c)
end

function WR.GoldToCopper(gold)
  if gold == nil or gold == "" then
    return nil
  end
  if type(gold) == "string" then
    gold = gold:gsub("^%s+", ""):gsub("%s+$", ""):gsub("[gG]$", "")
  end
  if gold == "" then
    return nil
  end
  local n = tonumber(gold)
  if not n or n < 0 then
    return nil
  end
  return n * 10000
end

-- Rewrite a PriceWrit result so an already-owned writ costs nothing to
-- buy. The fill item still costs unless it is also already owned.
function WR.ApplyOwnedPricing(price, writ, haveWrit, haveFill)
  if not price or not haveWrit then
    return price
  end
  price.ownedWrit = true
  price.ownedFill = haveFill and true or false
  price.ownedBank = price.ownedBank or false
  price.writCopper = 0
  if haveFill then
    price.itemCopper = 0
    price.totalCopper = 0
    price.known = true
    -- Leave repPerGold nil: a 1e9 sentinel used to sort these first
    -- but showed up in #3 as "1000000000.00 reputation per gold".
    -- RankWrits still treats free owned writs as best-in-list.
    price.repPerGold = nil
    if price.rewardCopper then
      price.netCopper = 0 - price.rewardCopper
    end
  else
    price.totalCopper = price.itemCopper
    price.known = price.itemCopper ~= nil
    if price.known and price.totalCopper and price.totalCopper > 0 and writ and writ.rep then
      price.repPerGold = writ.rep / (price.totalCopper / 10000)
    elseif price.known then
      price.repPerGold = nil
    end
    if price.known and price.rewardCopper then
      price.netCopper = (price.totalCopper or 0) - price.rewardCopper
    else
      price.netCopper = nil
    end
  end
  return price
end

-- True when a bag-owned writ costs nothing more to buy (writ and fill
-- already on hand). Rep/g is not a meaningful number in that case.
function WR.IsFreeOwnedWrit(price)
  return price and price.ownedWrit and (not price.totalCopper or price.totalCopper <= 0) and true or false
end

-- Display text for the #3 Rep/g column. Free owned writs are blank
-- (do not show a sort sentinel or "~∞"). Unknown prices show "—".
function WR.FormatRepPerGold(price, writ, rankByNet)
  if WR.IsFreeOwnedWrit(price) then
    return ""
  end
  if rankByNet and price and price.estNetKnown then
    local net = price.estNetCopper or 0
    if net <= 0 then
      return "~∞"
    end
    return string.format("~%.1f", ((writ and writ.rep) or 0) / (net / 10000))
  end
  if not price or not price.known then
    return "—"
  end
  if price.repPerGold then
    return string.format("%.1f", price.repPerGold)
  end
  return "—"
end

-- Tooltip line for Rep/g, or nil to omit. Free owned writs say
-- "Already owned" instead of a bogus reputation-per-gold figure.
function WR.RepPerGoldTooltipLine(price, writ, rankByNet)
  if WR.IsFreeOwnedWrit(price) then
    return "Already owned"
  end
  if price and price.repPerGold then
    return string.format("%.2f reputation per gold", price.repPerGold)
  end
  return nil
end

function WR.ExpectedPouchCopper(tier)
  if WR.Ledger and WR.Ledger.ExpectedPouch then
    return WR.Ledger.ExpectedPouch(tier)
  end
  return nil
end

-- Attach the expected Coin Pouch return and an estimated net
-- (cost - quest gold - pouch). Does not invent a number: missing
-- averages stay nil and the UI shows "?".
function WR.AttachPouchEstimate(price, writ)
  if not price or not writ then
    return price
  end
  local pouch, kind, n, src = WR.ExpectedPouchCopper(writ.tier)
  price.estPouch = pouch
  price.estPouchKind = kind
  price.estPouchN = n
  price.estPouchSource = src
  if price.known and pouch then
    price.estNetCopper = (price.totalCopper or 0) - (price.rewardCopper or 0) - pouch
    price.estNetKnown = true
  else
    price.estNetCopper = price.netCopper
    price.estNetKnown = false
  end
  return price
end

local function WritIndex()
  local index = {}
  local writs = WritRunnerData and WritRunnerData.writs or {}
  local i
  for i = 1, #writs do
    local w = writs[i]
    if w.writItemId then
      index[w.writItemId] = w
    end
  end
  return index
end

-- Scan bags (and the bank, cheaply) for named writs the player already
-- owns. Routable ones are returned in `owned`; others in `skipped` with
-- a reason. Completed-today writs are ignored.
function WR.CollectBagWrits()
  local owned, skipped = {}, {}
  local index = WritIndex()
  local itemId, writ
  for itemId, writ in pairs(index) do
    if not (WR.Daily and WR.Daily.IsCompleted and WR.Daily.IsCompleted(writ)) then
      local bags, bank, total = 0, 0, 0
      if WR.GetOwnedCount then
        bags, bank, total = WR.GetOwnedCount(itemId)
      else
        bags = WR.GetBagCount and WR.GetBagCount(itemId) or 0
        total = bags
      end
      if total > 0 then
        local fillBags, fillBank, fillTotal = 0, 0, 0
        if writ.requiredItemId then
          if WR.GetOwnedCount then
            fillBags, fillBank, fillTotal = WR.GetOwnedCount(writ.requiredItemId)
            local need = writ.requiredCount or 1
            -- "Already in bags" means the bags themselves cover the fill.
            -- Bank counts as owned for shopping (withdraw first) but the
            -- shop list still lists it if only the bank has it? User asked
            -- for bags; bank is treated as owned so we don't re-buy it.
            fillBags = fillTotal >= need
          else
            fillBags = (WR.GetBagCount and WR.GetBagCount(writ.requiredItemId) or 0) >= (writ.requiredCount or 1)
          end
        end
        local ok, reason = true, nil
        if WR.Route and WR.Route.IsRoutable then
          ok, reason = WR.Route.IsRoutable(writ)
        elseif not (writ.zone and writ.npc and writ.coords) then
          ok, reason = false, "no turn-in location"
        end
        local rec = {
          writ = writ,
          bags = bags,
          bank = bank,
          haveFill = fillBags and true or false,
          inBank = bags <= 0 and bank > 0,
        }
        if ok then
          owned[#owned + 1] = rec
        else
          rec.reason = reason or "no known path to the NPC"
          skipped[#skipped + 1] = rec
        end
      end
    end
  end
  table.sort(owned, function(a, b)
    return (a.writ.writItemName or "") < (b.writ.writItemName or "")
  end)
  table.sort(skipped, function(a, b)
    return (a.writ.writItemName or "") < (b.writ.writItemName or "")
  end)
  return owned, skipped
end

-- Rank writs: known prices first by rep-per-gold descending, unknowns last.
-- Applies filters and excludes completed writs when requested.
function WR.RankWrits(opts)
  opts = opts or {}
  local maxCopper = opts.maxCopper
  local hideUnconfirmed = opts.hideUnconfirmed
  local hideCompleted = opts.hideCompleted
  local rows = {}
  local writs = WritRunnerData and WritRunnerData.writs or {}
  local i
  for i = 1, #writs do
    local w = writs[i]
    if hideCompleted and WR.Daily and WR.Daily.IsCompleted(w) then
      -- skip
    elseif hideUnconfirmed and not WR.Confirmed(w) then
      -- skip
    else
      local price = WR.AttachPouchEstimate(WR.PriceWrit(w), w)
      local overMax = maxCopper and price.known and price.totalCopper > maxCopper
      if not overMax then
        rows[#rows + 1] = { writ = w, price = price }
      end
    end
  end
  -- Owned bag writs: always listed when the option is on (even if they
  -- were hidden as unconfirmed or over Max per writ). Writ cost is 0.
  if opts.useBagWrits then
    local owned = opts.bagOwned
    if not owned then
      owned = select(1, WR.CollectBagWrits())
    end
    local have = {}
    local r
    for r = 1, #rows do
      local id = rows[r].writ and rows[r].writ.questId
      if id then
        have[id] = rows[r]
      end
    end
    local i
    for i = 1, #(owned or {}) do
      local rec = owned[i]
      local w = rec.writ
      local row = w.questId and have[w.questId]
      if row then
        WR.ApplyOwnedPricing(row.price, w, true, rec.haveFill)
        WR.AttachPouchEstimate(row.price, w)
        row.price.ownedBank = rec.inBank and true or false
      else
        local price = WR.ApplyOwnedPricing(WR.PriceWrit(w), w, true, rec.haveFill)
        WR.AttachPouchEstimate(price, w)
        price.ownedBank = rec.inBank and true or false
        rows[#rows + 1] = { writ = w, price = price }
      end
    end
  end
  local function Rpg(row)
    -- Free owned writs sort first. 1e9 is sort-only; the UI leaves Rep/g blank.
    if row.price and row.price.ownedWrit and (not row.price.totalCopper or row.price.totalCopper <= 0) then
      return 1e9
    end
    if opts.rankByNet and row.price.estNetKnown and row.writ and row.writ.rep then
      local net = row.price.estNetCopper or 0
      if net <= 0 then
        return 1e9
      end
      return row.writ.rep / (net / 10000)
    end
    return row.price.repPerGold or 0
  end
  table.sort(rows, function(a, b)
    if a.price.known and b.price.known then
      local ra, rb = Rpg(a), Rpg(b)
      if ra ~= rb then
        return ra > rb
      end
      local na = (opts.rankByNet and a.price.estNetKnown) and (a.price.estNetCopper or 0) or a.price.totalCopper
      local nb = (opts.rankByNet and b.price.estNetKnown) and (b.price.estNetCopper or 0) or b.price.totalCopper
      return (na or 0) < (nb or 0)
    end
    if a.price.known ~= b.price.known then
      return a.price.known
    end
    return (a.writ.writItemName or "") < (b.writ.writItemName or "")
  end)
  return rows
end

-- Greedy pick: walk the ranked list and take a writ when its known cost
-- fits in the remaining budget. Unknown-cost writs are never auto-picked.
function WR.PickWithinBudget(ranked, budgetCopper)
  local picked = {}
  local spent = 0
  local i
  -- Owned writs always come first and always fit (writ is free; only a
  -- missing fill item may add cost, and even then we keep the writ).
  for i = 1, #ranked do
    local row = ranked[i]
    if row.price and row.price.ownedWrit then
      picked[#picked + 1] = row
      if row.price.known then
        spent = spent + (row.price.totalCopper or 0)
      end
    end
  end
  for i = 1, #ranked do
    local row = ranked[i]
    if not (row.price and row.price.ownedWrit) then
      if row.price.known then
        if not budgetCopper or (spent + row.price.totalCopper) <= budgetCopper then
          picked[#picked + 1] = row
          spent = spent + row.price.totalCopper
        end
      end
    end
  end
  return picked, spent
end

function WR.TryAuctionatorShopping(terms, listName)
  local api = GetAPI()
  if not api then
    return false, "Auctionator is not loaded."
  end
  listName = listName or "WritRunner"

  -- Auctionator v1: CreateShoppingList(callerID, name, searchStrings[])
  -- replaces any existing list with the same name.
  if api.CreateShoppingList then
    local searchStrings = {}
    for _, term in ipairs(terms) do
      local s
      if api.ConvertToSearchString then
        local okc, res = pcall(api.ConvertToSearchString, WR.CALLER_ID, { searchString = term, isExact = true })
        if okc and type(res) == "string" then s = res end
      end
      searchStrings[#searchStrings + 1] = s or ('"' .. term .. '"')
    end
    local ok, err = pcall(api.CreateShoppingList, WR.CALLER_ID, listName, searchStrings)
    if ok then
      return true, "Created Auctionator shopping list: " .. listName .. " (" .. #searchStrings .. " items)"
    end
  end

  -- Confirmed current fallback: MultiSearch / MultiSearchExact require the AH
  -- to be open. Prefer exact name matches so "Mana Potion" does not fuzzy-hit
  -- Lesser Mana Potion.
  local ahOpen = (WR.Buyer and WR.Buyer.IsAHOpen and WR.Buyer.IsAHOpen())
    or (AuctionFrame and AuctionFrame.IsShown and AuctionFrame:IsShown())
    or (AuctionHouseFrame and AuctionHouseFrame.IsShown and AuctionHouseFrame:IsShown())
  if not ahOpen then
    return false, "Open the Auction House first. CreateShoppingList is not available in this Auctionator build, so WritRunner uses MultiSearch instead."
  end
  if api.MultiSearchExact then
    local ok, err = pcall(api.MultiSearchExact, WR.CALLER_ID, terms)
    if ok then
      return true, "Started an Auctionator exact search for the shopping list."
    end
    return false, "Auctionator MultiSearchExact failed: " .. tostring(err)
  end
  if api.MultiSearch then
    local ok, err = pcall(api.MultiSearch, WR.CALLER_ID, terms)
    if ok then
      return true, "Started an Auctionator search for the shopping list."
    end
    return false, "Auctionator MultiSearch failed: " .. tostring(err)
  end
  return false, "This Auctionator build has no CreateShoppingList or MultiSearch API."
end
