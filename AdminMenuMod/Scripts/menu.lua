--[[
    menu.lua - discovery step for adding real buttons to the game's own cheat menu.

    Goal: find the VerticalBox that holds the Storage Modules buttons, so new buttons
    can be added to it with PanelWidget:AddChild.

    How this ended up here
    ----------------------
    v1  Read the submenus by variable name off the cheat widget. Every one came back
        "not present". Name bindings are not readable that way from Lua.

    v2  Called FindAllOf("BP_VoyageCheat_Button_C"), got 119 hits, and killed the game
        in the loop over them. The log stopped at "spawn buttons found: 119" with no Lua
        error, which means a native access violation - pcall cannot catch those.
        FindAllOf had returned the CLASS TEMPLATE, not the live menu: the cheat widget
        it found lived inside BP_AdminWidget_C:WidgetTree, the archetype the game copies
        from. Its 119 buttons were archetypes too, and they are not wired up like live
        objects. On top of that it read every property of every button in one pass,
        including the soft class pointer SpawnActorClass, so the crash said nothing
        about which call had faulted.

    v3  Walked the LIVE widget main.lua opened, handed over through state.lua. No crash,
        and the live instance is a real one:
            BP_AdminWidget_C /Engine/Transient.VoyageGameEngine:...BP_AdminWidget_C_2147471301
        But it stopped after 36 nodes. A UUserWidget is not a UPanelWidget, so the walk
        treated every nested widget as a leaf - including BP_VoyageCheatWiget, which is
        exactly where the buttons live.

    v4  This one. When a node has no children as a panel, it is asked for its own
        WidgetTree instead, and the walk continues into that. That is the step that
        reaches the cheat menu's insides.

    A UserWidget's WidgetTree holds every widget the designer placed, whether or not it
    is currently on screen, so there is no need to navigate to a submenu first.

    Confirmed API used here:
        UserWidget.WidgetTree -> WidgetTree.RootWidget
        PanelWidget:GetChildrenCount(), PanelWidget:GetChildAt(Index)
        Object:GetFullName()

    Watch out: UE4SS returns a TrivialObject, NOT nil, for a member that does not exist.
    "obj.Foo ~= nil" is therefore never a valid existence test - the call has to be
    attempted inside pcall.

    Every risky call logs a [step] line BEFORE it runs. If the game dies anyway, the last
    step line in UE4SS.log names the exact object and the exact call that did it.

    Usage - open the menu with F1, then in the F10 console:

        menuscan            structure only. Safest. Start here.
        menuscan labels     same walk, plus the text on every button.
        menuscan config 7   safe properties of button 7 from the last listing.
        menuscan raw 0 10   the old FindAllOf route, bounded, for bisecting v2's crash.

    Commands can be repeated without restarting the game. Only code changes need a
    restart, because hot reload is off.

    Nothing here changes anything. It only reports.
--]]

local state = require("state")

local BUTTON_CLASS = "BP_VoyageCheat_Button_C"
local MAX_NODES = 4000
local MAX_DEPTH = 40

-- Buttons from the most recent scan, so 'menuscan config N' can address one by number.
local lastButtons = {}

local function say(msg)
    print("[AdminMenu] " .. msg .. "\n")
end

-- Written BEFORE the call it describes. A native memory fault kills the game without
-- leaving a Lua error, and then this is the only trace of where it happened.
local function mark(what)
    print("[AdminMenu][step] " .. what .. "\n")
end

local function safe(what, fn)
    mark(what)
    local ok, res = pcall(fn)
    if not ok then
        say("  ! " .. what .. " failed: " .. tostring(res))
        return nil
    end
    return res
end

-- For calls that are EXPECTED to fail, such as asking a plain widget for children.
-- Still marked, so the crash trail stays complete, but it does not spam the log.
local function probe(what, fn)
    mark(what)
    local ok, res = pcall(fn)
    if not ok then
        return nil
    end
    return res
end

-- Must not assume o:IsValid() exists: on a TrivialObject the call itself throws.
local function isValid(o)
    if o == nil then
        return false
    end
    local ok, res = pcall(function() return o:IsValid() end)
    return ok and res == true
end

-- GetFullName gives class and path in one call: "VerticalBox /Game/...:WidgetTree.Foo".
-- One call instead of GetClass plus GetFName is one less chance to fault.
local function nameOf(o, tag)
    return safe(tag .. ".GetFullName", function() return o:GetFullName() end) or "?"
end

-- Everything after the last dot: the widget's variable name in the blueprint.
local function tailOf(full)
    return full:match("([^.]+)$") or full
end

local function isButton(full)
    return full:find(BUTTON_CLASS, 1, true) == 1
end

local function indent(depth)
    return string.rep("  ", depth)
end

-- A UserWidget is not a panel. Its children hang off its own WidgetTree instead.
local function innerRoot(node, tag)
    local tree = probe(tag .. ".WidgetTree", function() return node.WidgetTree end)
    if not isValid(tree) then
        return nil
    end
    local root = probe(tag .. ".WidgetTree.RootWidget", function() return tree.RootWidget end)
    if not isValid(root) then
        return nil
    end
    return root
end

-- The live widget main.lua opened, never the archetype.
local function liveRootWidget()
    local w = state.widget
    if not isValid(w) then
        say("no live admin widget - press F1 to open the menu, then run menuscan")
        return nil
    end
    say("live admin widget: " .. nameOf(w, "adminWidget"))
    local root = innerRoot(w, "adminWidget")
    if root == nil then
        say("the admin widget has no readable WidgetTree")
    end
    return root
end

local function readLabel(node, tag)
    -- ButtonText is a TextBlock WIDGET, so the label needs two hops.
    local tb = probe(tag .. ".ButtonText", function() return node.ButtonText end)
    if not isValid(tb) then
        return ""
    end
    local txt = safe(tag .. ".ButtonText.GetText", function() return tb:GetText() end)
    if txt == nil then
        return ""
    end
    return safe(tag .. ".ButtonText.GetText.ToString", function() return txt:ToString() end) or ""
end

-- Depth first walk of the live tree. Children are pushed in reverse so that siblings
-- come out in the order they appear on screen.
local function walk(root, withLabels)
    local stack = { { node = root, depth = 0, parent = "-" } }
    local seen = 0
    local visited = {}
    local panels = {}
    local order = {}

    lastButtons = {}

    while #stack > 0 and seen < MAX_NODES do
        local item = table.remove(stack)
        local node = item.node
        local tag = "n" .. (seen + 1)
        local full = nil
        if isValid(node) then
            full = nameOf(node, tag)
        end

        -- Skipping what has already been seen keeps a cycle in the tree from looping
        -- forever, and full names are unique per object.
        if full ~= nil and not visited[full] then
            visited[full] = true
            seen = seen + 1

            local short = tailOf(full)
            local button = isButton(full)
            local line

            if button then
                lastButtons[#lastButtons + 1] = { obj = node, name = short, parent = item.parent }
                local label = withLabels and readLabel(node, tag) or ""

                line = string.format("%s[btn %3d] %s", indent(item.depth), #lastButtons, short)
                if label ~= "" then
                    line = line .. "   " .. label
                end

                local p = panels[item.parent]
                if p == nil then
                    p = { count = 0, labels = {} }
                    panels[item.parent] = p
                    order[#order + 1] = item.parent
                end
                p.count = p.count + 1
                if label ~= "" then
                    p.labels[#p.labels + 1] = label
                end
            end

            -- A panel has children directly. Anything else may still be a UserWidget
            -- with a widget tree of its own. Cheat buttons are left as leaves: their
            -- insides are just artwork and we already have what we need from them.
            local count = probe(tag .. ".GetChildrenCount", function()
                return node:GetChildrenCount()
            end)
            local nested = nil
            if count == nil and not button then
                nested = innerRoot(node, tag)
            end

            if not button then
                local suffix = ""
                if count ~= nil then
                    suffix = string.format("   (%d children)", count)
                elseif nested ~= nil then
                    suffix = "   (widget tree)"
                end
                line = string.format("%s%s%s", indent(item.depth), short, suffix)
            end
            say(line)

            if item.depth < MAX_DEPTH then
                if count ~= nil and count > 0 then
                    for i = count - 1, 0, -1 do
                        local child = safe(tag .. ".GetChildAt(" .. i .. ")", function()
                            return node:GetChildAt(i)
                        end)
                        if child ~= nil then
                            stack[#stack + 1] =
                                { node = child, depth = item.depth + 1, parent = short }
                        end
                    end
                elseif nested ~= nil then
                    stack[#stack + 1] = { node = nested, depth = item.depth + 1, parent = short }
                end
            end
        end
    end

    say("")
    say(string.format("nodes visited: %d, buttons: %d", seen, #lastButtons))
    say("")
    say("PANELS THAT HOLD BUTTONS")
    for _, key in ipairs(order) do
        local p = panels[key]
        say(string.format("   %-40s %d buttons", key, p.count))
        if #p.labels > 0 then
            say("      " .. table.concat(p.labels, ", "))
        end
    end
end

--[[ Reading one button's configuration ------------------------------------------------

    SpawnActorClass is deliberately NOT read here, and must never be added back.

    Reading it kills the game outright. The step marker caught it exactly:

        [AdminMenu] button 32: BP_VoyageCheat_Button_17 in Spawn_ResourceContainer_Submenu
        [AdminMenu][step] btn32.SpawnActorClass        <- last line in the log

    No Lua error, no stack, just a native access violation. UE4SS's Lua binding for
    SoftClassProperty is broken in this build, in both directions. That is also what
    killed v2 of this scanner, which read the property for all 119 buttons at once.

    Everything below is a plain string, bool or object property and is safe.
--]]
local function readConfig(index)
    local entry = lastButtons[index]
    if entry == nil then
        say("no button " .. tostring(index) .. " - run menuscan first")
        return
    end
    if not isValid(entry.obj) then
        say("button " .. index .. " is no longer valid - the menu was probably closed")
        return
    end
    say("button " .. index .. ": " .. entry.name .. " in " .. entry.parent)

    local button = entry.obj
    for _, field in ipairs({ "Text", "Buildable", "Unique", "Enabled", "InventoryType" }) do
        local value = probe("btn" .. index .. "." .. field, function()
            return button[field]
        end)
        if value ~= nil then
            say(string.format("  %-14s %s", field, tostring(value)))
        end
    end

    local craftables = probe("btn" .. index .. ".Craftables", function()
        return button.Craftables
    end)
    if isValid(craftables) then
        say("  Craftables     " .. (nameOf(craftables, "btn" .. index .. ".Craftables")))
    end

    say("  SpawnActorClass  not read on purpose - a SoftClassProperty read crashes UE4SS")
end

-- The old route, kept only so v2's crash can be bisected if that is ever needed.
-- Bounded on purpose: 'menuscan raw 0 10' touches ten objects and no more.
local function rawScan(startIndex, count)
    local buttons = FindAllOf(BUTTON_CLASS) or {}
    say(string.format("FindAllOf(%s): %d objects, archetypes included",
        BUTTON_CLASS, #buttons))
    local last = math.min(startIndex + count, #buttons)
    for i = startIndex + 1, last do
        local b = buttons[i]
        local tag = "raw" .. (i - 1)
        say(string.format("[%d] %s", i - 1, nameOf(b, tag)))
        local parent = safe(tag .. ".GetParent", function() return b:GetParent() end)
        if isValid(parent) then
            say("     parent: " .. nameOf(parent, tag .. ".parent"))
        end
    end
    say("raw scan done")
end

RegisterConsoleCommandHandler("menuscan", function(FullCommand, Parameters, Ar)
    -- Console handlers already run on the game thread. Never wrap this in
    -- ExecuteInGameThread: Ar only lives for the duration of this call, and a deferred
    -- closure that touches it is a use after free. That killed an earlier command once.
    local ok, err = pcall(function()
        local mode = ""
        if Parameters ~= nil and Parameters[1] ~= nil then
            mode = tostring(Parameters[1]):lower()
        end

        if mode == "config" then
            readConfig(tonumber(Parameters[2]) or 0)
            return
        end

        if mode == "class" then
            say("'menuscan class' is gone. Reading SpawnActorClass crashes the game -")
            say("UE4SS cannot touch a SoftClassProperty in this build. Use 'menuscan config N'.")
            return
        end

        if mode == "raw" then
            rawScan(tonumber(Parameters[2]) or 0, tonumber(Parameters[3]) or 10)
            return
        end

        local withLabels = (mode == "labels")
        say("scanning the live widget tree" ..
            (withLabels and ", with labels" or ", structure only"))
        local root = liveRootWidget()
        if root == nil then
            return
        end
        walk(root, withLabels)
        say("done - the full listing is in ue4ss/UE4SS.log")
    end)
    if not ok then
        say("ERROR in menuscan: " .. tostring(err))
    end
    return true
end)

say("menuscan registered - F1, browse to Storage Modules, then 'menuscan'")
