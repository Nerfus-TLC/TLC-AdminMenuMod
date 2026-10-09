--[[
    patterns.lua - developer tool. Lists the build and craft patterns the player has not
    unlocked yet.

    Not part of the release. main.lua loads it with pcall, so its absence is normal.

    The stats screen counts unlocked patterns (Build 143 / 156, Craft 323 / 368) but never
    says which ones are missing. The game does keep both lists:

        VoyageGameplayBlueprintFunctionLibrary:GetAllPatterns(out OutPatterns)
        VoyageGameplayBlueprintFunctionLibrary:GetAllPlayerPatterns(InController, out OutPatterns)

    Both fill a TArray<VoyageItem*>. Those are hard object references, which UE4SS reads
    fine. GetAllPatterns holds all 368 patterns - the stats screen's craft total. The build
    total is the subset where IsBuildable() is true: that is exactly what the game's own
    BP_VaultInfoLogic_BuildPatterns:GetVaultInfo does with these two lists.

    Per item only these are touched:

        Name                    TextProperty   (from VoyageBaseDataAsset)
        GetIdentifierString()   -> FString
        IsBuildable()           -> bool
        IsCraftable()           -> bool
        IsScannable             BoolProperty
        ScanLevelRequirement    IntProperty
        bUnlockAsBuildable      BoolProperty

    Never DroppedMesh or DroppedActor: those are soft references, and reading one kills
    the game in this UE4SS build.

    Usage, in the console:
        patterns            missing build and craft patterns, with totals
        patterns build      only the missing build patterns
        patterns craft      only the missing craft patterns

    Every pattern, unlocked or not, is also written to patterns.txt in this mod's folder.
--]]

local UEHelpers = require("UEHelpers")

local LIB_CDO = "/Script/Voyage.Default__VoyageGameplayBlueprintFunctionLibrary"
local REPORT_FILE = "ue4ss/Mods/AdminMenuMod/patterns.txt"

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

-- FString and FText both come back as userdata with ToString.
local function str(v)
    if v == nil then
        return nil
    end
    if type(v) == "string" then
        return v
    end
    local s
    if pcall(function() s = v:ToString() end) and s ~= nil then
        return tostring(s)
    end
    return tostring(v)
end

-- Array elements come back wrapped (a param object, not the UObject itself), so method
-- calls on them fail with "attempt to call a nil value". get() unwraps them. Tested
-- 2026-10-02: without this, every item read failed on all 368 patterns.
local function unwrap(v)
    local inner
    if type(v) == "userdata" and pcall(function() inner = v:get() end) and inner ~= nil then
        return inner
    end
    return v
end

-- Turns whatever UE4SS handed back into a plain Lua list of objects. Depending on the
-- version an out TArray comes back as the return value, written into the table that
-- was passed in, or under the parameter's name in that table, so all three are tried.
-- In this build it is the second: the return value is nil and the table holds the items.
local function listFrom(x)
    if x == nil then
        return nil
    end
    if type(x) == "table" then
        if x[1] ~= nil then
            local t = {}
            for _, v in ipairs(x) do
                t[#t + 1] = unwrap(v)
            end
            return t
        end
        if x.OutPatterns ~= nil then
            return listFrom(x.OutPatterns)
        end
        return nil
    end
    if type(x) == "userdata" then
        local n
        if pcall(function() n = x:GetArrayNum() end) and type(n) == "number" then
            local t = {}
            for i = 1, n do
                local v
                if pcall(function() v = x[i] end) and v ~= nil then
                    t[#t + 1] = unwrap(v)
                end
            end
            return t
        end
    end
    return nil
end

local function collect(Ar, what, call)
    local holder = {}
    local ret
    out(Ar, "[step] " .. what)
    local ok, err = pcall(function() ret = call(holder) end)
    if not ok then
        out(Ar, "ERROR in " .. what .. ": " .. tostring(err))
        return nil
    end
    local list = listFrom(ret) or listFrom(holder)
    out(Ar, string.format("[step] %s returned %s, holder[1] %s, holder.OutPatterns %s -> %s items",
        what, type(ret), type(holder[1]), type(holder.OutPatterns), list and #list or "no"))
    return list
end

-- Reads one item. Every failed read is counted and the first failure per field is
-- logged with its reason, so a field that never works cannot hide.
local function describe(Ar, item, first, failures)
    local d = {}
    local function read(key, fn)
        if first then
            out(Ar, "[step] item field " .. key)
        end
        local ok, err = pcall(function() d[key] = fn() end)
        if not ok then
            failures[key] = (failures[key] or 0) + 1
            if failures[key] == 1 then
                out(Ar, "reading " .. key .. " failed: " .. tostring(err))
            end
        end
    end
    read("path", function() return item:GetFullName() end)
    read("name", function() return str(item.Name) end)
    read("id", function() return str(item:GetIdentifierString()) end)
    read("build", function() return item:IsBuildable() end)
    read("craft", function() return item:IsCraftable() end)
    read("scan", function() return item.IsScannable end)
    read("scanLevel", function() return item.ScanLevelRequirement end)
    read("unlockAsBuild", function() return item.bUnlockAsBuildable end)
    return d
end

local function kindOf(d)
    if d.build == true and d.craft == true then
        return "BOTH "
    elseif d.build == true then
        return "BUILD"
    elseif d.craft == true then
        return "CRAFT"
    end
    return "OTHER"
end

local function line(d, mark)
    local scan = d.scan == true and ("scan lvl " .. tostring(d.scanLevel)) or "no scan"
    return string.format("%s %s  %-40s  %-12s  %s", mark, kindOf(d), tostring(d.name or "?"),
        scan, tostring(d.id or d.path or "?"))
end

RegisterConsoleCommandHandler("patterns", function(FullCommand, Parameters, Ar)
    local ok, err = pcall(function()
        local filter = Parameters ~= nil and Parameters[1] ~= nil and Parameters[1]:lower() or nil

        local lib = StaticFindObject(LIB_CDO)
        if not isValid(lib) then
            out(Ar, "VoyageGameplayBlueprintFunctionLibrary not found")
            return
        end
        local pc = UEHelpers.GetPlayerController()
        if not isValid(pc) then
            out(Ar, "no PlayerController - load a save first")
            return
        end

        local all = collect(Ar, "GetAllPatterns", function(h) return lib:GetAllPatterns(h) end)
        local mine = collect(Ar, "GetAllPlayerPatterns", function(h) return lib:GetAllPlayerPatterns(pc, h) end)
        if all == nil or mine == nil then
            out(Ar, "could not read the pattern lists - see the lines above")
            return
        end

        local failures = {}
        local unlocked = {}
        for i, item in ipairs(mine) do
            local path
            pcall(function() path = item:GetFullName() end)
            if path ~= nil then
                unlocked[path] = true
            elseif i == 1 then
                out(Ar, "could not read the full name of an unlocked pattern")
            end
        end

        local rows = {}
        local totals = { BUILD = { 0, 0 }, CRAFT = { 0, 0 }, ["BOTH "] = { 0, 0 }, OTHER = { 0, 0 } }
        for i, item in ipairs(all) do
            local d = describe(Ar, item, i == 1, failures)
            d.unlocked = d.path ~= nil and unlocked[d.path] == true
            local k = kindOf(d)
            totals[k][1] = totals[k][1] + 1
            if d.unlocked then
                totals[k][2] = totals[k][2] + 1
            end
            rows[#rows + 1] = d
        end
        table.sort(rows, function(a, b)
            if kindOf(a) ~= kindOf(b) then
                return kindOf(a) < kindOf(b)
            end
            return tostring(a.name) < tostring(b.name)
        end)

        out(Ar, string.format("%d patterns in the game, %d unlocked by this player", #all, #mine))
        for _, k in ipairs({ "BUILD", "CRAFT", "BOTH ", "OTHER" }) do
            out(Ar, string.format("  %s  %d / %d unlocked", k, totals[k][2], totals[k][1]))
        end
        for key, n in pairs(failures) do
            out(Ar, string.format("  field %s could not be read on %d items", key, n))
        end

        local shown = 0
        for _, d in ipairs(rows) do
            local k = kindOf(d)
            local wanted = filter == nil
                or (filter == "build" and (k == "BUILD" or k == "BOTH "))
                or (filter == "craft" and (k == "CRAFT" or k == "BOTH "))
            if not d.unlocked and wanted then
                out(Ar, line(d, "MISSING"))
                shown = shown + 1
            end
        end
        out(Ar, shown .. " missing shown")

        local f, ferr = io.open(REPORT_FILE, "w")
        if f == nil then
            out(Ar, "could not write " .. REPORT_FILE .. ": " .. tostring(ferr))
            return
        end
        for _, d in ipairs(rows) do
            f:write(line(d, d.unlocked and "have   " or "MISSING"), "\t", tostring(d.path), "\n")
        end
        f:close()
        out(Ar, "full list written to " .. REPORT_FILE)
    end)
    if not ok then
        print("[AdminMenu] ERROR in patterns: " .. tostring(err) .. "\n")
    end
    return true
end)

print("[AdminMenu] patterns registered - type 'patterns' in the game console\n")
