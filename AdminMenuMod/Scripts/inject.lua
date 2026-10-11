--[[
    inject.lua - puts real buttons into the game's own cheat menu:

        Bulk Battery               Cheats -> Spawn/Craft -> Storage Modules
        Reset Weather to Default   at the bottom of the Weather page

    This is the whole user interface. The mod has no console commands: everything it
    does, it does from buttons that look and behave like the game's own. TARGETS below
    lists them - where each goes, what it says and what a click does.

    How a cheat button works (read out of the reflection dump)
    ---------------------------------------------------------
    BP_VoyageCheat_Button_C has:
        Text              StrProperty      the label
        ButtonText        TextBlock        UMG-bound to Text: setting Text is enough before
                                           the button is first drawn, but a button already
                                           on screen needs SetText on this TextBlock
        SpawnActorClass   SoftClassProperty  what it spawns
        Craftables, Items, Buildable, Unique, Enabled, Style

    The label is easy to set. SpawnActorClass is not, and that is the whole design
    problem here:

        UE4SS CANNOT TOUCH SoftClassProperty IN THIS BUILD.

    Reading btn.SpawnActorClass kills the game with a native access violation - no Lua
    error, nothing pcall can catch. Proven with a step marker in the log:

        [AdminMenu] button 32: BP_VoyageCheat_Button_17 in Spawn_ResourceContainer_Submenu
        [AdminMenu][step] btn32.SpawnActorClass        <- last line before the crash

    Writing goes through the same broken property handler, so configuring a new button
    the way the game does is off the table.

    The way around it
    -----------------
    Build the button, set only its label, and leave SpawnActorClass empty. Then hook the
    button class's own click event and do the spawning ourselves.

    The hook fires for every cheat button in the game, all 119 of the game's own
    included. It reads the label - a plain string, safe to touch - and acts only on the
    ones that belong to this mod. Everything else falls straight through to the game's
    own logic, untouched.

    Our buttons run the game's click logic too, with an empty SpawnActorClass. That is
    handled inside the blueprint VM, which is null safe, and never reaches the UE4SS
    property code that faults.

    The building itself lives in catalog.lua and takes the game's own route: put a
    BP_Module_Crafter down at GetGroundSpawnLocation and let it do the rest. The button
    object is handed over for exactly that reason - it is what knows where the ground is.

    Everything a click needs is prepared while the menu opens - the classes are resolved
    up front by catalog.preload. A synchronous package load from inside a click froze the
    game outright.
--]]

local UEHelpers = require("UEHelpers")
local catalog = require("catalog")
local state = require("state")

local function log(msg)
    print("[AdminMenu] " .. msg .. "\n")
end

-- The weather module is optional: if it is missing or broken, the menu and the Bulk
-- Battery button must still work, so the failure is logged and the target left out.
local weatherOk, weatherreset = pcall(require, "weatherreset")
if not weatherOk then
    log("weather reset unavailable: " .. tostring(weatherreset))
    weatherreset = nil
end

local BUTTON_CLASS = "/Game/UI/Game/HUD/BP_VoyageCheat_Button.BP_VoyageCheat_Button_C"
local WIDGET_LIB_CDO = "/Script/UMG.Default__WidgetBlueprintLibrary"
local TEXT_LIB_CDO = "/Script/Engine.Default__KismetTextLibrary"
local CHEAT_BUTTON_PREFIX = "BP_VoyageCheat_Button_C "

-- The bound event the button's own Button widget calls when clicked. A real UFunction
-- on the blueprint class, so RegisterHook can attach to it.
local CLICK_EVENT = BUTTON_CLASS ..
    ":BndEvt__BP_VoyageCheat_Button_Button_K2Node_ComponentBoundEvent_1_OnButtonClickedEvent__DelegateSignature"

local M = {}

local hookRegistered = false

--[[ The buttons this mod adds -----------------------------------------------------------

    panel          the VerticalBox the button goes into
    templatePanel  where to copy the look from, when panel holds no cheat button of its
                   own (optional, defaults to panel). Read from the first target of
                   each panel; later targets in the same panel should not differ.
    label          what the button says
    doneLabel      label after a successful click (optional)
    failLabel      label after a failed click (optional)
    action         function(button) -> ok, message

    The menu is rebuilt from scratch on every open, so a changed label lasts until the
    menu closes and the next open shows the normal one again.
--]]
local TARGETS = {}
for _, entry in ipairs(catalog.ADDITIONS) do
    TARGETS[#TARGETS + 1] = {
        panel = "Spawn_ResourceContainer_Submenu",
        label = entry[1],
        -- The button goes along because it is what knows where the ground is:
        -- GetGroundSpawnLocation lives on it, and that is where the crafter goes.
        action = function(button) return catalog.craft(entry, button) end,
    }
end
if weatherreset ~= nil then
    TARGETS[#TARGETS + 1] = {
        panel = "Weather_Submenu",
        templatePanel = "Spawn_ResourceContainer_Submenu",
        label = "Reset Weather to Default",
        doneLabel = "Weather reset - save to keep",
        failLabel = "Weather reset failed - see UE4SS.log",
        action = function() return weatherreset.reset() end,
    }
end

-- label -> target, for every label one of this mod's buttons can carry.
local owned = {}
for _, target in ipairs(TARGETS) do
    owned[target.label] = target
    if target.doneLabel ~= nil then
        owned[target.doneLabel] = target
    end
    if target.failLabel ~= nil then
        owned[target.failLabel] = target
    end
end

-- Panel names in first-seen order, and the targets that go into each.
local PANEL_ORDER = {}
local TARGETS_BY_PANEL = {}
for _, target in ipairs(TARGETS) do
    if TARGETS_BY_PANEL[target.panel] == nil then
        TARGETS_BY_PANEL[target.panel] = {}
        PANEL_ORDER[#PANEL_ORDER + 1] = target.panel
    end
    local group = TARGETS_BY_PANEL[target.panel]
    if group[1] ~= nil and group[1].templatePanel ~= target.templatePanel then
        log("targets in " .. target.panel .. " disagree on templatePanel - using " ..
            tostring(group[1].templatePanel))
    end
    table.insert(group, target)
end

local function try(what, fn)
    local ok, err = pcall(fn)
    if not ok then
        log("ERROR in " .. what .. ": " .. tostring(err))
    end
    return ok
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
    return ok and name or nil
end

-- A button's label. StrProperty, so this is safe to read - but UE4SS may hand back
-- either a Lua string or an FString userdata, and tostring on the latter gives an
-- address rather than the text. Both shapes are handled.
local function labelOf(widget)
    local ok, text = pcall(function() return widget.Text end)
    if not ok or text == nil then
        return nil
    end
    if type(text) == "string" then
        return text
    end
    local converted
    if pcall(function() converted = text:ToString() end) and converted ~= nil then
        return tostring(converted)
    end
    return tostring(text)
end

--[[ Finding the live panel ------------------------------------------------------------

    Walking the whole widget tree finds it, but costs about three seconds and would
    freeze the game every time F1 is pressed. FindAllOf goes straight to it instead.

    The catch is that FindAllOf also returns archetypes - the templates inside the
    blueprint class that the game copies from. Those are not live objects and must not
    be touched. Telling them apart is done on the outer chain in the full name:

        live:      VerticalBox /Engine/Transient.VoyageGameEngine_...BP_AdminWidget_C_2147471301...
        archetype: VerticalBox /Game/UI/Game/HUD/BP_VoyageCheatWiget.BP_VoyageCheatWiget_C:WidgetTree...

    A live one lives under /Engine/Transient and carries the name of the admin widget
    this mod opened, which pins it to the exact menu on screen right now.
--]]
-- boxes is FindAllOf("VerticalBox"), fetched once per menu open by the caller rather
-- than once per panel.
local function findPanel(name, boxes)
    if not isValid(state.widget) then
        return nil
    end
    local adminFull = fullNameOf(state.widget)
    if adminFull == nil then
        return nil
    end
    local adminTag = adminFull:match("([^.]+)$")

    local fallback = nil
    for _, box in ipairs(boxes) do
        local full = fullNameOf(box)
        local tail = full ~= nil and full:sub(-(#name + 1)) or nil
        if full ~= nil
            and (tail == "." .. name or tail == ":" .. name)
            and full:find("/Engine/Transient", 1, true) ~= nil
        then
            if adminTag ~= nil and full:find(adminTag, 1, true) ~= nil then
                return box
            end
            fallback = box
        end
    end
    if fallback ~= nil then
        log("panel " .. name .. " found, but not inside the menu that is open - using it anyway")
    end
    return fallback
end

local function alreadyInjected(panel)
    local count = 0
    local ok = pcall(function() count = panel:GetChildrenCount() end)
    if not ok then
        return false
    end
    for i = 0, count - 1 do
        local child
        if pcall(function() child = panel:GetChildAt(i) end) and isValid(child) then
            local full = fullNameOf(child)
            if full ~= nil and full:sub(1, #CHEAT_BUTTON_PREFIX) == CHEAT_BUTTON_PREFIX then
                local label = labelOf(child)
                if label ~= nil and owned[label] ~= nil then
                    return true
                end
            end
        end
    end
    return false
end

-- Changes the label of a button already on screen. Setting Text is enough before the
-- button is first drawn (makeButton), but once it is on screen the TextBlock does not
-- follow: the button's own graph pushes the text with Conv_StringToText and SetText, so
-- this does the same. Text is still set because the click hook identifies buttons by it.
local function setLabel(button, label)
    try("set Text", function() button.Text = label end)

    local lib = StaticFindObject(TEXT_LIB_CDO)
    if not isValid(lib) then
        log("could not find KismetTextLibrary - the label on screen stays as it was")
        return
    end
    local text
    log("[step] Conv_StringToText")
    if not try("Conv_StringToText", function() text = lib:Conv_StringToText(label) end) then
        return
    end
    log("[step] ButtonText:SetText")
    try("ButtonText:SetText", function() button.ButtonText:SetText(text) end)
end

--[[ The click hook --------------------------------------------------------------------

    Registered on first use rather than at startup: the button blueprint is not loaded
    until a save is running, and RegisterHook on a class that is not in memory fails.
--]]
local function ensureHook()
    if hookRegistered then
        return true
    end
    local ok = try("RegisterHook(cheat button click)", function()
        RegisterHook(CLICK_EVENT, function(Context)
            local handled, err = pcall(function()
                local button = Context
                local got, unwrapped = pcall(function() return Context:get() end)
                if got and unwrapped ~= nil then
                    button = unwrapped
                end

                local label = labelOf(button)

                -- One line per click, not per button, so this is cheap. It is also the
                -- only way to tell "the hook never fired" apart from "the hook fired but
                -- did not recognise the label".
                log("click: " .. tostring(label))

                if label == nil then
                    return
                end
                local target = owned[label]
                if target == nil then
                    -- One of the game's own buttons. Not ours to interfere with.
                    return
                end

                local ran, done, msg = pcall(target.action, button)
                if not ran then
                    -- The action threw: done holds the error. Still show the fail label.
                    done, msg = false, done
                end
                log((done and "" or "ERROR: ") .. tostring(msg))

                local newLabel
                if done then
                    newLabel = target.doneLabel
                else
                    newLabel = target.failLabel
                end
                if newLabel ~= nil then
                    setLabel(button, newLabel)
                end
            end)
            if not handled then
                log("ERROR in click hook: " .. tostring(err))
            end
        end)
    end)
    hookRegistered = ok
    return ok
end

--[[ Making a button look and behave like its neighbours -------------------------------

    A freshly created widget carries the class defaults, and those are not what the
    designer set on the buttons already in the menu. The first attempt showed exactly
    which parts were missing: the new buttons drew with a white background and grey
    text, and did not respond to clicks.

        white background   Style was the class default, not the menu's style
        grey text          the widget was disabled, so UMG drew it with the disabled tint
        no clicks          a disabled widget does not receive them either

    So the configuration is copied off a neighbour at runtime rather than hardcoded.
    That way it keeps matching if the game restyles its menu.

    Items is deliberately NOT copied: it is a map keyed by TSoftObjectPtr, and soft
    pointers are what crash UE4SS. Nothing here needs it.
--]]
local COPY_FIELDS = { "Enabled", "Buildable", "Unique", "InventoryType", "Style", "Craftables" }

-- A real cheat button already in the panel, to copy the look from. Skips this mod's own
-- buttons and anything that is not a BP_VoyageCheat_Button_C.
local function findTemplate(panel)
    local count = 0
    if not pcall(function() count = panel:GetChildrenCount() end) then
        return nil
    end
    for i = count - 1, 0, -1 do
        local child
        if pcall(function() child = panel:GetChildAt(i) end) and isValid(child) then
            local full = fullNameOf(child)
            if full ~= nil and full:sub(1, #CHEAT_BUTTON_PREFIX) == CHEAT_BUTTON_PREFIX then
                local label = labelOf(child)
                if label ~= nil and label ~= "" and owned[label] == nil then
                    return child
                end
            end
        end
    end
    return nil
end

-- The slot is where a VerticalBox keeps padding, alignment and sizing for one child.
-- AddChild creates one with defaults, which is why the first buttons sat flush against
-- each other with no gap. Copying the neighbour's slot lines them up with the rest.
local SLOT_SETTERS = {
    { field = "Padding", setter = "SetPadding" },
    { field = "Size", setter = "SetSize" },
    { field = "HorizontalAlignment", setter = "SetHorizontalAlignment" },
    { field = "VerticalAlignment", setter = "SetVerticalAlignment" },
}

local function copySlot(template, slot)
    if not isValid(slot) or not isValid(template) then
        return
    end
    local source
    if not pcall(function() source = template.Slot end) or not isValid(source) then
        log("neighbour has no readable Slot - spacing left at the default")
        return
    end

    for _, item in ipairs(SLOT_SETTERS) do
        local value
        if pcall(function() value = source[item.field] end) and value ~= nil then
            -- The setter also pushes the change into Slate. A plain assignment only
            -- changes the property and can leave the layout stale.
            local ok = pcall(function() slot[item.setter](slot, value) end)
            if not ok then
                ok = pcall(function() slot[item.field] = value end)
            end
            if not ok then
                log("could not copy slot " .. item.field)
            end
        end
    end
end

local function copyConfig(template, widget)
    for _, field in ipairs(COPY_FIELDS) do
        local value
        local read = pcall(function() value = template[field] end)
        if read and value ~= nil then
            local written = pcall(function() widget[field] = value end)
            if not written then
                log("could not copy " .. field .. " - leaving the default")
            end
        end
    end
end

local function makeButton(pc, lib, cls, label, template)
    local widget
    local ok = try("Create button widget", function()
        widget = lib:Create(pc, cls, pc)
    end)
    if not ok or not isValid(widget) then
        return nil
    end

    if isValid(template) then
        copyConfig(template, widget)
    end

    -- ButtonText is UMG-bound to this property, so the label follows on its own.
    if not try("set Text", function() widget.Text = label end) then
        return nil
    end

    -- The click hook identifies our buttons by this label, so it matters that reading
    -- it back gives the same string it was written as.
    local readBack = labelOf(widget)
    if readBack ~= label then
        log("WARNING: Text was set to '" .. label ..
            "' but reads back as '" .. tostring(readBack) .. "'")
    end

    -- Clicks only reach an enabled widget, and a disabled one is drawn greyed out.
    try("SetIsEnabled", function() widget:SetIsEnabled(true) end)

    -- PreConstruct is what pushes Style onto the inner Button. It already ran during
    -- Create, before any of the above was set, so it has to run once more.
    try("PreConstruct", function() widget:PreConstruct(false) end)

    -- Belt and braces: if the Style struct would not copy, or PreConstruct did not push
    -- it down, set the inner Button's own style straight across. Same data, one level
    -- lower, and it has to happen after PreConstruct or PreConstruct would undo it.
    if isValid(template) then
        pcall(function()
            widget.Button.WidgetStyle = template.Button.WidgetStyle
        end)
    end

    return widget
end

-- Puts the targets that belong in one panel into it. Returns how many were added.
local function injectPanel(pc, lib, cls, name, targets, boxes)
    local panel = findPanel(name, boxes)
    if panel == nil then
        log("could not find " .. name .. " - no buttons added there")
        return 0
    end
    if alreadyInjected(panel) then
        log(name .. " already has the buttons - skipped")
        return 0
    end

    local templatePanel = panel
    local templateName = targets[1].templatePanel
    if templateName ~= nil then
        templatePanel = findPanel(templateName, boxes)
        if templatePanel == nil then
            log("could not find " .. templateName .. " to copy the look from - using " .. name)
            templatePanel = panel
        end
    end

    local template = findTemplate(templatePanel)
    if template == nil then
        log("no neighbour button to copy the style from - the new ones may look wrong")
    else
        log("copying look and behaviour from '" .. tostring(labelOf(template)) .. "'")
    end

    local added = 0
    for _, target in ipairs(targets) do
        local widget = makeButton(pc, lib, cls, target.label, template)
        if widget ~= nil then
            local slot
            if try("AddChild " .. target.label, function() slot = panel:AddChild(widget) end) then
                copySlot(template, slot)
                added = added + 1
            end
        end
    end

    log(string.format("added %d buttons to %s", added, name))
    return added
end

-- Called after the admin menu has been opened and added to the viewport. The menu is
-- rebuilt from scratch on every open, so this runs every time. A panel that fails is
-- logged and skipped; it never stops the others.
function M.apply(pc)
    if not ensureHook() then
        log("click hook could not be registered - not adding buttons that would do nothing")
        return false
    end

    local cls = StaticFindObject(BUTTON_CLASS)
    if not isValid(cls) then
        log("could not find " .. BUTTON_CLASS)
        return false
    end
    local lib = StaticFindObject(WIDGET_LIB_CDO)
    if not isValid(lib) then
        log("could not find WidgetBlueprintLibrary")
        return false
    end

    -- Resolve the crafter and the craftable value now, while the menu is opening.
    -- A click must never load anything: doing so freezes the game.
    catalog.preload()

    local boxes = FindAllOf("VerticalBox") or {}
    local added = 0
    for _, name in ipairs(PANEL_ORDER) do
        local ok, count = pcall(injectPanel, pc, lib, cls, name, TARGETS_BY_PANEL[name], boxes)
        if ok then
            added = added + count
        else
            log("ERROR adding buttons to " .. name .. ": " .. tostring(count))
        end
    end
    return added > 0
end

return M
