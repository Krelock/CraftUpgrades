-- Craft Upgrades' tooltips: the item an upgrade makes, its score and the alt-click
-- hint. On another character's upgrade, what that character wears replaces
-- Blizzard's comparison (your gear), and lines red for you are white for them.
--
-- Sections: Lines, Comparison tooltips, Hovering an upgrade.

local ADDON_NAME, ns = ...

local GetItemInfo = C_Item.GetItemInfo
local GetItemInfoInstant = C_Item.GetItemInfoInstant
local ipairs = ipairs

local SCORE_LINE = "%s: %.1f (worn: %.1f)" -- role, score, and what it replaces
local HIDE_HINT = "<Alt Left Click to Hide>"
local SHOW_HINT = "<Alt Left Click to Show>"

local SLOTS, RANGED, me, missing = ns.SLOTS, ns.RANGED, ns.me, ns.missing
local PlayerKey, Character, RoleFor = ns.PlayerKey, ns.Character, ns.RoleFor
local Score, ItemStats, ReplacedScore = ns.Score, ns.ItemStats, ns.ReplacedScore
local WeaponByLevel, TypeSkills = ns.WeaponByLevel, ns.TypeSkills
local LoadItem, HiddenList = ns.LoadItem, ns.HiddenList

---------------------------------------------------------------------------
-- Lines
---------------------------------------------------------------------------

-- Not on weapons that go by item level.
local function AddScoreLine(data)
    local key = data.upgradeFor or PlayerKey()
    local who = data.upgradeFor and Character(data.upgradeFor) or me
    local role = who and RoleFor(key, who)
    local _, _, _, equipLoc, _, classID = GetItemInfoInstant(data.upgradeItemID)
    local link = role and not WeaponByLevel(role, classID, equipLoc) and select(2, GetItemInfo(data.upgradeItemID))
    if link then
        GameTooltip:AddLine(SCORE_LINE:format(role.name, Score(role, ItemStats(link), RANGED[equipLoc]),
            (ReplacedScore(who, role, equipLoc))))
    end
end

-- The game draws the slot and type line and the level line red for the character
-- you're on. White is how it would draw them for the other (the type only when
-- they can use it).
local function WhitenTooltip(tooltip, item, typeUsable)
    local equipLoc = select(4, GetItemInfoInstant(item))
    local minLevel = select(5, GetItemInfo(item))
    local slotText = typeUsable and _G[equipLoc]
    local levelText = minLevel and ITEM_MIN_LEVEL:format(minLevel)
    local r, g, b = HIGHLIGHT_FONT_COLOR:GetRGB()
    for i = 1, tooltip:NumLines() do
        local left = tooltip:GetLeftLine(i)
        local text = left:GetText()
        if text == slotText then
            left:SetTextColor(r, g, b)
            tooltip:GetRightLine(i):SetTextColor(r, g, b)
        elseif text == levelText then
            left:SetTextColor(r, g, b)
        end
    end
end

---------------------------------------------------------------------------
-- Comparison tooltips
---------------------------------------------------------------------------
-- Made like Blizzard's, labeled with the character's name, and only when first
-- needed.

local COMPARE_HEADER_PADDING = 30 -- Blizzard's
local compareTooltips = {}
local compareWaiting -- an item the hovered upgrade's character wears is loading

local function CompareTooltip(i)
    local tooltip = compareTooltips[i]
    if not tooltip then
        -- No parent until it's made: the gamepad UI's CreateFrame hook looks at it.
        tooltip = CreateFrame("GameTooltip", ADDON_NAME .. "CompareTooltip" .. i, nil, "ShoppingTooltipTemplate")
        tooltip:SetParent(UIParent)
        tooltip:SetFrameStrata("TOOLTIP")
        tooltip:SetClampedToScreen(true)
        compareTooltips[i] = tooltip
    end
    return tooltip
end

-- Like Blizzard's: the label, the item, and the game's list of what would
-- change (for a two-hander against both hands, on the first one only).
local function FillCompareTooltip(i, name, link, crafted, paired, deltaHeader)
    local tooltip = CompareTooltip(i)
    tooltip:SetOwner(GameTooltip, "ANCHOR_NONE")
    tooltip:SetHyperlink(link)
    WhitenTooltip(tooltip, link, true)
    local header = tooltip.CompareHeader
    header.Label:SetText(name)
    header:SetWidth(header.Label:GetWidth() + COMPARE_HEADER_PADDING)
    header:Show()
    local delta = deltaHeader and C_TooltipComparison.GetItemComparisonDelta({ hyperlink = crafted }, { hyperlink = link },
        paired and { hyperlink = paired })
    if delta and #delta > 0 then
        GameTooltip_AddBlankLineToTooltip(tooltip)
        GameTooltip_AddNormalLine(tooltip, deltaHeader)
        for _, line in ipairs(delta) do GameTooltip_AddHighlightLine(tooltip, line) end
    end
    tooltip:Show()
end

-- Beside the item's tooltip like Blizzard's: on the right unless only the left
-- has room (on the right, the first one is the farther one).
local function AnchorCompareTooltips(count)
    local first, second = compareTooltips[1], count > 1 and compareTooltips[2]
    local width = first:GetWidth() + (second and second:GetWidth() or 0)
    local left, right = GameTooltip:GetLeft() or 0, GameTooltip:GetRight() or 0
    local room = GetScreenWidth() - right
    first:ClearAllPoints()
    if second then second:ClearAllPoints() end
    if width > room and left > room then
        first:SetPoint("TOPRIGHT", GameTooltip, "TOPLEFT")
        if second then second:SetPoint("TOPRIGHT", first, "TOPLEFT") end
    elseif second then
        second:SetPoint("TOPLEFT", GameTooltip, "TOPRIGHT")
        first:SetPoint("TOPLEFT", second, "TOPRIGHT")
    else
        first:SetPoint("TOPLEFT", GameTooltip, "TOPRIGHT")
    end
end

local BOTH_HANDS = { INVSLOT_MAINHAND, INVSLOT_OFFHAND }
local function HideCompareTooltips()
    for _, tooltip in ipairs(compareTooltips) do tooltip:Hide() end
end

-- What the character wears where the upgrade would go, when Blizzard would
-- compare (Always Compare Items, or Shift). Worn items still loading are asked
-- for, and drawn once they're in.
local function ShowAltComparison(data)
    HideCompareTooltips()
    local who = data.upgradeFor and Character(data.upgradeFor)
    local links = who and who.links
    local crafted = links and select(2, GetItemInfo(data.upgradeItemID))
    if not (crafted and TooltipUtil.ShouldDoItemComparison(GameTooltip)) then return end
    local equipLoc = select(4, GetItemInfoInstant(data.upgradeItemID))
    local worn, waiting = {}, false
    for _, slot in ipairs(equipLoc == "INVTYPE_2HWEAPON" and BOTH_HANDS or SLOTS[equipLoc]) do
        local link = links[slot]
        local itemID = link and (slot ~= INVSLOT_OFFHAND or equipLoc ~= "INVTYPE_WEAPON" or who.dualWield)
            and GetItemInfoInstant(link)
        if itemID and not missing[itemID] then
            if not C_Item.IsItemDataCachedByID(link) then
                waiting = true
                LoadItem(itemID)
            end
            worn[#worn + 1] = link
        end
    end
    if waiting then
        compareWaiting = true
        return
    end
    if equipLoc == "INVTYPE_2HWEAPON" and #worn > 1 then
        FillCompareTooltip(1, who.name, worn[1], crafted, worn[2], ITEM_DELTA_MULTIPLE_COMPARISON_DESCRIPTION)
        FillCompareTooltip(2, who.name, worn[2])
    else
        for i, link in ipairs(worn) do FillCompareTooltip(i, who.name, link, crafted, nil, ITEM_DELTA_DESCRIPTION) end
    end
    if #worn > 0 then AnchorCompareTooltips(#worn) end
end

---------------------------------------------------------------------------
-- Hovering an upgrade
---------------------------------------------------------------------------

-- The hint is green like Blizzard's "<Shift Right Click to Socket>".
local altTooltipRow -- the row while GameTooltip shows another character's upgrade
local function OnRecipeEnter(button)
    local data = button.GetElementData and button:GetElementData()
    data = data and data:GetData()
    local itemID = data and data.upgradeItemID
    altTooltipRow = nil
    if itemID then
        GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
        altTooltipRow = data.upgradeFor and button or nil -- after SetOwner, which may hide the tooltip
        GameTooltip:SetItemByID(itemID)
        AddScoreLine(data)
        GameTooltip_AddInstructionLine(GameTooltip, HiddenList(data.upgradeFor)[data.recipeInfo.recipeID] and SHOW_HINT or HIDE_HINT)
        GameTooltip:Show()
        ShowAltComparison(data)
    end
end

-- Blizzard compares before GameTooltip is shown, so its comparison (your gear)
-- is hidden both when it's filled and when it's shown. Hiding only runs
-- Blizzard's OnHide, which clears their padding.
local function HideAltComparison()
    if altTooltipRow then
        for _, tooltip in ipairs(GameTooltip.shoppingTooltips) do tooltip:Hide() end
    end
end

-- An item post-call runs each time the game fills GameTooltip, also when it
-- builds it again as item data comes in (TOOLTIP_DATA_UPDATE), which would
-- leave the lines red.
local function OnItemTooltip(tooltip)
    if tooltip ~= GameTooltip or not altTooltipRow or GameTooltip:GetOwner() ~= altTooltipRow then return end
    local data = altTooltipRow:GetElementData():GetData()
    local who = Character(data.upgradeFor)
    if who then
        local _, _, _, _, _, classID, subclassID = GetItemInfoInstant(data.upgradeItemID)
        local skills = TypeSkills(who, classID, subclassID)
        WhitenTooltip(GameTooltip, data.upgradeItemID, skills and skills[subclassID])
    end
end

-- The game doesn't hide tooltips owned by GameTooltip with it.
local function OnTooltipHide()
    altTooltipRow = nil
    HideCompareTooltips()
end

-- An item came in: a comparison that waited for one is drawn now.
local function RedrawComparison()
    if compareWaiting then
        compareWaiting = false
        if altTooltipRow and GameTooltip:IsOwned(altTooltipRow) then OnRecipeEnter(altTooltipRow) end
    end
end

ns.OnRecipeEnter, ns.HideAltComparison, ns.OnItemTooltip = OnRecipeEnter, HideAltComparison, OnItemTooltip
ns.OnTooltipHide, ns.RedrawComparison = OnTooltipHide, RedrawComparison
