-- Simple AH: stat filter for the auction house's own Browse Auctions list.
-- A "Stats" button next to Filter opens a list of stats with a minimum each.
-- While any are ticked, the browse results only show items that have all of
-- them; each result's stats are read from its tooltip (suffixes like
-- "of the Eagle" included).

local floor, max, format = math.floor, math.max, string.format

-- ---------------------------------------------------------------------------
-- Stats and how to read them
-- ---------------------------------------------------------------------------

local STATS = {
    { key = "str",   name = "Strength" },
    { key = "agi",   name = "Agility" },
    { key = "sta",   name = "Stamina" },
    { key = "int",   name = "Intellect" },
    { key = "spi",   name = "Spirit" },
    { key = "spell", name = "Spell Power" },
    { key = "heal",  name = "Healing" },
    { key = "ap",    name = "Attack Power" },
    { key = "crit",  name = "Crit %" },
    { key = "hit",   name = "Hit %" },
    { key = "scrit", name = "Spell Crit %" },
    { key = "shit",  name = "Spell Hit %" },
    { key = "def",   name = "Defense" },
    { key = "dodge", name = "Dodge %" },
    { key = "parry", name = "Parry %" },
    { key = "block", name = "Block" },
    { key = "mp5",   name = "Mana per 5 sec" },
}

-- GetItemStats keys
local STATMAP = {
    ITEM_MOD_STRENGTH_SHORT = "str", ITEM_MOD_AGILITY_SHORT = "agi", ITEM_MOD_STAMINA_SHORT = "sta",
    ITEM_MOD_INTELLECT_SHORT = "int", ITEM_MOD_SPIRIT_SHORT = "spi",
    ITEM_MOD_SPELL_POWER_SHORT = "spell", ITEM_MOD_SPELL_DAMAGE_DONE_SHORT = "spell",
    ITEM_MOD_SPELL_HEALING_DONE_SHORT = "heal",
    ITEM_MOD_ATTACK_POWER_SHORT = "ap", ITEM_MOD_MELEE_ATTACK_POWER_SHORT = "ap",
    ITEM_MOD_CRIT_RATING_SHORT = "crit", ITEM_MOD_CRIT_MELEE_RATING_SHORT = "crit",
    ITEM_MOD_HIT_RATING_SHORT = "hit", ITEM_MOD_HIT_MELEE_RATING_SHORT = "hit",
    ITEM_MOD_CRIT_SPELL_RATING_SHORT = "scrit", ITEM_MOD_HIT_SPELL_RATING_SHORT = "shit",
    ITEM_MOD_DEFENSE_SKILL_RATING_SHORT = "def", ITEM_MOD_DODGE_RATING_SHORT = "dodge",
    ITEM_MOD_PARRY_RATING_SHORT = "parry", ITEM_MOD_BLOCK_RATING_SHORT = "block",
    ITEM_MOD_BLOCK_VALUE_SHORT = "block",
    ITEM_MOD_MANA_REGENERATION_SHORT = "mp5", ITEM_MOD_POWER_REGEN0_SHORT = "mp5",
}

-- Tooltip wording (classic). Lower-cased lines; first capture is the value.
local PATTERNS = {
    { "str",   "^%+(%d+) strength" },
    { "agi",   "^%+(%d+) agility" },
    { "sta",   "^%+(%d+) stamina" },
    { "int",   "^%+(%d+) intellect" },
    { "spi",   "^%+(%d+) spirit" },
    { "spell", "damage and healing done by magical spells and effects by up to (%d+)" },
    { "spell", "increases spell power by (%d+)" },
    { "spell", "%+(%d+) spell power" },
    { "spell", "%+(%d+) spell damage and healing" },
    { "spell", "%+(%d+) damage and healing spells" },
    { "heal",  "increases healing done by spells and effects by up to (%d+)" },
    { "heal",  "increases healing done by up to (%d+)" },
    { "heal",  "%+(%d+) healing spells" },
    { "ap",    "%+(%d+) attack power", skip = "ranged" },
    { "crit",  "chance to get a critical strike by (%d+)%%" },
    { "scrit", "critical strike with spells by (%d+)%%" },
    { "hit",   "chance to hit by (%d+)%%" },
    { "shit",  "chance to hit with spells by (%d+)%%" },
    { "def",   "increased defense %+(%d+)" },
    { "def",   "%+(%d+) defense" },
    { "dodge", "chance to dodge an attack by (%d+)%%" },
    { "parry", "chance to parry an attack by (%d+)%%" },
    { "block", "block value of your shield by (%d+)" },
    { "block", "chance to block attacks with a shield by (%d+)%%" },
    { "mp5",   "restores (%d+) mana per 5 sec" },
    { "mp5",   "(%d+) mana every 5 sec" },
}

local function Print(msg) print("|cffd9b36bSimple AH|r  " .. msg) end

local function ParseLines(lines, s)
    s = s or {}
    for _, text in ipairs(lines) do
        local lower = text:lower()
        for _, p in ipairs(PATTERNS) do
            if not (p.skip and lower:find(p.skip, 1, true)) then
                local v = lower:match(p[2])
                if v then s[p[1]] = max(s[p[1]] or 0, tonumber(v)) end
            end
        end
    end
    return s
end
SimpleAH_ParseStatLines = ParseLines -- /run check of tooltip wording

local function KeyLink(itemKey)
    local suffix = itemKey.itemSuffix
    if suffix and suffix ~= 0 then return format("item:%d::::::%d", itemKey.itemID, suffix) end
    return "item:" .. itemKey.itemID
end

local function TooltipLinesFor(itemKey)
    local data
    if C_TooltipInfo then
        if C_TooltipInfo.GetItemKey then
            local ok, d = pcall(C_TooltipInfo.GetItemKey, itemKey.itemID, itemKey.itemLevel or 0, itemKey.itemSuffix or 0)
            if ok then data = d end
        end
        if (not data or not data.lines) and C_TooltipInfo.GetHyperlink then
            data = C_TooltipInfo.GetHyperlink(KeyLink(itemKey))
        end
    end
    if not data or not data.lines or #data.lines == 0 then return nil end
    local out = {}
    for _, line in ipairs(data.lines) do
        if line.leftText and line.leftText ~= "" then out[#out + 1] = line.leftText end
    end
    local first = out[1]
    if not first or (RETRIEVING_ITEM_INFO and first:find(RETRIEVING_ITEM_INFO, 1, true)) then return nil end
    return out
end

local statCache = {}   -- "itemID:suffix" -> stats table

-- Stats of a browse result, or nil while the game is still loading the item
local function StatsFor(itemKey)
    local id = itemKey.itemID .. ":" .. (itemKey.itemSuffix or 0)
    local s = statCache[id]
    if s then return s end
    local lines = TooltipLinesFor(itemKey)
    if not lines then
        if C_Item and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(itemKey.itemID) end
        return nil
    end
    s = {}
    local getStats = (C_Item and C_Item.GetItemStats) or GetItemStats
    if getStats then
        local ok, gs = pcall(getStats, KeyLink(itemKey))
        if ok and type(gs) == "table" then
            for k, v in pairs(gs) do
                local key = STATMAP[k]
                if key and v and v > 0 then s[key] = max(s[key] or 0, floor(v + 0.5)) end
            end
        end
    end
    ParseLines(lines, s)
    statCache[id] = s
    return s
end

-- Classic: "+X damage and healing" heals too
local function StatValue(s, key)
    if key == "heal" then return (s.heal or 0) + (s.spell or 0) end
    return s[key] or 0
end

-- ---------------------------------------------------------------------------
-- Filter state
-- ---------------------------------------------------------------------------

local function Settings()
    SimpleAHDB = SimpleAHDB or {}
    SimpleAHDB.statFilter = SimpleAHDB.statFilter or {}
    return SimpleAHDB.statFilter
end

local function Active()
    local f, list = Settings(), {}
    for _, s in ipairs(STATS) do
        if f[s.key] then list[#list + 1] = { key = s.key, min = tonumber(f[s.key]) or 0 } end
    end
    return list
end

-- ---------------------------------------------------------------------------
-- Hooking the browse results
-- ---------------------------------------------------------------------------

local browse            -- AuctionHouseFrame.BrowseResultsFrame
local allResults = {}   -- everything the auction house returned for the current search
local hidden, waiting = 0, 0
local applying = false
local UpdateButton      -- set below

local function RefreshList()
    local list = browse and browse.ItemList
    if not list then return end
    if list.DirtyScrollFrame then pcall(list.DirtyScrollFrame, list)
    elseif list.RefreshScrollFrame then pcall(list.RefreshScrollFrame, list) end
end

local recheckQueued = false
local function Apply()
    if not browse then return end
    local filters = Active()
    local shown = {}
    hidden, waiting = 0, 0
    for _, r in ipairs(allResults) do
        local keep = true
        if #filters > 0 then
            local s = r.itemKey and StatsFor(r.itemKey)
            if not s then
                keep = false
                waiting = waiting + 1
            else
                for _, f in ipairs(filters) do
                    local v = StatValue(s, f.key)
                    if v <= 0 or v < f.min then keep = false; break end
                end
            end
        end
        if keep then shown[#shown + 1] = r else hidden = hidden + 1 end
    end
    applying = true
    browse.browseResults = shown
    RefreshList()
    applying = false
    if UpdateButton then UpdateButton() end

    if #filters > 0 then
        -- load the rest of the search so the filter sees every match
        if C_AuctionHouse.HasFullBrowseResults and not C_AuctionHouse.HasFullBrowseResults()
            and C_AuctionHouse.RequestMoreBrowseResults then
            C_AuctionHouse.RequestMoreBrowseResults()
        end
        -- items still loading: look again shortly
        if waiting > 0 and not recheckQueued then
            recheckQueued = true
            C_Timer.After(0.5, function() recheckQueued = false; Apply() end)
        end
    end
end

local function OnBrowseUpdate(self, added)
    if applying then return end
    if added then
        for _, r in ipairs(added) do allResults[#allResults + 1] = r end
    else
        allResults = {}
        for _, r in ipairs(C_AuctionHouse.GetBrowseResults() or {}) do allResults[#allResults + 1] = r end
    end
    Apply()
end

-- ---------------------------------------------------------------------------
-- UI: Stats button beside Filter, and its dropdown
-- ---------------------------------------------------------------------------

local button, menu

local function SafeFrame(kind, parent, template, name)
    local ok, f = pcall(CreateFrame, kind, name, parent, template)
    if ok and f then return f end
    return CreateFrame(kind, name, parent)
end

UpdateButton = function()
    if not button then return end
    local n = #Active()
    if n > 0 then
        button:SetText(format("|cff00ff00Stats (%d)|r", n))
    else
        button:SetText("Stats")
    end
    if menu and menu.status then
        if n == 0 then
            menu.status:SetText("Tick stats to filter the results.")
        else
            menu.status:SetText(format("%d hidden%s", hidden, waiting > 0 and format(", %d loading", waiting) or ""))
        end
    end
end

local function BuildMenu()
    menu = SafeFrame("Frame", AuctionHouseFrame, "BackdropTemplate", "SimpleAHStatMenu")
    menu:SetFrameStrata("DIALOG")
    menu:SetSize(210, 74 + #STATS * 20)
    menu:EnableMouse(true)
    if menu.SetBackdrop then
        menu:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 },
        })
    end
    menu:Hide()
    tinsert(UISpecialFrames, "SimpleAHStatMenu")

    local title = menu:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 12, -10)
    title:SetText("Filter by stats")
    local minHead = menu:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    minHead:SetPoint("TOPRIGHT", -16, -12)
    minHead:SetText("min")

    menu.rows = {}
    for i, s in ipairs(STATS) do
        local y = -30 - (i - 1) * 20
        local cb = SafeFrame("CheckButton", menu, "UICheckButtonTemplate")
        cb:SetSize(20, 20)
        cb:SetPoint("TOPLEFT", 8, y)
        local label = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        label:SetPoint("LEFT", cb, "RIGHT", 2, 0)
        label:SetText(s.name)
        local eb = SafeFrame("EditBox", menu, "InputBoxTemplate")
        eb:SetSize(34, 16)
        eb:SetPoint("TOPRIGHT", -14, y - 2)
        eb:SetAutoFocus(false)
        eb:SetNumeric(true)
        eb:SetMaxLetters(4)
        local function store()
            local f = Settings()
            if cb:GetChecked() then f[s.key] = eb:GetText() ~= "" and eb:GetText() or "0" else f[s.key] = nil end
            Apply()
        end
        cb:SetScript("OnClick", store)
        eb:SetScript("OnTextChanged", function(self, user)
            if not user then return end
            if self:GetText() ~= "" then cb:SetChecked(true) end
            store()
        end)
        eb:SetScript("OnEnterPressed", eb.ClearFocus)
        eb:SetScript("OnEscapePressed", eb.ClearFocus)
        menu.rows[s.key] = { cb = cb, eb = eb }
    end

    local clear = SafeFrame("Button", menu, "UIPanelButtonTemplate")
    clear:SetSize(70, 20)
    clear:SetPoint("BOTTOMLEFT", 10, 10)
    clear:SetText("Clear")
    clear:SetScript("OnClick", function()
        wipe(Settings())
        for _, r in pairs(menu.rows) do r.cb:SetChecked(false); r.eb:SetText("") end
        Apply()
    end)

    menu.status = menu:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    menu.status:SetPoint("LEFT", clear, "RIGHT", 8, 0)
    menu.status:SetPoint("RIGHT", menu, "RIGHT", -10, 0)
    menu.status:SetJustifyH("LEFT")

    menu:SetScript("OnShow", function()
        local f = Settings()
        for key, r in pairs(menu.rows) do
            r.cb:SetChecked(f[key] ~= nil)
            r.eb:SetText(f[key] and f[key] ~= "0" and f[key] or "")
        end
        UpdateButton()
    end)
end

local function Build()
    if button or not AuctionHouseFrame then return end
    browse = AuctionHouseFrame.BrowseResultsFrame
    local bar = AuctionHouseFrame.SearchBar
    if not browse or not bar then return end

    if browse.UpdateBrowseResults then
        hooksecurefunc(browse, "UpdateBrowseResults", OnBrowseUpdate)
    else
        Print("This auction house window is different from what the stat filter expects; it is turned off.")
        return
    end

    local filter = bar.FilterButton or bar.SearchButton
    button = SafeFrame("Button", bar, "UIPanelButtonTemplate", "SimpleAHStatButton")
    button:SetSize(86, 22)
    -- sit left of Filter, or left of another addon's button already there
    local anchor = filter
    for _, child in ipairs({ bar:GetChildren() }) do
        if child ~= button and child ~= filter and child:IsObjectType("Button") then
            local _, rel = child:GetPoint(1)
            if rel == filter then anchor = child end
        end
    end
    if anchor then button:SetPoint("RIGHT", anchor, "LEFT", -6, 0) else button:SetPoint("TOPRIGHT", AuctionHouseFrame, "TOPRIGHT", -200, -30) end
    button:SetScript("OnClick", function()
        if not menu then BuildMenu() end
        if menu:IsShown() then menu:Hide() else
            menu:ClearAllPoints()
            menu:SetPoint("TOPRIGHT", button, "BOTTOMRIGHT", 0, -2)
            menu:Show()
        end
    end)
    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Filter by stats")
        GameTooltip:AddLine("Show only results with the stats you tick, e.g. Spell Power or Agility.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)
    UpdateButton()

    AuctionHouseFrame:HookScript("OnHide", function() if menu then menu:Hide() end end)
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("AUCTION_HOUSE_SHOW")
events:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 ~= "Blizzard_AuctionHouseUI" then return end
    Build()
end)

function SimpleAH_OpenStats()
    if not (AuctionHouseFrame and AuctionHouseFrame:IsShown()) then
        Print("Open the auction house; the Stats button is next to Filter on the Buy tab.")
        return
    end
    Build()
    if button then button:Click() end
end
