--[[
    state.lua - a tiny shared table.

    main.lua opens the admin widget and keeps the live instance here so that the
    scanner can walk exactly that widget. Looking the widget up with FindAllOf gave
    the class template inside BP_AdminWidget_C:WidgetTree instead of the live one,
    and template sub-objects are not safe to poke at.

    require() caches modules, so every file that requires this gets the same table.
--]]

return {
    widget = nil,
}
