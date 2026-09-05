--[[
    catalog.lua - what the mod adds to the menu, and how it gets built.

    The mod adds one button: Bulk Battery. The game already has the recipe for it and
    simply never got a cheat button, so the button is all that was missing.

    How it builds things
    --------------------
    Not by spawning the module actor. That was the first design and it was wrong: a
    module spawned straight from its class comes out half initialised. The battery gauge
    read 50% on a battery that was actually empty, and BP_Module_Petrol_ExtraLarge killed
    the game inside FinishSpawningActor - the module's own BeginPlay, not our code.

    The game's own buttons put down a BP_Module_Crafter and let it build the module
    through SpawnActorForItem with a full VoyageItemData. That is the pipeline this mod
    uses too, and everything comes with it for free: the build animation, correct
    initialisation, correct placement on the ground.

    Every route into that pipeline goes through a soft reference, which is what UE4SS
    crashes on in this build - except one:

        BP_Module_Crafter_C:StartCrafting(Object)

    Object is a ByteProperty over the enum CraftableObjectList, and a byte is a type
    UE4SS handles without complaint.

    The byte is looked up by name rather than hardcoded. The enum and the recipe array
    are ordered differently - the enum has Methane at 9 where the array has Oxygen -
    which proves StartCrafting resolves by name, and means a patch can renumber the enum
    without this mod quietly building the wrong thing.

    Why only one button
    -------------------
    The same patch added Bulk Petrol Tank and Bulk Diesel Tank. Neither is in the enum
    (66 entries) or in the recipe array (57), and no VoyageItem asset for them is
    reachable. The only way to place those is the raw actor spawn described above, and a
    mod that can crash the game is worse than a mod that does less. They are left out
    deliberately.

    Signatures, all read from a JMAP dump of the running game:

        KismetNodeHelperLibrary:GetEnumeratorUserFriendlyName(Enum, Value) -> FString
        BP_VoyageCheat_Button:GetGroundSpawnLocation(
            Distance, TraceComplex, out Location, out Rotation)   four, out params included
        KismetMathLibrary:Conv_DoubleToVector(InDouble)            -> Vector
        KismetMathLibrary:MakeRotator(Roll, pitch, Yaw)            -> Rotator
        KismetMathLibrary:MakeTransform(Location, Rotation, Scale) -> Transform
        KismetMathLibrary:Multiply_VectorVector(A, B)              -> Vector
        KismetMathLibrary:Add_VectorVector(A, B)                   -> Vector
        Controller:K2_GetPawn()                                    -> Pawn
        Actor:K2_GetActorLocation() / K2_GetActorRotation() / GetActorForwardVector()
        GameplayStatics:BeginDeferredActorSpawnFromClass(
            WorldContextObject, ActorClass, SpawnTransform,
            CollisionHandlingOverride, Owner, TransformScaleMethod) -> Actor
        GameplayStatics:FinishSpawningActor(Actor, SpawnTransform, TransformScaleMethod)

    ActorClass is a ClassProperty - a hard class pointer - so it can be passed straight
    in. That is the one door in this whole system that is not soft.
--]]

local UEHelpers = require("UEHelpers")

local CRAFTER_CLASS = "/Game/Blueprints/Tests/Eric/BP_Module_Crafter.BP_Module_Crafter_C"
local CRAFTER_PACKAGE = "/Game/Blueprints/Tests/Eric/BP_Module_Crafter"
local ENUM_PATH = "/Game/Blueprints/Tests/Eric/CraftableObjectList.CraftableObjectList"
local NODE_HELPER_CDO = "/Script/Engine.Default__KismetNodeHelperLibrary"
local CDO_KISMET = "/Script/Engine.Default__KismetMathLibrary"
local CDO_GAMEPLAY = "/Script/Engine.Default__GameplayStatics"

-- How far in front of the player the ground trace reaches, in centimetres.
local SPAWN_DISTANCE = 300.0

-- ESpawnActorCollisionHandlingMethod::AlwaysSpawn
local COLLISION_ALWAYS_SPAWN = 1
-- ESpawnActorScaleMethod::MultiplyWithRoot - keeps the blueprint's own root scale.
local SCALE_MULTIPLY_WITH_ROOT = 1

-- 66 in this build. A few spare cost nothing: unused values simply have no name.
local ENUM_SEARCH_LIMIT = 96

local M = {}

-- {button label, name of the recipe in the game's own craftable list}
M.ADDITIONS = {
    { "Bulk Battery", "Large Battery" },
}

local craftValues = {}
local crafterClass = nil

local function say(msg)
    print("[AdminMenu] " .. msg .. "\n")
end

-- Written BEFORE the call it describes. A native fault or a freeze leaves this as the
-- last line in the log, which is what turns "it crashed" into "it crashed on this".
local function step(what)
    print("[AdminMenu][step] " .. what .. "\n")
end

local function call(what, fn)
    step(what)
    local ok, res = pcall(fn)
    if not ok then
        say("  ! " .. what .. " failed: " .. tostring(res))
        return nil
    end
    return res
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

local function findObject(path)
    local ok, obj = pcall(function() return StaticFindObject(path) end)
    if not ok then
        return nil
    end
    return isValid(obj) and obj or nil
end

local function friendlyName(helper, enum, value)
    local name
    local ok = pcall(function()
        name = helper:GetEnumeratorUserFriendlyName(enum, value)
    end)
    if not ok or name == nil then
        return nil
    end
    if type(name) ~= "string" then
        local converted
        if not pcall(function() converted = name:ToString() end) or converted == nil then
            return nil
        end
        name = converted
    end
    name = tostring(name)
    return name ~= "" and name or nil
end

-- Finds the byte StartCrafting wants for a named recipe. Looked up rather than
-- hardcoded, so a patch that reorders the enum cannot make this build the wrong thing.
local function resolveCraftValue(recipeName)
    if craftValues[recipeName] ~= nil then
        return craftValues[recipeName]
    end

    local enum = findObject(ENUM_PATH)
    local helper = findObject(NODE_HELPER_CDO)
    if enum == nil or helper == nil then
        return nil
    end

    for value = 0, ENUM_SEARCH_LIMIT - 1 do
        if friendlyName(helper, enum, value) == recipeName then
            craftValues[recipeName] = value
            say(string.format("'%s' is craftable value %d", recipeName, value))
            return value
        end
    end

    say("'" .. recipeName .. "' is not in the game's craftable list")
    return nil
end

--[[ Where to put the crafter ----------------------------------------------------------

    GetGroundSpawnLocation gives the right spot horizontally but sits well above the
    surface, so the point is lowered to the height the player stands at before use. The
    measurements and the reasoning are with playerFeetZ and onSurface below.

    UE4SS wants EVERY parameter passed, out parameters included, or it refuses with
    "UFunction expected 4 parameters, received 2". Hence the two placeholder structs.
--]]
local function makeTransform(kismet, location, rotation)
    local scale = call("Conv_DoubleToVector(1)", function()
        return kismet:Conv_DoubleToVector(1.0)
    end)
    if scale == nil then
        return nil
    end
    return call("MakeTransform", function()
        return kismet:MakeTransform(location, rotation, scale)
    end)
end

-- Reading one component out of a Vector. Guarded: if UE4SS ever stops exposing struct
-- fields this way we want a logged failure, not a silently wrong position.
local function axis(vector, name)
    local value
    if pcall(function() value = vector[name] end) and type(value) == "number" then
        return value
    end
    return nil
end

local function playerPawn(pc)
    local pawn
    if pcall(function() pawn = pc.Pawn end) and isValid(pawn) then
        return pawn
    end
    pawn = call("K2_GetPawn", function() return pc:K2_GetPawn() end)
    return isValid(pawn) and pawn or nil
end

--[[ The height of the surface the player is standing on -------------------------------

    GetGroundSpawnLocation does not return the ground. It returns the point where the
    game puts its CRAFTER, which sits about 164 cm above the surface - measured as
    exactly 164 both on land and on the boat deck. The crafter builds the module where it
    stands, so using that point unchanged leaves everything hanging in mid air.

    The player is standing on the real surface a few metres away, so their capsule gives
    the height. Not GetActorBounds on the pawn: that measures a box around every
    colliding component, equipment included, and came out almost three metres wrong. The
    capsule is the part that actually rests on the ground.
--]]
local function playerFeetZ(pc)
    local pawn = playerPawn(pc)
    if pawn == nil then
        return nil
    end

    local capsule
    if not pcall(function() capsule = pawn.CapsuleComponent end) or not isValid(capsule) then
        capsule = call("GetCapsuleComponent", function() return pawn:GetCapsuleComponent() end)
    end
    if not isValid(capsule) then
        say("no capsule on the player - cannot measure the standing surface")
        return nil
    end

    local half = call("GetScaledCapsuleHalfHeight", function()
        return capsule:GetScaledCapsuleHalfHeight()
    end)
    local location = call("pawn K2_GetActorLocation", function()
        return pawn:K2_GetActorLocation()
    end)
    if half == nil or location == nil then
        return nil
    end

    local z = axis(location, "Z")
    return z and (z - half) or nil
end

-- Keeps where the trace landed, but drops it to the height the player is standing at.
local function onSurface(kismet, pc, location)
    local feetZ = playerFeetZ(pc)
    if feetZ == nil then
        return location
    end

    local x, y, z = axis(location, "X"), axis(location, "Y"), axis(location, "Z")
    if x == nil or y == nil or z == nil then
        return location
    end

    say(string.format("trace at %.0f, player stands on %.0f, lowering the crafter %.0f",
        z, feetZ, feetZ - z))

    return call("MakeVector", function() return kismet:MakeVector(x, y, feetZ) end) or location
end

local function groundTransform(kismet, pc, button)
    if button == nil then
        return nil
    end

    local outLocation = call("Conv_DoubleToVector(0)", function()
        return kismet:Conv_DoubleToVector(0.0)
    end)
    local outRotation = call("MakeRotator(0,0,0)", function()
        return kismet:MakeRotator(0.0, 0.0, 0.0)
    end)
    if outLocation == nil or outRotation == nil then
        return nil
    end

    local location, rotation
    step("GetGroundSpawnLocation")
    local ok, err = pcall(function()
        location, rotation =
            button:GetGroundSpawnLocation(SPAWN_DISTANCE, false, outLocation, outRotation)
    end)
    if not ok then
        say("  ! GetGroundSpawnLocation failed: " .. tostring(err))
        return nil
    end

    -- Whether UE4SS returns out parameters or writes into the ones passed in differs
    -- between builds, so both shapes are accepted.
    location = location or outLocation
    rotation = rotation or outRotation

    return makeTransform(kismet, onSurface(kismet, pc, location), rotation)
end

-- Fallback for when there is no button to ask. Puts the crafter in front of the player
-- at the player's own height.
local function pawnTransform(kismet, pc)
    local pawn = playerPawn(pc)
    if pawn == nil then
        say("no pawn to place anything in front of")
        return nil
    end

    local location = call("K2_GetActorLocation", function() return pawn:K2_GetActorLocation() end)
    local rotation = call("K2_GetActorRotation", function() return pawn:K2_GetActorRotation() end)
    local forward = call("GetActorForwardVector", function() return pawn:GetActorForwardVector() end)
    if location == nil or rotation == nil or forward == nil then
        return nil
    end

    local reach = call("Conv_DoubleToVector(distance)", function()
        return kismet:Conv_DoubleToVector(SPAWN_DISTANCE)
    end)
    if reach == nil then
        return nil
    end
    local offset = call("Multiply_VectorVector", function()
        return kismet:Multiply_VectorVector(forward, reach)
    end)
    if offset == nil then
        return nil
    end
    local target = call("Add_VectorVector", function()
        return kismet:Add_VectorVector(location, offset)
    end)
    if target == nil then
        return nil
    end

    return makeTransform(kismet, target, rotation)
end

local function deferredSpawn(worldContext, cls, transform)
    local gameplay = findObject(CDO_GAMEPLAY)
    if gameplay == nil then
        return nil
    end

    local actor
    step("BeginDeferredActorSpawnFromClass")
    local ok, err = pcall(function()
        actor = gameplay:BeginDeferredActorSpawnFromClass(
            worldContext, cls, transform, COLLISION_ALWAYS_SPAWN, nil, SCALE_MULTIPLY_WITH_ROOT)
    end)
    if not ok then
        say("  ! BeginDeferredActorSpawnFromClass failed: " .. tostring(err))
        return nil
    end
    if not isValid(actor) then
        say("  ! BeginDeferredActorSpawnFromClass returned nothing")
        return nil
    end

    -- An actor left half spawned is worse than none at all, so this must always run.
    step("FinishSpawningActor")
    local finished, ferr = pcall(function()
        gameplay:FinishSpawningActor(actor, transform, SCALE_MULTIPLY_WITH_ROOT)
    end)
    if not finished then
        say("  ! FinishSpawningActor failed: " .. tostring(ferr))
    end
    return actor
end

--[[ Getting everything ready before the click -----------------------------------------

    Called while the menu is opening. A synchronous package load from inside a click
    freezes the game outright - no crash, no crash reporter, no log line beyond
    "Asset was found but not loaded, could be a package" - so nothing may be loaded
    once a button is live.
--]]
function M.preload()
    if not isValid(crafterClass) then
        crafterClass = findObject(CRAFTER_CLASS)
        if crafterClass == nil and LoadAsset ~= nil then
            pcall(function() LoadAsset(CRAFTER_PACKAGE) end)
            crafterClass = findObject(CRAFTER_CLASS)
        end
    end

    for _, entry in ipairs(M.ADDITIONS) do
        resolveCraftValue(entry[2])
    end

    return isValid(crafterClass)
end

-- Returns ok, message. `button` is the cheat button that was clicked: it is what knows
-- where the ground is. nil is accepted and falls back to the player's own position.
function M.craft(entry, button)
    local pc = UEHelpers.GetPlayerController()
    if not isValid(pc) then
        return false, "no PlayerController - load a save first"
    end
    if not isValid(crafterClass) then
        return false, "the crafter is not loaded - close and reopen the menu, then try again"
    end

    local value = resolveCraftValue(entry[2])
    if value == nil then
        return false, entry[1] .. " is not in the game's craftable list"
    end

    local kismet = findObject(CDO_KISMET)
    if kismet == nil then
        return false, "KismetMathLibrary not found"
    end

    local transform = groundTransform(kismet, pc, button) or pawnTransform(kismet, pc)
    if transform == nil then
        return false, "could not work out where to put " .. entry[1]
    end

    local crafter = deferredSpawn(pc, crafterClass, transform)
    if crafter == nil then
        return false, "could not place the crafter - see UE4SS.log"
    end

    step("StartCrafting " .. value)
    local ok, err = pcall(function() crafter:StartCrafting(value) end)
    if not ok then
        return false, "StartCrafting failed: " .. tostring(err)
    end

    return true, "building " .. entry[1]
end

return M
