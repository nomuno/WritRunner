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
  local n = tonumber(gold)
  if not n or n < 0 then
    return nil
  end
  return n * 10000
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
      local price = WR.PriceWrit(w)
      local overMax = maxCopper and price.known and price.totalCopper > maxCopper
      if not overMax then
        rows[#rows + 1] = { writ = w, price = price }
      end
    end
  end
  table.sort(rows, function(a, b)
    if a.price.known and b.price.known then
      if a.price.repPerGold ~= b.price.repPerGold then
        return a.price.repPerGold > b.price.repPerGold
      end
      return a.price.totalCopper < b.price.totalCopper
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
  for i = 1, #ranked do
    local row = ranked[i]
    if row.price.known then
      if not budgetCopper or (spent + row.price.totalCopper) <= budgetCopper then
        picked[#picked + 1] = row
        spent = spent + row.price.totalCopper
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
  local ahOpen = AuctionHouseFrame and AuctionHouseFrame:IsShown()
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
