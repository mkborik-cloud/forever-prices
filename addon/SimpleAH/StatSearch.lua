-- Simple AH: Stats tab in the auction house.
-- Reads a full auction house scan (C_AuctionHouse.ReplicateItems), works out each
-- item's stats from its link, and lists gear that matches the stats you pick.
-- Clicking a result opens it on the Buy tab, so buying works the normal way.

local floor, max, min, format = math.floor, math.max, math.min, string.format

local SCAN_COOLDOWN = 15 * 60  -- the auction house allows one full scan per 15 minutes (measured on Forever)
local SCAN_TIMEOUT  = 60
local BUDGET_MS     = 8        -- per-frame time slice for background work

-- ---------------------------------------------------------------------------
-- Stats
-- ---------------------------------------------------------------------------

local STATS = {
    { key = "str",   name = "Strength",     short = "Str" },
    { key = "agi",   name = "Agility",      short = "Agi" },
    { key = "sta",   name = "Stamina",      short = "Sta" },
    { key = "int",   name = "Intellect",    short = "Int" },
    { key = "spi",   name = "Spirit",       short = "Spi" },
    { key = "spell", name = "Spell Power",  short = "SP" },
    { key = "heal",  name = "Healing",      short = "Heal" },
    { key = "ap",    name = "Attack Power", short = "AP" },
    { key = "crit",  name = "Crit %",       short = "Crit" },
    { key = "hit",   name = "Hit %",        short = "Hit" },
    { key = "scrit", name = "Spell Crit %", short = "SCrit" },
    { key = "shit",  name = "Spell Hit %",  short = "SHit" },
    { key = "def",   name = "Defense",      short = "Def" },
    { key = "dodge", name = "Dodge %",      short = "Dodge" },
    { key = "parry", name = "Parry %",      short = "Parry" },
    { key = "block", name = "Block",        short = "Block" },
    { key = "mp5",   name = "Mana per 5s",  short = "MP5" },
}
local STAT_BY_KEY = {}
for _, s in ipairs(STATS) do STAT_BY_KEY[s.key] = s end

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

-- Tooltip wording (classic style). Lower-cased lines are matched; the first
-- capture is the value. "skip" drops lines that contain that text.
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
    { "mp5",   "%+(%d+) mana every 5 seconds" },
}

local SLOTS = {
    { label = "Any slot" },
    { label = "Head",      locs = { INVTYPE_HEAD = true } },
    { label = "Neck",      locs = { INVTYPE_NECK = true } },
    { label = "Shoulder",  locs = { INVTYPE_SHOULDER = true } },
    { label = "Back",      locs = { INVTYPE_CLOAK = true } },
    { label = "Chest",     locs = { INVTYPE_CHEST = true, INVTYPE_ROBE = true } },
    { label = "Wrist",     locs = { INVTYPE_WRIST = true } },
    { label = "Hands",     locs = { INVTYPE_HAND = true } },
    { label = "Waist",     locs = { INVTYPE_WAIST = true } },
    { label = "Legs",      locs = { INVTYPE_LEGS = true } },
    { label = "Feet",      locs = { INVTYPE_FEET = true } },
    { label = "Finger",    locs = { INVTYPE_FINGER = true } },
    { label = "Trinket",   locs = { INVTYPE_TRINKET = true } },
    { label = "One-hand",  locs = { INVTYPE_WEAPON = true, INVTYPE_WEAPONMAINHAND = true, INVTYPE_WEAPONOFFHAND = true } },
    { label = "Two-hand",  locs = { INVTYPE_2HWEAPON = true } },
    { label = "Off-hand",  locs = { INVTYPE_SHIELD = true, INVTYPE_HOLDABLE = true, INVTYPE_WEAPONOFFHAND = true } },
    { label = "Ranged",    locs = { INVTYPE_RANGED = true, INVTYPE_RANGEDRIGHT = true, INVTYPE_THROWN = true, INVTYPE_RELIC = true } },
}
local SLOT_SHORT = {
    INVTYPE_HEAD = "Head", INVTYPE_NECK = "Neck", INVTYPE_SHOULDER = "Shoulder", INVTYPE_CLOAK = "Back",
    INVTYPE_CHEST = "Chest", INVTYPE_ROBE = "Chest", INVTYPE_WRIST = "Wrist", INVTYPE_HAND = "Hands",
    INVTYPE_WAIST = "Waist", INVTYPE_LEGS = "Legs", INVTYPE_FEET = "Feet", INVTYPE_FINGER = "Finger",
    INVTYPE_TRINKET = "Trinket", INVTYPE_WEAPON = "One-hand", INVTYPE_WEAPONMAINHAND = "Main hand",
    INVTYPE_WEAPONOFFHAND = "Off hand", INVTYPE_2HWEAPON = "Two-hand", INVTYPE_SHIELD = "Shield",
    INVTYPE_HOLDABLE = "Held", INVTYPE_RANGED = "Ranged", INVTYPE_RANGEDRIGHT = "Ranged",
    INVTYPE_THROWN = "Thrown", INVTYPE_RELIC = "Relic",
}
local NOT_GEAR = { INVTYPE_BAG = true, INVTYPE_QUIVER = true, INVTYPE_AMMO = true,
                   INVTYPE_TABARD = true, INVTYPE_BODY = true, INVTYPE_NON_EQUIP_IGNORE = true }

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function Print(msg) print("|cffd9b36bSimple AH|r  " .. msg) end

local function Money(c)
    if not c or c <= 0 then return "" end
    if GetMoneyString then return GetMoneyString(c, true) end
    return format("%dg %02ds %02dc", floor(c / 10000), floor(c / 100) % 100, c % 100)
end

local function Clock(sec)
    sec = max(0, floor(sec))
    return format("%d:%02d", floor(sec / 60), sec % 60)
end

local function InfoInstant(itemID)
    if C_Item and C_Item.GetItemInfoInstant then return C_Item.GetItemInfoInstant(itemID) end
    return GetItemInfoInstant(itemID)
end

local function ItemInfo(link)
    if C_Item and C_Item.GetItemInfo then return C_Item.GetItemInfo(link) end
    return GetItemInfo(link)
end

local function RequestItem(itemID)
    if C_Item and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(itemID) end
end

-- itemID:suffix identifies a variant ("of the Owl"); other link fields vary per listing
local function VariantKey(link, itemID)
    local s = link and link:match("item:([%-%d:]+)")
    if s then
        local f, i = {}, 0
        for part in (s .. ":"):gmatch("([^:]*):") do
            i = i + 1
            f[i] = part
            if i >= 7 then break end
        end
        local suffix = f[7]
        if suffix and suffix ~= "" and suffix ~= "0" then return (f[1] or itemID) .. ":" .. suffix end
        return f[1] or tostring(itemID)
    end
    return tostring(itemID)
end

-- Tooltip lines of a link, or nil while the item isn't loaded yet
local scanTip
local function TooltipLines(link)
    local out = {}
    if C_TooltipInfo and C_TooltipInfo.GetHyperlink then
        local data = C_TooltipInfo.GetHyperlink(link)
        if not data or not data.lines or #data.lines == 0 then return nil end
        for _, line in ipairs(data.lines) do
            local t = line.leftText
            if t and t ~= "" then out[#out + 1] = t end
        end
    else
        if not scanTip then
            scanTip = CreateFrame("GameTooltip", "SimpleAHScanTooltip", UIParent, "GameTooltipTemplate")
        end
        scanTip:SetOwner(WorldFrame, "ANCHOR_NONE")
        scanTip:ClearLines()
        scanTip:SetHyperlink(link)
        for i = 1, scanTip:NumLines() do
            local fs = _G["SimpleAHScanTooltipTextLeft" .. i]
            local t = fs and fs:GetText()
            if t and t ~= "" then out[#out + 1] = t end
        end
    end
    local first = out[1]
    if not first or (RETRIEVING_ITEM_INFO and first:find(RETRIEVING_ITEM_INFO, 1, true)) then return nil end
    return out
end

-- Stats written in tooltip lines
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
SimpleAH_ParseStatLines = ParseLines -- for checking tooltip wording with /run

-- Stats of one item link: { key = value }, or nil while not loaded
local function ParseStats(link)
    local lines = TooltipLines(link)
    if not lines then return nil end
    local s = {}
    local getStats = (C_Item and C_Item.GetItemStats) or GetItemStats
    if getStats then
        local ok, gs = pcall(getStats, link)
        if ok and type(gs) == "table" then
            for k, v in pairs(gs) do
                local key = STATMAP[k]
                if key and v and v > 0 then s[key] = max(s[key] or 0, floor(v + 0.5)) end
            end
        end
    end
    return ParseLines(lines, s)
end

-- Healing in classic: "+X damage and healing" also heals
local function StatValue(stats, key)
    if key == "heal" then return (stats.heal or 0) + (stats.spell or 0) end
    return stats[key] or 0
end

-- ---------------------------------------------------------------------------
-- Background jobs (time sliced so the game never stutters)
-- ---------------------------------------------------------------------------

local jobs = {}
local jobFrame = CreateFrame("Frame")
jobFrame:Hide()
local sliceStart

local function Pause()
    if sliceStart and debugprofilestop() - sliceStart > BUDGET_MS then coroutine.yield() end
end

local function RunJob(fn, done)
    jobs[#jobs + 1] = { co = coroutine.create(fn), done = done }
    jobFrame:Show()
end

jobFrame:SetScript("OnUpdate", function(self)
    local job = jobs[1]
    if not job then self:Hide(); return end
    sliceStart = debugprofilestop()
    local ok, err = coroutine.resume(job.co)
    sliceStart = nil
    if not ok then
        table.remove(jobs, 1)
        Print("|cffff6060stat search error: " .. tostring(err) .. "|r")
    elseif coroutine.status(job.co) == "dead" then
        table.remove(jobs, 1)
        if job.done then job.done() end
    end
    if not jobs[1] then self:Hide() end
end)

-- ---------------------------------------------------------------------------
-- Data: listings from the last full scan, grouped by item variant
-- ---------------------------------------------------------------------------

local S = {
    items = {},       -- key -> { link, itemID, price, qty, stats, level, loc, name, quality, icon }
    order = {},
    scanTime = 0,
    state = "idle",   -- idle, waiting, reading
    pending = {},     -- items waiting for item data
}

local function DB()
    SimpleAHDB = SimpleAHDB or {}
    SimpleAHDB.stats = SimpleAHDB.stats or { filters = {}, slot = 1 }
    return SimpleAHDB
end

local Refresh -- UI refresh, set below

local function Describe(item)
    -- fills name/level/slot/quality/icon/stats when the game has the item; returns true when complete
    if not item.name then
        local name, _, quality, _, minLevel, _, _, _, equipLoc, icon = ItemInfo(item.link)
        if not name then RequestItem(item.itemID); return false end
        item.name, item.quality, item.level, item.loc, item.icon = name, quality, minLevel or 0, equipLoc, icon
    end
    if not item.stats then
        item.stats = ParseStats(item.link)
        if not item.stats then RequestItem(item.itemID); return false end
    end
    return true
end

local function DescribeAll()
    if S.describing then S.again = true; return end
    S.describing = true
    RunJob(function()
        local waiting = 0
        for n, key in ipairs(S.order) do
            local item = S.items[key]
            if item and not item.stats then
                if not Describe(item) then
                    S.pending[key] = true
                    waiting = waiting + 1
                else
                    S.pending[key] = nil
                end
            end
            if n % 10 == 0 then Pause() end
        end
        S.waiting = waiting
    end, function()
        S.describing = false
        if Refresh then Refresh(true) end
        if S.again or (S.waiting or 0) > 0 then
            S.again = false
            C_Timer.After(2, function() if next(S.pending) then DescribeAll() end end)
        end
    end)
end

local function SaveScan()
    local saved = {}
    for key, it in pairs(S.items) do saved[key] = { it.link, it.itemID, it.price, it.qty } end
    DB().stats.scan = { t = S.scanTime, items = saved }
end

local function LoadSavedScan()
    local scan = DB().stats.scan
    if not scan or not scan.items then return end
    wipe(S.items); wipe(S.order)
    for key, v in pairs(scan.items) do
        S.items[key] = { link = v[1], itemID = v[2], price = v[3], qty = v[4] }
        S.order[#S.order + 1] = key
    end
    S.scanTime = scan.t or 0
end

local function ReadReplicate()
    S.state = "reading"
    if Refresh then Refresh() end
    local items, order = {}, {}
    RunJob(function()
        local total = C_AuctionHouse.GetNumReplicateItems() or 0
        S.total, S.done = total, 0
        for i = 0, total - 1 do
            local _, _, count, _, _, _, _, _, _, buyout, _, _, _, _, _, _, itemID = C_AuctionHouse.GetReplicateItemInfo(i)
            if itemID and buyout and buyout > 0 and count and count > 0 then
                local _, _, _, equipLoc = InfoInstant(itemID)
                if equipLoc and equipLoc ~= "" and not NOT_GEAR[equipLoc] then
                    local link = C_AuctionHouse.GetReplicateItemLink(i) or ("item:" .. itemID)
                    local key = VariantKey(link, itemID)
                    local unit = math.ceil(buyout / count)
                    local it = items[key]
                    if not it then
                        it = { link = link, itemID = itemID, price = unit, qty = 0 }
                        items[key] = it
                        order[#order + 1] = key
                    elseif unit < it.price then
                        it.price = unit
                    end
                    it.qty = it.qty + count
                end
            end
            S.done = i + 1
            if i % 50 == 0 then Pause() end
        end
    end, function()
        S.items, S.order = items, order
        S.scanTime = time()
        S.state = "idle"
        DB().stats.lastScan = S.scanTime
        SaveScan()
        Print(format("Stats: read %d pieces of gear from the auction house scan.", #order))
        DescribeAll()
        if Refresh then Refresh(true) end
    end)
end

local function ScanWait()
    return max(0, (DB().stats.lastScan or 0) + SCAN_COOLDOWN - time())
end

local function StartScan()
    if S.state ~= "idle" then return end
    if not (AuctionHouseFrame and AuctionHouseFrame:IsShown()) then
        Print("Open the auction house first.")
        return
    end
    local wait = ScanWait()
    if wait > 0 then
        Print("The auction house allows the next full scan in " .. Clock(wait) .. ".")
        return
    end
    S.state, S.asked = "waiting", time()
    DB().stats.lastScan = S.asked
    C_AuctionHouse.ReplicateItems()
    if Refresh then Refresh() end
end

-- ---------------------------------------------------------------------------
-- Filtering
-- ---------------------------------------------------------------------------

local results = {}

local function ActiveFilters()
    local f, list = DB().stats.filters, {}
    for _, s in ipairs(STATS) do
        local v = f[s.key]
        if v then list[#list + 1] = { key = s.key, min = tonumber(v) or 0 } end
    end
    return list
end

local function Matches(item, filters, slot, maxLevel, text)
    if not item.stats or not item.name then return false end
    if slot.locs and not slot.locs[item.loc] then return false end
    if maxLevel and (item.level or 0) > maxLevel then return false end
    if text ~= "" and not item.name:lower():find(text, 1, true) then return false end
    for _, flt in ipairs(filters) do
        local v = StatValue(item.stats, flt.key)
        if v <= 0 or v < flt.min then return false end
    end
    return true
end

local sortKey, sortDesc = nil, true

local function Filter()
    wipe(results)
    local db = DB().stats
    local filters = ActiveFilters()
    local slot = SLOTS[db.slot or 1] or SLOTS[1]
    local maxLevel = tonumber(db.maxLevel or "")
    local text = (db.text or ""):lower()
    if #filters == 0 and not slot.locs and text == "" then return filters end
    for _, key in ipairs(S.order) do
        local it = S.items[key]
        if it and Matches(it, filters, slot, maxLevel, text) then results[#results + 1] = it end
    end
    local sk = sortKey or (filters[1] and filters[1].key) or "price"
    table.sort(results, function(a, b)
        local va, vb
        if sk == "price" then va, vb = a.price, b.price
        elseif sk == "level" then va, vb = a.level or 0, b.level or 0
        elseif sk == "name" then va, vb = a.name, b.name
        else va, vb = StatValue(a.stats, sk), StatValue(b.stats, sk) end
        if va == vb then return a.price < b.price end
        local desc = sortDesc
        if sortKey == nil then desc = sk ~= "price" end
        if desc then return va > vb end
        return va < vb
    end)
    return filters
end

local function StatText(item, filters)
    local parts, used = {}, {}
    for _, flt in ipairs(filters) do
        local v = StatValue(item.stats, flt.key)
        parts[#parts + 1] = "|cffffffff" .. v .. " " .. STAT_BY_KEY[flt.key].short .. "|r"
        used[flt.key] = true
    end
    for _, s in ipairs(STATS) do
        if not used[s.key] and s.key ~= "heal" then
            local v = item.stats[s.key]
            if v and v > 0 then parts[#parts + 1] = v .. " " .. s.short end
        end
    end
    if not used.heal and (item.stats.heal or 0) > 0 then parts[#parts + 1] = item.stats.heal .. " Heal" end
    return table.concat(parts, "  ")
end

-- ---------------------------------------------------------------------------
-- UI (built the first time the auction house opens)
-- ---------------------------------------------------------------------------

local panel, rows, offset = nil, {}, 0
local ROW_H = 20

local function SafeFrame(kind, parent, template, name)
    local ok, f = pcall(CreateFrame, kind, name, parent, template)
    if ok and f then return f end
    return CreateFrame(kind, name, parent)
end

local function OpenOnBuyTab(item)
    if not AuctionHouseFrame then return end
    pcall(function()
        if AuctionHouseFrame.SetDisplayMode and AuctionHouseFrameDisplayMode then
            AuctionHouseFrame:SetDisplayMode(AuctionHouseFrameDisplayMode.Buy)
        end
        local bar = AuctionHouseFrame.SearchBar
        if bar and bar.SetSearchText then
            bar:SetSearchText(item.name)
            if bar.StartSearch then bar:StartSearch() end
        end
    end)
end

local function BuildPanel()
    if panel or not AuctionHouseFrame then return end
    panel = CreateFrame("Frame", "SimpleAHStatsPanel", AuctionHouseFrame)
    panel:SetPoint("TOPLEFT", AuctionHouseFrame, "TOPLEFT", 4, -60)
    panel:SetPoint("BOTTOMRIGHT", AuctionHouseFrame, "BOTTOMRIGHT", -4, 28)
    panel:Hide()

    -- left: filter column
    local left = SafeFrame("Frame", panel, "InsetFrameTemplate")
    left:SetPoint("TOPLEFT", 0, 0)
    left:SetPoint("BOTTOMLEFT", 0, 0)
    left:SetWidth(200)

    local title = left:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 10, -8)
    title:SetText("Stats")
    local minHead = left:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    minHead:SetPoint("TOPRIGHT", -14, -10)
    minHead:SetText("min")

    panel.checks = {}
    for i, s in ipairs(STATS) do
        local cb = SafeFrame("CheckButton", left, "UICheckButtonTemplate")
        cb:SetSize(20, 20)
        cb:SetPoint("TOPLEFT", 6, -24 - (i - 1) * 19)
        local label = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        label:SetPoint("LEFT", cb, "RIGHT", 2, 0)
        label:SetText(s.name)
        cb.label = label
        local eb = SafeFrame("EditBox", left, "InputBoxTemplate")
        eb:SetSize(34, 16)
        eb:SetPoint("TOPRIGHT", -12, -26 - (i - 1) * 19)
        eb:SetAutoFocus(false)
        eb:SetNumeric(true)
        eb:SetMaxLetters(4)
        cb:SetScript("OnClick", function(self)
            local f = DB().stats.filters
            if self:GetChecked() then f[s.key] = eb:GetText() ~= "" and eb:GetText() or "0"
            else f[s.key] = nil end
            offset = 0
            Refresh(true)
        end)
        eb:SetScript("OnTextChanged", function(self, user)
            if not user then return end
            local f = DB().stats.filters
            if self:GetText() ~= "" then cb:SetChecked(true) end
            if cb:GetChecked() then f[s.key] = self:GetText() ~= "" and self:GetText() or "0" end
            offset = 0
            Refresh(true)
        end)
        eb:SetScript("OnEnterPressed", eb.ClearFocus)
        eb:SetScript("OnEscapePressed", eb.ClearFocus)
        panel.checks[s.key] = { cb = cb, eb = eb }
    end

    local y = -24 - #STATS * 19 - 8
    -- slot picker (click: next, right-click: previous)
    local slotBtn = SafeFrame("Button", left, "UIPanelButtonTemplate")
    slotBtn:SetSize(120, 22)
    slotBtn:SetPoint("TOPLEFT", 10, y)
    slotBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    slotBtn:SetScript("OnClick", function(_, button)
        local db = DB().stats
        local n = #SLOTS
        db.slot = ((db.slot or 1) - 1 + (button == "RightButton" and n - 1 or 1)) % n + 1
        offset = 0
        Refresh(true)
    end)
    slotBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Slot")
        GameTooltip:AddLine("Left-click: next slot. Right-click: previous.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    slotBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    panel.slotBtn = slotBtn

    local lvlLabel = left:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    lvlLabel:SetPoint("TOPLEFT", 12, y - 30)
    lvlLabel:SetText("Max level")
    local lvl = SafeFrame("EditBox", left, "InputBoxTemplate")
    lvl:SetSize(34, 16)
    lvl:SetPoint("LEFT", lvlLabel, "RIGHT", 10, 0)
    lvl:SetAutoFocus(false)
    lvl:SetNumeric(true)
    lvl:SetMaxLetters(3)
    lvl:SetScript("OnTextChanged", function(self, user)
        if not user then return end
        DB().stats.maxLevel = self:GetText()
        offset = 0
        Refresh(true)
    end)
    lvl:SetScript("OnEnterPressed", lvl.ClearFocus)
    lvl:SetScript("OnEscapePressed", lvl.ClearFocus)
    panel.lvl = lvl

    local myLvl = SafeFrame("Button", left, "UIPanelButtonTemplate")
    myLvl:SetSize(40, 20)
    myLvl:SetPoint("LEFT", lvl, "RIGHT", 6, 0)
    myLvl:SetText("Me")
    myLvl:SetScript("OnClick", function()
        local l = tostring(UnitLevel("player") or "")
        lvl:SetText(l)
        DB().stats.maxLevel = l
        offset = 0
        Refresh(true)
    end)

    local reset = SafeFrame("Button", left, "UIPanelButtonTemplate")
    reset:SetSize(80, 22)
    reset:SetPoint("BOTTOMLEFT", 10, 8)
    reset:SetText("Reset")
    reset:SetScript("OnClick", function()
        local db = DB().stats
        wipe(db.filters)
        db.slot, db.maxLevel, db.text = 1, nil, nil
        for _, c in pairs(panel.checks) do c.cb:SetChecked(false); c.eb:SetText("") end
        lvl:SetText("")
        panel.search:SetText("")
        offset = 0
        Refresh(true)
    end)

    -- right: results
    local right = SafeFrame("Frame", panel, "InsetFrameTemplate")
    right:SetPoint("TOPLEFT", left, "TOPRIGHT", 4, 0)
    right:SetPoint("BOTTOMRIGHT", 0, 0)
    panel.right = right

    local search = SafeFrame("EditBox", right, "SearchBoxTemplate")
    search:SetSize(220, 20)
    search:SetPoint("TOPLEFT", 12, -8)
    search:SetAutoFocus(false)
    search:SetScript("OnTextChanged", function(self)
        if SearchBoxTemplate_OnTextChanged then SearchBoxTemplate_OnTextChanged(self) end
        DB().stats.text = self:GetText()
        offset = 0
        Refresh(true)
    end)
    panel.search = search

    local scanBtn = SafeFrame("Button", right, "UIPanelButtonTemplate")
    scanBtn:SetSize(90, 22)
    scanBtn:SetPoint("TOPRIGHT", -10, -6)
    scanBtn:SetMotionScriptsWhileDisabled(true)
    scanBtn:SetScript("OnClick", StartScan)
    scanBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Full scan")
        GameTooltip:AddLine("Reads every listing on the auction house. The game allows this once every 15 minutes; scans started by other addons count too.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    scanBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    panel.scanBtn = scanBtn

    local status = right:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    status:SetPoint("RIGHT", scanBtn, "LEFT", -10, 0)
    status:SetJustifyH("RIGHT")
    panel.status = status

    -- column headers
    local COLS = {
        { key = "name",  text = "Item",  x = 8,   w = 210, justify = "LEFT" },
        { key = "level", text = "Lvl",   x = 218, w = 30,  justify = "RIGHT" },
        { key = nil,     text = "Slot",  x = 256, w = 64,  justify = "LEFT" },
        { key = nil,     text = "Stats", x = 322, w = 0,   justify = "LEFT" },
        { key = "price", text = "Price", x = -50, w = 110, justify = "RIGHT" },
        { key = nil,     text = "Qty",   x = -8,  w = 36,  justify = "RIGHT" },
    }
    panel.cols = COLS
    local head = CreateFrame("Frame", nil, right)
    head:SetPoint("TOPLEFT", 4, -34)
    head:SetPoint("TOPRIGHT", -22, -34)
    head:SetHeight(18)
    for _, c in ipairs(COLS) do
        local b = CreateFrame("Button", nil, head)
        b:SetHeight(18)
        if c.x >= 0 then b:SetPoint("LEFT", c.x, 0) else b:SetPoint("RIGHT", c.x, 0) end
        if c.w > 0 then b:SetWidth(c.w) else b:SetPoint("RIGHT", head, "RIGHT", -170, 0) end
        local fs = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetAllPoints()
        fs:SetJustifyH(c.justify)
        fs:SetText(c.text)
        if c.key then
            b:SetScript("OnClick", function()
                if sortKey == c.key then sortDesc = not sortDesc else sortKey, sortDesc = c.key, c.key ~= "price" and c.key ~= "name" end
                Refresh(true)
            end)
        end
    end

    local list = CreateFrame("Frame", nil, right)
    list:SetPoint("TOPLEFT", head, "BOTTOMLEFT", 0, -2)
    list:SetPoint("BOTTOMRIGHT", right, "BOTTOMRIGHT", -22, 6)
    list:EnableMouseWheel(true)
    list:SetScript("OnMouseWheel", function(_, delta)
        offset = max(0, offset - delta * 3)
        Refresh()
    end)
    panel.list = list

    local slider = SafeFrame("Slider", right, "UIPanelScrollBarTemplate")
    slider:SetPoint("TOPRIGHT", right, "TOPRIGHT", -4, -52)
    slider:SetPoint("BOTTOMRIGHT", right, "BOTTOMRIGHT", -4, 22)
    slider:SetWidth(16)
    slider:SetValueStep(1)
    slider:SetMinMaxValues(0, 0)
    slider:SetValue(0)
    slider:SetScript("OnValueChanged", function(_, v)
        v = floor(v + 0.5)
        if v ~= offset then offset = v; Refresh() end
    end)
    panel.slider = slider

    for i = 1, 40 do
        local row = CreateFrame("Button", nil, list)
        row:SetHeight(ROW_H)
        row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
        row:SetPoint("TOPRIGHT", 0, -(i - 1) * ROW_H)
        local hl = row:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 0.82, 0, 0.12)
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(16, 16)
        row.icon:SetPoint("LEFT", 4, 0)
        row.cells = {}
        for ci, c in ipairs(COLS) do
            local fs = row:CreateFontString(nil, "OVERLAY", ci == 4 and "GameFontDisableSmall" or "GameFontHighlightSmall")
            fs:SetJustifyH(c.justify)
            fs:SetWordWrap(false)
            local x = c.x
            if ci == 1 then x = 24 end
            if x >= 0 then fs:SetPoint("LEFT", x, 0) else fs:SetPoint("RIGHT", x, 0) end
            if c.w > 0 then fs:SetWidth(ci == 1 and c.w - 20 or c.w) else fs:SetPoint("RIGHT", row, "RIGHT", -170, 0) end
            row.cells[ci] = fs
        end
        row:SetScript("OnEnter", function(self)
            if not self.item then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink(self.item.link)
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        row:RegisterForClicks("LeftButtonUp")
        row:SetScript("OnClick", function(self)
            if not self.item then return end
            if IsModifiedClick and IsModifiedClick() then
                HandleModifiedItemClick(self.item.link)
            else
                OpenOnBuyTab(self.item)
            end
        end)
        rows[i] = row
    end

    local empty = right:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    empty:SetPoint("CENTER", list, "CENTER")
    empty:SetWidth(360)
    panel.empty = empty

    -- restore saved filters
    local db = DB().stats
    for key, c in pairs(panel.checks) do
        local v = db.filters[key]
        c.cb:SetChecked(v ~= nil)
        c.eb:SetText(v and v ~= "0" and v or "")
    end
    lvl:SetText(db.maxLevel or "")
    search:SetText(db.text or "")

    panel:SetScript("OnShow", function() Refresh(true) end)
    local acc = 0
    panel:SetScript("OnUpdate", function(_, dt)
        acc = acc + dt
        if acc < 0.5 then return end
        acc = 0
        if S.state == "waiting" and time() - (S.asked or 0) > SCAN_TIMEOUT then
            S.state = "idle"
            Print("The auction house didn't send the scan. Its wait between scans may not be over; try again later.")
        end
        Refresh()
    end)
end

Refresh = function(refilter)
    if not panel or not panel:IsShown() then return end
    local filters = ActiveFilters()
    if refilter then filters = Filter() end

    -- scan button and status
    local b = panel.scanBtn
    if S.state == "waiting" then
        b:SetText("..."); b:Disable()
    elseif S.state == "reading" then
        b:SetText(S.total and S.total > 0 and floor((S.done or 0) * 100 / S.total) .. "%" or "..."); b:Disable()
    else
        local wait = ScanWait()
        if wait > 0 then b:SetText(Clock(wait)); b:Disable() else b:SetText("Scan"); b:Enable() end
    end
    local waiting = 0
    for _ in pairs(S.pending) do waiting = waiting + 1 end
    if S.scanTime > 0 then
        local age = floor((time() - S.scanTime) / 60)
        panel.status:SetText(format("%d items  |  scanned %s%s", #S.order,
            age < 1 and "just now" or (age < 120 and age .. " min ago" or floor(age / 60) .. " h ago"),
            waiting > 0 and format("  |  loading %d", waiting) or ""))
    else
        panel.status:SetText("No scan yet")
    end

    panel.slotBtn:SetText(SLOTS[DB().stats.slot or 1].label)

    -- rows
    local list = panel.list
    local visible = max(1, floor((list:GetHeight() or 300) / ROW_H))
    local n = #results
    local maxOffset = max(0, n - visible)
    if offset > maxOffset then offset = maxOffset end
    panel.slider:SetMinMaxValues(0, maxOffset)
    if floor((panel.slider:GetValue() or 0) + 0.5) ~= offset then panel.slider:SetValue(offset) end
    for i, row in ipairs(rows) do
        local it = (i <= visible) and results[offset + i] or nil
        if it then
            row.item = it
            row.icon:SetTexture(it.icon or 134400)
            local color = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[it.quality or 1]
            row.cells[1]:SetText((color and color.hex or "|cffffffff") .. it.name .. "|r")
            row.cells[2]:SetText(it.level and it.level > 0 and it.level or "")
            row.cells[3]:SetText(SLOT_SHORT[it.loc] or "")
            row.cells[4]:SetText(StatText(it, filters))
            row.cells[5]:SetText(Money(it.price))
            row.cells[6]:SetText(it.qty)
            row:Show()
        else
            row.item = nil
            row:Hide()
        end
    end

    local text
    if S.scanTime == 0 and S.state == "idle" then
        text = "Click Scan to read the auction house.\nThen tick the stats you want and set a minimum."
    elseif n == 0 then
        local slot = SLOTS[DB().stats.slot or 1]
        if #filters == 0 and not slot.locs and (DB().stats.text or "") == "" then
            text = "Tick one or more stats on the left."
        else
            text = "No gear on the auction house matches." .. (waiting > 0 and "\nSome items are still loading." or "")
        end
    end
    panel.empty:SetText(text or "")
    panel.empty:SetShown(text ~= nil)
end

-- ---------------------------------------------------------------------------
-- Tab in the auction house window
-- ---------------------------------------------------------------------------

local tabBuilt = false

local function OwnTab()
    -- a tab like the game's, placed after the last tab (used when LibAHTab isn't loaded)
    local anchor = AuctionHouseFrame.Tabs and AuctionHouseFrame.Tabs[#AuctionHouseFrame.Tabs]
    local tab = SafeFrame("Button", AuctionHouseFrame, "AuctionHouseFrameDisplayModeTabTemplate", "SimpleAHStatsTab")
    tab:SetText("Stats")
    if PanelTemplates_TabResize then PanelTemplates_TabResize(tab, 20, nil, 70) end
    if anchor then tab:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 3, 0) end
    if PanelTemplates_DeselectTab then PanelTemplates_DeselectTab(tab) end
    tab:SetScript("OnClick", function()
        AuctionHouseFrame:SetDisplayMode({})
        AuctionHouseFrame.displayMode = nil
        for _, t in ipairs(AuctionHouseFrame.Tabs or {}) do PanelTemplates_DeselectTab(t) end
        PanelTemplates_SelectTab(tab)
        if AuctionHouseFrame.SetTitle then AuctionHouseFrame:SetTitle("Stats") end
        panel:Show()
    end)
    hooksecurefunc(AuctionHouseFrame, "SetDisplayMode", function(_, mode)
        if mode ~= nil and #mode > 0 then
            panel:Hide()
            PanelTemplates_DeselectTab(tab)
        end
    end)
end

local function BuildTab()
    if tabBuilt or not AuctionHouseFrame then return end
    tabBuilt = true
    BuildPanel()
    local lib = LibStub and LibStub("LibAHTab-1-0", true)
    local ok = lib and pcall(lib.CreateTab, lib, "SimpleAHStats", panel, "Stats", "Simple AH: Stats")
    if not ok then OwnTab() end
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("AUCTION_HOUSE_SHOW")
events:RegisterEvent("REPLICATE_ITEM_LIST_UPDATE")
events:RegisterEvent("GET_ITEM_INFO_RECEIVED")

local lastRead = 0
events:SetScript("OnEvent", function(_, event, arg1)
    if event == "PLAYER_LOGIN" then
        LoadSavedScan()
        if #S.order > 0 then DescribeAll() end
    elseif event == "ADDON_LOADED" then
        if arg1 == "Blizzard_AuctionHouseUI" then BuildTab() end
    elseif event == "AUCTION_HOUSE_SHOW" then
        BuildTab()
    elseif event == "REPLICATE_ITEM_LIST_UPDATE" then
        -- also arrives when another addon asked for the scan; the list repeats briefly
        if S.state == "reading" then return end
        if S.state ~= "waiting" and time() - lastRead < 60 then return end
        if S.state ~= "waiting" then DB().stats.lastScan = time() end
        lastRead = time()
        ReadReplicate()
    elseif event == "GET_ITEM_INFO_RECEIVED" then
        -- item data arrived; re-check waiting items soon (batched)
        if next(S.pending) and not S.recheck then
            S.recheck = true
            C_Timer.After(1, function() S.recheck = nil; DescribeAll() end)
        end
    end
end)

-- /run for k,v in ipairs(SimpleAH_StatResults()) do print(v.name, v.price) end
function SimpleAH_StatResults()
    Filter()
    return results
end

function SimpleAH_OpenStats()
    if not (AuctionHouseFrame and AuctionHouseFrame:IsShown()) then
        Print("Open the auction house, then use the Stats tab.")
        return
    end
    BuildTab()
    local lib = LibStub and LibStub("LibAHTab-1-0", true)
    if lib and lib.DoesIDExist and lib:DoesIDExist("SimpleAHStats") then
        lib:SetSelected("SimpleAHStats")
    elseif SimpleAHStatsTab then
        SimpleAHStatsTab:Click()
    end
end
