-- Numbered world-map pins for the active run. All C_Map / map-canvas calls
-- are pcall'd. Minimap pins are not implemented (rotation/zoom is not easy
-- to get right without a pin library).

local WR = WritRunner
WR.Pins = WR.Pins or {}
local Pins = WR.Pins

local pins = {}
local hooked
local providerInstalled
local sizeHooked

local function GetCanvas()
  if not WorldMapFrame then
    return nil
  end
  if WorldMapFrame.ScrollContainer and WorldMapFrame.ScrollContainer.Child then
    return WorldMapFrame.ScrollContainer.Child
  end
  if WorldMapFrame.GetCanvas then
    local ok, canvas = pcall(WorldMapFrame.GetCanvas, WorldMapFrame)
    if ok then
      return canvas
    end
  end
  return nil
end

local function GetViewedMapID()
  if not WorldMapFrame then
    return nil
  end
  if WorldMapFrame.GetMapID then
    local ok, id = pcall(WorldMapFrame.GetMapID, WorldMapFrame)
    if ok and type(id) == "number" then
      return id
    end
  end
  return nil
end

local function Acquire(i)
  local pin = pins[i]
  if pin then
    return pin
  end
  local canvas = GetCanvas()
  if not canvas then
    return nil
  end
  pin = CreateFrame("Button", nil, canvas)
  pin:SetSize(22, 22)
  pin:SetFrameStrata("HIGH")
  pin:SetFrameLevel((canvas.GetFrameLevel and canvas:GetFrameLevel() or 0) + 20)
  pin.bg = pin:CreateTexture(nil, "BACKGROUND")
  pin.bg:SetAllPoints()
  pin.bg:SetColorTexture(0.05, 0.05, 0.05, 0.9)
  pin.border = pin:CreateTexture(nil, "BORDER")
  pin.border:SetPoint("TOPLEFT", -1, 1)
  pin.border:SetPoint("BOTTOMRIGHT", 1, -1)
  pin.border:SetColorTexture(0.85, 0.7, 0.2, 1)
  pin.bg:SetDrawLayer("BACKGROUND", 1)
  pin.label = pin:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  pin.label:SetPoint("CENTER", 0, 0)
  pin:SetScript("OnEnter", function(self)
    if not self.step then
      return
    end
    local s = self.step
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(string.format("Step %d: %s", self.index or 0, s.writItemName or "Writ"))
    local dest = (s.npc or "unknown NPC") .. " — " .. (s.zone or "unknown zone")
    if s.coords then
      dest = dest .. string.format(" (%.1f, %.1f)", s.coords.x, s.coords.y)
    end
    GameTooltip:AddLine(dest, 1, 1, 1)
    GameTooltip:AddLine("Hand in: " .. (s.requiredItemName or "?"), 0.9, 0.9, 0.7)
    if s.done then
      GameTooltip:AddLine("Completed", 0.6, 0.6, 0.6)
    elseif self.current then
      GameTooltip:AddLine("Current step  ·  click to set waypoint", 1, 0.82, 0)
    else
      GameTooltip:AddLine("Click to set a waypoint here", 0.7, 0.7, 0.7)
    end
    GameTooltip:Show()
  end)
  pin:SetScript("OnLeave", function()
    GameTooltip:Hide()
  end)
  pin:SetScript("OnClick", function(self)
    if not self.step or not WR.Route then
      return
    end
    local writ = {
      zone = self.step.zone,
      npc = self.step.npc,
      coords = self.step.coords,
      writItemName = self.step.writItemName,
    }
    local ok, msg = WR.Route.SetWaypointForWrit(writ)
    if msg then
      WR.Print(msg)
    end
  end)
  pins[i] = pin
  return pin
end

local function Style(pin, step, index, current)
  pin.step = step
  pin.index = index
  pin.current = current and true or false
  pin.label:SetText(tostring(index))
  if step.done then
    pin.border:SetColorTexture(0.45, 0.45, 0.45, 1)
    pin.label:SetTextColor(0.6, 0.6, 0.6)
    pin:SetSize(18, 18)
  elseif current then
    pin.border:SetColorTexture(1, 0.82, 0, 1)
    pin.label:SetTextColor(1, 0.92, 0.3)
    pin:SetSize(24, 24)
  else
    pin.border:SetColorTexture(0.85, 0.7, 0.2, 1)
    pin.label:SetTextColor(1, 1, 1)
    pin:SetSize(20, 20)
  end
end

function Pins.HideAll()
  local i
  for i = 1, #pins do
    pins[i]:Hide()
  end
end

function Pins.Refresh()
  if not WorldMapFrame or not WorldMapFrame:IsShown() then
    Pins.HideAll()
    return
  end
  local canvas = GetCanvas()
  local viewed = GetViewedMapID()
  if not canvas or not viewed or not WR.Run or not WR.Run.IsActive() then
    Pins.HideAll()
    return
  end
  local width, height = canvas:GetWidth(), canvas:GetHeight()
  if not width or not height or width < 1 or height < 1 then
    Pins.HideAll()
    return
  end

  local steps = WR.Run.Steps()
  local current = WR.Run.CurrentIndex()
  local shown = 0
  local i
  for i = 1, #steps do
    local step = steps[i]
    local mapId = step.mapId
    if (not mapId) and step.zone and WR.Route and WR.Route.MapIdForZone then
      mapId = WR.Route.MapIdForZone(step.zone)
      step.mapId = mapId
    end
    local cx, cy
    if step.coords and mapId and WR.Route and WR.Route.MapPosOnMap then
      local ok, x, y = pcall(WR.Route.MapPosOnMap, mapId, step.coords.x / 100, step.coords.y / 100, viewed)
      if ok then
        cx, cy = x, y
      end
    end
    if cx and cy then
      shown = shown + 1
      local pin = Acquire(shown)
      if pin then
        if pin:GetParent() ~= canvas then
          pin:SetParent(canvas)
        end
        Style(pin, step, i, current == i)
        pin:ClearAllPoints()
        pin:SetPoint("CENTER", canvas, "TOPLEFT", cx * width, -cy * height)
        pin:Show()
      end
    end
  end
  local j
  for j = shown + 1, #pins do
    pins[j]:Hide()
  end
end

local function HookCanvasSize()
  local canvas = GetCanvas()
  if not canvas or sizeHooked == canvas then
    return
  end
  sizeHooked = canvas
  canvas:HookScript("OnSizeChanged", function()
    Pins.Refresh()
  end)
end

local function InstallProvider()
  if providerInstalled or not WorldMapFrame or not WorldMapFrame.AddDataProvider then
    return
  end
  local provider
  if MapCanvasDataProviderMixin and CreateFromMixins then
    local ok, obj = pcall(CreateFromMixins, MapCanvasDataProviderMixin)
    if ok then
      provider = obj
    end
  end
  provider = provider or {}
  function provider:RefreshAllData()
    HookCanvasSize()
    Pins.Refresh()
  end
  function provider:OnMapChanged()
    HookCanvasSize()
    Pins.Refresh()
  end
  function provider:RemoveAllData()
    Pins.HideAll()
  end
  function provider:OnShow()
    HookCanvasSize()
    Pins.Refresh()
  end
  function provider:OnHide()
    Pins.HideAll()
  end
  local ok = pcall(WorldMapFrame.AddDataProvider, WorldMapFrame, provider)
  if ok then
    providerInstalled = true
  end
end

local function InstallHooks()
  if hooked or not WorldMapFrame then
    return
  end
  hooked = true
  pcall(function()
    WorldMapFrame:HookScript("OnShow", function()
      HookCanvasSize()
      Pins.Refresh()
    end)
  end)
  pcall(function()
    WorldMapFrame:HookScript("OnHide", function()
      Pins.HideAll()
    end)
  end)
  if WorldMapFrame.OnMapChanged then
    pcall(hooksecurefunc, WorldMapFrame, "OnMapChanged", function()
      HookCanvasSize()
      Pins.Refresh()
    end)
  end
  HookCanvasSize()
end

function Pins.Install()
  pcall(InstallProvider)
  pcall(InstallHooks)
  if WorldMapFrame and WorldMapFrame:IsShown() then
    Pins.Refresh()
  end
end

local ready = CreateFrame("Frame")
ready:RegisterEvent("PLAYER_LOGIN")
ready:SetScript("OnEvent", function()
  Pins.Install()
end)
