--[[
    weather.lua - developer tool. Finds weather overrides left behind by the admin menu.

    Not part of the release. main.lua loads it with pcall, so its absence is normal.

    Why this exists
    ---------------
    The game's own admin menu has a Weather page. Its presets and its "customize"
    sliders work through weather volumes - capsules in the world, each with a climate,
    a priority and a radius. The highest priority volume around the player wins.

    The volume class the customize widget works on, WeatherVolumeActor_C, carries a
    VoyagePersistentActorComponent and has OnCustomDataSave, so whatever the menu did
    to it goes into the save file. A warm override can then follow a save into an area
    that should be cold, and the game has no button to undo it.

    Classes read from the JMAP dump:
        VoyageWeatherVolume (SceneComponent)
            Radius, Height, InterpolationRange, WeatherPreset, WeatherMask,
            Climate (VoyageWorldClimate), Wind, Priority, Multiplier, Modified
        VoyageWeatherPreset: WeatherMask, Climate, Wind
        VoyageWorldClimate:  MaxTemp, MinTemp, Temperature, Precipitation, Thunder,
                             CloudCoverage, FogDensity
        BP_VoyageCheatWiget_C.CheatWeatherVolumeActor   -> BP_WeatherVolumeActor_C
        BP_VoyageCheat_WeatherAdjustWidget_C.WeatherVolumeActor -> WeatherVolumeActor_C

    Only hard references are read. WaveProperties and the dynamic spawner's
    SpawnedWeatherVolumes are soft references or arrays of them and are left alone.

    Usage, in the console:
        weatherscan              list every live weather volume, numbered
        weatherset N priority V            preview: set the priority of volume N
        weatherset N multiplier V confirm  do it (priority or multiplier)
        weatherprio N V [confirm]          shorthand for weatherset N priority V
        weatherkill N            preview: destroy the actor that owns volume N
        weatherkill N confirm    do it - refused for level placed actors
        weatherunmod N           preview: clear Modified on volume N and copy the
                                 climate, wind and mask back from its preset
        weatherunmod N confirm   do it

    The numbers come from the last weatherscan. Save the game afterwards for a change
    to stick, then load that save to check it held.
--]]

local UEHelpers = require("UEHelpers")

local VOLUME_CLASS = "VoyageWeatherVolume"
local SPAWNER_CLASS = "BP_DynamicWeatherSpawner_C"
local SUBSYSTEM_CLASSES = { "BP_VoyageWeatherSubsystem_C", "VoyageWeatherSubsystem" }
local CLIMATE_FIELDS = {
    "Temperature", "MinTemp", "MaxTemp", "Precipitation", "Thunder", "CloudCoverage",
    "FogDensity",
}
local WIND_FIELDS = { "Direction", "SpeedInKm" }

-- Volumes from the last weatherscan, so kill and unmod address the same numbers.
local lastScan = {}

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

-- Reads one value and says why when it cannot. Never a silent pcall.
local function read(Ar, what, fn)
    local ok, value = pcall(fn)
    if not ok then
        out(Ar, "  ! could not read " .. what .. ": " .. tostring(value))
        return nil
    end
    return value
end

local function fullNameOf(o)
    local ok, name = pcall(function() return o:GetFullName() end)
    return ok and name or "?"
end

-- Short object name: the last path segment of the full name.
local function shortNameOf(o)
    return fullNameOf(o):match("([^.:]+)$") or "?"
end

local function className(o)
    local ok, name = pcall(function() return o:GetClass():GetFName():ToString() end)
    return ok and tostring(name) or "?"
end

local function num(v)
    if type(v) == "number" then
        return string.format("%.1f", v)
    end
    return tostring(v)
end

local function axis(vector, key)
    local ok, v = pcall(function() return vector[key] end)
    return ok and type(v) == "number" and v or nil
end

local function climateText(Ar, climate)
    if climate == nil then
        return "?"
    end
    local parts = {}
    for _, field in ipairs(CLIMATE_FIELDS) do
        local value = read(Ar, "Climate." .. field, function() return climate[field] end)
        parts[#parts + 1] = field .. "=" .. num(value)
    end
    return table.concat(parts, " ")
end

-- Archetypes are templates inside a blueprint class, not live objects. Their names
-- give them away; touching them is how the menu scanner once crashed the game.
local function isTemplate(full)
    return full:find("Default__", 1, true) ~= nil
        or full:find("_GEN_VARIABLE", 1, true) ~= nil
        or full:find(":WidgetTree", 1, true) ~= nil
end

-- World partition gives every actor placed in the editor a name with _UAID_ in it.
-- Actors spawned while playing get a plain numbered name instead.
local function isLevelPlaced(actor)
    return shortNameOf(actor):find("_UAID_", 1, true) ~= nil
end

local function playerLocation()
    local pawn
    pcall(function() pawn = UEHelpers.GetPlayer() end)
    if not isValid(pawn) then
        return nil
    end
    local ok, location = pcall(function() return pawn:K2_GetActorLocation() end)
    return ok and location or nil
end

local function liveVolumes(Ar)
    local found = FindAllOf(VOLUME_CLASS) or {}
    local live = {}
    for _, volume in ipairs(found) do
        local full = fullNameOf(volume)
        if isValid(volume) and not isTemplate(full) then
            live[#live + 1] = volume
        end
    end
    out(Ar, string.format("FindAllOf(%s): %d objects, %d live", VOLUME_CLASS, #found, #live))
    return live
end

local function describeSubsystem(Ar)
    for _, cls in ipairs(SUBSYSTEM_CLASSES) do
        local subsystem
        pcall(function() subsystem = FindFirstOf(cls) end)
        if isValid(subsystem) then
            out(Ar, "subsystem " .. fullNameOf(subsystem))
            local current = read(Ar, "CurrentClimate", function() return subsystem.CurrentClimate end)
            out(Ar, "  CurrentClimate:       " .. climateText(Ar, current))
            local state = read(Ar, "CurrentWorldState", function() return subsystem.CurrentWorldState end)
            if state ~= nil then
                local climate = read(Ar, "CurrentWorldState.Climate", function() return state.Climate end)
                out(Ar, "  CurrentWorldState:    " .. climateText(Ar, climate))
            end
            return
        end
    end
    out(Ar, "no weather subsystem found")
end

local function describeVolume(Ar, index, volume, player)
    local owner = read(Ar, "GetOwner", function() return volume:GetOwner() end)
    local ownerOk = isValid(owner)

    out(Ar, string.format("[%d] %s", index, fullNameOf(volume)))
    if ownerOk then
        out(Ar, string.format("     owner %s (%s)  %s", shortNameOf(owner), className(owner),
            isLevelPlaced(owner) and "level placed" or "SPAWNED AT RUNTIME"))
    else
        out(Ar, "     no owner")
    end

    local location = read(Ar, "K2_GetComponentLocation", function()
        return volume:K2_GetComponentLocation()
    end)
    local radius = read(Ar, "Radius", function() return volume.Radius end)
    local height = read(Ar, "Height", function() return volume.Height end)
    local blend = read(Ar, "InterpolationRange", function() return volume.InterpolationRange end)

    local where = "?"
    local x, y, z = axis(location, "X"), axis(location, "Y"), axis(location, "Z")
    if x ~= nil then
        where = string.format("%.0f, %.0f, %.0f", x, y, z)
        local px, py = axis(player, "X"), axis(player, "Y")
        if px ~= nil and type(radius) == "number" then
            local distance = math.sqrt((px - x) ^ 2 + (py - y) ^ 2)
            local reach = radius + (type(blend) == "number" and blend or 0)
            where = where .. string.format("  distance to player %.0f%s", distance,
                distance <= reach and "  << COVERS PLAYER" or "")
        end
    end
    out(Ar, "     at " .. where)
    out(Ar, string.format("     radius %s  height %s  blend %s", num(radius), num(height), num(blend)))

    local priority = read(Ar, "Priority", function() return volume.Priority end)
    local multiplier = read(Ar, "Multiplier", function() return volume.Multiplier end)
    local modified = read(Ar, "Modified", function() return volume.Modified end)
    local mask = read(Ar, "WeatherMask", function() return volume.WeatherMask end)
    out(Ar, string.format("     priority %s  multiplier %s  mask %s  Modified %s",
        num(priority), num(multiplier), tostring(mask), tostring(modified)))

    local climate = read(Ar, "Climate", function() return volume.Climate end)
    out(Ar, "     climate " .. climateText(Ar, climate))

    local preset = read(Ar, "WeatherPreset", function() return volume.WeatherPreset end)
    if isValid(preset) then
        local presetClimate = read(Ar, "WeatherPreset.Climate", function() return preset.Climate end)
        local presetMask = read(Ar, "WeatherPreset.WeatherMask", function() return preset.WeatherMask end)
        out(Ar, "     preset " .. shortNameOf(preset) .. "  mask " .. tostring(presetMask))
        out(Ar, "     preset climate " .. climateText(Ar, presetClimate))
    else
        out(Ar, "     no preset")
    end

    if ownerOk then
        local persistent = nil
        pcall(function() persistent = owner.VoyagePersistentActor end)
        if isValid(persistent) then
            local id = read(Ar, "PersistentUniqueId", function() return persistent.PersistentUniqueId end)
            local rid = read(Ar, "PersistentUniqueIdRuntime", function()
                return persistent.PersistentUniqueIdRuntime
            end)
            out(Ar, string.format("     persistent id %s  runtime id %s", tostring(id), tostring(rid)))
        end
        if className(owner) == "WeatherVolumeActor_C" then
            local dynamic = read(Ar, "Dynamic", function() return owner.Dynamic end)
            local curve = read(Ar, "CurveMultiplier", function() return owner.CurveMultiplier end)
            out(Ar, string.format("     dynamic %s  curve multiplier %s", tostring(dynamic), num(curve)))
        end
    end
end

local function describeSpawners(Ar)
    local found = FindAllOf(SPAWNER_CLASS) or {}
    for _, spawner in ipairs(found) do
        local full = fullNameOf(spawner)
        if isValid(spawner) and not isTemplate(full) then
            local priority = read(Ar, "spawner Priority", function() return spawner.Priority end)
            local maxActive = read(Ar, "spawner MaxActive", function() return spawner.MaxActive end)
            out(Ar, string.format("spawner %s  priority %s  max active %s",
                shortNameOf(spawner), num(priority), tostring(maxActive)))
        end
    end
end

RegisterConsoleCommandHandler("weatherscan", function(FullCommand, Parameters, Ar)
    local ok, err = pcall(function()
        local player = playerLocation()
        if player ~= nil then
            out(Ar, string.format("player at %.0f, %.0f, %.0f",
                axis(player, "X") or 0, axis(player, "Y") or 0, axis(player, "Z") or 0))
        else
            out(Ar, "no player location - load a save first")
        end

        describeSubsystem(Ar)
        lastScan = liveVolumes(Ar)
        for index, volume in ipairs(lastScan) do
            describeVolume(Ar, index, volume, player)
        end
        describeSpawners(Ar)
        out(Ar, "weatherscan done - " .. #lastScan .. " volumes")
    end)
    if not ok then
        print("[AdminMenu] ERROR in weatherscan: " .. tostring(err) .. "\n")
    end
    return true
end)

-- Returns the volume numbered N in the last scan, or nil with the reason logged.
local function pickVolume(Ar, Parameters)
    local index = Parameters ~= nil and tonumber(Parameters[1]) or nil
    if index == nil then
        out(Ar, "give a number from weatherscan")
        return nil
    end
    local volume = lastScan[index]
    if not isValid(volume) then
        out(Ar, "no live volume " .. index .. " - run weatherscan again")
        return nil
    end
    return volume
end

local function confirmed(Parameters)
    return Parameters ~= nil and Parameters[2] ~= nil and Parameters[2]:lower() == "confirm"
end

RegisterConsoleCommandHandler("weatherkill", function(FullCommand, Parameters, Ar)
    local ok, err = pcall(function()
        local volume = pickVolume(Ar, Parameters)
        if volume == nil then
            return
        end
        local owner = read(Ar, "GetOwner", function() return volume:GetOwner() end)
        if not isValid(owner) then
            out(Ar, "volume has no owner actor to destroy")
            return
        end
        -- Destroying a level placed actor would be stored as destroyed in the save and
        -- take a piece of the map's weather with it for good. Only runtime spawns go.
        if isLevelPlaced(owner) then
            out(Ar, "refused: " .. shortNameOf(owner) .. " is level placed - use weatherunmod")
            return
        end
        if not confirmed(Parameters) then
            out(Ar, "preview: would destroy " .. fullNameOf(owner))
            out(Ar, "run 'weatherkill " .. Parameters[1] .. " confirm' to do it")
            return
        end
        out(Ar, "[step] K2_DestroyActor " .. fullNameOf(owner))
        owner:K2_DestroyActor()
        lastScan[tonumber(Parameters[1])] = nil
        out(Ar, "destroyed - save the game for it to stick")
    end)
    if not ok then
        print("[AdminMenu] ERROR in weatherkill: " .. tostring(err) .. "\n")
    end
    return true
end)

-- Copies the named float fields from one struct to another and reads them back.
local function copyFields(Ar, label, from, to, fields)
    for _, field in ipairs(fields) do
        local value = read(Ar, label .. "." .. field, function() return from[field] end)
        if type(value) == "number" then
            local ok, err = pcall(function() to[field] = value end)
            if not ok then
                out(Ar, "  ! could not write " .. label .. "." .. field .. ": " .. tostring(err))
            end
        end
    end
end

RegisterConsoleCommandHandler("weatherunmod", function(FullCommand, Parameters, Ar)
    local ok, err = pcall(function()
        local volume = pickVolume(Ar, Parameters)
        if volume == nil then
            return
        end
        local preset = read(Ar, "WeatherPreset", function() return volume.WeatherPreset end)
        local hasPreset = isValid(preset)

        if not confirmed(Parameters) then
            out(Ar, "preview: would set Modified = false on " .. fullNameOf(volume))
            if hasPreset then
                out(Ar, "and copy climate, wind and mask back from " .. shortNameOf(preset))
            else
                out(Ar, "it has no preset, so the climate is left as it is")
            end
            out(Ar, "run 'weatherunmod " .. Parameters[1] .. " confirm' to do it")
            return
        end

        out(Ar, "[step] restoring " .. fullNameOf(volume))
        if hasPreset then
            local fromClimate = read(Ar, "preset Climate", function() return preset.Climate end)
            local toClimate = read(Ar, "volume Climate", function() return volume.Climate end)
            if fromClimate ~= nil and toClimate ~= nil then
                copyFields(Ar, "Climate", fromClimate, toClimate, CLIMATE_FIELDS)
            end
            local fromWind = read(Ar, "preset Wind", function() return preset.Wind end)
            local toWind = read(Ar, "volume Wind", function() return volume.Wind end)
            if fromWind ~= nil and toWind ~= nil then
                copyFields(Ar, "Wind", fromWind, toWind, WIND_FIELDS)
            end
            local mask = read(Ar, "preset WeatherMask", function() return preset.WeatherMask end)
            if type(mask) == "number" then
                volume.WeatherMask = mask
            end
        end
        volume.Modified = false

        local climate = read(Ar, "Climate", function() return volume.Climate end)
        out(Ar, "  now climate " .. climateText(Ar, climate))
        out(Ar, "  Modified " .. tostring(read(Ar, "Modified", function() return volume.Modified end)))
        out(Ar, "done - save the game for it to stick")
    end)
    if not ok then
        print("[AdminMenu] ERROR in weatherunmod: " .. tostring(err) .. "\n")
    end
    return true
end)

--[[ weatherprio ------------------------------------------------------------------------

    What the first real scan found, Update 6, 2026-10-11, standing in The Jump:

        [1] WeatherVolume_C_UAID_005056C0... at 0,0,0  radius 1e10  priority 99
            preset DA_WeatherPreset_Default, 30 C, mask 255, Modified false
        [2] WeatherVolume_C_UAID_C87F5407... snow biome, radius 4.5e6, priority 1
            preset DA_WeatherPreset_Snow_Biome_Default, -40 C

    Both cover the player and the higher priority wins, so the world wide default beat
    the snow biome and The Jump stayed at 30 C. A base layer has to sit below every
    regional volume (they run 0.1 to 2), and the admin menu's customize widget ships
    with DefaultPriority = -1. The 99 was the widget's override, saved with the game.
    Climate and mask still matched the preset, so priority was the only thing wrong.

    Setting Priority to -1 turned The Jump cold at once (CurrentClimate -40 C).

    Do NOT call WeatherVolumeActor_C:ForceUpdate here. The first version did, and on
    this non-dynamic volume it dropped Multiplier from 1.0 to 0.0 - it runs the
    weather curve, and a volume without one comes out at zero. It also set Modified
    to true. Modified looks like the "changed, write me to the save" flag: the 99
    survived reloads although the scan showed Modified false, so the flag is not
    stored, only the values it lets through. weatherset therefore sets it to true
    itself, so the new value is written on the next save.
--]]
local SETTABLE = { priority = "Priority", multiplier = "Multiplier" }

local function setField(Ar, volume, field, value)
    local before = read(Ar, field, function() return volume[field] end)
    out(Ar, "[step] " .. field .. " " .. num(before) .. " -> " .. num(value))
    volume[field] = value
    volume.Modified = true
    out(Ar, string.format("  now %s %s  Modified %s", field,
        num(read(Ar, field, function() return volume[field] end)),
        tostring(read(Ar, "Modified", function() return volume.Modified end))))
end

RegisterConsoleCommandHandler("weatherset", function(FullCommand, Parameters, Ar)
    local ok, err = pcall(function()
        local volume = pickVolume(Ar, Parameters)
        if volume == nil then
            return
        end
        local field = Parameters[2] ~= nil and SETTABLE[Parameters[2]:lower()] or nil
        local value = Parameters[3] ~= nil and tonumber(Parameters[3]) or nil
        if field == nil or value == nil then
            out(Ar, "usage: weatherset N priority|multiplier value [confirm]")
            return
        end
        if Parameters[4] == nil or Parameters[4]:lower() ~= "confirm" then
            local before = read(Ar, field, function() return volume[field] end)
            out(Ar, string.format("preview: would change %s %s -> %s on %s",
                field, num(before), num(value), fullNameOf(volume)))
            out(Ar, string.format("run 'weatherset %s %s %s confirm' to do it",
                Parameters[1], Parameters[2], Parameters[3]))
            return
        end
        setField(Ar, volume, field, value)
        out(Ar, "done - run weatherscan to check, then save the game for it to stick")
    end)
    if not ok then
        print("[AdminMenu] ERROR in weatherset: " .. tostring(err) .. "\n")
    end
    return true
end)

-- Shorthand kept from the first version: weatherprio N V [confirm].
RegisterConsoleCommandHandler("weatherprio", function(FullCommand, Parameters, Ar)
    local ok, err = pcall(function()
        local volume = pickVolume(Ar, Parameters)
        if volume == nil then
            return
        end
        local value = Parameters[2] ~= nil and tonumber(Parameters[2]) or nil
        if value == nil then
            out(Ar, "usage: weatherprio N value [confirm]")
            return
        end
        if Parameters[3] == nil or Parameters[3]:lower() ~= "confirm" then
            out(Ar, "preview: would change Priority " .. num(volume.Priority) .. " -> "
                .. num(value) .. " on " .. fullNameOf(volume))
            return
        end
        setField(Ar, volume, "Priority", value)
        out(Ar, "done - run weatherscan to check, then save the game for it to stick")
    end)
    if not ok then
        print("[AdminMenu] ERROR in weatherprio: " .. tostring(err) .. "\n")
    end
    return true
end)

print("[AdminMenu] weatherscan registered - lists weather volumes; weatherset / weatherprio / weatherkill / weatherunmod fix them\n")
