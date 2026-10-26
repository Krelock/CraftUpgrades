-- Craft Upgrades' tables: where each kind of gear is worn, the armor each class
-- wears, the skills behind weapon and armor types, the weapons and shields each
-- class can learn, and each class's roles with their stat weights.

local _, ns = ...

-- Shirts, tabards, bags and ammo aren't upgrades, so they aren't listed.
local SLOTS = {
    INVTYPE_HEAD = { INVSLOT_HEAD },
    INVTYPE_NECK = { INVSLOT_NECK },
    INVTYPE_SHOULDER = { INVSLOT_SHOULDER },
    INVTYPE_CHEST = { INVSLOT_CHEST },
    INVTYPE_ROBE = { INVSLOT_CHEST },
    INVTYPE_WAIST = { INVSLOT_WAIST },
    INVTYPE_LEGS = { INVSLOT_LEGS },
    INVTYPE_FEET = { INVSLOT_FEET },
    INVTYPE_WRIST = { INVSLOT_WRIST },
    INVTYPE_HAND = { INVSLOT_HAND },
    INVTYPE_FINGER = { INVSLOT_FINGER1, INVSLOT_FINGER2 },
    INVTYPE_TRINKET = { INVSLOT_TRINKET1, INVSLOT_TRINKET2 },
    INVTYPE_CLOAK = { INVSLOT_BACK },
    INVTYPE_WEAPON = { INVSLOT_MAINHAND, INVSLOT_OFFHAND }, -- the off hand only with dual wield
    INVTYPE_2HWEAPON = { INVSLOT_MAINHAND },
    INVTYPE_WEAPONMAINHAND = { INVSLOT_MAINHAND },
    INVTYPE_WEAPONOFFHAND = { INVSLOT_OFFHAND },
    INVTYPE_SHIELD = { INVSLOT_OFFHAND },
    INVTYPE_HOLDABLE = { INVSLOT_OFFHAND },
    INVTYPE_RANGED = { INVSLOT_RANGED },
    INVTYPE_RANGEDRIGHT = { INVSLOT_RANGED },
    INVTYPE_THROWN = { INVSLOT_RANGED },
    INVTYPE_RELIC = { INVSLOT_RANGED },
}

-- Mail and plate still have to be learned, which the tooltip check sees.
local ARMOR = Enum.ItemArmorSubclass
local CLASS_ARMOR = {
    WARRIOR = { [ARMOR.Mail] = true, [ARMOR.Plate] = true },
    PALADIN = { [ARMOR.Mail] = true, [ARMOR.Plate] = true },
    HUNTER = { [ARMOR.Leather] = true, [ARMOR.Mail] = true },
    SHAMAN = { [ARMOR.Leather] = true, [ARMOR.Mail] = true },
    ROGUE = { [ARMOR.Leather] = true },
    DRUID = { [ARMOR.Leather] = true },
    MAGE = { [ARMOR.Cloth] = true },
    PRIEST = { [ARMOR.Cloth] = true },
    WARLOCK = { [ARMOR.Cloth] = true },
}
local ARMOR_TYPES = { [ARMOR.Cloth] = true, [ARMOR.Leather] = true, [ARMOR.Mail] = true, [ARMOR.Plate] = true }

-- Skill lines. The weapons' are the character pane's own; the armor skills are
-- classic's.
local WEAPON = Enum.ItemWeaponSubclass
local WEAPON_SKILLS = {
    [WEAPON.Sword1H] = 43, [WEAPON.Axe1H] = 44, [WEAPON.Bows] = 45, [WEAPON.Guns] = 46, [WEAPON.Mace1H] = 54,
    [WEAPON.Sword2H] = 55, [WEAPON.Staff] = 136, [WEAPON.Mace2H] = 160, [WEAPON.Axe2H] = 172, [WEAPON.Dagger] = 173,
    [WEAPON.Thrown] = 176, [WEAPON.Crossbow] = 226, [WEAPON.Wand] = 228, [WEAPON.Polearm] = 229, [WEAPON.Unarmed] = 162,
}
local ARMOR_SKILLS = {
    [ARMOR.Cloth] = 415, [ARMOR.Leather] = 414, [ARMOR.Mail] = 413, [ARMOR.Plate] = 293, [ARMOR.Shield] = 433,
}

-- The weapons each class can learn, as in classic, for characters whose skills
-- can't tell: fist weapons go by the Unarmed skill, which every class has, and
-- players you add have no skills written down.
local CLASS_WEAPONS = {
    WARRIOR = "Axe1H Axe2H Mace1H Mace2H Sword1H Sword2H Polearm Staff Dagger Unarmed Bows Crossbow Guns Thrown",
    PALADIN = "Axe1H Axe2H Mace1H Mace2H Sword1H Sword2H Polearm",
    HUNTER = "Axe1H Axe2H Sword1H Sword2H Polearm Staff Dagger Unarmed Bows Crossbow Guns Thrown",
    ROGUE = "Mace1H Sword1H Dagger Unarmed Bows Crossbow Guns Thrown",
    PRIEST = "Mace1H Staff Dagger Wand",
    SHAMAN = "Axe1H Axe2H Mace1H Mace2H Staff Dagger Unarmed",
    MAGE = "Sword1H Staff Dagger Wand",
    WARLOCK = "Sword1H Staff Dagger Wand",
    DRUID = "Mace1H Mace2H Staff Dagger Unarmed",
}
for class, names in pairs(CLASS_WEAPONS) do
    local types = {}
    for name in names:gmatch("%S+") do types[WEAPON[name]] = true end
    CLASS_WEAPONS[class] = types
end
local CLASS_SHIELDS = { WARRIOR = true, PALADIN = true, SHAMAN = true }

-- The role of each talent tree, in the talent window's order.
local SPEC_ROLES = {
    WARRIOR = { "arms", "arms", "protection" }, -- Arms, Fury, Protection
    PALADIN = { "holy", "protection", "retribution" },
    HUNTER = { "marksmanship", "marksmanship", "survival" }, -- Beast Mastery, Marksmanship, Survival
    ROGUE = { "combat", "combat", "subtlety" }, -- Assassination, Combat, Subtlety
    PRIEST = { "holy", "holy", "shadow" }, -- Discipline, Holy, Shadow
    SHAMAN = { "elemental", "enhancement", "restoration" },
    MAGE = { "arcane", "fire", "frost" },
    WARLOCK = { "affliction", "demonology", "destruction" },
    DRUID = { "balance", "feral", "restoration" },
}

-- Classes that pass on gear with only caster stats, or only melee stats.
local NO_CASTER_GEAR = { WARRIOR = true, ROGUE = true }
local NO_MELEE_GEAR = { MAGE = true, PRIEST = true, WARLOCK = true }

-- Weights per point of each stat, from Icy Veins' stat priorities for Forever.
-- Hit, Crit, Haste and Expertise are per 1%, DPS per point of weapon damage per
-- second. melee, ranged and spell: which kinds of Hit, Crit and attack power
-- count. meleeDPS and rangedDPS: which weapons' damage counts.
-- AP a guide doesn't rank is worth half the stat it comes from (Strength, or
-- Agility for Rogues and Hunters). Arcane, Fire, ...: a spell school's damage,
-- at the Spell Power weight, for the school a caster mostly casts.
local ROLES = {
    WARRIOR = {
        { key = "arms", name = "Arms / Fury", melee = true, meleeDPS = true,
            DPS = 3.5, Hit = 8, Crit = 6.5, Str = 0.5, Agi = 0.4, Sta = 0.3, AP = 0.25 },
        { key = "protection", name = "Protection", melee = true, meleeDPS = true,
            DPS = 3.5, Hit = 8, Crit = 2, Str = 0.65, Agi = 0.5, Sta = 0.3, AP = 0.325, Armor = 0.04 },
    },
    PALADIN = {
        { key = "holy", name = "Holy", spell = true,
            Crit = 5, Haste = 4, Int = 0.8, Spi = 0.3, Heal = 0.45, MP5 = 1.63 },
        { key = "protection", name = "Protection", melee = true, spell = true,
            Hit = 8, Str = 0.15, Agi = 0.1, Sta = 0.65, Int = 0.2, AP = 0.075, SP = 0.85, Holy = 0.85, Def = 0.5, Armor = 0.04 },
        { key = "retribution", name = "Retribution", melee = true, meleeDPS = true,
            DPS = 3.5, Hit = 8, Exp = 8, Crit = 6.5, Str = 0.4, Agi = 0.2, Sta = 0.15, Int = 0.3, Spi = 0.1, AP = 0.2, SP = 0.43, Holy = 0.43 },
    },
    HUNTER = {
        { key = "marksmanship", name = "Beast Mastery / Marksmanship", ranged = true, rangedDPS = true,
            DPS = 3.5, Hit = 8, Crit = 5, Agi = 0.65, Sta = 0.2, Int = 0.4, Spi = 0.3, AP = 0.325 },
        { key = "survival", name = "Survival", melee = true, ranged = true, meleeDPS = true, rangedDPS = true,
            DPS = 3.5, Hit = 8, Crit = 5, Str = 0.4, Agi = 0.65, Sta = 0.15, Int = 0.3, Spi = 0.2, AP = 0.325 },
    },
    ROGUE = {
        { key = "combat", name = "Assassination / Combat", melee = true, meleeDPS = true,
            DPS = 3.5, Hit = 8, Exp = 8, Crit = 5, Str = 0.4, Agi = 0.65, Sta = 0.3, AP = 0.325 },
        { key = "subtlety", name = "Subtlety", melee = true, meleeDPS = true,
            DPS = 3.5, Hit = 8, Exp = 8, Crit = 4, Str = 0.3, Agi = 0.65, AP = 0.25 },
    },
    PRIEST = {
        { key = "holy", name = "Holy / Discipline", spell = true,
            Crit = 4, Int = 0.5, Spi = 0.65, Heal = 0.45, MP5 = 2 },
        { key = "shadow", name = "Shadow", spell = true,
            Hit = 6.5, Crit = 8, Sta = 0.4, Int = 0.5, SP = 0.85, Shadow = 0.85, MP5 = 0.75 },
    },
    SHAMAN = {
        { key = "elemental", name = "Elemental", spell = true,
            Hit = 6.5, Crit = 8, Sta = 0.2, Int = 0.5, Spi = 0.3, SP = 0.85, Nature = 0.85, MP5 = 1 },
        { key = "enhancement", name = "Enhancement", melee = true, meleeDPS = true,
            DPS = 3.5, Hit = 8, Exp = 8, Crit = 6.5, Str = 0.5, Agi = 0.3, Sta = 0.1, Int = 0.4, Spi = 0.15, AP = 0.25, SP = 0.17 },
        { key = "restoration", name = "Restoration", spell = true,
            Crit = 8, Sta = 0.3, Int = 0.65, Spi = 0.5, Heal = 0.45, MP5 = 1 },
    },
    MAGE = {
        { key = "arcane", name = "Arcane", spell = true,
            Hit = 10, Crit = 4, Sta = 0.3, Int = 0.5, Spi = 0.65, SP = 0.68, Arcane = 0.68, MP5 = 0.5 },
        { key = "fire", name = "Fire", spell = true,
            Hit = 10, Crit = 6.5, Sta = 0.3, Int = 0.4, Spi = 0.5, SP = 0.68, Fire = 0.68, MP5 = 0.5 },
        { key = "frost", name = "Frost", spell = true,
            Hit = 10, Crit = 6.5, Str = 0.15, Agi = 0.2, Sta = 0.3, Int = 0.4, Spi = 0.5, SP = 0.68, Frost = 0.68 },
    },
    WARLOCK = {
        { key = "affliction", name = "Affliction", spell = true,
            Hit = 8, Crit = 6.5, Haste = 3, Sta = 0.2, Int = 0.5, Spi = 0.4, SP = 0.85, Shadow = 0.85 },
        { key = "demonology", name = "Demonology", spell = true,
            Hit = 8, Crit = 5, Haste = 3, Sta = 0.2, Int = 0.65, Spi = 0.4, SP = 0.85, Shadow = 0.85 },
        { key = "destruction", name = "Destruction", spell = true,
            Hit = 8, Crit = 5, Haste = 6.5, Sta = 0.2, Int = 0.3, Spi = 0.4, SP = 0.85, Shadow = 0.85 },
    },
    DRUID = {
        { key = "balance", name = "Balance", spell = true,
            Crit = 4, Haste = 3, Int = 1, Spi = 0.65, SP = 0.68, Nature = 0.68, Arcane = 0.68, MP5 = 1.25 },
        { key = "feral", name = "Feral (Cat and Bear)", melee = true, meleeDPS = true,
            DPS = 3.5, Hit = 8, Exp = 8, Crit = 6.5, Str = 0.5, Agi = 0.4, Sta = 0.3, Int = 0.15, Spi = 0.2, AP = 0.25, SP = 0.09 },
        { key = "restoration", name = "Restoration", spell = true,
            Crit = 4, Haste = 3, Int = 1, Spi = 0.65, SP = 0.68, Heal = 0.36, MP5 = 1.25 },
    },
}
local RANGED = { INVTYPE_RANGED = true, INVTYPE_RANGEDRIGHT = true, INVTYPE_THROWN = true }

ns.SLOTS, ns.CLASS_ARMOR, ns.ARMOR_TYPES = SLOTS, CLASS_ARMOR, ARMOR_TYPES
ns.WEAPON_SKILLS, ns.ARMOR_SKILLS, ns.SPEC_ROLES = WEAPON_SKILLS, ARMOR_SKILLS, SPEC_ROLES
ns.CLASS_WEAPONS, ns.CLASS_SHIELDS = CLASS_WEAPONS, CLASS_SHIELDS
ns.NO_CASTER_GEAR, ns.NO_MELEE_GEAR, ns.ROLES, ns.RANGED = NO_CASTER_GEAR, NO_MELEE_GEAR, ROLES, RANGED
