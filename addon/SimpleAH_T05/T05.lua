-- Simple AH: T0.5 Planner
-- Shopping list for the Tier 0.5 (Dungeon Set 2) quest chain. Counts what you
-- already have (bags + bank), lets you tick off what you have covered, and
-- prices the rest with Simple AH's auction house data. Each craftable item
-- can be priced as bought or as crafted from its materials.
-- Source of the list: Wowhead "How to Acquire Tier 0.5 Dungeon Sets in Forever".

local floor, max, format = math.floor, math.max, string.format

-- ---------------------------------------------------------------------------
-- The shopping list
-- ---------------------------------------------------------------------------

local PARTS = {
    "Part 1  \194\183  Wrists",
    "Part 2  \194\183  Belt & Gloves",
    "Part 3  \194\183  Legs, Shoulders & Boots",
    "Part 4  \194\183  Helm & Chest",
}

-- gold = fixed vendor/fee cost per unit; craft = materials per ONE item
local ROWS = {
    { part = 1, key = "fee_handin", name = "Hand-in fee", gold = 20,
      note = "Paid to Deliana / Mokvar with the 15 samples." },

    { part = 2, key = "fee_mux", name = "Distiller fee (Mux)", gold = 40,
      note = "Paid to Mux Manascrambler with the distiller materials." },
    { part = 2, key = "felrod", id = 21939, name = "Fel Elemental Rod", need = 1, gold = 40,
      note = "Vi'el, Darkwhisper Gorge, Winterspring. Buy it before taking the quest: it costs 50g after." },
    { part = 2, key = "converter", id = 16006, name = "Delicate Arcanite Converter", need = 1, mode = "craft",
      craft = { { 12363, 1 }, { 12359, 1 }, { 14227, 1 } },
      note = "Craft: Arcanite Bar (transmute: Thorium Bar + Arcane Crystal) + Ironweb Spider Silk." },
    { part = 2, key = "gee", id = 16203, name = "Greater Eternal Essence", need = 4 },
    { part = 2, key = "oil", id = 13423, name = "Stonescale Oil", need = 10,
      craft = { { 13422, 0.5 }, { 3372, 0.5 } }, note = "Each craft makes 2." },
    { part = 2, key = "fuel", id = 9061, name = "Goblin Rocket Fuel", need = 8,
      craft = { { 4625, 0.5 }, { 9260, 0.5 }, { 3372, 0.5 } },
      note = "You get 8 in the chain; extras help with the ectoplasm. Each craft makes 2." },

    { part = 3, key = "darkiron", id = 11371, name = "Dark Iron Bar", need = 3,
      craft = { { 11370, 8 } }, note = "Smelted at the Black Forge in Blackrock Depths." },
    { part = 3, key = "mooncloth", id = 14342, name = "Mooncloth", need = 3,
      craft = { { 14256, 2 } }, note = "Tailoring, has a cooldown." },
    { part = 3, key = "eleather", id = 12810, name = "Enchanted Leather", need = 20,
      craft = { { 8170, 1 }, { 16202, 1 } } },
    { part = 3, key = "curedhide", id = 15407, name = "Cured Rugged Hide", need = 4,
      craft = { { 8171, 0.5 }, { 15409, 0.5 } }, note = "Each craft makes 2." },
    { part = 3, key = "lbs", id = 14344, name = "Large Brilliant Shard", need = 8 },
    { part = 3, key = "darkrune", id = 20520, name = "Dark Rune", need = 4 },

    { part = 4, key = "brazier", id = 22014, name = "Hallowed Brazier", need = 1, gold = 120,
      note = "Needs Honored with the Argent Dawn." },
    { part = 4, key = "flask", id = 13512, name = "Flask of Supreme Power", need = 1,
      craft = { { 13463, 30 }, { 13465, 10 }, { 13468, 1 }, { 8925, 1 } } },
}

-- ---------------------------------------------------------------------------
-- Look and helpers
-- ---------------------------------------------------------------------------

local T = {
    bg = { 0.07, 0.08, 0.10, 0.96 }, line = { 1, 1, 1, 0.07 }, accent = { 0.85, 0.70, 0.42 },
    fg = "|cffe6e9ee", muted = "|cff8a93a0", faint = "|cff5c6470", gold = "|cffd9b36b",
    good = "|cff4ade80", bad = "|cfff87171",
}
local UI_FONT = "Fonts\\ARIALN.TTF"
local WIDTH, ROW_H, PART_H = 480, 22, 22

local db

local function Money(c)
    if not c then return T.faint .. "no price|r" end
    c = floor(c + 0.5)
    if c <= 0 then return T.faint .. "-|r" end
    local g, s, cp = floor(c / 10000), floor(c / 100) % 100, c % 100
    if g > 0 then return format("%s%d|r%sg|r %s%02d|r|cffaab2bas|r", T.fg, g, T.gold, T.fg, s) end
    if s > 0 then return format("%s%d|r|cffaab2bas|r %s%02d|r|cffc0835ac|r", T.fg, s, T.fg, cp) end
    return format("%s%d|r|cffc0835ac|r", T.fg, cp)
end

local function AHPrice(id)
    if not SimpleAH or not id then return nil end
    local p = SimpleAH.GetMarket(id) or SimpleAH.GetMin(id)
    if p and p > 0 then return p end
end

local function Count(id)
    if not id then return 0 end
    if C_Item and C_Item.GetItemCount then return C_Item.GetItemCount(id, true) or 0 end
    return GetItemCount(id, true) or 0
end

local function ItemName(id, fallback)
    local n = id and C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id)
    return n or fallback or ("item " .. tostring(id))
end

local function ItemIcon(id)
    if not id then return nil end
    if C_Item and C_Item.GetItemIconByID then return C_Item.GetItemIconByID(id) end
    return GetItemIcon and GetItemIcon(id)
end

local function Mode(row)
    if not row.craft then return "buy" end
    return db.mode[row.key] or row.mode or "buy"
end

-- price of one unit, and whether every part of it has a price
local function UnitPrice(row)
    if row.gold then return row.gold * 10000 end
    if Mode(row) == "craft" then
        local sum = 0
        for _, m in ipairs(row.craft) do
            local p = AHPrice(m[1])
            if not p then return nil end
            sum = sum + p * m[2]
        end
        return sum
    end
    return AHPrice(row.id)
end

local function State(row)
    local need = row.need or 1
    local have = row.id and Count(row.id) or 0
    local done = db.done[row.key] or have >= need
    local missing = done and 0 or max(0, need - have)
    local unit = UnitPrice(row)
    return {
        need = need, have = have, done = done, missing = missing, unit = unit,
        cost = unit and unit * missing, full = unit and unit * need,
    }
end

-- ---------------------------------------------------------------------------
-- Frame
-- ---------------------------------------------------------------------------

local frame = CreateFrame("Frame", "SimpleAHT05Frame", UIParent)
frame:SetSize(WIDTH, 400)
frame:SetFrameStrata("MEDIUM")
frame:SetClampedToScreen(true)
frame:SetMovable(true)
frame:EnableMouse(true)
frame:RegisterForDrag("LeftButton")
frame:Hide()
tinsert(UISpecialFrames, "SimpleAHT05Frame")

local function Solid(parent, layer, c)
    local t = parent:CreateTexture(nil, layer or "BACKGROUND")
    t:SetColorTexture(c[1], c[2], c[3], c[4] or 1)
    return t
end

local function Text(parent, size, justify, font)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    fs:SetFont(font or UI_FONT, size, "")
    fs:SetJustifyH(justify or "LEFT")
    fs:SetWordWrap(false)
    return fs
end

Solid(frame, "BACKGROUND", T.bg):SetAllPoints()
do
    local c = { 1, 1, 1, 0.10 }
    local t = Solid(frame, "BORDER", c); t:SetPoint("TOPLEFT"); t:SetPoint("TOPRIGHT"); t:SetHeight(1)
    local b = Solid(frame, "BORDER", c); b:SetPoint("BOTTOMLEFT"); b:SetPoint("BOTTOMRIGHT"); b:SetHeight(1)
    local l = Solid(frame, "BORDER", c); l:SetPoint("TOPLEFT"); l:SetPoint("BOTTOMLEFT"); l:SetWidth(1)
    local r = Solid(frame, "BORDER", c); r:SetPoint("TOPRIGHT"); r:SetPoint("BOTTOMRIGHT"); r:SetWidth(1)
    local a = Solid(frame, "ARTWORK", T.accent); a:SetPoint("TOPLEFT", 1, -1); a:SetPoint("TOPRIGHT", -1, -1); a:SetHeight(2)
end

frame:SetScript("OnDragStart", frame.StartMoving)
frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local p, _, rp, x, y = self:GetPoint()
    db.point = { p, rp, x, y }
end)

local title = Text(frame, 15)
title:SetPoint("TOPLEFT", 14, -12)
title:SetText(T.fg .. "Tier 0.5 Planner|r")

local close = CreateFrame("Button", nil, frame)
close:SetSize(20, 20)
close:SetPoint("TOPRIGHT", -6, -8)
local closeTxt = Text(close, 15, "CENTER")
closeTxt:SetPoint("CENTER")
closeTxt:SetText(T.muted .. "x|r")
close:SetScript("OnClick", function() frame:Hide() end)
close:SetScript("OnEnter", function() closeTxt:SetText(T.bad .. "x|r") end)
close:SetScript("OnLeave", function() closeTxt:SetText(T.muted .. "x|r") end)

-- summary
local toBuyLabel = Text(frame, 10)
toBuyLabel:SetPoint("TOPLEFT", 14, -38)
toBuyLabel:SetText(T.muted .. "STILL TO BUY|r")
local toBuy = Text(frame, 20)
toBuy:SetPoint("TOPLEFT", toBuyLabel, "BOTTOMLEFT", 0, -3)
local totalLabel = Text(frame, 10, "RIGHT")
totalLabel:SetPoint("TOPRIGHT", -14, -38)
local progress = Text(frame, 13, "RIGHT")
progress:SetPoint("TOPRIGHT", totalLabel, "BOTTOMRIGHT", 0, -5)

local barBg = Solid(frame, "ARTWORK", { 1, 1, 1, 0.07 })
barBg:SetPoint("TOPLEFT", 14, -82)
barBg:SetPoint("TOPRIGHT", -14, -82)
barBg:SetHeight(3)
local bar = Solid(frame, "OVERLAY", T.accent)
bar:SetPoint("TOPLEFT", barBg, "TOPLEFT")
bar:SetHeight(3)

-- column heads
local LIST_TOP = -96
local heads = {
    { "ITEM", 54, 200, "LEFT" }, { "HAVE", 262, 52, "RIGHT" }, { "PRICED AS", 320, 52, "CENTER" }, { "STILL COSTS", 374, 92, "RIGHT" },
}
for _, h in ipairs(heads) do
    local fs = Text(frame, 9, h[4])
    fs:SetPoint("TOPLEFT", h[2], LIST_TOP)
    fs:SetWidth(h[3])
    fs:SetText(T.faint .. h[1] .. "|r")
end

-- ---------------------------------------------------------------------------
-- Rows
-- ---------------------------------------------------------------------------

local Update -- forward

local function RowTooltip(owner, row)
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    if row.id then GameTooltip:SetItemByID(row.id) else GameTooltip:AddLine(row.name) end
    GameTooltip:AddLine(" ")
    local s = State(row)
    if row.gold then
        GameTooltip:AddDoubleLine("Cost", Money(row.gold * 10000), 0.8, 0.8, 0.8)
    else
        GameTooltip:AddDoubleLine("Buy (AH, each)", Money(AHPrice(row.id)), 0.8, 0.8, 0.8)
        if row.craft then
            local sum, ok = 0, true
            for _, m in ipairs(row.craft) do
                local p = AHPrice(m[1])
                if p then sum = sum + p * m[2] else ok = false end
            end
            GameTooltip:AddDoubleLine("Craft (materials, each)", ok and Money(sum) or Money(nil), 0.8, 0.8, 0.8)
            for _, m in ipairs(row.craft) do
                local n = m[2] * s.need
                GameTooltip:AddDoubleLine(format("   %sx %s", (n == floor(n)) and tostring(n) or format("%.1f", n), ItemName(m[1])),
                    Money(AHPrice(m[1]) and AHPrice(m[1]) * n), 0.65, 0.65, 0.65)
            end
        end
    end
    GameTooltip:AddDoubleLine(format("Need %d, have %d", s.need, s.have), s.done and "|cff4ade80covered|r" or Money(s.cost), 0.8, 0.8, 0.8)
    if row.note then GameTooltip:AddLine(row.note, 0.6, 0.65, 0.7, true) end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Click: search it at the auction house (when open)", 0.45, 0.5, 0.55)
    GameTooltip:AddLine("Shift-click: link it / Simple AH search", 0.45, 0.5, 0.55)
    GameTooltip:Show()
end

local function SearchAH(row)
    if not row.id or not (AuctionHouseFrame and AuctionHouseFrame:IsShown()) then return end
    local bar = AuctionHouseFrame.SearchBar
    if bar and bar.SetSearchText and bar.StartSearch then
        pcall(bar.SetSearchText, bar, ItemName(row.id, row.name))
        pcall(bar.StartSearch, bar)
    end
end

local partHeads, rowFrames = {}, {}
local y = LIST_TOP - 14
local lastPart
for _, row in ipairs(ROWS) do
    if row.part ~= lastPart then
        lastPart = row.part
        local h = Text(frame, 11)
        h:SetPoint("TOPLEFT", 14, y - 7)
        h:SetText(T.gold .. PARTS[row.part] .. "|r")
        local line = Solid(frame, "ARTWORK", T.line)
        line:SetPoint("TOPLEFT", 14, y - PART_H + 2)
        line:SetPoint("TOPRIGHT", -14, y - PART_H + 2)
        line:SetHeight(1)
        partHeads[row.part] = h
        y = y - PART_H
    end

    local f = CreateFrame("Frame", nil, frame)
    f:SetPoint("TOPLEFT", 0, y)
    f:SetSize(WIDTH, ROW_H)
    f.row = row

    local hl = Solid(f, "BACKGROUND", { 1, 1, 1, 0.04 })
    hl:SetPoint("TOPLEFT", 10, 0); hl:SetPoint("BOTTOMRIGHT", -10, 0); hl:Hide()

    local cb = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    cb:SetSize(20, 20)
    cb:SetPoint("LEFT", 10, 0)
    cb:SetScript("OnClick", function(self)
        db.done[row.key] = self:GetChecked() or nil
        Update()
    end)
    cb:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Covered")
        GameTooltip:AddLine("Tick when you have it or will make it yourself. Items in your bags and bank are counted automatically.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    cb:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local icon = f:CreateTexture(nil, "ARTWORK")
    icon:SetSize(16, 16)
    icon:SetPoint("LEFT", 34, 0)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    local nameBtn = CreateFrame("Button", nil, f)
    nameBtn:SetPoint("LEFT", 54, 0)
    nameBtn:SetSize(204, ROW_H)
    local name = Text(nameBtn, 12, "LEFT", "Fonts\\FRIZQT__.TTF")
    name:SetAllPoints()
    nameBtn:SetScript("OnEnter", function(self) hl:Show(); RowTooltip(self, row) end)
    nameBtn:SetScript("OnLeave", function() hl:Hide(); GameTooltip:Hide() end)
    nameBtn:SetScript("OnClick", function()
        if IsShiftKeyDown() and row.id then
            local _, link = GetItemInfo(row.id)
            if link and ChatEdit_InsertLink then ChatEdit_InsertLink(link) end
        else
            SearchAH(row)
        end
    end)

    local have = Text(f, 12, "RIGHT")
    have:SetPoint("LEFT", 262, 0)
    have:SetWidth(52)

    local mode = CreateFrame("Button", nil, f)
    mode:SetSize(50, 16)
    mode:SetPoint("LEFT", 321, 0)
    local modeBg = Solid(mode, "BACKGROUND", { 1, 1, 1, 0.06 })
    modeBg:SetAllPoints()
    local modeTxt = Text(mode, 10, "CENTER")
    modeTxt:SetAllPoints()
    mode:SetScript("OnClick", function()
        db.mode[row.key] = (Mode(row) == "craft") and "buy" or "craft"
        Update()
    end)
    mode:SetScript("OnEnter", function(self)
        modeBg:SetColorTexture(1, 1, 1, 0.12)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Buy or craft")
        GameTooltip:AddLine("Click to price this item as bought at the auction house or crafted from its materials.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    mode:SetScript("OnLeave", function() modeBg:SetColorTexture(1, 1, 1, 0.06); GameTooltip:Hide() end)

    local cost = Text(f, 12, "RIGHT")
    cost:SetPoint("LEFT", 374, 0)
    cost:SetWidth(92)

    f.cb, f.icon, f.name, f.have, f.mode, f.modeTxt, f.cost = cb, icon, name, have, mode, modeTxt, cost
    rowFrames[#rowFrames + 1] = f
    y = y - ROW_H
end

local footer = Text(frame, 10)
footer:SetPoint("TOPLEFT", 14, y - 10)
footer:SetPoint("RIGHT", frame, "RIGHT", -14, 0)
frame:SetHeight(-y + 32)

-- ---------------------------------------------------------------------------
-- Update
-- ---------------------------------------------------------------------------

local function Age(ts)
    if not ts or ts <= 0 then return "never" end
    local sec = time() - ts
    if sec < 3600 then return format("%dm ago", floor(sec / 60)) end
    return format("%dh %dm ago", floor(sec / 3600), floor(sec % 3600 / 60))
end

Update = function()
    if not db or not frame:IsShown() then return end
    local remaining, total, doneCount, unpriced = 0, 0, 0, 0
    for _, f in ipairs(rowFrames) do
        local row = f.row
        local s = State(row)
        f.cb:SetChecked(db.done[row.key] and true or false)
        local ic = ItemIcon(row.id) or (row.gold and 133784) or 134400
        f.icon:SetTexture(ic)
        f.icon:SetDesaturated(s.done)
        local nm = ItemName(row.id, row.name)
        if row.key == "fuel" then nm = nm .. " (extra)" end
        f.name:SetText((s.done and T.faint or T.fg) .. nm .. "|r")
        if row.id then
            local col = s.done and T.good or (s.have > 0 and T.fg or T.muted)
            f.have:SetText(format("%s%d|r%s / %d|r", col, math.min(s.have, 999), T.faint, s.need))
        else
            f.have:SetText("")
        end
        if row.craft then
            f.mode:Show()
            f.modeTxt:SetText((Mode(row) == "craft" and T.gold .. "Craft" or T.fg .. "Buy") .. "|r")
        else
            f.mode:Hide()
        end
        if s.done then
            f.cost:SetText(T.good .. "\226\156\147|r")
            doneCount = doneCount + 1
        else
            f.cost:SetText(Money(s.cost))
            if not s.unit then unpriced = unpriced + 1 end
        end
        remaining = remaining + (s.cost or 0)
        total = total + (s.full or 0)
    end
    toBuy:SetText(Money(remaining))
    totalLabel:SetText(T.muted .. "WHOLE CHAIN  |r" .. Money(total))
    progress:SetText(format("%s%d|r%s / %d covered|r", T.fg, doneCount, T.muted, #rowFrames))
    local w = barBg:GetWidth() or (WIDTH - 28)
    bar:SetWidth(math.max(1, w * doneCount / #rowFrames))

    local foot
    if not SimpleAH then
        foot = T.bad .. "Simple AH is not loaded, so there are no prices.|r"
    else
        local label, scanned = "Auction house", 0
        if SimpleAH.GetMarketInfo then label, scanned = SimpleAH.GetMarketInfo() end
        foot = format("%sPrices: %s, scanned %s|r", T.muted, (label and label ~= "") and label or "Simple AH", Age(scanned))
        if unpriced > 0 then foot = foot .. format("%s  \194\183  %d without a price|r", T.bad, unpriced) end
    end
    footer:SetText(foot)
end

frame:SetScript("OnShow", function() Update() end)

-- ---------------------------------------------------------------------------
-- Events and commands
-- ---------------------------------------------------------------------------

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("BAG_UPDATE_DELAYED")
events:RegisterEvent("PLAYERBANKSLOTS_CHANGED")
events:RegisterEvent("BANKFRAME_OPENED")
events:RegisterEvent("GET_ITEM_INFO_RECEIVED")
events:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= "SimpleAH_T05" then return end
        SimpleAHT05DB = SimpleAHT05DB or {}
        db = SimpleAHT05DB
        db.done = db.done or {}
        db.mode = db.mode or {}
        if not db.seeded then
            db.seeded = true
            db.done.curedhide = true -- 2 in the bags, 2 more from tomorrow's cooldown
        end
        local p = db.point
        if p then frame:ClearAllPoints(); frame:SetPoint(p[1], UIParent, p[2], p[3], p[4])
        else frame:SetPoint("CENTER", 0, 60) end
        return
    end
    Update()
end)

SLASH_SIMPLEAHT051 = "/t05"
SlashCmdList.SIMPLEAHT05 = function(msg)
    msg = (msg or ""):lower():match("^%s*(.-)%s*$")
    if msg == "reset" then
        wipe(db.done)
        wipe(db.mode)
        print("|cffd9b36bT0.5 Planner|r  ticks and buy/craft choices cleared.")
        Update()
    else
        frame:SetShown(not frame:IsShown())
    end
end
