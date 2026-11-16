-- Simple AH
-- Auction house prices for WoW Forever, supplied by the desktop updater (Blizzard API) in PriceData.lua.
-- /ah [text]   open the search
-- /ah bind     set a key that opens the search

local ADDON = ...

local floor, format, tinsert, max, min = math.floor, string.format, table.insert, math.max, math.min

-- ---------------------------------------------------------------------------
-- Design tokens
-- Layout: a single search field that grows into a result list underneath,
-- nothing else on screen until there is something to show.
-- ---------------------------------------------------------------------------

local T = {
    surface  = { 0.071, 0.078, 0.090, 0.96 },  -- slate, slightly cool
    raised   = { 1, 1, 1, 0.035 },
    hairline = { 1, 1, 1, 0.07 },
    hover    = { 0.85, 0.70, 0.42, 0.08 },     -- warm tint of the accent
    accent   = { 0.85, 0.70, 0.42 },           -- muted coin gold
    fg       = "|cffe6e8ea",
    muted    = "|cff7f8a94",
    faint    = "|cff4d565e",
    accentHex= "|cffd9b36b",
}
local FONT_UI   = "Fonts\\ARIALN.TTF"
local FONT_TEXT = STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"

local WIDTH      = 520
local PAD        = 14
local SEARCH_H   = 44
local HEAD_H     = 20
local ROW_H      = 24
local MAX_ROWS   = 12
local FOOT_H     = 26

local BIND_ACTION = "SIMPLEAH_TOGGLE"
BINDING_HEADER_SIMPLEAH = "Simple AH"
BINDING_NAME_SIMPLEAH_TOGGLE = "Open price search"

local defaults = {
    point   = { "TOP", "UIParent", "TOP", 0, -140 },
    scale   = 1,
    tooltip = true,
}

local db, names
local DATA = SimpleAHData or {}
local MK = { items = {}, count = 0, scanned = 0, label = "" } -- the market being shown
local GROUP_LABELS = { pvp = "PvP", g2 = "Group 2", g3 = "Group 3", g4 = "Group 4", g5 = "Group 5" }

-- ---------------------------------------------------------------------------
-- Data access
-- ---------------------------------------------------------------------------

local parsed = {}

-- Returns { min, market, avg, qty, auctions } or nil
local function GetPrice(itemID)
    local p = parsed[itemID]
    if p ~= nil then return p or nil end
    local s = MK.items[itemID]
    local a, b, c, d, e
    if s then a, b, c, d, e = s:match("^(%d+),(%d+),(%d+),(%d+),(%d+)$") end
    if not a then
        parsed[itemID] = false
        return nil
    end
    p = { min = tonumber(a), market = tonumber(b), avg = tonumber(c), qty = tonumber(d), auctions = tonumber(e) }
    parsed[itemID] = p
    return p
end

-- Public API for other addons / macros
SimpleAH = {
    GetPrice  = GetPrice,
    GetMarket = function(id) local p = GetPrice(id); return p and p.market end,
    GetMin    = function(id) local p = GetPrice(id); return p and p.min end,
}

local function ItemName(id)
    if C_Item and C_Item.GetItemNameByID then return C_Item.GetItemNameByID(id) end
    return (GetItemInfo(id))
end

local function ItemQuality(id)
    if C_Item and C_Item.GetItemQualityByID then return C_Item.GetItemQualityByID(id) end
    return select(3, GetItemInfo(id))
end

local function ItemIcon(id)
    if C_Item and C_Item.GetItemIconByID then return C_Item.GetItemIconByID(id) end
    return GetItemIcon and GetItemIcon(id)
end

local function RequestItem(id)
    if C_Item and C_Item.RequestLoadItemDataByID then
        C_Item.RequestLoadItemDataByID(id)
    else
        GetItemInfo(id)
    end
end

local function QualityHex(q)
    local c = q and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
    if c and c.hex then return c.hex end
    if c then return format("|cff%02x%02x%02x", floor(c.r * 255), floor(c.g * 255), floor(c.b * 255)) end
    return T.fg
end

-- ---------------------------------------------------------------------------
-- Formatting
-- ---------------------------------------------------------------------------

local function Thousands(n)
    local s = tostring(floor(n))
    return (s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", ""))
end

local G, S, C = "|cffd9b36bg|r", "|cffaab2bas|r", "|cffc0835ac|r"

local function Money(c)
    if not c or c <= 0 then return T.faint .. "-|r" end
    local g = floor(c / 10000)
    local s = floor(c / 100) % 100
    local cp = c % 100
    if g >= 100 then
        return format("%s%s%s", T.fg, Thousands(g), "|r" .. G)
    elseif g > 0 then
        return format("%s%d|r%s %s%02d|r%s", T.fg, g, G, T.fg, s, S)
    elseif s > 0 then
        return format("%s%d|r%s %s%02d|r%s", T.fg, s, S, T.fg, cp, C)
    end
    return format("%s%d|r%s", T.fg, cp, C)
end

local function MoneyFull(c)
    if not c or c <= 0 then return "-" end
    if GetMoneyString then return GetMoneyString(c, true) end
    return Money(c)
end

local function Age(ts)
    if not ts or ts <= 0 then return "never" end
    local sec = time() - ts
    if sec < 90 then return "just now" end
    if sec < 3600 then return format("%d min ago", floor(sec / 60)) end
    if sec < 86400 then return format("%dh %dm ago", floor(sec / 3600), floor(sec % 3600 / 60)) end
    return format("%d days ago", floor(sec / 86400))
end

-- ---------------------------------------------------------------------------
-- Name index (loads the names of every item in the data, a little per frame)
-- ---------------------------------------------------------------------------

local lowerNames = {}
local indexQueue, queuePos, pendingCount = {}, 1, 0
local indexed, total = 0, 0
local pending = {}

local function SetName(id, name)
    if not names[id] then indexed = indexed + 1 end
    names[id] = name
    lowerNames[id] = name:lower()
end

local function BuildIndexQueue()
    wipe(indexQueue)
    queuePos, indexed, total = 1, 0, 0
    for id in pairs(MK.items) do
        total = total + 1
        local n = names[id]
        if n then
            indexed = indexed + 1
            lowerNames[id] = n:lower()
        else
            indexQueue[#indexQueue + 1] = id
        end
    end
end

local indexer = CreateFrame("Frame")
local stuckTimer = 0
indexer:SetScript("OnUpdate", function(self, elapsed)
    if queuePos > #indexQueue and pendingCount == 0 then
        self:Hide()
        return
    end
    stuckTimer = stuckTimer + elapsed
    if stuckTimer > 10 then
        stuckTimer = 0
        pendingCount = 0
        wipe(pending)
    end
    local budget = 60
    while budget > 0 and queuePos <= #indexQueue and pendingCount < 250 do
        local id = indexQueue[queuePos]
        queuePos = queuePos + 1
        budget = budget - 1
        if not names[id] then
            local n = ItemName(id)
            if n and n ~= "" then
                SetName(id, n)
            else
                pending[id] = true
                pendingCount = pendingCount + 1
                RequestItem(id)
            end
        end
    end
end)
indexer:Hide()

local function ItemLoaded(id, success)
    if not pending[id] then return end
    pending[id] = nil
    pendingCount = max(0, pendingCount - 1)
    stuckTimer = 0
    if success ~= false then
        local n = ItemName(id)
        if n and n ~= "" then SetName(id, n) end
    end
end

-- ---------------------------------------------------------------------------
-- Markets: the data holds every auction house; show the one for this
-- character's faction in the chosen ruleset group.
-- ---------------------------------------------------------------------------

local function GroupLabel(g) return GROUP_LABELS[g] or g or "" end

local function MarketList()
    local out = {}
    for id, m in pairs(DATA.markets or {}) do out[#out + 1] = { id = id, m = m } end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

local function Groups()
    local seen, out = {}, {}
    for _, e in ipairs(MarketList()) do
        local g = e.m.group or ""
        if not seen[g] then seen[g] = true; out[#out + 1] = g end
    end
    return out
end

local OnMarketChanged -- set by the UI below

local function SelectMarket()
    local chosen
    if DATA.markets then
        local group = db and db.group or "pvp"
        local faction = (db and db.neutral) and "Blackwater" or (UnitFactionGroup("player") or "Horde")
        local fallback
        for _, e in ipairs(MarketList()) do
            if e.m.group == group then
                fallback = fallback or e
                if e.m.faction == faction then chosen = e; break end
            end
        end
        chosen = chosen or fallback or MarketList()[1]
    end
    if chosen then
        local m = chosen.m
        MK = { id = chosen.id, items = m.items or {}, count = m.count or 0,
               scanned = m.scanned or DATA.updated or 0, group = m.group, faction = m.faction,
               label = (GroupLabel(m.group) .. " " .. (m.faction or "")):gsub("^%s+", "") }
    elseif DATA.items then -- older single-market file
        MK = { items = DATA.items, count = DATA.count or 0, scanned = DATA.scanned or 0, label = DATA.market or "" }
    else
        MK = { items = {}, count = 0, scanned = 0, label = "" }
    end
    wipe(parsed)
    if names then
        wipe(lowerNames)
        BuildIndexQueue()
        if #indexQueue > 0 then indexer:Show() end
    end
    if OnMarketChanged then OnMarketChanged() end
end

-- ---------------------------------------------------------------------------
-- UI primitives
-- ---------------------------------------------------------------------------

local function Fill(parent, layer, c)
    local t = parent:CreateTexture(nil, layer or "BACKGROUND")
    t:SetColorTexture(c[1], c[2], c[3], c[4] or 1)
    return t
end

local function Outline(f, c)
    local t = Fill(f, "BORDER", c); t:SetPoint("TOPLEFT"); t:SetPoint("TOPRIGHT"); t:SetHeight(1)
    local b = Fill(f, "BORDER", c); b:SetPoint("BOTTOMLEFT"); b:SetPoint("BOTTOMRIGHT"); b:SetHeight(1)
    local l = Fill(f, "BORDER", c); l:SetPoint("TOPLEFT"); l:SetPoint("BOTTOMLEFT"); l:SetWidth(1)
    local r = Fill(f, "BORDER", c); r:SetPoint("TOPRIGHT"); r:SetPoint("BOTTOMRIGHT"); r:SetWidth(1)
end

local function Label(parent, font, size, justify)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    fs:SetFont(font, size, "")
    fs:SetShadowOffset(0, 0)
    fs:SetJustifyH(justify or "LEFT")
    fs:SetWordWrap(false)
    return fs
end

-- ---------------------------------------------------------------------------
-- Window
-- ---------------------------------------------------------------------------

local frame = CreateFrame("Frame", "SimpleAHFrame", UIParent)
frame:SetSize(WIDTH, SEARCH_H)
frame:SetFrameStrata("DIALOG")
frame:SetClampedToScreen(true)
frame:SetMovable(true)
frame:EnableMouse(true)
frame:RegisterForDrag("LeftButton")
frame:Hide()
tinsert(UISpecialFrames, "SimpleAHFrame") -- ESC closes

Fill(frame, "BACKGROUND", T.surface):SetAllPoints()
Outline(frame, T.hairline)

frame:SetScript("OnDragStart", frame.StartMoving)
frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local p, _, rp, x, y = self:GetPoint()
    db.point = { p, "UIParent", rp, x, y }
end)

-- Search row ------------------------------------------------------------------
local searchRow = CreateFrame("Frame", nil, frame)
searchRow:SetPoint("TOPLEFT")
searchRow:SetPoint("TOPRIGHT")
searchRow:SetHeight(SEARCH_H)

local glyph = searchRow:CreateTexture(nil, "ARTWORK")
glyph:SetSize(14, 14)
glyph:SetPoint("LEFT", PAD, 0)
glyph:SetTexture("Interface\\Common\\UI-Searchbox-Icon")
glyph:SetVertexColor(0.50, 0.54, 0.58)

local linkedIcon = searchRow:CreateTexture(nil, "ARTWORK")
linkedIcon:SetSize(20, 20)
linkedIcon:SetPoint("CENTER", glyph, "CENTER")
linkedIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
linkedIcon:Hide()

-- key hint / rebind button on the right
local keyBtn = CreateFrame("Button", nil, searchRow)
keyBtn:SetHeight(20)
keyBtn:SetPoint("RIGHT", -PAD + 4, 0)
local keyBg = Fill(keyBtn, "BACKGROUND", T.raised)
keyBg:SetAllPoints()
Outline(keyBtn, T.hairline)
keyBtn.text = Label(keyBtn, FONT_UI, 11, "CENTER")
keyBtn.text:SetPoint("CENTER", 0, 0)

local search = CreateFrame("EditBox", "SimpleAHSearchBox", searchRow)
search:SetPoint("LEFT", glyph, "RIGHT", 10, 0)
search:SetPoint("RIGHT", keyBtn, "LEFT", -10, 0)
search:SetHeight(SEARCH_H - 8)
search:SetAutoFocus(false)
search:SetFont(FONT_TEXT, 14, "")
search:SetTextColor(0.90, 0.91, 0.92)
search:SetMaxLetters(80)

local placeholder = Label(searchRow, FONT_TEXT, 14)
placeholder:SetPoint("LEFT", search, "LEFT", 0, 0)
placeholder:SetPoint("RIGHT", search, "RIGHT", 0, 0)
placeholder:SetText(T.faint .. "Search items, or shift-click an item|r")

local focusRule = Fill(searchRow, "OVERLAY", T.accent)
focusRule:SetPoint("BOTTOMLEFT", 1, 0)
focusRule:SetPoint("BOTTOMRIGHT", -1, 0)
focusRule:SetHeight(1)
focusRule:SetAlpha(0)

-- Results ---------------------------------------------------------------------
local body = CreateFrame("Frame", nil, frame)
body:SetPoint("TOPLEFT", searchRow, "BOTTOMLEFT")
body:SetPoint("TOPRIGHT", searchRow, "BOTTOMRIGHT")
body:SetHeight(1)
body:Hide()
local divider = Fill(body, "ARTWORK", T.hairline)
divider:SetPoint("TOPLEFT"); divider:SetPoint("TOPRIGHT"); divider:SetHeight(1)

local INNER = WIDTH - PAD * 2
local COLS = {
    { key = "name",   head = "Item",   w = INNER - 92 * 3 - 52, justify = "LEFT"  },
    { key = "min",    head = "Min",    w = 92, justify = "RIGHT" },
    { key = "market", head = "Market", w = 92, justify = "RIGHT" },
    { key = "avg",    head = "7d avg", w = 92, justify = "RIGHT" },
    { key = "qty",    head = "Qty",    w = 52, justify = "RIGHT" },
}
do
    local x = 0
    for _, col in ipairs(COLS) do col.x = x; x = x + col.w end
end

local sortKey, sortDesc = "relevance", false
local results = {}
local offset = 0
local Refresh -- forward

local header = CreateFrame("Frame", nil, body)
header:SetPoint("TOPLEFT", PAD, -8)
header:SetSize(INNER, HEAD_H)

local headButtons = {}
for _, col in ipairs(COLS) do
    local b = CreateFrame("Button", nil, header)
    b:SetPoint("LEFT", col.x, 0)
    b:SetSize(col.w, HEAD_H)
    b.label = Label(b, FONT_UI, 10, col.justify)
    b.label:SetPoint("LEFT", col.key == "name" and 28 or 0, 0)
    b.label:SetPoint("RIGHT", 0, 0)
    b.col = col
    b:SetScript("OnClick", function(self)
        if sortKey == self.col.key then
            sortDesc = not sortDesc
        else
            sortKey = self.col.key
            sortDesc = self.col.key ~= "name"
        end
        Refresh(true)
    end)
    b:SetScript("OnEnter", function(self) self.hover = true; Refresh() end)
    b:SetScript("OnLeave", function(self) self.hover = false; Refresh() end)
    headButtons[#headButtons + 1] = b
end

local list = CreateFrame("Frame", nil, body)
list:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -2)
list:SetSize(INNER, ROW_H * MAX_ROWS)
list:EnableMouseWheel(true)

local rows = {}
for i = 1, MAX_ROWS do
    local row = CreateFrame("Button", nil, list)
    row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
    row:SetSize(INNER, ROW_H)
    row:RegisterForClicks("AnyUp")
    local hl = Fill(row, "HIGHLIGHT", T.hover)
    hl:SetPoint("TOPLEFT", -6, 0)
    hl:SetPoint("BOTTOMRIGHT", 6, 0)
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(18, 18)
    row.icon:SetPoint("LEFT", 0, 0)
    row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    row.cells = {}
    for _, col in ipairs(COLS) do
        local isName = col.key == "name"
        local fs = Label(row, isName and FONT_TEXT or FONT_UI, isName and 12 or 12, col.justify)
        fs:SetPoint("LEFT", col.x + (isName and 28 or 0), 0)
        fs:SetWidth(col.w - (isName and 34 or 0))
        row.cells[col.key] = fs
    end
    row:SetScript("OnEnter", function(self)
        if not self.id then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetItemByID(self.id)
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row:SetScript("OnClick", function(self)
        if not self.id then return end
        local _, link = GetItemInfo(self.id)
        HandleModifiedItemClick(link or ("item:" .. self.id))
    end)
    rows[i] = row
end

local track = Fill(body, "ARTWORK", { 1, 1, 1, 0.04 })
track:SetPoint("TOPLEFT", list, "TOPRIGHT", 6, 0)
track:SetPoint("BOTTOMLEFT", list, "BOTTOMRIGHT", 6, 0)
track:SetWidth(2)
local thumb = Fill(body, "OVERLAY", { T.accent[1], T.accent[2], T.accent[3], 0.55 })
thumb:SetWidth(2)

local message = Label(body, FONT_UI, 12, "LEFT")
message:SetPoint("TOPLEFT", PAD, -14)
message:SetPoint("RIGHT", -PAD, 0)
message:SetWordWrap(true)

local footLeft = Label(body, FONT_UI, 10, "LEFT")
-- market switch: shows which auction house the prices come from
local marketBtn = CreateFrame("Button", nil, body)
marketBtn:SetSize(240, 16)
marketBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
local footRight = Label(marketBtn, FONT_UI, 10, "RIGHT")
footRight:SetAllPoints()

-- Key capture overlay ---------------------------------------------------------
local capture = CreateFrame("Frame", nil, frame)
capture:SetAllPoints(searchRow)
capture:SetFrameLevel(searchRow:GetFrameLevel() + 10)
Fill(capture, "BACKGROUND", T.surface):SetAllPoints()
capture.text = Label(capture, FONT_UI, 13, "CENTER")
capture.text:SetPoint("CENTER")
capture:EnableMouse(true)
capture:Hide()

-- ---------------------------------------------------------------------------
-- Keybinding
-- ---------------------------------------------------------------------------

local function CurrentKey()
    local k = GetBindingKey and GetBindingKey(BIND_ACTION)
    if not k then return nil end
    return GetBindingText and GetBindingText(k, "KEY_") or k
end

local function UpdateKeyButton()
    local k = CurrentKey()
    keyBtn.text:SetText(k and (T.muted .. k .. "|r") or (T.muted .. "Set key|r"))
    keyBtn:SetWidth(max(56, keyBtn.text:GetStringWidth() + 16))
end

local MODIFIERS = { LSHIFT = true, RSHIFT = true, LCTRL = true, RCTRL = true, LALT = true, RALT = true,
                    LMETA = true, RMETA = true, UNKNOWN = true }

local function Print(msg)
    print(T.accentHex .. "Simple AH|r  " .. msg)
end

local function StopCapture()
    capture:Hide()
    capture:EnableKeyboard(false)
    capture:SetScript("OnKeyDown", nil)
end

local function StartCapture()
    if InCombatLockdown() then
        Print("Key bindings can't be changed in combat.")
        return
    end
    if not frame:IsShown() then frame:Show() end
    search:ClearFocus()
    capture.text:SetText(T.fg .. "Press a key or key combination|r  " .. T.faint .. "Esc cancels, Backspace clears|r")
    capture:Show()
    capture:EnableKeyboard(true)
    if capture.SetPropagateKeyboardInput then capture:SetPropagateKeyboardInput(false) end
    capture:SetScript("OnKeyDown", function(_, key)
        if MODIFIERS[key] then return end
        if key == "ESCAPE" then StopCapture(); return end
        local k1, k2 = GetBindingKey(BIND_ACTION)
        if k1 then SetBinding(k1) end
        if k2 then SetBinding(k2) end
        if key == "BACKSPACE" then
            SaveBindings(GetCurrentBindingSet())
            Print("Key binding cleared.")
        else
            local combo = key
            if IsShiftKeyDown() then combo = "SHIFT-" .. combo end
            if IsControlKeyDown() then combo = "CTRL-" .. combo end
            if IsAltKeyDown() then combo = "ALT-" .. combo end
            if SetBinding(combo, BIND_ACTION) then
                SaveBindings(GetCurrentBindingSet())
                Print("Search opens with " .. (GetBindingText and GetBindingText(combo, "KEY_") or combo) .. ".")
            else
                Print("That key can't be bound.")
            end
        end
        StopCapture()
        UpdateKeyButton()
    end)
end

keyBtn:SetScript("OnClick", StartCapture)
keyBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
    GameTooltip:AddLine("Search key")
    GameTooltip:AddLine("Click to set the key that opens this window.", 0.7, 0.72, 0.75, true)
    GameTooltip:Show()
end)
keyBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

-- ---------------------------------------------------------------------------
-- Search
-- ---------------------------------------------------------------------------

local lastQuery, linkedID = "", nil

local function AddResult(id, score)
    local p = GetPrice(id)
    local ln = lowerNames[id] or ""
    results[#results + 1] = {
        id = id, lname = ln, score = score,
        min = p and p.min or 0, market = p and p.market or 0, avg = p and p.avg or 0, qty = p and p.qty or 0,
    }
end

local function DoSearch()
    wipe(results)
    if linkedID then
        AddResult(linkedID, 0)
        return
    end
    local q = (search:GetText() or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    lastQuery = q
    if q == "" then return end

    local words = {}
    for w in q:gmatch("%S+") do words[#words + 1] = w end
    local qid = tonumber(q)
    if qid and MK.items[qid] then AddResult(qid, 0) end

    for id in pairs(MK.items) do
        local ln = lowerNames[id]
        if ln and id ~= qid then
            local ok = true
            for _, w in ipairs(words) do
                if not ln:find(w, 1, true) then ok = false; break end
            end
            if ok then
                local score = (ln == q and 0) or (ln:sub(1, #q) == q and 1) or 2
                AddResult(id, score)
            end
        end
    end
end

local function SortResults()
    local key, desc = sortKey, sortDesc
    table.sort(results, function(a, b)
        if key == "relevance" then
            if a.score ~= b.score then return a.score < b.score end
            if #a.lname ~= #b.lname then return #a.lname < #b.lname end
            return a.lname < b.lname
        end
        local va, vb = a[key], b[key]
        if key == "name" then va, vb = a.lname, b.lname end
        if va == vb then return a.lname < b.lname end
        if desc then return va > vb end
        return va < vb
    end)
end

local function SetBodyHeight(h)
    if h <= 0 then
        body:Hide()
        frame:SetHeight(SEARCH_H)
    else
        body:SetHeight(h)
        body:Show()
        frame:SetHeight(SEARCH_H + h)
    end
end

Refresh = function(resort)
    if resort then SortResults() end
    local hasData = (MK.count or 0) > 0
    local n = #results
    local querying = linkedID or lastQuery ~= ""

    -- linked item indicator
    if linkedID then
        linkedIcon:SetTexture(ItemIcon(linkedID) or 134400)
        linkedIcon:Show(); glyph:Hide()
    else
        linkedIcon:Hide(); glyph:Show()
    end

    footLeft:ClearAllPoints()
    marketBtn:ClearAllPoints()

    -- states without a list
    if not hasData or n == 0 then
        header:Hide(); list:Hide(); track:Hide(); thumb:Hide()
        local text
        if not hasData then
            text = T.muted .. "No prices yet. Run SimpleAH.exe on your PC, then type /reload.|r"
        elseif querying then
            text = T.muted .. "No items match." ..
                (indexed < total and format(" Item names are still loading (%d%%).", floor(indexed / total * 100)) or "") .. "|r"
        end
        if text then
            message:SetText(text)
            message:Show()
            SetBodyHeight(message:GetStringHeight() + 28)
        else
            message:Hide()
            SetBodyHeight(0)
        end
        return
    end
    message:Hide()

    -- header
    header:Show()
    for _, b in ipairs(headButtons) do
        local active = (sortKey == b.col.key)
        local arrow = active and (sortDesc and "  \226\134\147" or "  \226\134\145") or ""
        local color = active and T.accentHex or (b.hover and T.fg or T.faint)
        b.label:SetText(color .. b.col.head:upper() .. arrow .. "|r")
    end

    -- rows
    local visible = min(n, MAX_ROWS)
    local maxOffset = max(0, n - MAX_ROWS)
    if offset > maxOffset then offset = maxOffset end
    list:Show()
    list:SetHeight(visible * ROW_H)
    for i, row in ipairs(rows) do
        local r = results[offset + i]
        if r and i <= visible then
            row.id = r.id
            local nm = names[r.id]
            row.icon:SetTexture(ItemIcon(r.id) or 134400)
            row.cells.name:SetText(nm and (QualityHex(ItemQuality(r.id)) .. nm .. "|r") or (T.faint .. "item " .. r.id .. "|r"))
            row.cells.min:SetText(Money(r.min))
            row.cells.market:SetText(Money(r.market))
            row.cells.avg:SetText(Money(r.avg))
            row.cells.qty:SetText(T.muted .. Thousands(r.qty) .. "|r")
            row:Show()
        else
            row.id = nil
            row:Hide()
        end
    end

    -- scrollbar
    if n > MAX_ROWS then
        local h = visible * ROW_H
        local th = max(16, h * MAX_ROWS / n)
        thumb:SetHeight(th)
        thumb:ClearAllPoints()
        thumb:SetPoint("TOP", track, "TOP", 0, -(h - th) * offset / maxOffset)
        track:Show(); thumb:Show()
    else
        track:Hide(); thumb:Hide()
    end

    -- footer
    footLeft:SetPoint("TOPLEFT", list, "BOTTOMLEFT", 0, -9)
    marketBtn:SetPoint("TOPRIGHT", list, "BOTTOMRIGHT", 0, -8)
    footLeft:SetText(T.faint .. (n == 1 and "1 item" or (Thousands(n) .. " items")) ..
        (n > MAX_ROWS and "  \194\183  scroll for more" or "") .. "|r")
    if indexed < total then
        footRight:SetText(T.muted .. format("Loading names %d%%", floor(indexed / total * 100)) .. "|r")
    else
        local hover = marketBtn:IsMouseOver()
        footRight:SetText((hover and T.fg or T.muted) .. (MK.label ~= "" and MK.label or "Prices") .. "|r" ..
            T.faint .. "  \194\183  scanned " .. Age(MK.scanned) .. "|r")
    end

    SetBodyHeight(8 + HEAD_H + 2 + visible * ROW_H + FOOT_H)
end

local searchTimer
local function QueueSearch()
    if searchTimer then searchTimer:Cancel() end
    searchTimer = C_Timer.NewTimer(0.12, function()
        offset = 0
        DoSearch()
        Refresh(true)
    end)
end

search:SetScript("OnTextChanged", function(self, userInput)
    if userInput and linkedID then linkedID = nil end
    placeholder:SetShown(self:GetText() == "")
    QueueSearch()
end)
search:SetScript("OnEditFocusGained", function() focusRule:SetAlpha(1) end)
search:SetScript("OnEditFocusLost", function() focusRule:SetAlpha(0) end)
search:SetScript("OnEscapePressed", function(self)
    if self:GetText() ~= "" then
        linkedID = nil
        self:SetText("")
    else
        self:ClearFocus()
        frame:Hide()
    end
end)
search:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

OnMarketChanged = function()
    if frame:IsShown() then
        DoSearch()
        Refresh(true)
    end
end

marketBtn:SetScript("OnClick", function(_, button)
    if button == "RightButton" then
        db.neutral = not db.neutral
    else
        local groups = Groups()
        local nextIndex = 1
        for i, g in ipairs(groups) do
            if g == (MK.group or db.group) then nextIndex = i % #groups + 1 end
        end
        db.group = groups[nextIndex] or db.group
    end
    SelectMarket()
end)
marketBtn:SetScript("OnEnter", function(self)
    Refresh()
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
    GameTooltip:AddLine("Auction house")
    GameTooltip:AddLine("Left-click: next ruleset group", 0.7, 0.72, 0.75)
    GameTooltip:AddLine("Right-click: Blackwater (neutral) on or off", 0.7, 0.72, 0.75)
    GameTooltip:Show()
end)
marketBtn:SetScript("OnLeave", function() GameTooltip:Hide(); Refresh() end)

list:SetScript("OnMouseWheel", function(_, delta)
    offset = max(0, offset - delta * 3)
    Refresh()
end)

-- ---------------------------------------------------------------------------
-- Shift-click linking: an item link sent while the window is open searches
-- for exactly that item.
-- ---------------------------------------------------------------------------

local function ChatIsOpen()
    local active = ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow()
    return active and active:IsShown()
end

local function OnLinkInserted(link)
    if type(link) ~= "string" or not frame:IsShown() then return end
    if not search:HasFocus() and ChatIsOpen() then return end -- the link went to chat
    local id = tonumber(link:match("item:(%d+)"))
    if not id then return end
    linkedID = id
    local name = link:match("%[(.-)%]") or ItemName(id) or ("item " .. id)
    search:SetText(name)
    search:SetCursorPosition(#name)
    placeholder:Hide()
    offset = 0
    DoSearch()
    Refresh(true)
end

if ChatEdit_InsertLink then hooksecurefunc("ChatEdit_InsertLink", OnLinkInserted) end
if ChatFrameUtil and ChatFrameUtil.InsertLink then hooksecurefunc(ChatFrameUtil, "InsertLink", OnLinkInserted) end

-- ---------------------------------------------------------------------------
-- Open / close
-- ---------------------------------------------------------------------------

local ticker
frame:SetScript("OnShow", function()
    UpdateKeyButton()
    Refresh(true)
    if ticker then ticker:Cancel() end
    ticker = C_Timer.NewTicker(2, function()
        if indexed < total and not linkedID and lastQuery ~= "" then
            DoSearch()
            Refresh(true)
        else
            Refresh()
        end
    end)
end)
frame:SetScript("OnHide", function()
    if ticker then ticker:Cancel(); ticker = nil end
    StopCapture()
end)

local function OpenSearch(text)
    frame:Show()
    if text and text ~= "" then
        linkedID = nil
        search:SetText(text)
    else
        search:HighlightText()
    end
    search:SetFocus()
end

function SimpleAH_Toggle()
    if frame:IsShown() then
        frame:Hide()
    else
        OpenSearch()
    end
end

-- ---------------------------------------------------------------------------
-- Tooltip
-- ---------------------------------------------------------------------------

local function AddTooltip(tt, itemID)
    if not db or not db.tooltip or (MK.count or 0) == 0 then return end
    local p = GetPrice(itemID)
    tt:AddLine(" ")
    if p then
        tt:AddDoubleLine("AH market", MoneyFull(p.market), 0.55, 0.6, 0.65, 1, 1, 1)
        tt:AddDoubleLine("AH min buyout", MoneyFull(p.min), 0.55, 0.6, 0.65, 1, 1, 1)
        if p.avg > 0 then
            tt:AddDoubleLine("AH 7-day average", MoneyFull(p.avg), 0.55, 0.6, 0.65, 1, 1, 1)
        end
        tt:AddDoubleLine("AH quantity", format("%s in %d auctions", Thousands(p.qty), p.auctions),
            0.55, 0.6, 0.65, 0.8, 0.82, 0.85)
    else
        tt:AddLine("Not on the auction house", 0.55, 0.6, 0.65)
    end
end

if TooltipDataProcessor and Enum and Enum.TooltipDataType then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tt, data)
        if data and data.id then AddTooltip(tt, data.id) end
    end)
else
    local function hook(tt)
        tt:HookScript("OnTooltipSetItem", function(self)
            local _, link = self:GetItem()
            local id = link and tonumber(link:match("item:(%d+)"))
            if id then AddTooltip(self, id) end
        end)
    end
    hook(GameTooltip)
    if ItemRefTooltip then hook(ItemRefTooltip) end
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("GET_ITEM_INFO_RECEIVED")
pcall(events.RegisterEvent, events, "ITEM_DATA_LOAD_RESULT") -- not every client has it

events:SetScript("OnEvent", function(_, event, a1, a2)
    if event == "ADDON_LOADED" then
        if a1 ~= ADDON then return end
        SimpleAHDB = SimpleAHDB or {}
        db = SimpleAHDB
        for k, v in pairs(defaults) do
            if db[k] == nil then db[k] = v end
        end
        SimpleAHNames = SimpleAHNames or {}
        names = SimpleAHNames
        DATA = SimpleAHData or DATA

        frame:ClearAllPoints()
        local p = db.point
        frame:SetPoint(p[1], UIParent, p[3], p[4], p[5])
        frame:SetScale(db.scale or 1)
    elseif event == "PLAYER_LOGIN" then
        SelectMarket()
    elseif event == "GET_ITEM_INFO_RECEIVED" or event == "ITEM_DATA_LOAD_RESULT" then
        if a1 then ItemLoaded(a1, a2) end
    end
end)

-- ---------------------------------------------------------------------------
-- Slash commands
-- ---------------------------------------------------------------------------

SLASH_SIMPLEAH1 = "/ah"
SLASH_SIMPLEAH2 = "/simpleah"
SlashCmdList.SIMPLEAH = function(msg)
    msg = msg or ""
    local cmd, arg = msg:match("^%s*(%S*)%s*(.-)%s*$")
    local lc = cmd:lower()
    if lc == "stats" then
        if SimpleAH_OpenStats then SimpleAH_OpenStats() end
    elseif lc == "bind" then
        StartCapture()
    elseif lc == "tooltip" then
        db.tooltip = not db.tooltip
        Print("Tooltip prices " .. (db.tooltip and "on." or "off."))
    elseif lc == "scale" and tonumber(arg) then
        db.scale = max(0.5, min(2, tonumber(arg)))
        frame:SetScale(db.scale)
    elseif lc == "reset" then
        db.point = defaults.point
        db.scale = 1
        frame:ClearAllPoints()
        frame:SetPoint("TOP", UIParent, "TOP", 0, -140)
        frame:SetScale(1)
        Print("Window position reset.")
    elseif lc == "info" then
        Print(format("%s items from %s, scanned %s. Item names loaded: %d/%d.",
            Thousands(MK.count or 0), MK.label ~= "" and MK.label or "?", Age(MK.scanned), indexed, total))
    elseif lc == "market" then
        local want = arg:lower()
        if want == "" then
            local labels = {}
            for _, g in ipairs(Groups()) do labels[#labels + 1] = g .. " (" .. GroupLabel(g) .. ")" end
            Print("Showing " .. MK.label .. ". Groups: " .. table.concat(labels, ", ") .. ".")
            Print("Use /ah market <group>, or /ah market blackwater to switch the neutral auction house on or off.")
        elseif want == "blackwater" or want == "neutral" then
            db.neutral = not db.neutral
            SelectMarket()
            Print("Showing " .. MK.label .. ".")
        else
            db.group = want
            SelectMarket()
            Print("Showing " .. MK.label .. ".")
        end
    elseif lc == "help" then
        Print("/ah [text]  open the search, optionally with a query")
        Print("/ah bind  set a key that opens the search")
        Print("/ah stats  open the Stats tab at the auction house (find gear by stats)")
        Print("/ah market [group|blackwater]  choose the auction house")
        Print("/ah tooltip  show or hide prices in item tooltips")
        Print("/ah scale <0.5-2>  window size")
        Print("/ah info  data status")
        Print("/ah reset  reset window position")
    elseif msg == "" and frame:IsShown() then
        frame:Hide()
    else
        OpenSearch(msg)
    end
end
