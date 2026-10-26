-- Craft Upgrades on Blizzard's recipe rows: the hidden mark, one-line titles and
-- alt-click to hide. Blizzard reuses its rows, so both are set on each setup.

local _, ns = ...

local HiddenList, ourNodes, QueueRefresh = ns.HiddenList, ns.ourNodes, ns.QueueRefresh
local OnRecipeEnter = ns.OnRecipeEnter

-- Hidden upgrades (listed while the hide option is off) get Blizzard's "hidden"
-- icon where Blizzard puts its lock on locked recipes.
local marks = {} -- [row] = its mark
local function UpdateMark(row)
    local data = row.GetElementData and row:GetElementData()
    data = data and data:GetData()
    local isHidden = data and data.upgradeItemID and HiddenList(data.upgradeFor)[data.recipeInfo.recipeID] or false
    local mark = marks[row]
    if not mark then
        if not isHidden then return end
        mark = row:CreateTexture(nil, "OVERLAY")
        mark:SetAtlas("transmog-icon-hidden")
        mark:SetSize(14, 12) -- half size, to fit beside a long name
        marks[row] = mark
    end
    if isHidden then
        local lock = row.LockedIcon
        if lock and lock:IsShown() then
            mark:SetPoint("RIGHT", lock, "LEFT", 0, -1)
        else
            mark:SetPoint("RIGHT", 0, -1)
        end
    end
    mark:SetShown(isHidden)
end

-- "Upgrades for <first name> <surname>" can wrap out of Blizzard's header. On
-- one line the game cuts it short with "...", and Blizzard's header shows a
-- cut title whole in a tooltip.
local oneLine = {} -- [header row] = true while its title is kept to one line
local function UpdateTitle(row)
    local data = row.GetElementData and row:GetElementData()
    data = data and data:GetData()
    local info = data and data.categoryInfo
    local title = info and row.ButtonText
    if not title then return end
    local ours = ourNodes[info.categoryID] ~= nil
    if ours ~= (oneLine[row] or false) then
        oneLine[row] = ours or nil
        title:SetWordWrap(not ours)
    end
end

local function OnRowInitialized(_, row)
    UpdateMark(row)
    UpdateTitle(row)
end

-- Hides an upgrade, or shows it again. Blizzard does nothing on an alt-click,
-- and tells its EventRegistry about every click on a recipe.
local function OnRecipeClick(_, button, buttonName)
    local data = button.GetElementData and button:GetElementData()
    data = data and data:GetData()
    if data and data.upgradeItemID and buttonName == "LeftButton"
        and IsAltKeyDown() and not IsShiftKeyDown() and not IsControlKeyDown() then
        local recipeID, hiddenList = data.recipeInfo.recipeID, HiddenList(data.upgradeFor, true)
        hiddenList[recipeID] = not hiddenList[recipeID] or nil
        UpdateMark(button)
        if GameTooltip:IsOwned(button) then
            -- The tooltip goes with the upgrade, or its hint changes.
            if hiddenList[recipeID] and ns.db.hideSelected then GameTooltip:Hide() else OnRecipeEnter(button) end
        end
        QueueRefresh() -- once Blizzard is done with the click
    end
end

ns.OnRowInitialized, ns.OnRecipeClick = OnRowInitialized, OnRecipeClick
