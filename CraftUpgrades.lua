-- Craft Upgrades: an "Upgrades" category at the top of the crafting window's
-- recipe list, with the recipes that make gear better than what you wear. Your
-- other characters and the players you add get a category each too.
--
-- The categories are real categories of Blizzard's own list, put back in each
-- time Blizzard builds it, so Blizzard draws, scrolls and clicks them.
--
-- Files, in load order (they share functions through the addon table `ns`):
--   Data.lua           slots, armor, skills, roles and stat weights
--   CraftUpgrades.lua  finding upgrades, the categories, loading and events
--   Players.lua        other players' gear, read by inspecting them (Beta)
--   Tooltips.lua       an upgrade's tooltip and its comparison tooltips
--   Rows.lua           the hidden mark, one-line titles, alt-click to hide
--   FilterMenu.lua     the options in the Filter menu
--
-- Sections: Item data, Characters, Comparing gear, Recipes, Categories, Loading.

local ADDON_NAME, ns = ...

local C_TradeSkillUI = C_TradeSkillUI
local GetItemInfo = C_Item.GetItemInfo
local GetItemInfoInstant = C_Item.GetItemInfoInstant
local GetDetailedItemLevelInfo = C_Item.GetDetailedItemLevelInfo
local GetItemStats = C_Item.GetItemStats
local GetInventoryItemLink = GetInventoryItemLink
local ipairs, pairs, next, wipe = ipairs, pairs, next, wipe
local max, sort = math.max, table.sort

local CATEGORY_NAME = "Upgrades"
local ALT_CATEGORY_NAME = "Upgrades for %s"
local LOAD_BATCH = 0.25 -- seconds to wait for more item data before updating
local GEAR_TRIES = 30 -- seconds after a loading screen to wait for your gear

local defaults = {
    showUnlearned = false, -- also list recipes you haven't learned
    hideSelected = true, -- leave out the upgrades you alt-clicked
    showAlts = true, -- a category for each of your other characters
    showFriends = true, -- one for each player you added
    showTarget = true, -- one for your target while the crafting window is open
}

local SLOTS, CLASS_ARMOR, ARMOR_TYPES = ns.SLOTS, ns.CLASS_ARMOR, ns.ARMOR_TYPES
local WEAPON_SKILLS, ARMOR_SKILLS, SPEC_ROLES = ns.WEAPON_SKILLS, ns.ARMOR_SKILLS, ns.SPEC_ROLES
local NO_CASTER_GEAR, NO_MELEE_GEAR, ROLES, RANGED = ns.NO_CASTER_GEAR, ns.NO_MELEE_GEAR, ns.ROLES, ns.RANGED
local CLASS_WEAPONS, CLASS_SHIELDS = ns.CLASS_WEAPONS, ns.CLASS_SHIELDS

local db
local hidden -- [recipeID] = true for what you alt-clicked (per character)
local hiddenForAlts -- [character] = { [recipeID] = true }, the same for the others' categories
local characters -- ["Full Name-Realm"] = what that character wears (account-wide)
local events = CreateFrame("Frame")
local NOTHING = {}

-- Blizzard's crafting page, its recipe list and the list's scroll box.
local page, recipeList, blizzardList
local collapsed = {} -- [categoryID] = true while collapsed (until logout, like Blizzard's)
local dirty -- something changed while the list was hidden

local craftedGear = {} -- [recipeID] = the gear it makes, or false
local wearable = {} -- [itemID] = whether you would wear it
local statsByLink = {} -- [item link] = its stats
local weightsByRole = {} -- [role] = { [stat] = weight }
local missing = {} -- [itemID] = true for items that don't exist
local makesGear = {} -- [professionID] = whether any of its recipes makes gear
local loading = {} -- [itemID] = true while its data is on its way
local askedGear = {} -- [itemID] = true once a worn item's data was asked for
local gearLoading -- worn items are loading: you're written down again when they're in

---------------------------------------------------------------------------
-- Item data
---------------------------------------------------------------------------

-- Asked for once while on its way, like Blizzard's own item loader;
-- ITEM_DATA_LOAD_RESULT says when it's in.
local function LoadItem(itemID)
    if loading[itemID] then return end
    loading[itemID] = true
    events:RegisterEvent("ITEM_DATA_LOAD_RESULT")
    C_Item.RequestLoadItemDataByID(itemID)
end

-- Kept once the item's data is in.
local function ItemStats(link)
    local stats = statsByLink[link]
    if not stats then
        stats = GetItemStats(link)
        if not stats and not C_Item.IsItemDataCachedByID(link) then return NOTHING end
        stats = stats or {}
        statsByLink[link] = stats
    end
    return stats
end

-- { link, minLevel, bindType, itemLevel }, read once (nil while loading).
local itemInfo = {}
local function ItemInfo(itemID)
    local info = itemInfo[itemID]
    if not info then
        local name, link, _, _, minLevel, _, _, _, _, _, _, _, _, bindType = GetItemInfo(itemID)
        if not name then
            LoadItem(itemID)
            return nil
        end
        info = { link = link, minLevel = minLevel or 0, bindType = bindType, itemLevel = GetDetailedItemLevelInfo(itemID) or 0 }
        itemInfo[itemID] = info
    end
    return info
end

---------------------------------------------------------------------------
-- Characters
---------------------------------------------------------------------------
-- A character's record: name, realm, faction, class, spec, level, dualWield,
-- twoHand, gear = { [slot] = item level, 0 when empty }, stats and links by
-- slot, and weapons and armor = { [subclassID] = true }, nil when the game
-- listed none of those skills.

local me = { gear = {}, stats = {}, links = {} } -- you, read again on each update
local newLevel -- PLAYER_LEVEL_UP fires before UnitLevel changes

-- The talent tree with the most points (nil before any, or on a tie).
local function ByOrder(a, b) return a.orderIndex < b.orderIndex end
local function SpecRole(class)
    local configID = C_SpecializationInfo.GetCombatConfigIDForSpecGroup(C_SpecializationInfo.GetActiveSpecGroup())
    local config = configID and C_Traits.GetConfigInfo(configID)
    local treeID = config and config.treeIDs and config.treeIDs[1]
    if not treeID then return nil end
    local trees, groupIDs, spent = C_Traits.GetGroupDisplayInfoByTreeID(treeID), {}, {}
    sort(trees, ByOrder)
    for i, tree in ipairs(trees) do groupIDs[i] = tree.groupID end
    for _, group in ipairs(C_Traits.GetGroupCurrencyInfo(configID, groupIDs)) do
        local currency = group.currencyInfos[1]
        spent[group.traitNodeGroupID] = currency and currency.spent or 0
    end
    local best, most, tie = nil, 0, false
    for i, tree in ipairs(trees) do
        local points = spent[tree.groupID] or 0
        if points > most then
            best, most, tie = i, points, false
        elseif points == most and points > 0 then
            tie = true
        end
    end
    return not tie and best and SPEC_ROLES[class] and SPEC_ROLES[class][best] or nil
end

-- Returns how many items you wear, and asks for those not loaded yet.
local function ReadCharacter(who)
    who.class = select(2, UnitClass("player"))
    who.spec = SpecRole(who.class)
    who.level = max(UnitLevel("player"), newLevel or 0)
    who.dualWield = CanDualWield()
    local gear, stats, worn = who.gear, who.stats, 0
    for slot = INVSLOT_HEAD, INVSLOT_RANGED do
        local link = GetInventoryItemLink("player", slot)
        if link then
            worn = worn + 1
            local itemID = not C_Item.IsItemDataCachedByID(link) and GetItemInfoInstant(link)
            if itemID and not askedGear[itemID] then
                askedGear[itemID] = true
                gearLoading = true
                LoadItem(itemID)
            end
        end
        gear[slot] = link and GetDetailedItemLevelInfo(link) or 0
        stats[slot] = link and ItemStats(link) or nil
        who.links[slot] = link
    end
    -- A two-hander fills the off hand too.
    local mainHand = GetInventoryItemLink("player", INVSLOT_MAINHAND)
    who.twoHand = mainHand ~= nil and select(4, GetItemInfoInstant(mainHand)) == "INVTYPE_2HWEAPON"
    if who.twoHand then
        gear[INVSLOT_OFFHAND] = gear[INVSLOT_MAINHAND]
        stats[INVSLOT_OFFHAND] = stats[INVSLOT_MAINHAND]
    end
    return worn
end

-- Forever's UnitName gives a first name and a surname, joined the way
-- Blizzard shows them.
local function FullName()
    local name, surname = UnitName("player")
    if surname and surname ~= "" then
        return name .. Constants.CharacterNameSeparatorConsts.CHARACTERNAME_SURNAME_SEPARATOR .. surname
    end
    return name
end

-- Characters can share a first name, so the key has the full one.
local function PlayerKey()
    return FullName() .. "-" .. GetRealmName()
end

-- nil when the game keeps the name secret.
local function OtherName(unit)
    local name, surname = UnitName(unit)
    if issecretvalue(name) or issecretvalue(surname) or not name then return nil end
    if surname and surname ~= "" then
        return name .. Constants.CharacterNameSeparatorConsts.CHARACTERNAME_SURNAME_SEPARATOR .. surname
    end
    return name
end

-- A player's key, made like yours (nil for anything else).
local function OtherKey(unit)
    local name = UnitIsPlayer(unit) and OtherName(unit)
    return name and name .. "-" .. GetRealmName() or nil
end

-- The types you have the skill for (nil if the game lists none of them).
local function KnownTypes(skills)
    local known
    for subclassID, skillID in pairs(skills) do
        if C_SkillInfo.GetSkillLineInfoByID(skillID) then
            known = known or {}
            known[subclassID] = true
        end
    end
    return known
end

-- Right after login the game hasn't sent your gear (nothing in any slot): the
-- last record stays, and it returns false. Wearing nothing counts once your
-- gear came this session and something was taken off (changed).
local gearCame
local function RecordCharacter(changed)
    if not characters then return true end
    local record = { name = FullName(), realm = GetRealmName(), faction = UnitFactionGroup("player"),
        gear = {}, stats = {}, links = {}, weapons = KnownTypes(WEAPON_SKILLS), armor = KnownTypes(ARMOR_SKILLS) }
    if ReadCharacter(record) == 0 and not (changed and gearCame) then return false end
    gearCame = true
    characters[PlayerKey()] = record
    return true
end

-- Many gear changes at once (putting on a set) are written down once, next frame.
local recordQueued
local function RecordQueued()
    recordQueued = false
    RecordCharacter(true)
end

-- After a loading screen: tried every second until your gear comes.
local gearTries = 0
local function RecordAfterLoading()
    if RecordCharacter() or gearTries >= GEAR_TRIES then
        gearTries = 0
    else
        gearTries = gearTries + 1
        C_Timer.After(1, RecordAfterLoading)
    end
end

---------------------------------------------------------------------------
-- Comparing gear
---------------------------------------------------------------------------

-- The item level a new piece would replace: the weaker ring or trinket, both
-- hands for a two-hander.
local function ReplacedLevel(who, equipLoc)
    local gear = who.gear
    if equipLoc == "INVTYPE_2HWEAPON" then
        return max(gear[INVSLOT_MAINHAND], gear[INVSLOT_OFFHAND])
    end
    local lowest
    for _, slot in ipairs(SLOTS[equipLoc]) do
        if slot ~= INVSLOT_OFFHAND or equipLoc ~= "INVTYPE_WEAPON" or who.dualWield then
            if not lowest or gear[slot] < lowest then lowest = gear[slot] end
        end
    end
    return lowest
end

-- The tooltip's red: something you can't use.
local function IsRed(color)
    return color ~= nil and color.r > 0.9 and color.g < 0.2 and color.b < 0.2
end

-- Whether all of the item's main stats are ones the class doesn't use.
local function WrongStats(class, link)
    local noCaster, noMelee = NO_CASTER_GEAR[class], NO_MELEE_GEAR[class]
    if not (noCaster or noMelee) then return false end
    local stats = ItemStats(link)
    local melee = (stats.ITEM_MOD_STRENGTH_SHORT or stats.ITEM_MOD_AGILITY_SHORT) ~= nil
    local caster = (stats.ITEM_MOD_INTELLECT_SHORT or stats.ITEM_MOD_SPIRIT_SHORT) ~= nil
    if noCaster then return caster and not melee end
    return melee and not caster
end

local function FindRole(class, roleKey)
    for _, role in ipairs(ROLES[class] or NOTHING) do
        if role.key == roleKey then return role end
    end
end

-- The role picked in the Filter menu, or the spec's (nil: item level).
local function RoleFor(key, who)
    local chosen = db.statWeights[key]
    if chosen == nil then chosen = who.spec end
    return FindRole(who.class, chosen)
end

local function Weights(role)
    local weights = weightsByRole[role]
    if not weights then
        weights = {
            ITEM_MOD_HIT_RATING_SHORT = role.Hit,
            ITEM_MOD_HIT_MELEE_RATING_SHORT = role.melee and role.Hit,
            ITEM_MOD_HIT_RANGED_RATING_SHORT = role.ranged and role.Hit,
            ITEM_MOD_HIT_SPELL_RATING_SHORT = role.spell and role.Hit,
            ITEM_MOD_CRIT_RATING_SHORT = role.Crit,
            ITEM_MOD_CRIT_MELEE_RATING_SHORT = role.melee and role.Crit,
            ITEM_MOD_CRIT_RANGED_RATING_SHORT = role.ranged and role.Crit,
            ITEM_MOD_CRIT_SPELL_RATING_SHORT = role.spell and role.Crit,
            ITEM_MOD_HASTE_RATING_SHORT = role.Haste,
            ITEM_MOD_EXPERTISE_RATING_SHORT = role.Exp,
            ITEM_MOD_STRENGTH_SHORT = role.Str,
            ITEM_MOD_AGILITY_SHORT = role.Agi,
            ITEM_MOD_STAMINA_SHORT = role.Sta,
            ITEM_MOD_INTELLECT_SHORT = role.Int,
            ITEM_MOD_SPIRIT_SHORT = role.Spi,
            ITEM_MOD_ATTACK_POWER_SHORT = role.AP,
            ITEM_MOD_MELEE_ATTACK_POWER_SHORT = role.melee and role.AP,
            ITEM_MOD_RANGED_ATTACK_POWER_SHORT = role.ranged and role.AP,
            ITEM_MOD_SPELL_POWER_SHORT = role.SP or role.Heal, -- spell power heals too
            ITEM_MOD_SPELL_DAMAGE_DONE_SHORT = role.SP,
            ITEM_MOD_ARCANE_DAMAGE_DONE_SHORT = role.Arcane,
            ITEM_MOD_FIRE_DAMAGE_DONE_SHORT = role.Fire,
            ITEM_MOD_FROST_DAMAGE_DONE_SHORT = role.Frost,
            ITEM_MOD_HOLY_DAMAGE_DONE_SHORT = role.Holy,
            ITEM_MOD_NATURE_DAMAGE_DONE_SHORT = role.Nature,
            ITEM_MOD_SHADOW_DAMAGE_DONE_SHORT = role.Shadow,
            ITEM_MOD_SPELL_HEALING_DONE_SHORT = role.Heal,
            ITEM_MOD_MANA_REGENERATION_SHORT = role.MP5,
            ITEM_MOD_POWER_REGEN0_SHORT = role.MP5,
            ITEM_MOD_DEFENSE_SKILL_RATING_SHORT = role.Def,
            RESISTANCE0_NAME = role.Armor,
        }
        weightsByRole[role] = weights
    end
    return weights
end

-- Stats times the role's weights. A weapon's damage only counts for the
-- weapons the role fights with.
local function Score(role, stats, ranged)
    local score, weights = 0, Weights(role)
    for stat, value in pairs(stats) do
        local weight = weights[stat]
        if weight then score = score + value * weight end
    end
    local dps = stats.ITEM_MOD_DAMAGE_PER_SECOND_SHORT
    if dps and role.DPS and (ranged and role.rangedDPS or not ranged and role.meleeDPS) then
        score = score + dps * role.DPS
    end
    return score
end

-- Weapons whose damage the role counts go by item level: simpler, and their
-- damage may not be in the game's item stats.
local function WeaponByLevel(role, classID, equipLoc)
    local ranged = RANGED[equipLoc]
    return classID == Enum.ItemClass.Weapon and (ranged and role.rangedDPS or not ranged and role.meleeDPS)
end

local function SlotScore(who, role, slot)
    local stats = who.stats and who.stats[slot]
    return stats and Score(role, stats, slot == INVSLOT_RANGED) or 0
end

-- ReplacedLevel by score, and that piece's item level: both hands for a
-- two-hander (unless it replaces one), else the lower score, then the lower
-- item level.
local function ReplacedScore(who, role, equipLoc)
    if equipLoc == "INVTYPE_2HWEAPON" then
        local score = SlotScore(who, role, INVSLOT_MAINHAND)
        return who.twoHand and score or score + SlotScore(who, role, INVSLOT_OFFHAND), ReplacedLevel(who, equipLoc)
    end
    local lowest, level
    for _, slot in ipairs(SLOTS[equipLoc]) do
        if slot ~= INVSLOT_OFFHAND or equipLoc ~= "INVTYPE_WEAPON" or who.dualWield then
            local score = SlotScore(who, role, slot)
            if not lowest or score < lowest or (score == lowest and who.gear[slot] < level) then
                lowest, level = score, who.gear[slot]
            end
        end
    end
    return lowest, level
end

-- Whether you'd wear it: not all wrong stats, and nothing red on its tooltip
-- but the level line. Checked once per item.
local function CanWear(itemID, link, minLevel)
    local known = wearable[itemID]
    if known ~= nil then return known end
    if WrongStats(me.class, link) then
        wearable[itemID] = false
        return false
    end
    local data = C_TooltipInfo.GetItemByID(itemID)
    if not data or not data.lines then return false end -- checked again next time
    local levelLine = ITEM_MIN_LEVEL and minLevel > 0 and ITEM_MIN_LEVEL:format(minLevel)
    known = true
    for _, line in ipairs(data.lines) do
        if (IsRed(line.leftColor) and line.leftText ~= levelLine) or IsRed(line.rightColor) then
            known = false
            break
        end
    end
    wearable[itemID] = known
    return known
end

-- The skills a character wrote down for the item's type, if the type needs one.
local function TypeSkills(who, classID, subclassID)
    return classID == Enum.ItemClass.Weapon and WEAPON_SKILLS[subclassID] and who.weapons
        or classID == Enum.ItemClass.Armor and ARMOR_SKILLS[subclassID] and who.armor
end

-- The tooltip only speaks for you, so another character goes by its skills and
-- by what its class can learn.
local function AltCanWear(who, link, classID, subclassID)
    local skills = TypeSkills(who, classID, subclassID)
    if skills and not skills[subclassID] then return false end
    local weapons = classID == Enum.ItemClass.Weapon and WEAPON_SKILLS[subclassID] and CLASS_WEAPONS[who.class]
    if weapons and not weapons[subclassID] then return false end
    if classID == Enum.ItemClass.Armor and subclassID == Enum.ItemArmorSubclass.Shield and not CLASS_SHIELDS[who.class] then
        return false
    end
    return not WrongStats(who.class, link)
end

-- Gear the character can wear now that beats what it would replace: a higher
-- item level, or with a role a higher score (on equal scores, item level).
-- nil while the item's data is loading.
local function IsUpgrade(who, role, itemID)
    local _, _, _, equipLoc, _, classID, subclassID = GetItemInfoInstant(itemID)
    if not SLOTS[equipLoc] or missing[itemID] or (who == me and wearable[itemID] == false)
        or (equipLoc == "INVTYPE_WEAPONOFFHAND" and not who.dualWield) then
        return false
    end
    local armorTypes = CLASS_ARMOR[who.class]
    if classID == Enum.ItemClass.Armor and ARMOR_TYPES[subclassID] and equipLoc ~= "INVTYPE_CLOAK"
        and armorTypes and not armorTypes[subclassID] then
        return false
    end
    local info = ItemInfo(itemID)
    if not info then return nil end
    if info.minLevel > who.level then return false end
    local link, itemLevel, better = info.link, info.itemLevel, nil
    if role and not WeaponByLevel(role, classID, equipLoc) then
        local score, worn, wornLevel = Score(role, ItemStats(link), RANGED[equipLoc]), ReplacedScore(who, role, equipLoc)
        better = score > worn or (score == worn and itemLevel > wornLevel)
    else
        better = itemLevel > ReplacedLevel(who, equipLoc)
    end
    if not better then return false end
    if who == me then return CanWear(itemID, link, info.minLevel) end
    -- The others get it by mail.
    return info.bindType ~= Enum.ItemBind.OnAcquire and AltCanWear(who, link, classID, subclassID)
end

---------------------------------------------------------------------------
-- Recipes
---------------------------------------------------------------------------

-- The gear a recipe makes, or false (enchants, bars, bags, ...).
local function CraftedGear(recipeID)
    local itemID = craftedGear[recipeID]
    if itemID == nil then
        local schematic = C_TradeSkillUI.GetRecipeSchematic(recipeID, false)
        itemID = schematic and schematic.outputItemID
        itemID = itemID and SLOTS[select(4, GetItemInfoInstant(itemID))] and itemID or false
        craftedGear[recipeID] = itemID
    end
    return itemID
end

-- Only professions that make gear get the options in the Filter menu.
local function MakesGear(professionID)
    local known = makesGear[professionID]
    if known == nil then
        known = false
        for _, recipeID in ipairs(C_TradeSkillUI.GetAllRecipeIDs()) do
            if C_TradeSkillUI.IsRecipeInSkillLine(recipeID, professionID) and CraftedGear(recipeID) then
                known = true
                break
            end
        end
        makesGear[professionID] = known
    end
    return known
end

local candidates = {} -- this update's recipes to check (first ranks)
local seen = {} -- [recipeID] = true once looked at in this update

-- Blizzard's list's own checks: in the profession's skill line, under its first
-- rank. Recipes that make no gear are dropped before their info is read.
local function Consider(recipeID, professionID, unlearnedOnly)
    if seen[recipeID] or not C_TradeSkillUI.IsRecipeInSkillLine(recipeID, professionID)
        or not CraftedGear(recipeID) then
        return
    end
    local recipeInfo = Professions.GetFirstRecipe(C_TradeSkillUI.GetRecipeInfo(recipeID))
    if not recipeInfo or seen[recipeInfo.recipeID] then return end
    if recipeInfo.learned then
        if unlearnedOnly then return end
    elseif not db.showUnlearned then
        return
    end
    seen[recipeInfo.recipeID] = true
    if CraftedGear(recipeInfo.recipeID) then candidates[#candidates + 1] = recipeInfo end
end

-- Blizzard's order: learned first, then the highest recipes.
local function SortUpgrades(a, b)
    local x, y = a.recipeInfo, b.recipeInfo
    if x.learned ~= y.learned then return x.learned end
    if x.maxTrivialLevel ~= y.maxTrivialLevel then return x.maxTrivialLevel > y.maxTrivialLevel end
    if x.itemLevel ~= y.itemLevel then return x.itemLevel > y.itemLevel end
    return strcmputf8i(x.name, y.name) < 0
end

-- This update's categories: [categoryID] = { name, uiOrder, altKey (nil for
-- yours), upgrades = { { recipeInfo, itemID } } }. The tables are reused.
local wanted = {}
local categories = {}

local function AddCategory(categoryID, name, uiOrder, altKey)
    local category = categories[categoryID]
    if not category then
        category = { upgrades = {} }
        categories[categoryID] = category
    end
    category.name, category.uiOrder, category.altKey = name, uiOrder, altKey
    wipe(category.upgrades)
    wanted[categoryID] = category
    return category
end

-- What's hidden from your category or another character's (made on first use).
local function HiddenList(altKey, make)
    if not altKey then return hidden end
    local list = hiddenForAlts[altKey]
    if not list and make then
        list = {}
        hiddenForAlts[altKey] = list
    end
    return list or NOTHING
end

local function CollectFor(who, key, category)
    local upgrades, hiddenList = category.upgrades, HiddenList(category.altKey)
    local role = RoleFor(key, who)
    for _, recipeInfo in ipairs(candidates) do
        if not (hiddenList[recipeInfo.recipeID] and db.hideSelected) then
            local itemID = CraftedGear(recipeInfo.recipeID)
            if IsUpgrade(who, role, itemID) then
                upgrades[#upgrades + 1] = { recipeInfo = recipeInfo, itemID = itemID }
            end
        end
    end
    sort(upgrades, SortUpgrades)
end

-- A saved record, or your target's, written down for now only (Players.lua).
local function Character(key)
    local guest = ns.guest
    return characters[key] or (guest and guest.key == key and guest) or nil
end

-- Your other characters on your realm and faction (the ones you can mail) and
-- the players you added, each unless its option is off (everyone: either way),
-- then your target while that option is on.
local alts = {}
local function Alts(everyone)
    wipe(alts)
    local you, realm, faction = PlayerKey(), GetRealmName(), UnitFactionGroup("player")
    for key, who in pairs(characters) do
        if key ~= you and who.realm == realm and who.faction == faction
            and (everyone or db[who.other and "showFriends" or "showAlts"]) then
            alts[#alts + 1] = key
        end
    end
    local guest = ns.guest
    if guest and db.showTarget and not characters[guest.key] and OtherKey("target") == guest.key then
        alts[#alts + 1] = guest.key
    end
    sort(alts)
    return alts
end

-- The recipes Blizzard's list shows (so its filters apply, as they do to
-- Favorites), plus unlearned ones with that option on: for you, then the others.
local function Collect(professionID)
    wipe(candidates)
    wipe(seen)
    for _, recipeID in ipairs(C_TradeSkillUI.GetFilteredRecipeIDs()) do
        Consider(recipeID, professionID, false)
    end
    if db.showUnlearned then
        for _, recipeID in ipairs(C_TradeSkillUI.GetAllRecipeIDs()) do
            Consider(recipeID, professionID, true)
        end
    end
    ReadCharacter(me)
    CollectFor(me, PlayerKey(), AddCategory(ADDON_NAME, CATEGORY_NAME, -1))
    for _, key in ipairs(Alts()) do
        local who = Character(key)
        CollectFor(who, key, AddCategory(ADDON_NAME .. ":" .. key, ALT_CATEGORY_NAME:format(who.name), 0, key))
    end
end

---------------------------------------------------------------------------
-- Categories
---------------------------------------------------------------------------

local ourProvider -- Blizzard's list the categories are in
local ourNodes = {} -- [categoryID] = node
local ourRecipes = {} -- [categoryID] = its recipe IDs, to tell when they change

local function UpgradeList(upgrades)
    local ids = {}
    for i, upgrade in ipairs(upgrades) do ids[i] = upgrade.recipeInfo.recipeID end
    return table.concat(ids, ",")
end

-- Built on the side, then handed over: each insert into Blizzard's list redraws
-- it, this way it's redrawn once.
local function BuildCategory(dataProvider, categoryID, category)
    local scratch = CreateTreeDataProvider()
    -- Group 0 sorts before Favorites (group 1). Blizzard remembers collapsed
    -- categories by their categoryID.
    local node = scratch:Insert({ group = 0,
        categoryInfo = { name = category.name, categoryID = categoryID, uiOrder = category.uiOrder } })
    node:Insert({ topPadding = true, order = -1 })
    for _, upgrade in ipairs(category.upgrades) do
        -- A copy marked like Favorites' copies, so Blizzard's search still finds
        -- the recipe's own row. After a click Blizzard selects the first row with
        -- the recipe and its mark, so each category has its own mark.
        local recipeInfo = CopyTable(upgrade.recipeInfo)
        recipeInfo.favoritesInstance = categoryID
        node:Insert({ recipeInfo = recipeInfo, order = 0, upgradeItemID = upgrade.itemID, upgradeFor = category.altKey })
    end
    node:Insert({ bottomPadding = true, order = 1 })
    node:SetCollapsed(collapsed[categoryID] or false)
    node.parent, node.dataProvider = dataProvider:GetRootNode(), dataProvider
    for _, child in ipairs(node:GetNodes()) do child.dataProvider = dataProvider end
    return node
end

-- Where Blizzard's sort would put it (group, then order, then name). Blizzard
-- draws its nodes in their current order until its next change.
local function Position(root, info)
    for index, node in ipairs(root:GetNodes()) do
        local data = node:GetData()
        local other = data.group == 0 and data.categoryInfo
        if not other or other.uiOrder > info.uiOrder
            or (other.uiOrder == info.uiOrder and strcmputf8i(other.name, info.name) > 0) then
            return index
        end
    end
    return #root:GetNodes() + 1
end

-- Puts a category back in when its recipes changed, or takes it out when empty.
local function Update(dataProvider, categoryID, category)
    local recipes = category and #category.upgrades > 0 and UpgradeList(category.upgrades) or nil
    if recipes == ourRecipes[categoryID] then return end
    local node = ourNodes[categoryID]
    if node then
        collapsed[categoryID] = node:IsCollapsed()
        -- Blizzard's selection would keep a removed row, and the old category with it.
        local selection = recipeList.selectionBehavior
        for _, child in ipairs(node:GetNodes()) do
            if selection:IsElementDataSelected(child) then selection:DeselectElementData(child) end
        end
        dataProvider:Remove(node)
        ourNodes[categoryID] = nil
    end
    ourRecipes[categoryID] = recipes
    if recipes then
        node = BuildCategory(dataProvider, categoryID, category)
        ourNodes[categoryID] = node
        local root = dataProvider:GetRootNode()
        root:InsertNode(node, Position(root, node:GetData().categoryInfo))
    end
end

local function Refresh()
    if not recipeList:IsVisible() then
        dirty = true
        return
    end
    dirty = false
    local dataProvider = blizzardList:GetDataProvider()
    if ourProvider ~= dataProvider then
        -- Blizzard built a new list, without the categories.
        for categoryID, node in pairs(ourNodes) do collapsed[categoryID] = node:IsCollapsed() end
        wipe(ourNodes)
        wipe(ourRecipes)
        ourProvider = dataProvider
    end
    if not dataProvider then return end
    wipe(wanted)
    local professionInfo = page.professionInfo
    -- Hidden while searching, like Favorites, and only for your own professions
    -- (not a linked list, a guild's or an NPC's).
    if professionInfo and professionInfo.professionID and not recipeList.SearchBox:HasText()
        and Professions.InLocalCraftingMode() then
        Collect(professionInfo.professionID)
    end
    for categoryID in pairs(ourNodes) do
        if not wanted[categoryID] then Update(dataProvider, categoryID, nil) end
    end
    for categoryID, category in pairs(wanted) do
        Update(dataProvider, categoryID, category)
    end
    -- Like Blizzard: "no results" only when its whole list is empty.
    recipeList.NoResultsText:SetShown(dataProvider:IsEmpty())
end

local queued
local function RunQueued()
    queued = false
    Refresh()
end

-- Next frame, or after `delay` seconds, once for any number of changes. While
-- the list is hidden it waits for the list instead.
local function QueueRefresh(delay)
    if not page then return end
    if not recipeList:IsVisible() then
        dirty = true
    elseif not queued then
        queued = true
        C_Timer.After(delay or 0, RunQueued)
    end
end

local function CatchUp()
    if dirty then Refresh() end
end

---------------------------------------------------------------------------
-- Loading
---------------------------------------------------------------------------

local function OnListShown()
    CatchUp()
    ns.RefreshNearby()
end

-- Once Blizzard's crafting window has loaded.
local function Setup()
    if page or not ProfessionsFrame then return end
    page = ProfessionsFrame.CraftingPage
    recipeList = page and page.RecipeList
    blizzardList = recipeList and recipeList.ScrollBox
    if not (blizzardList and blizzardList.GetDataProvider) then
        page = nil
        return
    end
    ns.page, ns.recipeList = page, recipeList

    local watcher = CreateFrame("Frame", nil, recipeList)
    watcher:SetScript("OnShow", OnListShown)

    -- Blizzard rebuilds its list after any profession, filter, search or recipe
    -- change, and the categories go back in each time.
    hooksecurefunc(page, "Init", Refresh)
    hooksecurefunc(ProfessionsRecipeListRecipeMixin, "OnEnter", ns.OnRecipeEnter)
    hooksecurefunc(TooltipComparisonManager, "RefreshItems", ns.HideAltComparison)
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, ns.OnItemTooltip)
    for _, tooltip in ipairs(GameTooltip.shoppingTooltips) do tooltip:HookScript("OnShow", ns.HideAltComparison) end
    GameTooltip:HookScript("OnHide", ns.OnTooltipHide)
    EventRegistry:RegisterCallback("ProfessionsDebug.CraftingRecipeListRecipeClicked", ns.OnRecipeClick, ADDON_NAME)
    ScrollUtil.AddInitializedFrameCallback(blizzardList, ns.OnRowInitialized, ADDON_NAME)
    Menu.ModifyMenu("MENU_PROFESSIONS_FILTER", ns.AddFilterOption)
    if recipeList.FilterDropdown and recipeList.FilterDropdown.ValidateResetState then
        hooksecurefunc(recipeList.FilterDropdown, "ValidateResetState", ns.HideFalseReset)
    end
    Refresh()
end

-- What the other files use of this one.
ns.NOTHING, ns.me, ns.missing, ns.alts, ns.ourNodes = NOTHING, me, missing, alts, ourNodes
ns.LoadItem, ns.ItemStats, ns.FullName = LoadItem, ItemStats, FullName
ns.PlayerKey, ns.OtherName, ns.OtherKey = PlayerKey, OtherName, OtherKey
ns.FindRole, ns.RoleFor, ns.Score = FindRole, RoleFor, Score
ns.WeaponByLevel, ns.ReplacedScore, ns.TypeSkills = WeaponByLevel, ReplacedScore, TypeSkills
ns.MakesGear, ns.HiddenList, ns.Character, ns.Alts = MakesGear, HiddenList, Character, Alts
ns.Refresh, ns.QueueRefresh = Refresh, QueueRefresh

events:RegisterEvent("ADDON_LOADED")
-- Also with the crafting window closed: you're written down for your other characters.
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
events:RegisterEvent("PLAYER_LEVEL_UP")
events:RegisterEvent("SKILL_LINES_CHANGED")
events:RegisterEvent("PLAYER_TALENT_UPDATE")
events:RegisterEvent("TRAIT_CONFIG_UPDATED")
events:RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED")
events:SetScript("OnEvent", function(self, event, arg1, arg2)
    if event == "ADDON_LOADED" then
        if arg1 == ADDON_NAME then
            -- After an update, a /reload only loads the files the old .toc listed:
            -- stay off until the game is restarted.
            if not (SLOTS and ns.WatchPlayers and ns.OnRecipeEnter and ns.OnRecipeClick and ns.AddFilterOption) then
                events:UnregisterAllEvents()
                return
            end
            CraftUpgradesDB = CraftUpgradesDB or {}
            db = CraftUpgradesDB
            for key, value in pairs(defaults) do
                if db[key] == nil then db[key] = value end
            end
            db.characters = nil -- an older format, keyed by first names only
            db.characterGear = db.characterGear or {}
            characters = db.characterGear
            ns.db, ns.characters = db, characters
            ns.WatchPlayers()
            db.statWeights = db.statWeights or {} -- ["Full Name-Realm"] = the role picked
            CraftUpgradesCharDB = CraftUpgradesCharDB or {}
            CraftUpgradesCharDB.hidden = CraftUpgradesCharDB.hidden or {}
            hidden = CraftUpgradesCharDB.hidden
            CraftUpgradesCharDB.hiddenForAlts = CraftUpgradesCharDB.hiddenForAlts or {}
            hiddenForAlts = CraftUpgradesCharDB.hiddenForAlts
            -- Another addon may have loaded the crafting window first.
            if C_AddOns.IsAddOnLoaded("Blizzard_Professions") then Setup() end
        elseif arg1 == "Blizzard_Professions" and db then
            Setup()
        end
    elseif event == "ITEM_DATA_LOAD_RESULT" then
        if loading[arg1] then
            loading[arg1] = nil
            if not arg2 then missing[arg1] = true end -- no such item
            ns.RedrawComparison()
            if next(loading) == nil then
                self:UnregisterEvent("ITEM_DATA_LOAD_RESULT")
                if gearLoading then
                    gearLoading = false
                    RecordCharacter()
                end
                ns.ReadWaitingPlayer()
                QueueRefresh()
            else
                QueueRefresh(LOAD_BATCH) -- more on the way
            end
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        if gearTries == 0 then RecordAfterLoading() end
    elseif event == "PLAYER_LEVEL_UP" then
        newLevel = arg1
        wipe(wearable)
        RecordCharacter()
        QueueRefresh()
    elseif event == "SKILL_LINES_CHANGED" then
        wipe(wearable) -- a new armor or weapon type may have been learned
        RecordCharacter()
        QueueRefresh()
    elseif event == "PLAYER_EQUIPMENT_CHANGED" then
        if not recordQueued then
            recordQueued = true
            C_Timer.After(0, RecordQueued)
        end
        QueueRefresh()
    else -- talents changed: the spec may too
        RecordCharacter()
        QueueRefresh()
    end
end)
