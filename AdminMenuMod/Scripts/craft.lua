--[[
    craft.lua - developer tool. Maps the game's craftable enum to readable names.

    Not part of the release. main.lua loads it with pcall, so its absence is normal.

    Why this exists
    ---------------
    Spawning a module actor directly gives a half-initialised module: the battery gauge
    reads 50% on a battery that is actually empty, and BP_Module_Petrol_ExtraLarge
    crashed the game inside FinishSpawningActor - that is the module's own BeginPlay,
    not our code.

    The game never spawns modules that way. Its buttons put down a BP_Module_Crafter,
    and the crafter builds the module through SpawnActorForItem with a full
    VoyageItemData. Every route into that goes through a soft reference, which is what
    UE4SS crashes on - except one:

        BP_Module_Crafter_C:StartCrafting(Object)

    Object is a ByteProperty over the enum
        /Game/Blueprints/Tests/Eric/CraftableObjectList.CraftableObjectList
    and a byte is a type UE4SS handles without complaint. StartCrafting turns it into a
    name with GetEnumeratorUserFriendlyName and looks the recipe up from there, so if we
    can find the right byte we get the game's own pipeline, correct initialisation and
    all.

    The dump gives 66 entries, but a cooked build strips their display names - they come
    out as CraftableObjectList::NewEnumerator7 and so on, in no useful order. The names
    do exist at runtime, which is what this command reads:

        /Script/Engine.KismetNodeHelperLibrary:GetEnumeratorUserFriendlyName(Enum, Value)
            -> FString

    Usage, in the console:
        craftlist            every value with its name
        craftlist bulk       only the ones matching "bulk"

    Both commands only read. craftdata, further down, reads the recipe array itself.

    Results against this build: 66 enum values, 57 recipes. Value 2 is "Large Battery",
    which is the UI's Bulk Battery, and that is the value the mod's button resolves at
    runtime. Neither list has an extra large petrol or diesel tank, which is why the mod
    adds only the battery. Run `craftlist bulk` after a game patch to see if that changed.
--]]

local CRAFTER_CLASS = "/Game/Blueprints/Tests/Eric/BP_Module_Crafter.BP_Module_Crafter_C"
local ENUM_PATH = "/Game/Blueprints/Tests/Eric/CraftableObjectList.CraftableObjectList"
local NODE_HELPER_CDO = "/Script/Engine.Default__KismetNodeHelperLibrary"

-- 66 entries in the dump. A couple spare costs nothing; the names simply come back empty.
local ENUM_COUNT = 70

local function out(Ar, msg)
    print("[AdminMenu] " .. msg .. "\n")
    if type(Ar) == "userdata" then
        pcall(function()
            if Ar.type ~= nil and Ar:type() == "FOutputDevice" then
                Ar:Log(msg)
            end
        end)
    end
end

local function isValid(o)
    if o == nil then
        return false
    end
    local ok, res = pcall(function() return o:IsValid() end)
    return ok and res == true
end

-- Returns name, problem. Never fails silently: an earlier version returned nil on any
-- error and the command reported "0 shown" without a single clue as to why.
local function friendlyName(helper, enum, value)
    local name
    local ok, err = pcall(function()
        name = helper:GetEnumeratorUserFriendlyName(enum, value)
    end)
    if not ok then
        return nil, tostring(err)
    end
    if name == nil then
        return nil, "returned nil"
    end
    if type(name) ~= "string" then
        local converted
        if pcall(function() converted = name:ToString() end) and converted ~= nil then
            name = converted
        else
            return nil, "got a " .. type(name) .. " that would not convert to a string"
        end
    end
    name = tostring(name)
    if name == "" then
        return nil, "empty string"
    end
    return name, nil
end

RegisterConsoleCommandHandler("craftlist", function(FullCommand, Parameters, Ar)
    local ok, err = pcall(function()
        local filter = nil
        if Parameters ~= nil and Parameters[1] ~= nil then
            filter = table.concat(Parameters, " "):lower()
        end

        local enum = StaticFindObject(ENUM_PATH)
        if not isValid(enum) then
            out(Ar, "craftable enum is not loaded - load a save first")
            return
        end
        local helper = StaticFindObject(NODE_HELPER_CDO)
        if not isValid(helper) then
            out(Ar, "KismetNodeHelperLibrary not found")
            return
        end

        out(Ar, filter and ("craftables matching '" .. filter .. "'") or "craftables")

        local shown, named, firstProblem = 0, 0, nil
        for value = 0, ENUM_COUNT - 1 do
            local name, problem = friendlyName(helper, enum, value)
            if problem ~= nil and firstProblem == nil then
                firstProblem = string.format("value %d: %s", value, problem)
            end
            if name ~= nil then
                named = named + 1
                if filter == nil or name:lower():find(filter, 1, true) then
                    out(Ar, string.format("%3d  %s", value, name))
                    shown = shown + 1
                end
            end
        end

        if named == 0 then
            out(Ar, "no names came back at all")
            out(Ar, "first problem was " .. tostring(firstProblem))
            out(Ar, "enum:   " .. tostring(select(2, pcall(function() return enum:GetFullName() end))))
            out(Ar, "helper: " .. tostring(select(2, pcall(function() return helper:GetFullName() end))))
        else
            out(Ar, named .. " of " .. ENUM_COUNT .. " values have names")
        end
        out(Ar, shown .. " shown")
    end)
    if not ok then
        print("[AdminMenu] ERROR in craftlist: " .. tostring(err) .. "\n")
    end
    return true
end)

print("[AdminMenu] craftlist registered - type 'craftlist' in the game console\n")

--[[ Reading the recipe list itself ---------------------------------------------------

    The enum is only one way to address the recipes: the data asset holds them as

        CraftingRecipesBaseData_C.Craftables : TArray<CraftableObjectStruct>

    and each struct carries a Name. The array turned out to hold 57 entries, fewer than
    the enum, and neither bulk tank is among them. This command is what checks that.

    ONLY the Name field is touched. The struct also holds Item (SoftObject), Class
    (SoftClass) and StaticMesh (SoftObject), and reading any of those is what kills the
    game. The field names carry blueprint GUID suffixes, hence the constant below.
--]]
local CRAFTER_CDO = "/Game/Blueprints/Tests/Eric/BP_Module_Crafter.Default__BP_Module_Crafter_C"
local NAME_FIELD = "Name_22_50942B7A4FF3E994CF4D7BA836C6FF46"

local function recipeArray(Ar)
    local cdo = StaticFindObject(CRAFTER_CDO)
    if not isValid(cdo) then
        out(Ar, "crafter class default not found - open the admin menu once first")
        return nil
    end

    local asset
    if not pcall(function() asset = cdo.Craftables end) or not isValid(asset) then
        out(Ar, "the crafter has no Craftables data asset")
        return nil
    end

    local list
    if not pcall(function() list = asset.Craftables end) or list == nil then
        out(Ar, "the data asset has no Craftables array")
        return nil
    end
    return list
end

local function nameOfEntry(entry)
    local value
    if not pcall(function() value = entry[NAME_FIELD] end) or value == nil then
        return nil
    end
    if type(value) ~= "string" then
        local converted
        if pcall(function() converted = value:ToString() end) and converted ~= nil then
            return tostring(converted)
        end
    end
    return tostring(value)
end

RegisterConsoleCommandHandler("craftdata", function(FullCommand, Parameters, Ar)
    local ok, err = pcall(function()
        local filter = nil
        if Parameters ~= nil and Parameters[1] ~= nil then
            filter = table.concat(Parameters, " "):lower()
        end

        local list = recipeArray(Ar)
        if list == nil then
            return
        end

        local count
        if not pcall(function() count = list:GetArrayNum() end) or count == nil then
            pcall(function() count = #list end)
        end
        if count == nil then
            out(Ar, "could not measure the array")
            return
        end
        out(Ar, "recipe array holds " .. count .. " entries (the enum has 66)")

        local shown = 0
        for i = 1, count do
            local entry
            if pcall(function() entry = list[i] end) and entry ~= nil then
                local name = nameOfEntry(entry) or "?"
                if filter == nil or name:lower():find(filter, 1, true) then
                    out(Ar, string.format("%3d  %s", i - 1, name))
                    shown = shown + 1
                end
            end
        end
        out(Ar, shown .. " shown")
    end)
    if not ok then
        print("[AdminMenu] ERROR in craftdata: " .. tostring(err) .. "\n")
    end
    return true
end)

print("[AdminMenu] craftdata registered - lists the recipe array itself\n")
