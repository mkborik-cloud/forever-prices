-- Simple AH: craft cost in the profession window.
-- Under the selected recipe it shows what the reagents cost at the auction
-- house (Simple AH market prices), what the crafted item sells for, and the
-- profit after the 5% auction house cut. Hover the line for a breakdown.

local floor, format = math.floor, string.format

local GOLD = "|cffd9b36b"
local MUTED = "|cff8a93a0"

local function Money(c)
    if not c then return MUTED .. "-|r" end
    c = floor(c + 0.5)
    local neg = c < 0
    if neg then c = -c end
    local g, s, cp = floor(c / 10000), floor(c / 100) % 100, c % 100
    local out
    if g > 0 then
        out = format("%d|cffd9b36bg|r %02d|cffaab2bas|r", g, s)
    elseif s > 0 then
        out = format("%d|cffaab2bas|r %02d|cffc0835ac|r", s, cp)
    else
        out = format("%d|cffc0835ac|r", cp)
    end
    return (neg and "-" or "") .. out
end

local function Price(itemID)
    if not (SimpleAH and itemID) then return nil end
    local p = SimpleAH.GetMarket(itemID) or SimpleAH.GetMin(itemID)
    if p and p > 0 then return p end
end

local function ItemName(id)
    local n = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id)
    if not n and GetItemInfo then n = GetItemInfo(id) end
    if not n and C_Item and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(id) end
    return n or ("item " .. id)
end

local function IDFromLink(link)
    return link and tonumber(link:match("item:(%d+)"))
end

-- ---------------------------------------------------------------------------
-- Cost calculation
-- result = { reagents = { {id, name, count, price} }, cost, missing, outputID, made, value }
-- ---------------------------------------------------------------------------

local function Finish(r)
    r.cost, r.missing = 0, 0
    for _, g in ipairs(r.reagents) do
        if g.price then r.cost = r.cost + g.price * g.count else r.missing = r.missing + 1 end
    end
    if r.outputID then
        local v = Price(r.outputID)
        if v then r.value = v * (r.made or 1) end
    end
    return r
end

-- Retail-style professions window (C_TradeSkillUI schematics)
local function FromRecipe(recipeID)
    if not (recipeID and C_TradeSkillUI and C_TradeSkillUI.GetRecipeSchematic) then return nil end
    local ok, sch = pcall(C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
    if not ok or not sch then return nil end
    local r = { reagents = {}, outputID = sch.outputItemID }
    local made = sch.quantityMin or 1
    if sch.quantityMax and sch.quantityMax > made then made = (made + sch.quantityMax) / 2 end
    r.made = made
    local basic = Enum and Enum.CraftingReagentType and Enum.CraftingReagentType.Basic
    for _, slot in ipairs(sch.reagentSlotSchematics or {}) do
        local needed = (slot.required ~= false) and (basic == nil or slot.reagentType == nil or slot.reagentType == basic)
        if needed and slot.reagents and #slot.reagents > 0 and (slot.quantityRequired or 0) > 0 then
            -- several qualities of one reagent: take the cheapest one with a price
            local best, bestPrice = slot.reagents[1].itemID, nil
            for _, opt in ipairs(slot.reagents) do
                local p = Price(opt.itemID)
                if p and (not bestPrice or p < bestPrice) then best, bestPrice = opt.itemID, p end
            end
            if best then
                r.reagents[#r.reagents + 1] = { id = best, name = ItemName(best), count = slot.quantityRequired, price = bestPrice }
            end
        end
    end
    return Finish(r)
end

-- Classic trade skill window (GetTradeSkill* API)
local function FromTradeSkill(index)
    if not (index and GetTradeSkillNumReagents) then return nil end
    local r = { reagents = {} }
    for i = 1, GetTradeSkillNumReagents(index) or 0 do
        local name, _, count = GetTradeSkillReagentInfo(index, i)
        local id = IDFromLink(GetTradeSkillReagentItemLink(index, i))
        if id and count then
            r.reagents[#r.reagents + 1] = { id = id, name = name or ItemName(id), count = count, price = Price(id) }
        end
    end
    r.outputID = IDFromLink(GetTradeSkillItemLink and GetTradeSkillItemLink(index))
    local lo, hi = 1, 1
    if GetTradeSkillNumMade then lo, hi = GetTradeSkillNumMade(index) end
    r.made = ((lo or 1) + (hi or lo or 1)) / 2
    return Finish(r)
end

SimpleAH_CraftCost = FromRecipe -- for /run checks

-- ---------------------------------------------------------------------------
-- Display
-- ---------------------------------------------------------------------------

local function MakeLine(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(300, 30)
    f:SetFrameLevel((parent:GetFrameLevel() or 1) + 5)
    f.top = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.top:SetPoint("TOPLEFT", 0, 0)
    f.top:SetJustifyH("LEFT")
    f.bottom = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.bottom:SetPoint("TOPLEFT", f.top, "BOTTOMLEFT", 0, -3)
    f.bottom:SetJustifyH("LEFT")
    f:EnableMouse(true)
    f:SetScript("OnEnter", function(self)
        local r = self.result
        if not r then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOPLEFT")
        GameTooltip:AddLine("Simple AH  craft cost")
        for _, g in ipairs(r.reagents) do
            GameTooltip:AddDoubleLine(format("%dx %s", g.count, g.name),
                g.price and Money(g.price * g.count) or (MUTED .. "no AH price|r"), 1, 1, 1, 1, 1, 1)
        end
        if r.missing > 0 then
            GameTooltip:AddLine("Reagents without an AH price (often vendor items) are not counted.", 0.6, 0.6, 0.6, true)
        end
        if r.value then
            GameTooltip:AddLine(" ")
            GameTooltip:AddDoubleLine("AH value" .. (r.made ~= 1 and format(" (%gx)", r.made) or ""), Money(r.value), 1, 1, 1, 1, 1, 1)
            GameTooltip:AddDoubleLine("After 5% AH cut", Money(r.value * 0.95), 1, 1, 1, 1, 1, 1)
        end
        GameTooltip:Show()
    end)
    f:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return f
end

local function Show(line, r)
    line.result = r
    if not r or #r.reagents == 0 then line:Hide(); return end
    local cost = GOLD .. "Craft cost|r  " .. Money(r.cost)
    if r.missing > 0 then cost = cost .. MUTED .. format("  (+%d without AH price)|r", r.missing) end
    line.top:SetText(cost)
    if r.value then
        local profit = r.value * 0.95 - r.cost
        local color = profit >= 0 and "|cff4ade80+" or "|cfff87171"
        line.bottom:SetText(GOLD .. "AH value|r  " .. Money(r.value) .. "    " .. GOLD .. "Profit|r  " .. color .. Money(profit) .. "|r")
    elseif r.outputID then
        line.bottom:SetText(GOLD .. "AH value|r  " .. MUTED .. "no AH price|r")
    else
        line.bottom:SetText("")
    end
    line:Show()
end

-- retail professions window
local retailLine
local function RecipeIDOf(form, info)
    info = info or (form.GetRecipeInfo and form:GetRecipeInfo()) or form.currentRecipeInfo
    return info and info.recipeID
end

local function UpdateRetail(form, info)
    if not retailLine then return end
    Show(retailLine, FromRecipe(RecipeIDOf(form, info)))
end

local function HookRetail()
    local form = ProfessionsFrame and ProfessionsFrame.CraftingPage and ProfessionsFrame.CraftingPage.SchematicForm
    if not form or retailLine then return end
    retailLine = MakeLine(form)
    retailLine:SetPoint("BOTTOMLEFT", form, "BOTTOMLEFT", 22, 12)
    if form.Init then hooksecurefunc(form, "Init", UpdateRetail) end
    form:HookScript("OnShow", function(self) UpdateRetail(self) end)
end

-- classic trade skill window
local classicLine
local function UpdateClassic()
    if not classicLine or not GetTradeSkillSelectionIndex then return end
    Show(classicLine, FromTradeSkill(GetTradeSkillSelectionIndex()))
end

local function HookClassic()
    if classicLine or not TradeSkillFrame or not TradeSkillFrame_SetSelection then return end
    classicLine = MakeLine(TradeSkillFrame)
    classicLine:SetPoint("BOTTOMLEFT", TradeSkillFrame, "BOTTOMLEFT", 22, 100)
    hooksecurefunc("TradeSkillFrame_SetSelection", UpdateClassic)
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("TRADE_SKILL_SHOW")
events:SetScript("OnEvent", function(_, event)
    HookRetail()
    HookClassic()
    if event ~= "ADDON_LOADED" then
        local form = ProfessionsFrame and ProfessionsFrame.CraftingPage and ProfessionsFrame.CraftingPage.SchematicForm
        if form and form:IsShown() then UpdateRetail(form) end
        if TradeSkillFrame and TradeSkillFrame:IsShown() then UpdateClassic() end
    end
end)
