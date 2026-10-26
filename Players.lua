-- Craft Upgrades' other players (Beta): what they wear, from what the game sends
-- when it's asked to inspect them. The game holds one inspected player at a time
-- (the one Blizzard's inspect window shows), so one is asked for at a time, and
-- on its own only out of combat and while Blizzard isn't showing one.
--
-- Sections: Inspecting, Reading gear again, Options, Events.

local _, ns = ...

local GetItemInfo = C_Item.GetItemInfo
local GetItemInfoInstant = C_Item.GetItemInfoInstant
local GetDetailedItemLevelInfo = C_Item.GetDetailedItemLevelInfo
local GetInventoryItemLink = GetInventoryItemLink
local ipairs, pairs = ipairs, pairs

local INSPECT_WAIT = 5 -- seconds to wait for their gear
local INSPECT_GAP = 1.5 -- seconds between two players asked for one after the other
local RETRY_AFTER = 30 -- seconds before a player whose gear didn't come is asked for again
local REFRESH_EVERY = 300 -- seconds before a player's gear is read again on its own

local OtherName, OtherKey, PlayerKey = ns.OtherName, ns.OtherKey, ns.PlayerKey
local LoadItem, ItemStats, missing = ns.LoadItem, ns.ItemStats, ns.missing
local Refresh, QueueRefresh = ns.Refresh, ns.QueueRefresh
local events = CreateFrame("Frame")

---------------------------------------------------------------------------
-- Inspecting
---------------------------------------------------------------------------

local NEARBY_EVENTS = { "PLAYER_TARGET_CHANGED", "UPDATE_MOUSEOVER_UNIT", "GROUP_ROSTER_UPDATE" }
local NEARBY_UNITS = { "target" } -- where added players are looked for when the crafting window opens
for i = 1, 4 do NEARBY_UNITS[#NEARBY_UNITS + 1] = "party" .. i end
for i = 1, 40 do NEARBY_UNITS[#NEARBY_UNITS + 1] = "raid" .. i end
local inspecting -- the request: { unit, key, guid, forNow, waiting (for item data) }
local nextTry = {} -- [player] = the GetTime() from which they're read again on their own
local watching -- a player is added and shown, so the events that say one is near are on

-- Whether Blizzard's inspect or talent window shows the game's inspected player.
local function BlizzardInspecting()
    return (InspectFrame ~= nil and InspectFrame:IsShown())
        or (PlayerSpellsFrame ~= nil and PlayerSpellsFrame.IsInspecting ~= nil and PlayerSpellsFrame:IsInspecting())
        or false
end

-- A record like yours (nil if anything is secret), how many items, and whether
-- some are still loading. An item given only by ID is taken without enchants.
local function ReadOther(unit)
    local name = OtherName(unit)
    local _, class = UnitClass(unit)
    if issecretvalue(class) or not (name and class) then return nil end
    local who = { name = name, realm = GetRealmName(), faction = UnitFactionGroup(unit), class = class,
        level = UnitLevel(unit), other = true, gear = {}, stats = {}, links = {} }
    local gear, stats, links, worn, waiting = who.gear, who.stats, who.links, 0, false
    for slot = INVSLOT_HEAD, INVSLOT_RANGED do
        local link = GetInventoryItemLink(unit, slot)
        if issecretvalue(link) then return nil end
        local itemID
        if link then
            itemID = not C_Item.IsItemDataCachedByID(link) and GetItemInfoInstant(link)
        else
            itemID = GetInventoryItemID(unit, slot)
            if issecretvalue(itemID) then return nil end
            link = itemID and select(2, GetItemInfo(itemID))
            itemID = not link and itemID
        end
        if itemID and not missing[itemID] then
            waiting = true
            LoadItem(itemID)
        end
        if link then worn = worn + 1 end
        gear[slot] = link and GetDetailedItemLevelInfo(link) or 0
        stats[slot] = link and ItemStats(link) or nil
        links[slot] = link
    end
    -- A two-hander fills the off hand too.
    local mainHand, offHand = links[INVSLOT_MAINHAND], links[INVSLOT_OFFHAND]
    who.twoHand = mainHand ~= nil and select(4, GetItemInfoInstant(mainHand)) == "INVTYPE_2HWEAPON"
    if who.twoHand then
        gear[INVSLOT_OFFHAND] = gear[INVSLOT_MAINHAND]
        stats[INVSLOT_OFFHAND] = stats[INVSLOT_MAINHAND]
    end
    -- The game doesn't say whether they can dual wield; a weapon in the off hand does.
    local offHandIs = offHand and select(4, GetItemInfoInstant(offHand))
    who.dualWield = offHandIs == "INVTYPE_WEAPON" or offHandIs == "INVTYPE_WEAPONOFFHAND"
    return who, worn, waiting
end

-- Only while an added player is shown (target changes also for the target option).
local function WatchPlayers()
    watching = false
    for _, who in pairs(ns.characters) do
        if who.other then
            watching = ns.db.showFriends
            break
        end
    end
    for _, event in ipairs(NEARBY_EVENTS) do
        if watching or (ns.db.showTarget and event == "PLAYER_TARGET_CHANGED") then
            events:RegisterEvent(event)
        else
            events:UnregisterEvent(event)
        end
    end
end

-- Lets go of the game's inspected player, as Blizzard's window does when it
-- closes (not while Blizzard shows one). The next player gets a turn shortly.
local RefreshNearby
local function EndInspect()
    inspecting = nil
    events:UnregisterEvent("INSPECT_READY")
    if not BlizzardInspecting() then ClearInspectPlayer() end
    C_Timer.After(INSPECT_GAP, RefreshNearby)
end

-- Written down unless the unit is someone else now, a fight started or nothing
-- came. Items still loading are waited for.
local function ReadInspected()
    local request = inspecting
    local guid = UnitGUID(request.unit)
    if InCombatLockdown() or issecretvalue(guid) or guid ~= request.guid then
        EndInspect()
        return
    end
    local who, worn, waiting = ReadOther(request.unit)
    if who and waiting then
        request.waiting = true
        return
    end
    if who and worn > 0 then
        if request.forNow then
            who.key = request.key
            ns.guest = who
        else
            ns.characters[request.key] = who
            WatchPlayers()
        end
        nextTry[request.key] = GetTime() + REFRESH_EVERY
        QueueRefresh()
    end
    EndInspect()
end

-- INSPECT_READY says when their gear is in. If it never comes (out of range, or
-- the game dropped the request), the wait ends on its own.
local function Inspect(unit, key, forNow)
    local guid = UnitGUID(unit)
    if issecretvalue(guid) or not guid then return end
    local request = { unit = unit, key = key, guid = guid, forNow = forNow }
    inspecting = request
    nextTry[key] = GetTime() + RETRY_AFTER
    events:RegisterEvent("INSPECT_READY")
    NotifyInspect(unit)
    C_Timer.After(INSPECT_WAIT, function()
        if inspecting == request then EndInspect() end
    end)
end

---------------------------------------------------------------------------
-- Reading gear again
---------------------------------------------------------------------------

local function CanRefresh()
    return not inspecting and not InCombatLockdown() and not BlizzardInspecting()
end

-- An added player's gear, when it's been a while and the game can inspect them
-- (they're near). Returns whether it asked.
local function RefreshPlayer(unit)
    local key = OtherKey(unit)
    local who = key and ns.characters[key]
    if who and who.other and GetTime() >= (nextTry[key] or 0) and CanInspect(unit) then
        Inspect(unit, key)
        return inspecting ~= nil
    end
    return false
end

-- Your target's key when it can be added now: a player of your faction (you can
-- trade with them) the game can inspect, out of combat. Not while Blizzard's
-- inspect or talent window shows someone else: asking would empty it.
local function AddableTarget()
    local key = OtherKey("target")
    if key == PlayerKey() or InCombatLockdown() or not CanInspect("target")
        or UnitFactionGroup("target") ~= UnitFactionGroup("player") then
        return nil
    end
    if BlizzardInspecting() then
        local shown = InspectFrame ~= nil and InspectFrame.unit -- nil while its window is closed
        local same = shown and UnitIsUnit("target", shown)
        if issecretvalue(same) or not same then return nil end
    end
    return key
end

local function AddTarget()
    local key = AddableTarget()
    if key then Inspect("target", key) end
end

-- The target option: with the recipe list on screen, a target who could be added
-- and isn't is written down for now only (ns.guest).
local function ShowTarget()
    if inspecting or not (ns.db.showTarget and ns.page and ns.recipeList:IsVisible()) then return end
    local key = AddableTarget()
    if key and not ns.characters[key] and GetTime() >= (nextTry[key] or 0) then Inspect("target", key, true) end
end

-- The first added player near you who is due; with none, your target for now.
function RefreshNearby()
    if watching and CanRefresh() then
        for _, unit in ipairs(NEARBY_UNITS) do
            if RefreshPlayer(unit) then return end
        end
    end
    ShowTarget()
end

---------------------------------------------------------------------------
-- Options
---------------------------------------------------------------------------

-- The submenu's two checkboxes: showFriends and showTarget.
local function IsShowing(option)
    return ns.db[option]
end

local function ToggleShowing(option)
    ns.db[option] = not ns.db[option]
    WatchPlayers()
    ShowTarget()
    Refresh()
end

local function RemovePlayer(key)
    ns.characters[key] = nil
    WatchPlayers()
    Refresh()
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

-- All the item data asked for is in: a player waiting on theirs is read now.
local function ReadWaitingPlayer()
    if inspecting and inspecting.waiting then ReadInspected() end
end

events:SetScript("OnEvent", function(_, event, arg1)
    if event == "INSPECT_READY" then
        if arg1 == inspecting.guid then ReadInspected() end
    elseif event == "PLAYER_TARGET_CHANGED" then
        if watching and CanRefresh() then RefreshPlayer("target") end
        ShowTarget()
        if ns.guest then QueueRefresh() end -- the target's category comes and goes with it
    elseif event == "UPDATE_MOUSEOVER_UNIT" then
        if CanRefresh() then RefreshPlayer("mouseover") end
    elseif event == "GROUP_ROSTER_UPDATE" then
        RefreshNearby()
    end
end)

ns.WatchPlayers, ns.RefreshNearby, ns.ReadWaitingPlayer = WatchPlayers, RefreshNearby, ReadWaitingPlayer
ns.AddableTarget, ns.AddTarget, ns.IsShowing = AddableTarget, AddTarget, IsShowing
ns.ToggleShowing, ns.RemovePlayer = ToggleShowing, RemovePlayer
