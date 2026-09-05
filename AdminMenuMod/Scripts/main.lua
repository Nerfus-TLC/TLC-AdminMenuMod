--[[
    AdminMenuMod - opens The Last Caretaker's own built-in admin menu on F1.

    A replacement for Dev Menu v0.5, which was a blueprint cooked for UE 5.7 and
    crashes the game after the update to 5.8.1. This does the same job in plain Lua,
    so it is independent of the engine version and needs no cooking. That is the whole
    point: an engine bump breaks cooked blueprint mods, not scripts.

    The menu itself is the game's own widget. This mod ships no game content, it only
    asks the game to open something it already has.

    Keys:
      F1          open / close the admin menu
      CTRL + F1   panic key: hand input back to the game whatever the state

    Signatures read from a JMAP dump of the running game, not guessed:
      WidgetBlueprintLibrary:Create(WorldContextObject, WidgetType, OwningPlayer)
      UserWidget:AddToViewport(ZOrder)
      Widget:RemoveFromParent()                                  -- no arguments
      WidgetBlueprintLibrary:SetInputMode_UIOnlyEx(PC, WidgetToFocus, MouseLockMode, bFlushInput)
      WidgetBlueprintLibrary:SetInputMode_GameOnly(PC, bFlushInput)   -- two arguments
      Controller:SetIgnoreLookInput(bNewLookInput)                -- one argument
      Controller:SetIgnoreMoveInput(bNewMoveInput)                -- one argument
      Controller:ResetIgnoreInputFlags()                          -- no arguments

    Changelog
      2026-09-04  First version.
      2026-09-05  F1 did not close the menu. BP_AdminWidget_C:CloseWidget only fires the
                  widget's own close event and does not remove it from the viewport.
                  Fixed by calling RemoveFromParent afterwards.
                  Mouse movement turned the character, because the widget was added
                  without changing input mode. Fixed with UI-only input.
      2026-09-05  Input never came back after closing and ESC was dead. Cause:
                  SetInputMode_GameOnly was called with one argument but takes two
                  (PC and bFlushInput). The call failed and pcall swallowed the error
                  silently, leaving input stuck in UI mode. Every call now logs its
                  failure instead of hiding it, and CTRL + F1 was added as a panic key.
      2026-09-05  Added spawn.lua, a console list for storage modules the game's own
                  admin panel does not offer. Strings translated to English.
      2026-09-05  Real GUI buttons. inject.lua adds the three missing bulk containers
                  to the game's own Storage Modules panel every time the menu opens.
                  SpawnActorClass could not be used - reading or writing a
                  SoftClassProperty from UE4SS kills the game - so the buttons carry
                  only a label and the spawning is done from a hook on the button
                  class's click event. See inject.lua for the full reasoning.
--]]

local UEHelpers = require("UEHelpers")

local ADMIN_WIDGET_CLASS = "/Game/UI/Game/Admin/BP_AdminWidget.BP_AdminWidget_C"
local WIDGET_LIB_CDO = "/Script/UMG.Default__WidgetBlueprintLibrary"
local TOGGLE_KEY = Key.F1
local PANIC_KEY = Key.F1
local PANIC_MODIFIERS = { ModifierKey.CONTROL }
local NO_MODIFIERS = {}

-- EMouseLockMode: 0 = DoNotLock, 1 = LockOnCapture, 2 = LockAlways, 3 = LockInFullscreen
local MOUSE_LOCK_MODE = 0

local state = require("state")
local inject = require("inject")

local function log(msg)
    print("[AdminMenu] " .. msg .. "\n")
end

-- Calls fn and LOGS any error. Never swallow silently: that is exactly what hid the
-- SetInputMode_GameOnly signature bug for two rounds of testing.
local function try(what, fn)
    local ok, err = pcall(fn)
    if not ok then
        log("ERROR in " .. what .. ": " .. tostring(err))
    end
    return ok
end

local function isValid(obj)
    return obj ~= nil and obj.IsValid ~= nil and obj:IsValid()
end

local function widgetLib()
    local lib = StaticFindObject(WIDGET_LIB_CDO)
    if isValid(lib) then
        return lib
    end
    log("could not find WidgetBlueprintLibrary")
    return nil
end

local function findWidgetClass()
    local cls = StaticFindObject(ADMIN_WIDGET_CLASS)
    if isValid(cls) then
        return cls
    end
    if LoadAsset ~= nil then
        try("LoadAsset", function() LoadAsset(ADMIN_WIDGET_CLASS) end)
        cls = StaticFindObject(ADMIN_WIDGET_CLASS)
        if isValid(cls) then
            return cls
        end
    end
    return nil
end

-- Gives mouse and keyboard to the menu and stops the game from reading the mouse.
local function grabInputForUI(pc, widget)
    local lib = widgetLib()
    if lib ~= nil then
        try("SetInputMode_UIOnlyEx", function()
            lib:SetInputMode_UIOnlyEx(pc, widget, MOUSE_LOCK_MODE, false)
        end)
    end
    try("SetIgnoreLookInput(true)", function() pc:SetIgnoreLookInput(true) end)
    try("SetIgnoreMoveInput(true)", function() pc:SetIgnoreMoveInput(true) end)
    pc.bShowMouseCursor = true
end

-- Hands input back to the game. Called on close and by the panic key.
local function releaseInputToGame(pc)
    if not isValid(pc) then
        log("no valid PlayerController - cannot restore input")
        return
    end
    -- ResetIgnoreInputFlags clears both counters no matter how many times SetIgnore*
    -- was called, which is safer than passing false. Those flags are counter based.
    try("ResetIgnoreInputFlags", function() pc:ResetIgnoreInputFlags() end)
    local lib = widgetLib()
    if lib ~= nil then
        -- Two arguments. One argument fails silently and locks input in UI mode.
        try("SetInputMode_GameOnly", function()
            lib:SetInputMode_GameOnly(pc, false)
        end)
    end
    pc.bShowMouseCursor = false
end

local function closeMenu(pc)
    if isValid(state.widget) then
        -- Let the widget run its own cleanup first, then remove it for real.
        if state.widget.CloseWidget ~= nil then
            try("CloseWidget", function() state.widget:CloseWidget() end)
        end
        local removed = false
        if state.widget.RemoveFromParent ~= nil then
            removed = try("RemoveFromParent", function() state.widget:RemoveFromParent() end)
        end
        if not removed and state.widget.RemoveFromViewport ~= nil then
            removed = try("RemoveFromViewport", function() state.widget:RemoveFromViewport() end)
        end
        log(removed and "closed" or "could not remove the widget from the viewport")
    end
    state.widget = nil
    releaseInputToGame(pc)
end

local function openMenu(pc)
    local cls = findWidgetClass()
    if cls == nil then
        log("could not find " .. ADMIN_WIDGET_CLASS .. " - are you in a loaded game?")
        return
    end

    local lib = widgetLib()
    if lib == nil then
        return
    end

    local ok, widget = pcall(function()
        return lib:Create(pc, cls, pc)
    end)
    if not ok then
        log("ERROR in Create: " .. tostring(widget))
        return
    end
    if not isValid(widget) then
        log("Create returned no widget")
        return
    end

    if not try("AddToViewport", function() widget:AddToViewport(0) end) then
        return
    end

    state.widget = widget
    grabInputForUI(pc, widget)

    -- The menu is built fresh on every open, so the extra buttons have to be put back
    -- each time. A failure here must never stop the menu from working.
    try("inject buttons", function() inject.apply(pc) end)

    log("opened")
end

local function toggleMenu()
    -- UI must be touched from the game thread, otherwise the game can crash.
    -- Key binds run on their own thread, so this deferral is required here.
    ExecuteInGameThread(function()
        local pc = UEHelpers.GetPlayerController()
        if not isValid(pc) then
            log("no PlayerController - load a save first")
            return
        end
        if state.widget ~= nil then
            closeMenu(pc)
        else
            openMenu(pc)
        end
    end)
end

-- Panic key: cleans up whatever the state, so the game never has to be killed to get
-- control back.
local function panicRestore()
    ExecuteInGameThread(function()
        local pc = UEHelpers.GetPlayerController()
        if isValid(state.widget) then
            if state.widget.RemoveFromParent ~= nil then
                try("panic RemoveFromParent", function() state.widget:RemoveFromParent() end)
            end
        end
        state.widget = nil
        releaseInputToGame(pc)
        log("panic key: input handed back to the game")
    end)
end

if IsKeyBindRegistered ~= nil and IsKeyBindRegistered(TOGGLE_KEY, NO_MODIFIERS) then
    log("F1 is already bound by another mod - change TOGGLE_KEY in main.lua")
else
    RegisterKeyBindAsync(TOGGLE_KEY, NO_MODIFIERS, toggleMenu)
    RegisterKeyBindAsync(PANIC_KEY, PANIC_MODIFIERS, panicRestore)
    log("loaded - F1 opens the menu, CTRL + F1 is the input panic key")
end

-- Developer tool: the menuscan console command that mapped the game's menu. It is not
-- part of the release, so its absence is normal and must not stop the mod from loading.
pcall(function() require("menu") end)
pcall(function() require("craft") end)
