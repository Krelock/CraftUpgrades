-- Craft Upgrades' options, in the crafting page's Filter menu for professions
-- that make gear: three checkboxes, Stat Weights (a submenu like Blizzard's
-- Slots) and Upgrades for Friends. Also hides the Filter button's false reset X.

local _, ns = ...

local ipairs = ipairs

local UNLEARNED_OPTION = "Show Unlearned Upgrades"
local HIDE_OPTION = "Hide Selected Upgrades"
local ALTS_OPTION = "Show Upgrades for Alts"
local STAT_WEIGHTS_OPTION = "Stat Weights (Beta)"
local ITEM_LEVEL_CHOICE = "Item Level"
local AUTOMATIC_CHOICE = "Automatic (%s)" -- the spec's role, or Item Level without a spec
local PLAYERS_OPTION = "Upgrades for Friends (Beta)"
local ADD_TARGET = "Add Target" -- grayed out while the target can't be added
local ADD_TARGET_NAMED = "Add Target: %s"
local UPDATE_TARGET_NAMED = "Update Target: %s" -- already added: reads their gear again
local REMOVE_PLAYER = "Remove"
local FRIENDS_OPTION = "Show Upgrades for Friends"
local TARGET_OPTION = "Show Upgrades for Target"
local ITEM_LEVEL = "itemLevel" -- saved for Item Level (nothing saved: Automatic)

local ROLES, NOTHING, me, alts = ns.ROLES, ns.NOTHING, ns.me, ns.alts
local Refresh, FindRole, MakesGear = ns.Refresh, ns.FindRole, ns.MakesGear
local FullName, PlayerKey, OtherName = ns.FullName, ns.PlayerKey, ns.OtherName
local Alts, Character = ns.Alts, ns.Character
local AddableTarget, AddTarget, IsShowing = ns.AddableTarget, ns.AddTarget, ns.IsShowing
local ToggleShowing, RemovePlayer = ns.ToggleShowing, ns.RemovePlayer

local function IsShowingUnlearned()
    return ns.db.showUnlearned
end

local function ToggleUnlearned()
    ns.db.showUnlearned = not ns.db.showUnlearned
    Refresh()
end

local function IsHidingSelected()
    return ns.db.hideSelected
end

local function ToggleHideSelected()
    ns.db.hideSelected = not ns.db.hideSelected
    Refresh()
end

local function IsShowingAlts()
    return ns.db.showAlts
end

local function ToggleAlts()
    ns.db.showAlts = not ns.db.showAlts
    Refresh()
end

-- A choice is { character, role key or ITEM_LEVEL (nil: Automatic) }.
local function IsChosen(choice)
    return ns.db.statWeights[choice[1]] == choice[2]
end

local function Choose(choice)
    ns.db.statWeights[choice[1]] = choice[2]
    Refresh()
end

-- Automatic, Item Level, then the class's roles.
local function AddRoleChoices(description, key, who)
    local spec = FindRole(who.class, who.spec)
    description:CreateRadio(AUTOMATIC_CHOICE:format(spec and spec.name or ITEM_LEVEL_CHOICE), IsChosen, Choose, { key })
    description:CreateRadio(ITEM_LEVEL_CHOICE, IsChosen, Choose, { key, ITEM_LEVEL })
    for _, role in ipairs(ROLES[who.class] or NOTHING) do
        description:CreateRadio(role.name, IsChosen, Choose, { key, role.key })
    end
end

-- Blizzard shows the red reset X after any click in the menu while its filters
-- aren't the defaults. Forever's default for "show unlearned" is off, but
-- Professions.IsUsingDefaultFilters wants it on, so the X shows with nothing
-- filtered. It's hidden when that's the only difference; a real filter keeps it.
local function HideFalseReset(dropdown)
    local resetButton = dropdown.ResetButton
    if resetButton and resetButton:IsShown()
        and Professions.GetDefaultShowUnlearned and not Professions.GetDefaultShowUnlearned()
        and C_TradeSkillUI.GetShowLearned()
        and not C_TradeSkillUI.GetOnlyShowMakeableRecipes() and not C_TradeSkillUI.GetOnlyShowSkillUpRecipes()
        and not C_TradeSkillUI.GetOnlyShowFirstCraftRecipes() and not C_TradeSkillUI.AreAnyInventorySlotsFiltered()
        and not C_TradeSkillUI.AnyRecipeCategoriesFiltered() and Professions.AreAllSourcesUnfiltered() then
        resetButton:Hide()
    end
end

-- Add Target, the two checkboxes, then a submenu with Remove for each player
-- added (also while their categories are off).
local function AddPlayerChoices(description)
    local target = AddableTarget()
    local name = target and OtherName("target")
    if name then
        description:CreateButton((ns.characters[target] and UPDATE_TARGET_NAMED or ADD_TARGET_NAMED):format(name), AddTarget)
    else
        description:CreateButton(ADD_TARGET):SetEnabled(false)
    end
    description:CreateCheckbox(FRIENDS_OPTION, IsShowing, ToggleShowing, "showFriends")
    description:CreateCheckbox(TARGET_OPTION, IsShowing, ToggleShowing, "showTarget")
    local divided = false
    for _, key in ipairs(Alts(true)) do
        local who = ns.characters[key] -- not a target written down for now
        if who and who.other then
            if not divided then
                divided = true
                description:CreateDivider()
            end
            description:CreateButton(who.name):CreateButton(REMOVE_PLAYER, RemovePlayer, key)
        end
    end
end

-- Stat Weights has your choices, then a submenu for each other character.
local function AddFilterOption(owner, rootDescription)
    local professionInfo = ns.page.professionInfo
    if owner == ns.recipeList.FilterDropdown and professionInfo and MakesGear(professionInfo.professionID) then
        rootDescription:CreateDivider()
        rootDescription:CreateCheckbox(UNLEARNED_OPTION, IsShowingUnlearned, ToggleUnlearned)
        rootDescription:CreateCheckbox(HIDE_OPTION, IsHidingSelected, ToggleHideSelected)
        rootDescription:CreateCheckbox(ALTS_OPTION, IsShowingAlts, ToggleAlts)
        local weights = rootDescription:CreateButton(STAT_WEIGHTS_OPTION)
        weights:CreateTitle(FullName())
        AddRoleChoices(weights, PlayerKey(), me)
        if #Alts() > 0 then
            weights:CreateDivider()
            for _, key in ipairs(alts) do
                local who = Character(key)
                AddRoleChoices(weights:CreateButton(who.name), key, who)
            end
        end
        AddPlayerChoices(rootDescription:CreateButton(PLAYERS_OPTION))
    end
end

ns.AddFilterOption, ns.HideFalseReset = AddFilterOption, HideFalseReset
