-- ==========================================================
-- LOOT LEDGER v0.4.4
-- RuneLite-style loot tracker: mobs, drops, gold per mob.
-- Right-click an item for session / permanent ignore.
-- ==========================================================

-- 1. STATE -------------------------------------------------
local ADDON_NAME = ...

-- Key binding label (shown in Escape > Key Bindings > AddOns)
BINDING_NAME_LOOTLEDGER_TOGGLE = "Toggle Loot Ledger"

local startTime      = time()
local searchText     = ""
local showIgnoreMode = false

-- SavedVariables (persist across sessions)
-- One-time migration: early builds used "AnniversaryLoot*" names. If the
-- player has old saved data and no new data yet, copy it over so nothing
-- is lost. Then null out the old globals so they stop being persisted
-- to the saved-variables file and eventually disappear.
if AnniversaryLootDB and not LootLedgerDB then
    LootLedgerDB = AnniversaryLootDB
end
if AnniversaryLootIgnore and not LootLedgerIgnore then
    LootLedgerIgnore = AnniversaryLootIgnore
end
if AnniversaryLootSettings and not LootLedgerSettings then
    LootLedgerSettings = AnniversaryLootSettings
end
AnniversaryLootDB = nil
AnniversaryLootIgnore = nil
AnniversaryLootSettings = nil

LootLedgerDB        = LootLedgerDB        or {}  -- [mob] = { loot={[item]=qty}, links={[item]=link}, totalGold=n, kills=n }
LootLedgerIgnore    = LootLedgerIgnore    or {}  -- [itemName] = true  (permanent item ignore)
LootLedgerMobIgnore = LootLedgerMobIgnore or {}  -- [mobKey]   = true  (permanent mob ignore)
LootLedgerSettings  = LootLedgerSettings  or {}

-- Merge defaults (so new settings added later get filled in on load)
local DEFAULTS = {
    opacity        = 0.4,
    combatHide     = false,
    rarityColors   = true,
    shiftClickLink = true,
    gridView       = false,
    point          = nil,
    width          = 320,
    height         = 420,
    collapsed      = nil,  -- [mobKey] = true for collapsed entries
}
for k, v in pairs(DEFAULTS) do
    if LootLedgerSettings[k] == nil then
        LootLedgerSettings[k] = v
    end
end
LootLedgerSettings.collapsed = LootLedgerSettings.collapsed or {}
local S = LootLedgerSettings -- short alias

-- In-memory only (cleared on /reload, logout, or toggling mode)
local SessionIgnore = {}  -- [item] = true
local wasShownBeforeCombat = false

-- Ephemeral corpse tracking keyed by mobKey then GUID. Kept out of
-- SavedVariables because corpse GUIDs are only meaningful within one play
-- session and shouldn't bloat the saved file across logins.
local SeenCorpses = {}  -- [mobKey] = { [guid] = true, ... }

-- Group loot attribution:
-- ourDamage     [mobGUID] = destName      mobs we or our group damaged, awaiting death
-- recentDeaths  [mobGUID] = {name,t}      recently-killed mobs with timestamp
-- recentDeathsCount                       size of recentDeaths, bounded
local ourDamage, recentDeaths = {}, {}
local recentDeathsCount = 0

-- Tracks which mob GUIDs have already had their first loot window opened.
-- A second LOOT_OPENED for the same Creature GUID means the player is
-- skinning, not looting — so those items route to Gathering instead.
local lootedCorpses = {}

-- Undo state: last ignore action, for the "Undo" footer affordance
-- { type = "session" | "permanent", item = "Name", expires = time }
local lastIgnoreAction = nil

-- The key of the loot source we're currently interacting with. Set in
-- LOOT_OPENED, used by CHAT_MSG_MONEY and CHAT_MSG_LOOT to attribute
-- items / gold to the correct bucket.
local currentLootKey = nil

-- After LOOT_CLOSED we keep the key for a brief grace window so any
-- CHAT_MSG_MONEY arriving immediately after still attributes correctly.
local lastLootKey = nil
local lastLootKeyAt = 0
local LOOT_CLOSE_GRACE = 3.0  -- seconds — wide enough to catch late echoes

-- Same-item dedup. WoW occasionally fires CHAT_MSG_LOOT twice for one
-- received item; this catches that. Resets every loot window.
local lastAddedItem    = nil  -- last item name added
local lastAddedQty     = 0
local lastAddedAt      = 0
local SAME_ITEM_DEDUP  = 0.2  -- seconds

-- Duplicate LOOT_OPENED dedup. The client occasionally fires LOOT_OPENED
-- twice for the same loot session; this catches that without blocking
-- legitimately-new loot windows whose LOOT_CLOSED was never delivered.
local lastLootOpenGUID = nil
local lastLootOpenAt   = 0
local LOOT_OPEN_DEDUP  = 0.5  -- seconds

-- Profession spell tracking. Prospecting and Disenchant don't open a
-- loot window — they hand items via "You receive loot:". Spell-cast
-- success sets a timestamp; CHAT_MSG_LOOT within the grace routes to
-- "Gathering" regardless of party state.
local lastProfessionCastAt = 0
local PROFESSION_GRACE = 5.0  -- seconds

-- Profession spell IDs (TBC Classic).
local PROFESSION_SPELL_IDS = {
    [31252] = true,  -- Prospecting
    [13262] = true,  -- Disenchant
}

-- Debug toggle. Off by default. Enable with /ll debug.
local debugEnabled = false
local function DPrint(...)
    if not debugEnabled then return end
    local parts = {}
    for i = 1, select("#", ...) do
        parts[i] = tostring(select(i, ...))
    end
    print("|cFFFF8800LL|r " .. table.concat(parts, " "))
end


-- Instance run-counter: track which instance we're currently in so we
-- can increment the run count exactly once per dungeon entry (not per mob).
local currentInstanceKey = nil
local instanceFirstLoad  = true  -- skip counting on login / UI reload

local labelPool = {}
local UpdateTrackerUI  -- forward decl

-- 2. MAIN FRAME --------------------------------------------
local f = CreateFrame("Frame", "LootTrackerMainFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate")
f:SetMovable(true); f:SetResizable(true)
f:SetSize(S.width or 320, S.height or 420); f:SetClampedToScreen(true)
if f.SetResizeBounds then
    f:SetResizeBounds(260, 220)
elseif f.SetMinResize then
    f:SetMinResize(260, 220)
end
f:SetBackdrop({
    bgFile   = "Interface\\ChatFrame\\ChatFrameBackground",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
})
f:SetBackdropColor(0, 0, 0, S.opacity or 0.4); f:Hide()
f:EnableMouse(true); f:RegisterForDrag("LeftButton")
f:SetScript("OnDragStart", f.StartMoving)
f:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    -- Save position
    local point, _, relPoint, x, y = self:GetPoint()
    S.point = { point = point, relPoint = relPoint, x = x, y = y }
end)

-- Restore saved position if we have one, otherwise center
local function RestorePosition()
    f:ClearAllPoints()
    if S.point and S.point.point then
        f:SetPoint(S.point.point, UIParent, S.point.relPoint or "CENTER",
                   S.point.x or 0, S.point.y or 0)
    else
        f:SetPoint("CENTER")
    end
end
RestorePosition()

-- Reset the frame to default size and position. Useful if the user has
-- resized/dragged the window somewhere unusable (e.g. resize grip off-screen).
local function ResetFrame()
    S.point  = nil
    S.width  = 320
    S.height = 420
    f:SetSize(320, 420)
    f:ClearAllPoints()
    f:SetPoint("CENTER")
    if not f:IsShown() then f:Show() end
    UpdateTrackerUI()
    print("|cFF00FFFFLoot Ledger:|r window reset to default size and position.")
end

local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
title:SetPoint("TOP", 0, -10); title:SetText("Loot Ledger")

local timerTxt = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
timerTxt:SetPoint("TOP", 0, -26); timerTxt:SetText("00:00:00")

local searchBox = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
-- Anchor both left and right so the search box stretches with the frame.
searchBox:SetHeight(20)
searchBox:SetPoint("TOPLEFT", 20, -50)
searchBox:SetPoint("TOPRIGHT", -20, -50)
searchBox:SetAutoFocus(false)
searchBox:SetScript("OnTextChanged", function(self)
    searchText = self:GetText():lower()
    UpdateTrackerUI()
end)
searchBox:SetScript("OnEnterPressed", function(self)
    -- Enter confirms the search: just drop focus, keep the text applied.
    self:ClearFocus()
end)
searchBox:SetScript("OnEscapePressed", function(self)
    -- Escape cancels: clear text and drop focus.
    self:SetText(""); self:ClearFocus()
end)

-- Clicking the tracker background (not a child widget) clears search focus.
-- Handles the common "I clicked on the tracker to look at it, stop typing" case.
f:HookScript("OnMouseDown", function()
    if searchBox:HasFocus() then
        searchBox:ClearFocus()
    end
end)

-- Close button (default 32x32)
local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
close:SetPoint("TOPRIGHT", 0, 0)

-- Settings cog. Sized to visually match the close button's X glyph,
-- and vertically centered with it.
local settingsBtn = CreateFrame("Button", nil, f)
settingsBtn:SetSize(22, 22)
settingsBtn:SetPoint("RIGHT", close, "LEFT", 0, 1)
settingsBtn:SetNormalTexture("Interface\\Buttons\\UI-OptionsButton")
settingsBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:SetText("Settings")
    GameTooltip:Show()
end)
settingsBtn:SetScript("OnLeave", GameTooltip_Hide)
-- OnClick handler set after SettingsFrame is built

-- Ignore-list toggle. Paper/note icon to distinguish from the cog.
local ignoreBtn = CreateFrame("Button", nil, f)
ignoreBtn:SetSize(22, 22)
ignoreBtn:SetPoint("RIGHT", settingsBtn, "LEFT", -2, 0)
ignoreBtn:SetNormalTexture("Interface\\Buttons\\UI-GuildButton-PublicNote-Up")
ignoreBtn:SetScript("OnClick", function()
    showIgnoreMode = not showIgnoreMode
    UpdateTrackerUI()
end)
ignoreBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:SetText(showIgnoreMode and "Back to Loot List" or "Open Ignore List")
    GameTooltip:Show()
end)
ignoreBtn:SetScript("OnLeave", GameTooltip_Hide)

local footer = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
footer:SetPoint("BOTTOMLEFT", 14, 6)
footer:SetPoint("BOTTOMRIGHT", -30, 6)
footer:SetJustifyH("LEFT")
footer:SetWordWrap(true)

-- Undo button — appears briefly after ignoring an item, lets the user reverse it.
local undoBtn = CreateFrame("Button", nil, f)
undoBtn:SetSize(280, 14)
undoBtn:SetPoint("BOTTOMLEFT", 14, 20)
undoBtn.txt = undoBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
undoBtn.txt:SetPoint("LEFT")
undoBtn:Hide()

local function PerformUndo()
    if not lastIgnoreAction then return end
    local action = lastIgnoreAction
    lastIgnoreAction = nil
    undoBtn:Hide()

    if action.type == "session" then
        SessionIgnore[action.item] = nil
        if action.snapshot then
            for mobKey, oldQty in pairs(action.snapshot) do
                local data = LootLedgerDB[mobKey]
                if data and data.loot then
                    data.loot[action.item] = oldQty
                end
            end
        end
    elseif action.type == "permanent" then
        LootLedgerIgnore[action.item] = nil
        if action.snapshot then
            for mobKey, oldQty in pairs(action.snapshot) do
                local data = LootLedgerDB[mobKey]
                if data and data.loot then
                    data.loot[action.item] = oldQty
                end
            end
        end
    elseif action.type == "mob" then
        LootLedgerMobIgnore[action.item] = nil
        if action.snapshot then
            LootLedgerDB[action.item] = action.snapshot
        end
        if action.corpseSnapshot then
            SeenCorpses[action.item] = action.corpseSnapshot
        end
    end
    UpdateTrackerUI()
end

undoBtn:SetScript("OnClick", PerformUndo)
undoBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("Click to undo this ignore action")
    GameTooltip:Show()
end)
undoBtn:SetScript("OnLeave", GameTooltip_Hide)

-- Timer: check every second whether the undo has expired
local undoTimer = CreateFrame("Frame")
undoTimer.t = 0
undoTimer:SetScript("OnUpdate", function(self, elapsed)
    self.t = self.t + elapsed
    if self.t < 0.5 then return end
    self.t = 0
    if lastIgnoreAction and GetTime() > lastIgnoreAction.expires then
        lastIgnoreAction = nil
        undoBtn:Hide()
    end
end)

local sf = CreateFrame("ScrollFrame", "LootTrackerScroll", f, "UIPanelScrollFrameTemplate")
sf:SetPoint("TOPLEFT", 12, -80); sf:SetPoint("BOTTOMRIGHT", -30, 40)
local Content = CreateFrame("Frame", nil, sf)
Content:SetSize(270, 1); sf:SetScrollChild(Content)

-- Resize grip (bottom-right corner)
local resizeGrip = CreateFrame("Button", nil, f)
resizeGrip:SetSize(16, 16); resizeGrip:SetPoint("BOTTOMRIGHT", -4, 4)
resizeGrip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
resizeGrip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
resizeGrip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
local isResizing = false

resizeGrip:SetScript("OnMouseDown", function()
    local left = f:GetLeft()
    local top  = f:GetTop()
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
    isResizing = true
    f:StartSizing("BOTTOMRIGHT")
end)
resizeGrip:SetScript("OnMouseUp", function()
    isResizing = false
    f:StopMovingOrSizing()
    S.width  = f:GetWidth()
    S.height = f:GetHeight()
    S.point  = { point = "TOPLEFT", relPoint = "BOTTOMLEFT",
                 x = f:GetLeft(), y = f:GetTop() }
    UpdateTrackerUI()
end)

-- 3. LABEL POOL --------------------------------------------
local function GetLabel()
    for _, btn in ipairs(labelPool) do
        if not btn:IsShown() then return btn end
    end
    local b = CreateFrame("Button", nil, Content)
    b:SetSize(250, 16)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetSize(14, 14)
    b.icon:SetPoint("LEFT", 0, 0)
    b.icon:Hide()
    b.txt = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.txt:SetPoint("LEFT", 0, 0)
    -- Right-aligned money/AH label. Top-anchored so when the row grows
    -- taller (long wrapped name), the price stays aligned with the first
    -- line of the name instead of drifting toward vertical centre.
    b.money = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.money:SetPoint("TOPRIGHT", 0, -1)
    b.money:SetJustifyH("RIGHT")
    b.money:SetJustifyV("TOP")
    table.insert(labelPool, b)
    return b
end

-- 3b. GRID ICON POOL ---------------------------------------
local iconPool = {}
local ICON_SIZE = 32

local function GetIconButton()
    for _, btn in ipairs(iconPool) do
        if not btn:IsShown() then return btn end
    end
    local b = CreateFrame("Button", nil, Content)
    b:SetSize(ICON_SIZE, ICON_SIZE)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetAllPoints(b)

    b.tint = b:CreateTexture(nil, "OVERLAY")
    b.tint:SetAllPoints(b)
    b.tint:SetBlendMode("ADD")
    b.tint:Hide()

    b.qty = b:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    b.qty:SetPoint("BOTTOMRIGHT", -2, 2)
    b.qty:SetJustifyH("RIGHT")

    table.insert(iconPool, b)
    return b
end

local function ClearIconPool()
    for _, btn in ipairs(iconPool) do
        btn:Hide()
        btn:SetScript("OnEnter",     nil)
        btn:SetScript("OnLeave",     nil)
        btn:SetScript("OnMouseDown", nil)
        btn.icon:SetTexture(nil)
        btn.tint:Hide()
        btn.qty:SetText("")
    end
end

local function ClearUI()
    for _, btn in ipairs(labelPool) do
        btn:Hide()
        btn:ClearAllPoints()
        btn:SetSize(250, 16)
        btn:SetScript("OnClick",     nil)
        btn:SetScript("OnMouseDown", nil)
        btn:SetScript("OnEnter",     nil)
        btn:SetScript("OnLeave",     nil)
        btn.txt:SetFontObject("GameFontHighlightSmall")
        btn.txt:SetText("")
        btn.txt:ClearAllPoints()
        btn.txt:SetPoint("LEFT", 0, 0)
        btn.icon:Hide()
        btn.icon:SetTexture(nil)
        btn.money:SetText("")
    end
    ClearIconPool()
end

-- 4. MONEY FORMATTING --------------------------------------
local function FormatWoWMoney(rawCopper)
    if not rawCopper or rawCopper <= 0 then return "0c" end
    local g = math.floor(rawCopper / 10000)
    local s = math.floor((rawCopper % 10000) / 100)
    local c = rawCopper % 100
    local out = ""
    if g > 0 then out = out .. "|cFFFFD700" .. g .. "g|r " end
    if s > 0 then out = out .. "|cFFC7C7C7" .. s .. "s|r " end
    if c > 0 then out = out .. "|cFFEDA55F" .. c .. "c|r" end
    return out
end

-- 4a. DATA SOURCE HELPERS ----------------------------------
-- Vendor price per unit. GetItemInfo's 11th return is sellPrice (copper).
-- Returns 0 if item is not in cache yet.
local function GetVendorPrice(link)
    if not link then return 0 end
    local _, _, _, _, _, _, _, _, _, _, sellPrice = GetItemInfo(link)
    return sellPrice or 0
end

-- Auctionator integration. Soft dependency: enabled only when its API
-- can be located. Auctionator's API surface differs across versions, so
-- we probe multiple known paths. Returns the path identifier ("v1",
-- "atr", etc.) when available, or false.
local function IsAuctionatorAvailable()
    -- Modern API: Auctionator.API.v1.GetAuctionPriceByItemID(callerID, itemID)
    if Auctionator and Auctionator.API and Auctionator.API.v1
       and type(Auctionator.API.v1.GetAuctionPriceByItemID) == "function" then
        return "v1_byID"
    end
    -- Same family, link-based variant
    if Auctionator and Auctionator.API and Auctionator.API.v1
       and type(Auctionator.API.v1.GetAuctionPriceByItemLink) == "function" then
        return "v1_byLink"
    end
    -- Legacy ATR API still shipped by some Classic builds
    if type(Atr_GetAuctionBuyout) == "function" then
        return "atr"
    end
    return false
end

-- Returns:
--   priceCopper, "ok"      → price available (per-unit, in copper)
--   nil,         "no_addon" → Auctionator isn't installed / API not found
--   nil,         "no_data"  → installed, but no scan data for this item
local function GetAuctionPrice(link)
    if not link then return nil, "no_data" end
    local api = IsAuctionatorAvailable()
    if not api then return nil, "no_addon" end

    if api == "v1_byID" then
        local itemID = GetItemInfoInstant and GetItemInfoInstant(link)
        if not itemID then return nil, "no_data" end
        local ok, price = pcall(Auctionator.API.v1.GetAuctionPriceByItemID,
                                "LootLedger", itemID)
        if not ok or not price or price <= 0 then return nil, "no_data" end
        return price, "ok"
    elseif api == "v1_byLink" then
        local ok, price = pcall(Auctionator.API.v1.GetAuctionPriceByItemLink,
                                "LootLedger", link)
        if not ok or not price or price <= 0 then return nil, "no_data" end
        return price, "ok"
    elseif api == "atr" then
        local ok, price = pcall(Atr_GetAuctionBuyout, link)
        if not ok or not price or price <= 0 then return nil, "no_data" end
        return price, "ok"
    end
    return nil, "no_addon"
end

-- Returns a bucket key "[Dungeon Name]" when the player is inside a dungeon
-- or raid instance, otherwise nil. Money and roll-won items received while
-- this returns non-nil get aggregated under the instance entry instead of
-- attributed to specific mobs (which is unreliable in groups).
local function GetInstanceBucketKey()
    if not GetInstanceInfo then return nil end
    local name, instanceType = GetInstanceInfo()
    if instanceType == "party" or instanceType == "raid" then
        if name and name ~= "" then
            return "[" .. name .. "]"
        end
    end
    return nil
end

-- Returns the active loot key (currentLootKey, or lastLootKey within
-- grace), or nil if no loot window is currently active or just-closed.
local function GetActiveLootKey()
    if currentLootKey then return currentLootKey end
    if lastLootKey and (GetTime() - lastLootKeyAt) < LOOT_CLOSE_GRACE then
        return lastLootKey
    end
    return nil
end

-- Detects if a CHAT_MSG_LOOT is a near-instant duplicate of the last
-- one we processed (Blizzard occasionally fires it twice).
local function IsRecentDuplicate(itemName, qty)
    return lastAddedItem == itemName
       and lastAddedQty  == qty
       and (GetTime() - lastAddedAt) < SAME_ITEM_DEDUP
end

-- Adds an item to a bucket. Honors all ignore lists. Creates the entry
-- if needed. Returns true if the item was added, false if filtered.
local function AddItemToBucket(key, itemName, link, qty)
    if not key or not itemName or not link or not qty or qty <= 0 then
        return false
    end
    if LootLedgerMobIgnore[key] then return false end
    if LootLedgerIgnore[itemName] or SessionIgnore[itemName] then return false end
    if not LootLedgerDB[key] then
        LootLedgerDB[key] = { loot = {}, links = {}, totalGold = 0, kills = 0 }
    end
    local data = LootLedgerDB[key]
    data.loot[itemName]  = (data.loot[itemName] or 0) + qty
    data.links           = data.links or {}
    data.links[itemName] = link
    data.lastSeen        = time()
    return true
end

-- 4b. SETTINGS PANEL ---------------------------------------
local settingsFrame = CreateFrame("Frame", "LootLedgerSettings", UIParent, BackdropTemplateMixin and "BackdropTemplate")
settingsFrame:SetSize(280, 280); settingsFrame:SetPoint("CENTER")
settingsFrame:SetFrameStrata("DIALOG")
settingsFrame:SetBackdrop({
    bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 },
})
settingsFrame:SetMovable(true); settingsFrame:EnableMouse(true)
settingsFrame:RegisterForDrag("LeftButton")
settingsFrame:SetScript("OnDragStart", settingsFrame.StartMoving)
settingsFrame:SetScript("OnDragStop",  settingsFrame.StopMovingOrSizing)
settingsFrame:Hide()

local sTitle = settingsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
sTitle:SetPoint("TOP", 0, -14); sTitle:SetText("Loot Ledger — Settings")

local sClose = CreateFrame("Button", nil, settingsFrame, "UIPanelCloseButton")
sClose:SetPoint("TOPRIGHT", -4, -4)

-- Opacity slider
local opacitySlider = CreateFrame("Slider", "LootLedgerOpacitySlider", settingsFrame, "OptionsSliderTemplate")
opacitySlider:SetPoint("TOP", 0, -50)
opacitySlider:SetWidth(220); opacitySlider:SetMinMaxValues(0, 1); opacitySlider:SetValueStep(0.05)
opacitySlider:SetObeyStepOnDrag(true); opacitySlider:SetValue(S.opacity)
_G[opacitySlider:GetName().."Low"]:SetText("0%")
_G[opacitySlider:GetName().."High"]:SetText("100%")
_G[opacitySlider:GetName().."Text"]:SetText(string.format("Background Opacity: %d%%", S.opacity * 100))
opacitySlider:SetScript("OnValueChanged", function(self, value)
    S.opacity = value
    f:SetBackdropColor(0, 0, 0, value)
    _G[self:GetName().."Text"]:SetText(string.format("Background Opacity: %d%%", value * 100))
end)

-- Compact grid view checkbox
local gridCB = CreateFrame("CheckButton", "LootLedgerGridCB", settingsFrame, "InterfaceOptionsCheckButtonTemplate")
gridCB:SetPoint("TOPLEFT", 20, -95)
gridCB.Text:SetText("Compact grid view (icons only)")
gridCB:SetChecked(S.gridView)
gridCB:SetScript("OnClick", function(self)
    S.gridView = self:GetChecked() and true or false
    UpdateTrackerUI()
end)

-- Combat hide checkbox
local combatHideCB = CreateFrame("CheckButton", "LootLedgerCombatHideCB", settingsFrame, "InterfaceOptionsCheckButtonTemplate")
combatHideCB:SetPoint("TOPLEFT", 20, -125)
combatHideCB.Text:SetText("Hide during combat")
combatHideCB:SetChecked(S.combatHide)
combatHideCB:SetScript("OnClick", function(self)
    S.combatHide = self:GetChecked() and true or false
end)

-- Rarity colors checkbox
local rarityCB = CreateFrame("CheckButton", "LootLedgerRarityCB", settingsFrame, "InterfaceOptionsCheckButtonTemplate")
rarityCB:SetPoint("TOPLEFT", 20, -155)
rarityCB.Text:SetText("Color item names by rarity")
rarityCB:SetChecked(S.rarityColors)
rarityCB:SetScript("OnClick", function(self)
    S.rarityColors = self:GetChecked() and true or false
    UpdateTrackerUI()
end)

-- Shift-click to link checkbox
local linkCB = CreateFrame("CheckButton", "LootLedgerLinkCB", settingsFrame, "InterfaceOptionsCheckButtonTemplate")
linkCB:SetPoint("TOPLEFT", 20, -185)
linkCB.Text:SetText("Shift-click item to link in chat")
linkCB:SetChecked(S.shiftClickLink)
linkCB:SetScript("OnClick", function(self)
    S.shiftClickLink = self:GetChecked() and true or false
end)

-- Reset window size/position
local resetWindowBtn = CreateFrame("Button", nil, settingsFrame, "UIPanelButtonTemplate")
resetWindowBtn:SetSize(120, 24); resetWindowBtn:SetPoint("BOTTOMLEFT", 20, 20)
resetWindowBtn:SetText("Reset Window")
resetWindowBtn:SetScript("OnClick", function()
    ResetFrame()
end)

-- Reset all tracked loot
local resetBtn = CreateFrame("Button", nil, settingsFrame, "UIPanelButtonTemplate")
resetBtn:SetSize(120, 24); resetBtn:SetPoint("BOTTOMRIGHT", -20, 20)
resetBtn:SetText("Reset Session")
resetBtn:SetScript("OnClick", function()
    StaticPopup_Show("LOOTLEDGER_CONFIRM_RESET_SESSION")
end)

-- Wire the cog button now that settings frame exists
settingsBtn:SetScript("OnClick", function()
    if settingsFrame:IsShown() then settingsFrame:Hide() else settingsFrame:Show() end
end)


local function SortedKeys(tbl)
    local keys = {}
    for k in pairs(tbl) do keys[#keys + 1] = k end
    table.sort(keys)
    return keys
end

-- 5. RIGHT-CLICK CURSOR DROPDOWN ---------------------------
local ItemMenu = CreateFrame("Frame", "LootLedgerItemMenu", UIParent, "UIDropDownMenuTemplate")

local function InitItemMenu(self, level)
    local itemName = self.itemName
    if not itemName then return end

    local info = UIDropDownMenu_CreateInfo()
    info.isTitle, info.notCheckable = true, true
    info.text = itemName
    UIDropDownMenu_AddButton(info, level)

    info = UIDropDownMenu_CreateInfo()
    info.notCheckable = true
    info.text = "|cFFFF8800Ignore for this session|r"
    info.func = function()
        local snapshot = {}
        for mobKey, data in pairs(LootLedgerDB) do
            if data.loot and data.loot[itemName] then
                snapshot[mobKey] = data.loot[itemName]
                data.loot[itemName] = nil
            end
        end
        SessionIgnore[itemName] = true
        lastIgnoreAction = {
            type = "session", item = itemName,
            snapshot = snapshot, expires = GetTime() + 6,
        }
        CloseDropDownMenus()
        UpdateTrackerUI()
    end
    UIDropDownMenu_AddButton(info, level)

    info = UIDropDownMenu_CreateInfo()
    info.notCheckable = true
    info.text = "|cFFFF4444Ignore permanently|r"
    info.func = function()
        local snapshot = {}
        for mobKey, data in pairs(LootLedgerDB) do
            if data.loot and data.loot[itemName] then
                snapshot[mobKey] = data.loot[itemName]
                data.loot[itemName] = nil
            end
        end
        LootLedgerIgnore[itemName] = true
        lastIgnoreAction = {
            type = "permanent", item = itemName,
            snapshot = snapshot, expires = GetTime() + 6,
        }
        CloseDropDownMenus()
        UpdateTrackerUI()
    end
    UIDropDownMenu_AddButton(info, level)

    info = UIDropDownMenu_CreateInfo()
    info.notCheckable = true
    info.text = CANCEL or "Cancel"
    info.func = function() CloseDropDownMenus() end
    UIDropDownMenu_AddButton(info, level)
end

UIDropDownMenu_Initialize(ItemMenu, InitItemMenu, "MENU")

local function ShowItemMenu(itemName)
    ItemMenu.itemName = itemName
    ToggleDropDownMenu(1, nil, ItemMenu, "cursor", 0, 0)
end

-- Confirmation popup for mob reset
StaticPopupDialogs["LOOTLEDGER_CONFIRM_RESET_MOB"] = {
    text         = "Reset all tracked loot and kills for |cFF00FFFF%s|r?",
    button1      = YES or "Yes",
    button2      = NO  or "No",
    OnAccept     = function(self, mobKey)
        if mobKey and LootLedgerDB[mobKey] then
            LootLedgerDB[mobKey] = nil
            SeenCorpses[mobKey] = nil
            UpdateTrackerUI()
        end
    end,
    timeout      = 0,
    whileDead    = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

StaticPopupDialogs["LOOTLEDGER_CONFIRM_RESET_SESSION"] = {
    text         = "Clear all tracked loot, kills, and money?\nThis cannot be undone.",
    button1      = YES or "Yes",
    button2      = NO  or "No",
    OnAccept     = function()
        wipe(LootLedgerDB)
        wipe(SessionIgnore)
        wipe(SeenCorpses)
        wipe(lootedCorpses)
        startTime = time()
        UpdateTrackerUI()
    end,
    timeout      = 0,
    whileDead    = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- Mob-row dropdown
local MobMenu = CreateFrame("Frame", "LootLedgerMobMenu", UIParent, "UIDropDownMenuTemplate")

local function InitMobMenu(self, level)
    local mobKey = self.mobName
    if not mobKey then return end
    local displayName = mobKey

    local info = UIDropDownMenu_CreateInfo()
    info.isTitle, info.notCheckable = true, true
    info.text = displayName
    UIDropDownMenu_AddButton(info, level)

    info = UIDropDownMenu_CreateInfo()
    info.notCheckable = true
    info.text = "|cFFFF4444Reset loot|r"
    info.func = function()
        CloseDropDownMenus()
        StaticPopup_Show("LOOTLEDGER_CONFIRM_RESET_MOB", displayName, nil, mobKey)
    end
    UIDropDownMenu_AddButton(info, level)

    info = UIDropDownMenu_CreateInfo()
    info.notCheckable = true
    info.text = "|cFFFF8800Ignore mob|r"
    info.func = function()
        CloseDropDownMenus()
        local snapshot       = LootLedgerDB[mobKey]
        local corpseSnapshot = SeenCorpses[mobKey]
        LootLedgerDB[mobKey] = nil
        SeenCorpses[mobKey]  = nil
        LootLedgerMobIgnore[mobKey] = true
        lastIgnoreAction = {
            type = "mob", item = mobKey,
            snapshot = snapshot, corpseSnapshot = corpseSnapshot,
            expires = GetTime() + 6,
        }
        UpdateTrackerUI()
    end
    UIDropDownMenu_AddButton(info, level)

    info = UIDropDownMenu_CreateInfo()
    info.notCheckable = true
    info.text = CANCEL or "Cancel"
    info.func = function() CloseDropDownMenus() end
    UIDropDownMenu_AddButton(info, level)
end

UIDropDownMenu_Initialize(MobMenu, InitMobMenu, "MENU")

local function ShowMobMenu(mobName)
    MobMenu.mobName = mobName
    ToggleDropDownMenu(1, nil, MobMenu, "cursor", 0, 0)
end

-- 6. DRAWING -----------------------------------------------
local function matchesSearch(a, b)
    if searchText == "" then return true end
    return (a and a:lower():find(searchText, 1, true))
        or (b and b:lower():find(searchText, 1, true))
end

local function isHidden(item)
    return LootLedgerIgnore[item] or SessionIgnore[item]
end

-- Shared hover/click behavior for item widgets (used by both list rows and grid icons)
local function AttachItemHandlers(widget, item, link)
    widget:SetScript("OnEnter", function(self)
        local screenW = GetScreenWidth()
        local fRight  = f:GetRight() or screenW
        GameTooltip:SetOwner(f, "ANCHOR_NONE")
        GameTooltip:ClearAllPoints()
        if fRight + 300 < screenW then
            GameTooltip:SetPoint("TOPLEFT", f, "TOPRIGHT", 5, 0)
        else
            GameTooltip:SetPoint("TOPRIGHT", f, "TOPLEFT", -5, 0)
        end
        if link then
            GameTooltip:SetHyperlink(link)
        else
            GameTooltip:SetText(item)
        end
        GameTooltip:Show()
    end)
    widget:SetScript("OnLeave", GameTooltip_Hide)

    widget:SetScript("OnMouseDown", function(_, btn)
        if btn == "RightButton" then
            ShowItemMenu(item)
        elseif btn == "LeftButton" and S.shiftClickLink
               and IsShiftKeyDown() and link then
            local edit = ChatEdit_GetActiveWindow()
                      or ChatEdit_ChooseBoxForSend()
            if edit then
                if not edit:IsShown() then
                    ChatEdit_ActivateChat(edit)
                end
                edit:Insert(link)
            end
        end
    end)
end

-- Returns rarity color {r,g,b,hex} and quality (int), or nil/nil if unknown
local function GetRarityColor(link)
    if not link then return nil, nil end
    local _, _, quality = GetItemInfo(link)
    if quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality] then
        return ITEM_QUALITY_COLORS[quality], quality
    end
    return nil, nil
end

function UpdateTrackerUI()
    ClearUI()
    local offset, totalVal = -5, 0
    Content:SetWidth(f:GetWidth() - 40)

    if showIgnoreMode then
        -- ----- Ignore List View -----
        title:SetText("|cFFFFD100Ignore List|r")

        local permKeys      = SortedKeys(LootLedgerIgnore)
        local sessKeys      = SortedKeys(SessionIgnore)
        local mobIgnoreKeys = SortedKeys(LootLedgerMobIgnore)

        local function RenderSection(headerText, entries, removeAll, removeOne)
            local hdr = GetLabel()
            hdr:SetPoint("TOPLEFT", 5, offset)
            hdr:EnableMouse(false)
            hdr.txt:SetFontObject("GameFontNormal")
            hdr.txt:SetText(headerText)
            hdr:Show()
            if #entries > 0 then
                local raBtn = GetLabel()
                raBtn:SetSize(90, 14)
                raBtn:SetPoint("TOPRIGHT", -22, offset)
                raBtn.txt:ClearAllPoints()
                raBtn.txt:SetPoint("RIGHT", 0, 0)
                raBtn.txt:SetText("|cFFFF4444[Remove All]|r")
                raBtn:SetScript("OnClick", removeAll)
                raBtn:Show()
            end
            offset = offset - 16

            if #entries == 0 then
                local empty = GetLabel()
                empty:SetPoint("TOPLEFT", 15, offset)
                empty.txt:SetText("|cFF888888(none)|r")
                empty:Show(); offset = offset - 14
            else
                for _, key in ipairs(entries) do
                    local nameRow = GetLabel()
                    nameRow:SetPoint("TOPLEFT", 15, offset)
                    nameRow:EnableMouse(false)
                    nameRow.txt:SetText(key)
                    nameRow:Show()
                    local rmBtn = GetLabel()
                    rmBtn:SetSize(70, 14)
                    rmBtn:SetPoint("TOPRIGHT", -22, offset)
                    rmBtn.txt:ClearAllPoints()
                    rmBtn.txt:SetPoint("RIGHT", 0, 0)
                    rmBtn.txt:SetText("|cFFFF4444[Remove]|r")
                    rmBtn:SetScript("OnClick", function() removeOne(key) end)
                    rmBtn:Show()
                    offset = offset - 14
                end
            end
            offset = offset - 8
        end

        RenderSection("|cFFFFD100Permanent|r", permKeys,
            function() wipe(LootLedgerIgnore); UpdateTrackerUI() end,
            function(k) LootLedgerIgnore[k] = nil; UpdateTrackerUI() end)

        RenderSection("|cFFFFD100Session|r", sessKeys,
            function() wipe(SessionIgnore); UpdateTrackerUI() end,
            function(k) SessionIgnore[k] = nil; UpdateTrackerUI() end)

        RenderSection("|cFFFFD100Mobs|r", mobIgnoreKeys,
            function() wipe(LootLedgerMobIgnore); UpdateTrackerUI() end,
            function(k) LootLedgerMobIgnore[k] = nil; UpdateTrackerUI() end)

        footer:SetText(string.format("%d permanent, %d session, %d mobs",
            #permKeys, #sessKeys, #mobIgnoreKeys))
    else
        -- ----- Normal Loot View -----
        title:SetText("Loot Ledger")

        local totalVendor = 0
        local totalAH     = 0

        local mobKeys = {}
        for k in pairs(LootLedgerDB) do
            if not LootLedgerMobIgnore[k] then mobKeys[#mobKeys + 1] = k end
        end
        table.sort(mobKeys, function(a, b)
            local ta = LootLedgerDB[a].lastSeen or 0
            local tb = LootLedgerDB[b].lastSeen or 0
            if ta ~= tb then return ta > tb end
            return a < b
        end)

        -- Pre-pass: decide whether to show the "Scan AH for price" banner.
        -- Only shown when Auctionator is installed but no item has data
        -- (i.e. the player hasn't run a scan yet this session).
        local needsAHScan = IsAuctionatorAvailable()
        if needsAHScan then
            for _, mobKey in ipairs(mobKeys) do
                local data = LootLedgerDB[mobKey]
                for item, qty in pairs(data.loot or {}) do
                    if qty > 0 and not isHidden(item) then
                        local link = data.links and data.links[item]
                        if link then
                            local _, status = GetAuctionPrice(link)
                            if status == "ok" then
                                needsAHScan = false
                                break
                            end
                        end
                    end
                end
                if not needsAHScan then break end
            end
        end

        if needsAHScan then
            local banner = GetLabel()
            banner:SetPoint("TOPLEFT", 5, offset)
            banner:SetPoint("RIGHT", Content, "RIGHT", -5, 0)
            banner:EnableMouse(false)
            banner.txt:SetFontObject("GameFontHighlightSmall")
            banner.txt:SetText("|cFFFFAA00Scan auction house for AH prices.|r")
            banner:Show()
            offset = offset - 16
        end

        for _, mobKey in ipairs(mobKeys) do
            local data = LootLedgerDB[mobKey]
            local mobDisplay = mobKey

            local hasVisible = false
            for item, qty in pairs(data.loot or {}) do
                if qty > 0 and not isHidden(item) and matchesSearch(mobDisplay, item) then
                    hasVisible = true; break
                end
            end
            if not hasVisible and (data.totalGold or 0) > 0 and matchesSearch(mobDisplay, nil) then
                hasVisible = true
            end

            if hasVisible then
                local visibleItems = {}
                for _, item in ipairs(SortedKeys(data.loot)) do
                    local qty = data.loot[item]
                    if qty > 0 and not isHidden(item) and matchesSearch(mobDisplay, item) then
                        local link  = data.links and data.links[item]
                        local price = GetVendorPrice(link)
                        local ahPrice = GetAuctionPrice(link)  -- nil if unavailable
                        visibleItems[#visibleItems + 1] = {
                            name     = item,
                            qty      = qty,
                            link     = link,
                            value    = price * qty,
                            hasPrice = price > 0,
                            ahPrice  = ahPrice,
                            ahValue  = (ahPrice and ahPrice * qty) or 0,
                        }
                    end
                end
                table.sort(visibleItems, function(a, b)
                    if a.hasPrice ~= b.hasPrice then return a.hasPrice end
                    if a.value ~= b.value then return a.value > b.value end
                    return a.name < b.name
                end)

                local mobVendor, mobAH = 0, 0
                for _, e in ipairs(visibleItems) do
                    mobVendor = mobVendor + e.value
                    mobAH    = mobAH    + e.ahValue
                end
                totalVendor = totalVendor + mobVendor
                totalAH     = totalAH     + mobAH
                totalVal = totalVal + (data.totalGold or 0)

                local isInstanceBucket = mobDisplay:sub(1, 1) == "["
                local collapsed = S.collapsed[mobKey] and true or false
                local glyph = collapsed and "|cFF888888[+]|r" or "|cFF888888[-]|r"

                local nameColor = isInstanceBucket and "|cFFFFD100" or "|cFF00FFFF"
                local kills = data.kills or 0

                -- Only show dropped gold per mob. Vendor value is footer-only.
                local moneyText = ""
                if (data.totalGold or 0) > 0 then
                    moneyText = FormatWoWMoney(data.totalGold)
                end

                local headerText = string.format("%s %s%s|r (%d)",
                    glyph, nameColor, mobDisplay, kills)

                local mName = GetLabel()
                -- Span the full content width so the money label can right-align.
                mName:SetPoint("TOPLEFT", 5, offset)
                mName:SetPoint("RIGHT", Content, "RIGHT", -5, 0)

                -- Responsive layout: bound the name to the money label's
                -- left edge with word-wrap so long names line-break instead
                -- of overlapping the gold text.
                mName.txt:ClearAllPoints()
                mName.txt:SetPoint("TOPLEFT", 0, 0)
                mName.txt:SetPoint("RIGHT", mName.money, "LEFT", -8, 0)
                mName.txt:SetWordWrap(true)
                mName.txt:SetJustifyH("LEFT")
                mName.txt:SetJustifyV("TOP")
                mName.txt:SetFontObject("GameFontNormal")
                mName.txt:SetText(headerText)
                mName.money:SetText(moneyText)

                local mh = math.max(15, math.ceil((mName.txt:GetStringHeight() or 15) + 2))
                mName:SetHeight(mh)
                mName:SetScript("OnMouseDown", function(_, btn)
                    if btn == "LeftButton" then
                        S.collapsed[mobKey] = not S.collapsed[mobKey] or nil
                        UpdateTrackerUI()
                    elseif btn == "RightButton" then
                        ShowMobMenu(mobKey)
                    end
                end)
                mName:Show(); offset = offset - mh

                if not collapsed then
                    if S.gridView then
                        -- ===== GRID MODE =====
                        local gap    = 2
                        local cell   = ICON_SIZE + gap
                        local usable = math.max(cell, Content:GetWidth() - 20)
                        local perRow = math.max(1, math.floor(usable / cell))

                        local col = 0
                        for i, entry in ipairs(visibleItems) do
                            local itemName = entry.name
                            local link     = data.links and data.links[itemName]
                            local btn      = GetIconButton()

                            btn:SetPoint("TOPLEFT", 15 + col * cell, offset)

                            local tex = link and GetItemIcon and GetItemIcon(link)
                            btn.icon:SetTexture(tex or "Interface\\Icons\\INV_Misc_QuestionMark")

                            if S.rarityColors then
                                local c, quality = GetRarityColor(link)
                                if c and quality and quality >= 2 then
                                    btn.tint:SetColorTexture(c.r, c.g, c.b, 0.35)
                                    btn.tint:Show()
                                else
                                    btn.tint:Hide()
                                end
                            else
                                btn.tint:Hide()
                            end

                            if entry.qty > 1 then
                                btn.qty:SetText(entry.qty)
                            else
                                btn.qty:SetText("")
                            end

                            AttachItemHandlers(btn, itemName, link)
                            btn:Show()

                            col = col + 1
                            if col >= perRow and i < #visibleItems then
                                col = 0
                                offset = offset - cell
                            end
                        end
                        if #visibleItems > 0 then
                            offset = offset - cell - 2
                        end
                    else
                        -- ===== LIST MODE =====
                        for _, entry in ipairs(visibleItems) do
                            local itemName, qty = entry.name, entry.qty
                            local link = data.links and data.links[itemName]
                            local row  = GetLabel()
                            -- Span full content width so the AH-price label
                            -- can right-align without overlapping the name.
                            row:SetPoint("TOPLEFT", 25, offset)
                            row:SetPoint("RIGHT", Content, "RIGHT", -5, 0)

                            -- Anchor the name from the icon (or row's left
                            -- edge) on the left, to the money label on the
                            -- right, so word-wrap kicks in instead of
                            -- visually overlapping the AH price.
                            row.txt:ClearAllPoints()
                            if link then
                                local icon = GetItemIcon and GetItemIcon(link)
                                if icon then
                                    row.icon:SetTexture(icon)
                                    row.icon:ClearAllPoints()
                                    row.icon:SetPoint("TOPLEFT", 0, -1)
                                    row.icon:Show()
                                    row.txt:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 4, 0)
                                else
                                    row.txt:SetPoint("TOPLEFT", 0, 0)
                                end
                            else
                                row.txt:SetPoint("TOPLEFT", 0, 0)
                            end
                            -- Item rows have no per-row gold/AH column;
                            -- only the mob header shows dropped gold and
                            -- the footer shows the AH total. Bound the
                            -- name to the row's right edge so long names
                            -- still wrap responsively.
                            row.txt:SetPoint("RIGHT", -5, 0)
                            row.txt:SetWordWrap(true)
                            row.txt:SetJustifyH("LEFT")
                            row.txt:SetJustifyV("TOP")

                            local colorStart, colorEnd = "", ""
                            if S.rarityColors then
                                local c = GetRarityColor(link)
                                if c then
                                    colorStart = c.hex or ""
                                    colorEnd   = "|r"
                                end
                            end
                            row.txt:SetText(colorStart .. itemName .. colorEnd .. " x" .. qty)

                            local rh = math.max(14, math.ceil((row.txt:GetStringHeight() or 14) + 1))
                            row:SetHeight(rh)
                            AttachItemHandlers(row, itemName, link)
                            row:Show(); offset = offset - rh
                        end
                    end
                end
                offset = offset - 3
            end
        end

        local parts = {}
        parts[#parts + 1] = "Dropped: " .. FormatWoWMoney(totalVal)
        if totalVendor > 0 then
            parts[#parts + 1] = "Vendor: " .. FormatWoWMoney(totalVendor)
        end
        if totalAH > 0 then
            parts[#parts + 1] = "AH: " .. FormatWoWMoney(totalAH)
        end
        footer:SetText(table.concat(parts, "\n"))
    end

    Content:SetHeight(math.abs(offset) + 40)

    if lastIgnoreAction and GetTime() < lastIgnoreAction.expires then
        undoBtn.txt:SetText("|cFFFF8800Undo:|r " .. lastIgnoreAction.item
            .. " (" .. lastIgnoreAction.type .. ")")
        undoBtn:Show()
    else
        lastIgnoreAction = nil
        undoBtn:Hide()
    end
end

-- 7. EVENTS ------------------------------------------------
local E = CreateFrame("Frame")
E:RegisterEvent("ADDON_LOADED")
E:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
E:RegisterEvent("LOOT_OPENED")
E:RegisterEvent("LOOT_CLOSED")
E:RegisterEvent("CHAT_MSG_MONEY")
E:RegisterEvent("CHAT_MSG_LOOT")
E:RegisterEvent("PLAYER_REGEN_DISABLED")
E:RegisterEvent("PLAYER_REGEN_ENABLED")
E:RegisterEvent("GET_ITEM_INFO_RECEIVED")
E:RegisterEvent("PLAYER_ENTERING_WORLD")
E:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")

-- Build locale-independent patterns from Blizzard's own format strings.
local function buildMoneyPattern(fmt)
    if not fmt then return nil end
    local p = fmt:gsub("([%-%.%+%[%]%(%)%$%^%%%?%*])", "%%%1")
    p = p:gsub("%%%%d", "(%%d+)")
    return p
end

local GOLD_PATTERN   = buildMoneyPattern(GOLD_AMOUNT)
local SILVER_PATTERN = buildMoneyPattern(SILVER_AMOUNT)
local COPPER_PATTERN = buildMoneyPattern(COPPER_AMOUNT)

-- Build patterns for "You receive loot: <link>." messages.
-- Deliberately does NOT match LOOT_ITEM_PUSHED_SELF ("You receive item:")
-- which fires for trades, crafting, and quest rewards.
local function buildLootItemPattern(fmt)
    if not fmt then return nil end
    local p = fmt:gsub("([%-%.%+%[%]%(%)%$%^%%%?%*])", "%%%1")
    p = p:gsub("%%%%s", "(.+)")
    p = p:gsub("%%%%d", "(%%d+)")
    return p
end

local LOOT_ITEM_PATTERN          = buildLootItemPattern(LOOT_ITEM_SELF)
local LOOT_ITEM_MULTIPLE_PATTERN = buildLootItemPattern(LOOT_ITEM_SELF_MULTIPLE)

-- 7b. EVENT HANDLERS (one function per event) ---------------

local function OnAddonLoaded(loaded)
    if loaded ~= ADDON_NAME then return end

    -- Scrub legacy fields no longer used (kept only for backwards compat).
    for _, data in pairs(LootLedgerDB) do
        data.seenCorpses = nil
        data.zone        = nil
    end

    -- One-time migration: an earlier build keyed entries as "Name|Zone".
    -- Merge those into plain "Name" entries so same-named mobs combine.
    local merges = {}
    for key in pairs(LootLedgerDB) do
        if type(key) == "string" and key:find("|", 1, true)
           and key:sub(1, 1) ~= "[" then
            merges[#merges + 1] = key
        end
    end
    for _, oldKey in ipairs(merges) do
        local oldData = LootLedgerDB[oldKey]
        local pipe    = oldKey:find("|", 1, true)
        local newKey  = pipe and oldKey:sub(1, pipe - 1) or oldKey
        local newData = LootLedgerDB[newKey]
        if not newData then
            LootLedgerDB[newKey] = oldData
        else
            newData.kills     = (newData.kills or 0) + (oldData.kills or 0)
            newData.totalGold = (newData.totalGold or 0) + (oldData.totalGold or 0)
            if (oldData.lastSeen or 0) > (newData.lastSeen or 0) then
                newData.lastSeen = oldData.lastSeen
            end
            newData.loot  = newData.loot  or {}
            newData.links = newData.links or {}
            for item, qty in pairs(oldData.loot or {}) do
                newData.loot[item] = (newData.loot[item] or 0) + (qty or 0)
            end
            for item, link in pairs(oldData.links or {}) do
                newData.links[item] = newData.links[item] or link
            end
        end
        LootLedgerDB[oldKey] = nil
    end

    UpdateTrackerUI()
end

local function OnCombatLog()
    local _, sub, _, sourceGUID, _, sourceFlags, _,
          destGUID, destName, destFlags = CombatLogGetCurrentEventInfo()

    -- Only track hostile/neutral non-player targets.
    local HOSTILE = COMBATLOG_OBJECT_REACTION_HOSTILE or 0x40
    local NEUTRAL = COMBATLOG_OBJECT_REACTION_NEUTRAL or 0x20
    local destIsTrackableMob = destFlags
        and (bit.band(destFlags, HOSTILE) > 0 or bit.band(destFlags, NEUTRAL) > 0)
        and bit.band(destFlags, COMBATLOG_OBJECT_TYPE_PLAYER or 0x400) == 0

    if not destIsTrackableMob then return end

    -- Is the damage source us, our pet, or a group member?
    local AFFIL_MINE  = COMBATLOG_OBJECT_AFFILIATION_MINE  or 0x1
    local AFFIL_PARTY = COMBATLOG_OBJECT_AFFILIATION_PARTY or 0x2
    local AFFIL_RAID  = COMBATLOG_OBJECT_AFFILIATION_RAID  or 0x4
    local sourceIsUs = sourceFlags
        and bit.band(sourceFlags, AFFIL_MINE + AFFIL_PARTY + AFFIL_RAID) > 0

    -- Any damage from us/group marks the mob as ours.
    if sourceIsUs and destGUID and destGUID ~= "" then
        if sub == "SWING_DAMAGE" or sub == "RANGE_DAMAGE"
           or sub == "SPELL_DAMAGE" or sub == "SPELL_PERIODIC_DAMAGE"
           or sub == "SPELL_BUILDING_DAMAGE" then
            ourDamage[destGUID] = destName or true
        end
    end

    -- On death: record a kill if we damaged this mob (outdoor only).
    -- Inside dungeons the run counter is bumped once on entry.
    if sub == "UNIT_DIED" and destGUID and destGUID ~= "" then
        if ourDamage[destGUID] then
            recentDeaths[destGUID] = { name = destName, t = GetTime() }
            recentDeathsCount = recentDeathsCount + 1
            -- Cap at 200; keep the 100 most recent.
            if recentDeathsCount > 200 then
                local entries = {}
                for g, v in pairs(recentDeaths) do
                    entries[#entries + 1] = { guid = g, name = v.name, t = v.t }
                end
                table.sort(entries, function(a, b) return a.t > b.t end)
                local keep = {}
                for i = 1, math.min(100, #entries) do
                    local e = entries[i]
                    keep[e.guid] = { name = e.name, t = e.t }
                end
                recentDeaths      = keep
                recentDeathsCount = 100
            end
            ourDamage[destGUID] = nil
            -- Note: we deliberately do NOT create a LootLedgerDB entry here.
            -- Mobs only enter the tracker when you actually loot their corpse
            -- (handled in OnLootOpened). Killing without looting → invisible.
        end
    end
end

local function OnLootOpened()
    -- 1. Identify the source by GUID
    local corpseGUID
    if GetLootSourceInfo then
        for i = 1, GetNumLootItems() do
            local g = GetLootSourceInfo(i)
            if g and g ~= "" then corpseGUID = g; break end
        end
    end

    DPrint("LOOT_OPENED guid=", corpseGUID or "nil",
           "numItems=", GetNumLootItems and GetNumLootItems() or "?")

    -- Skip if this is a real duplicate event for the same source within
    -- the dedup window. (We deliberately do NOT use `if currentLootKey
    -- then return end` — that would also block legitimate new windows
    -- whose previous LOOT_CLOSED never arrived.)
    if corpseGUID and corpseGUID == lastLootOpenGUID
       and (GetTime() - lastLootOpenAt) < LOOT_OPEN_DEDUP then
        DPrint("  → skipped (duplicate within", LOOT_OPEN_DEDUP, "sec)")
        return
    end
    lastLootOpenGUID = corpseGUID
    lastLootOpenAt   = GetTime()

    local isGameObject = corpseGUID and corpseGUID:sub(1, 11) == "GameObject-"
    local isMobCorpse  = corpseGUID and corpseGUID:sub(1, 9)  == "Creature-"
    -- "Item-..." GUIDs come from profession activities like Prospecting,
    -- Disenchanting, Milling, and opening lockboxes — the source is an
    -- item in your bag, not a world object. Treat as gathering.
    local isItemSource = corpseGUID and corpseGUID:sub(1, 5)  == "Item-"

    -- 2. Classify the loot window
    local isGathering = false  -- true for nodes / herbs / skinning / profession
    local mobName              -- only meaningful when not gathering

    if isGameObject or isItemSource then
        isGathering = true
    elseif isMobCorpse and recentDeaths[corpseGUID] then
        if lootedCorpses[corpseGUID] then
            isGathering = true   -- second open of this corpse = skinning
        else
            mobName = recentDeaths[corpseGUID].name
            lootedCorpses[corpseGUID] = true
        end
    elseif isMobCorpse then
        mobName = "Unknown"      -- creature corpse but we never damaged it
    else
        mobName = "Unknown"      -- unrecognisable GUID (special-death mobs)
    end

    -- 3. Choose the destination bucket
    --    Inside an instance everything aggregates to the dungeon bucket.
    --    Outside, gathering always goes to "Gathering"; mob loot uses
    --    the mob name (solo or grouped — no per-party bucket anymore).
    local instanceKey = GetInstanceBucketKey()
    local key
    if instanceKey then
        key = instanceKey
    elseif isGathering then
        key = "Gathering"
    else
        key = mobName
    end

    -- Always set currentLootKey first — even for ignored mobs — so any
    -- subsequent CHAT_MSG_LOOT / CHAT_MSG_MONEY routes through this key.
    -- AddItemToBucket / OnChatMsgMoney both honour LootLedgerMobIgnore,
    -- so ignored mobs' loot is silently dropped (not redirected to the
    -- fallback "Gathering" bucket).
    currentLootKey = key
    DPrint("  → key=", key, "isGathering=", isGathering, "mobName=", mobName or "nil")

    if LootLedgerMobIgnore[key] then
        DPrint("  → mob is ignored, no DB update")
        return
    end

    if not LootLedgerDB[key] then
        LootLedgerDB[key] = { loot = {}, links = {}, totalGold = 0, kills = 0 }
    end
    local data = LootLedgerDB[key]
    data.lastSeen  = time()

    -- 4. Increment the loot counter (outdoors only).
    --    Gathering windows count each open; mob corpses dedupe by GUID.
    --    Instance buckets count run entries instead — that increment
    --    happens in OnEnteringWorld, NOT here.
    if not instanceKey then
        if isGathering then
            data.kills = (data.kills or 0) + 1
        elseif isMobCorpse and recentDeaths[corpseGUID] then
            SeenCorpses[key] = SeenCorpses[key] or {}
            if not SeenCorpses[key][corpseGUID] then
                SeenCorpses[key][corpseGUID] = true
                data.kills = (data.kills or 0) + 1
            end
        end
    end

    UpdateTrackerUI()
end

local function OnLootClosed()
    DPrint("LOOT_CLOSED, currentLootKey=", currentLootKey or "nil")
    -- TBC Classic fires LOOT_CLOSED twice per loot session. Only act on
    -- the first one (when currentLootKey is still set); otherwise the
    -- second call would wipe out the grace-window key, leaving any
    -- late-arriving CHAT_MSG_LOOT with no context to attribute to.
    if not currentLootKey then return end
    lastLootKey    = currentLootKey
    lastLootKeyAt  = GetTime()
    currentLootKey = nil
end

local function OnChatMsgMoney(msg)
    if not msg then return end
    local g = GOLD_PATTERN   and tonumber(msg:match(GOLD_PATTERN))   or 0
    local s = SILVER_PATTERN and tonumber(msg:match(SILVER_PATTERN)) or 0
    local c = COPPER_PATTERN and tonumber(msg:match(COPPER_PATTERN)) or 0
    local copper = g * 10000 + s * 100 + c
    if copper <= 0 then return end

    -- Priority order:
    --   1. Active loot window (we opened a corpse / node)
    --   2. Just-closed loot window (grace window for race conditions)
    --   3. Inside an instance — dungeon bucket
    --   4. Drop silently — outdoor money with no loot window context
    --      (party gold share for a corpse you didn't open) is unattributable
    local key = currentLootKey
    if not key and lastLootKey
       and (GetTime() - lastLootKeyAt) < LOOT_CLOSE_GRACE then
        key = lastLootKey
    end
    if not key then
        key = GetInstanceBucketKey()
    end
    if not key then return end

    if LootLedgerMobIgnore[key] then return end
    if not LootLedgerDB[key] then
        LootLedgerDB[key] = { loot = {}, links = {}, totalGold = 0, kills = 0 }
    end
    LootLedgerDB[key].totalGold = (LootLedgerDB[key].totalGold or 0) + copper
    LootLedgerDB[key].lastSeen  = time()
    UpdateTrackerUI()
end

local function OnChatMsgLoot(msg)
    if not msg then return end

    -- Parse the item out of the message.
    local link, qty
    if LOOT_ITEM_MULTIPLE_PATTERN then
        link, qty = msg:match(LOOT_ITEM_MULTIPLE_PATTERN)
    end
    if not link and LOOT_ITEM_PATTERN then
        link = msg:match(LOOT_ITEM_PATTERN)
        qty  = 1
    end
    if not link then return end
    qty = tonumber(qty) or 1

    local itemName = link:match("|h%[(.-)%]|h")
    if not itemName or itemName == "" then return end

    DPrint("CHAT_MSG_LOOT item=", itemName, "qty=", qty,
           "currentLootKey=", currentLootKey or "nil",
           "lastLootKey=", lastLootKey or "nil",
           "lastLootKeyAt=", string.format("%.2f", GetTime() - lastLootKeyAt), "sec ago")

    -- Same-item dedup: WoW occasionally fires this event twice for one
    -- received item. Skip if we just processed this exact item.
    if IsRecentDuplicate(itemName, qty) then
        DPrint("  → skipped (same-item dedup)")
        return
    end

    -- Decide which bucket to attribute the item to.
    local key, path
    if GetActiveLootKey() then
        key = GetActiveLootKey()
        path = "active loot key"
    elseif (GetTime() - lastProfessionCastAt) < PROFESSION_GRACE then
        key = GetInstanceBucketKey() or "Gathering"
        path = "profession spell grace"
    else
        key = GetInstanceBucketKey() or "Gathering"
        path = "fallback (no loot window context)"
    end
    DPrint("  → bucket=", key, "via", path)

    if AddItemToBucket(key, itemName, link, qty) then
        lastAddedItem = itemName
        lastAddedQty  = qty
        lastAddedAt   = GetTime()
        UpdateTrackerUI()
    end
end

local function OnEnterCombat()
    if S.combatHide and f:IsShown() then
        wasShownBeforeCombat = true
        f:Hide()
    end
end

local function OnLeaveCombat()
    if S.combatHide and wasShownBeforeCombat then
        f:Show()
        UpdateTrackerUI()
    end
    wasShownBeforeCombat = false
end

local function OnItemInfoReceived()
    if f:IsShown() then UpdateTrackerUI() end
end

-- Player just finished casting a spell. If it's a known profession that
-- delivers items via "You receive loot:" without a loot window, stamp
-- the time so OnChatMsgLoot routes those items to "Gathering".
local function OnSpellCastSucceeded(unit, _, spellID)
    if unit ~= "player" then return end
    if PROFESSION_SPELL_IDS[spellID] then
        lastProfessionCastAt = GetTime()
    end
end

local function OnEnteringWorld()
    local instanceKey = GetInstanceBucketKey()
    if not instanceFirstLoad and instanceKey
       and instanceKey ~= currentInstanceKey then
        if not LootLedgerDB[instanceKey] then
            LootLedgerDB[instanceKey] = { loot = {}, links = {},
                totalGold = 0, kills = 0 }
        end
        local data = LootLedgerDB[instanceKey]
        data.kills    = (data.kills or 0) + 1
        data.lastSeen = time()
        UpdateTrackerUI()
    end
    instanceFirstLoad  = false
    currentInstanceKey = instanceKey
end

-- Dispatcher — routes each WoW event to its handler function.
local EventHandlers = {
    ADDON_LOADED                = OnAddonLoaded,
    COMBAT_LOG_EVENT_UNFILTERED = OnCombatLog,
    LOOT_OPENED                 = OnLootOpened,
    LOOT_CLOSED                 = OnLootClosed,
    CHAT_MSG_MONEY              = OnChatMsgMoney,
    CHAT_MSG_LOOT               = OnChatMsgLoot,
    PLAYER_REGEN_DISABLED       = OnEnterCombat,
    PLAYER_REGEN_ENABLED        = OnLeaveCombat,
    GET_ITEM_INFO_RECEIVED      = OnItemInfoReceived,
    PLAYER_ENTERING_WORLD       = OnEnteringWorld,
    UNIT_SPELLCAST_SUCCEEDED    = OnSpellCastSucceeded,
}

E:SetScript("OnEvent", function(self, event, ...)
    local handler = EventHandlers[event]
    if handler then handler(...) end
end)

-- 8. SLASH COMMANDS & KEY BINDING --------------------------
local function ToggleLootLedger()
    if f:IsShown() then f:Hide() else f:Show(); UpdateTrackerUI() end
end

-- Keybinding handler: called by Bindings.xml via RunBinding
function LOOTLEDGER_TOGGLE()
    ToggleLootLedger()
end

_G["SLASH_LLEDGER1"] = "/ll"
_G["SLASH_LLEDGER2"] = "/lootledger"
SlashCmdList["LLEDGER"] = function(msg)
    msg = (msg or ""):lower():match("^%s*(.-)%s*$")
    if msg == "reset" then
        StaticPopup_Show("LOOTLEDGER_CONFIRM_RESET_SESSION")
        return
    elseif msg == "resetwindow" or msg == "resetframe" then
        ResetFrame()
        return
    elseif msg == "debug" then
        debugEnabled = not debugEnabled
        print("|cFF00FFFFLoot Ledger:|r debug mode is now "
              .. (debugEnabled and "|cFF00FF00ON|r" or "|cFFFF0000OFF|r"))
        return
    elseif msg == "status" then
        print("|cFF00FFFFLoot Ledger status:|r")
        print("  currentLootKey   = " .. tostring(currentLootKey))
        print("  lastLootKey      = " .. tostring(lastLootKey)
              .. " (" .. string.format("%.1f", GetTime() - lastLootKeyAt)
              .. "s ago)")
        print("  lastProfCastAt   = " .. string.format("%.1f", GetTime() - lastProfessionCastAt) .. "s ago")
        local rd = 0
        for _ in pairs(recentDeaths) do rd = rd + 1 end
        print("  recentDeaths     = " .. rd .. " entries")
        print("  in instance      = " .. tostring(GetInstanceBucketKey() ~= nil))
        print("  in group         = " .. tostring(IsInGroup and IsInGroup() or false))
        print("  Auctionator API  = " .. tostring(IsAuctionatorAvailable()))
        print("    Auctionator    = " .. tostring(Auctionator ~= nil))
        print("    .API           = " .. tostring(Auctionator and Auctionator.API ~= nil))
        print("    .API.v1        = " .. tostring(Auctionator and Auctionator.API and Auctionator.API.v1 ~= nil))
        if Auctionator and Auctionator.API and Auctionator.API.v1 then
            local fns = {}
            for k, v in pairs(Auctionator.API.v1) do
                if type(v) == "function" then fns[#fns + 1] = k end
            end
            table.sort(fns)
            print("    v1 functions   = " .. table.concat(fns, ", "))
        end
        return
    elseif msg == "help" or msg == "?" then
        print("|cFF00FFFFLoot Ledger:|r commands:")
        print("  /ll              toggle window")
        print("  /ll reset        clear all tracked loot")
        print("  /ll resetwindow  reset window size/position")
        print("  /ll debug        toggle event debug printing")
        print("  /ll status       print current state")
        return
    end
    ToggleLootLedger()
end

-- 9. TIMER -------------------------------------------------
f:SetScript("OnUpdate", function(self, elapsed)
    self.t = (self.t or 0) + elapsed
    if self.t >= 1 then
        local s = time() - startTime
        timerTxt:SetText(string.format("%02d:%02d:%02d",
            math.floor(s / 3600),
            math.floor(s / 60) % 60,
            s % 60))
        self.t = 0
    end
    -- Safety net: if the mouse is released outside the resize grip,
    -- OnMouseUp on the grip won't fire — stop sizing here instead.
    if isResizing and not IsMouseButtonDown("LeftButton") then
        isResizing = false
        self:StopMovingOrSizing()
        S.width  = self:GetWidth()
        S.height = self:GetHeight()
        S.point  = { point = "TOPLEFT", relPoint = "BOTTOMLEFT",
                     x = self:GetLeft(), y = self:GetTop() }
        UpdateTrackerUI()
    end
end)
