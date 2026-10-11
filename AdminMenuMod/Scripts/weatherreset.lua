--[[
    weatherreset.lua - puts the world's default weather back after the admin menu's
    Weather page has overridden it.

    Why this exists
    ---------------
    The game's admin menu has a Weather page. Its customize option works on the one
    weather volume that covers the whole world, and raises its priority to 99. That
    volume is saved with the game, so the override outlives the menu. Since Update 6
    "The Jump" made temperature matter, that is a real problem: a world wide 30 C at
    priority 99 beats the snow biome (priority 1, -40 C), and the cold regions stay warm
    for good. The game has no button to undo it.

    Weather volumes, read from the reflection dump:
        VoyageWeatherVolume   Radius, Priority, Multiplier, Modified, WeatherMask,
                              WeatherPreset, Climate, Wind
        VoyageWorldClimate    Temperature, MinTemp, MaxTemp, Precipitation, Thunder,
                              CloudCoverage, FogDensity
        VoyageWorldWind       Direction, SpeedInKm
    Around the player, the volume with the highest priority wins.

    What reset() does
    -----------------
    Ticking Customize on the Weather page swaps the volume's preset to
    DA_WeatherPreset_Cheat_Default and sets priority 99. Unticking it restores the preset
    but leaves 99. reset() handles both states.

    It finds the world volume - level placed, preset DA_WeatherPreset_Default or
    DA_WeatherPreset_Cheat_Default, radius above 1e8, and exactly one of them. It looks up
    the game's already loaded default preset first (and changes nothing if it is missing),
    then sets:
        Priority     -1   the admin menu's own DefaultPriority, below every regional
                          volume (those run from 0.1 to 2)
        Multiplier    1
        WeatherPreset the default preset object, if the volume has another one
        WeatherMask, Climate and Wind copied from the default preset
        Modified     true, last: the flag that gets the values written to the save
    Then it removes the menu's preset override actors (BP_WeatherVolumeActor_C). Those
    are plain actors without a persistence component; they live for the session only
    and are never saved.

    It never calls WeatherVolumeActor_C:ForceUpdate - on this volume that runs the
    weather curve and drops Multiplier to 0. It touches no other volume, and it loads
    nothing: every object it needs is already alive in the world.

    Offline tests: tools/test_weatherreset.py
--]]

local M = {}

local VOLUME_CLASS = "VoyageWeatherVolume"
local OVERRIDE_CLASS = "BP_WeatherVolumeActor_C"
local DEFAULT_PRESET = "DA_WeatherPreset_Default"
local CHEAT_PRESET = "DA_WeatherPreset_Cheat_Default"
local PRESET_CLASS = "VoyageWeatherPreset"
local WORLD_RADIUS = 1e8
local DEFAULT_PRIORITY = -1.0
local DEFAULT_MULTIPLIER = 1.0
local CLIMATE_FIELDS = {
    "Temperature", "MinTemp", "MaxTemp", "Precipitation", "Thunder", "CloudCoverage",
    "FogDensity",
}
local WIND_FIELDS = { "Direction", "SpeedInKm" }

local function log(msg)
    print("[AdminMenu] " .. msg .. "\n")
end

-- Marks a risky call in the log before it runs. A native fault leaves no Lua error,
-- and the last step line is then the only trace.
local function step(what)
    log("[step] " .. what)
end

-- UE4SS hands back a TrivialObject, not nil, for a member that does not exist, and
-- calling IsValid on one throws. So the call has to be attempted, not tested for.
local function isValid(o)
    if o == nil then
        return false
    end
    local ok, res = pcall(function() return o:IsValid() end)
    return ok and res == true
end

local function fullNameOf(o)
    local ok, name = pcall(function() return o:GetFullName() end)
    return ok and tostring(name) or "?"
end

local function shortNameOf(o)
    return fullNameOf(o):match("([^.:]+)$") or "?"
end

-- FindAllOf also returns archetypes, the templates inside a blueprint class. They are
-- not live objects and must not be touched. Their names give them away.
local function isTemplate(full)
    return full:find("Default__", 1, true) ~= nil
        or full:find("_GEN_VARIABLE", 1, true) ~= nil
        or full:find(":WidgetTree", 1, true) ~= nil
end

-- World partition names every actor placed in the editor with _UAID_ in it. Actors
-- spawned while playing get a plain numbered name instead.
local function isLevelPlaced(actor)
    return shortNameOf(actor):find("_UAID_", 1, true) ~= nil
end

local function isWorldVolume(volume)
    if not isValid(volume) or isTemplate(fullNameOf(volume)) then
        return false
    end
    local owner = volume:GetOwner()
    if not isValid(owner) or not isLevelPlaced(owner) then
        return false
    end
    local preset = volume.WeatherPreset
    if not isValid(preset) then
        return false
    end
    local presetName = shortNameOf(preset)
    if presetName ~= DEFAULT_PRESET and presetName ~= CHEAT_PRESET then
        return false
    end
    local radius = volume.Radius
    return type(radius) == "number" and radius > WORLD_RADIUS
end

-- Returns the world volume, or nil and the reason.
local function findWorldVolume()
    local found = FindAllOf(VOLUME_CLASS) or {}
    local candidates = {}
    for _, volume in ipairs(found) do
        local ok, isWorld = pcall(isWorldVolume, volume)
        if not ok then
            log("  ! skipped a weather volume: " .. tostring(isWorld))
        elseif isWorld then
            candidates[#candidates + 1] = volume
        end
    end
    if #candidates ~= 1 then
        return nil, string.format("expected one world weather volume, found %d among %d",
            #candidates, #found)
    end
    return candidates[1]
end

local function same(a, b)
    return type(a) == "number" and type(b) == "number" and math.abs(a - b) < 0.001
end

-- Returns true when every wanted field reads back. Otherwise false, the first field that
-- did not, and why: what it read back, or the read error.
local function readsBack(volume, prop, wanted)
    for field, value in pairs(wanted) do
        local ok, now = pcall(function() return volume[prop][field] end)
        if not ok then
            return false, field, "read error: " .. tostring(now)
        end
        if not same(now, value) then
            return false, field, "read back " .. tostring(now)
        end
    end
    return true
end

-- One compact line of a struct's values, for the log. Never throws.
local function describeStruct(volume, prop, fields)
    local ok, text = pcall(function()
        local struct = volume[prop]
        local parts = {}
        for _, field in ipairs(fields) do
            parts[#parts + 1] = field .. "=" .. tostring(struct[field])
        end
        return table.concat(parts, " ")
    end)
    if ok then
        return text
    end
    return "unreadable (" .. tostring(text) .. ")"
end

-- Copies the named number fields of one struct property from the preset onto the
-- volume. Field by field first; if the values do not read back - which is what happens
-- when the property comes back as a copy - the whole struct is assigned as a table.
local function copyStruct(volume, preset, prop, fields)
    local wanted = {}
    for _, field in ipairs(fields) do
        local value = preset[prop][field]
        if type(value) ~= "number" then
            error("preset " .. prop .. "." .. field .. " is not a number")
        end
        wanted[field] = value
    end

    log("  " .. prop .. " before: " .. describeStruct(volume, prop, fields))
    step("copy " .. prop .. " field by field")
    local ok, err = pcall(function()
        local target = volume[prop]
        for field, value in pairs(wanted) do
            target[field] = value
        end
    end)
    if not ok then
        log("  ! field by field failed: " .. tostring(err))
    end
    local taken, badField, detail = readsBack(volume, prop, wanted)
    if taken then
        log("  " .. prop .. " now: " .. describeStruct(volume, prop, fields))
        return
    end
    log("  ! " .. prop .. " field by field did not take (" .. badField .. " " .. detail .. ")")

    step("copy " .. prop .. " as a whole struct")
    ok, err = pcall(function() volume[prop] = wanted end)
    if not ok then
        log("  ! whole struct failed: " .. tostring(err))
    end
    taken, badField, detail = readsBack(volume, prop, wanted)
    if not taken then
        error(prop .. " did not take the preset values (" .. badField .. " " .. detail .. ")")
    end
    log("  " .. prop .. " now: " .. describeStruct(volume, prop, fields))
end

local function setNumber(volume, field, value)
    local readOk, before = pcall(function() return volume[field] end)
    if not readOk then
        before = "unreadable (" .. tostring(before) .. ")"
    end
    step(field .. " " .. tostring(before) .. " -> " .. tostring(value))
    volume[field] = value
    local now = volume[field]
    log("  now " .. field .. " " .. tostring(now))
    if not same(now, value) then
        error(field .. " reads back as " .. tostring(now))
    end
end

-- The game's default preset object: the volume's own when it still has it, otherwise a
-- loaded one found by name. FindAllOf only looks up objects that are already alive.
-- Returns nil when there is none.
local function findDefaultPreset(volume)
    local current = volume.WeatherPreset
    if isValid(current) and shortNameOf(current) == DEFAULT_PRESET then
        return current
    end
    for _, preset in ipairs(FindAllOf(PRESET_CLASS) or {}) do
        if isValid(preset) and not isTemplate(fullNameOf(preset))
            and shortNameOf(preset) == DEFAULT_PRESET then
            return preset
        end
    end
    return nil
end

local function resetVolume(volume, defaultPreset)
    local problems = {}
    local function attempt(what, fn)
        local ok, err = pcall(fn)
        if not ok then
            problems[#problems + 1] = what .. ": " .. tostring(err)
            log("  ! " .. what .. ": " .. tostring(err))
        end
        return ok
    end

    -- Priority first. It alone is what keeps the cold regions warm, so if it will not
    -- take, nothing else is worth writing.
    if not attempt("Priority", function() setNumber(volume, "Priority", DEFAULT_PRIORITY) end) then
        return false, "could not set the weather priority - see UE4SS.log"
    end
    attempt("Multiplier", function() setNumber(volume, "Multiplier", DEFAULT_MULTIPLIER) end)

    -- Customize swaps the preset object; put the default one back, then copy from it.
    attempt("WeatherPreset", function()
        local current = volume.WeatherPreset
        if isValid(current) and shortNameOf(current) == DEFAULT_PRESET then
            return
        end
        step("WeatherPreset " .. (isValid(current) and shortNameOf(current) or "?")
            .. " -> " .. DEFAULT_PRESET)
        volume.WeatherPreset = defaultPreset
        local now = volume.WeatherPreset
        if not isValid(now) or shortNameOf(now) ~= DEFAULT_PRESET then
            error("WeatherPreset reads back as " .. (isValid(now) and shortNameOf(now) or "?"))
        end
    end)

    local preset = defaultPreset
    attempt("WeatherMask", function()
        if type(preset.WeatherMask) ~= "number" then
            error("preset WeatherMask is not a number")
        end
        setNumber(volume, "WeatherMask", preset.WeatherMask)
    end)
    attempt("Climate", function() copyStruct(volume, preset, "Climate", CLIMATE_FIELDS) end)
    attempt("Wind", function() copyStruct(volume, preset, "Wind", WIND_FIELDS) end)

    -- Last, so the next save writes everything above.
    attempt("Modified", function()
        step("Modified -> true")
        volume.Modified = true
        local now = volume.Modified
        if now ~= true then
            error("Modified reads back as " .. tostring(now))
        end
    end)

    if #problems > 0 then
        return false, "weather partly reset - " .. table.concat(problems, "; ")
    end
    return true, "world weather is back to the game's default - save the game to keep it"
end

-- The admin menu's preset buttons put a BP_WeatherVolumeActor_C in the world. It has no
-- persistence component, so it only lives until the game is closed - but until then it
-- keeps overriding the weather.
local function removeOverrides()
    local removed = 0
    for _, actor in ipairs(FindAllOf(OVERRIDE_CLASS) or {}) do
        if isValid(actor) and fullNameOf(actor) == "?" then
            log("  ! skipped an override whose name could not be read")
        elseif isValid(actor) and isLevelPlaced(actor) then
            log("  skipped level placed " .. fullNameOf(actor))
        elseif isValid(actor) and not isTemplate(fullNameOf(actor)) then
            step("K2_DestroyActor " .. fullNameOf(actor))
            local ok, err = pcall(function() actor:K2_DestroyActor() end)
            if ok then
                removed = removed + 1
            else
                log("  ! could not remove " .. fullNameOf(actor) .. ": " .. tostring(err))
            end
        end
    end
    return removed
end

-- Returns ok, message. Never throws.
function M.reset()
    local ok, done, message = pcall(function()
        local volume, why = findWorldVolume()
        if volume == nil then
            return false, why
        end
        local defaultPreset = findDefaultPreset(volume)
        if defaultPreset == nil then
            return false, "could not find the game's default weather preset - untick "
                .. "Customize on the Weather page, then press again"
        end
        log("default preset " .. fullNameOf(defaultPreset))
        log("resetting " .. fullNameOf(volume))
        local resetOk, msg = resetVolume(volume, defaultPreset)
        local removed = removeOverrides()
        if removed > 0 then
            msg = msg .. string.format(" (removed %d preset override%s)",
                removed, removed == 1 and "" or "s")
        end
        return resetOk, msg
    end)
    if not ok then
        return false, "weather reset failed: " .. tostring(done)
    end
    return done, message
end

return M
