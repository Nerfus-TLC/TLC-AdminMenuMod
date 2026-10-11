"""Offline tests for weatherreset.lua.

Runs the module in a real Lua 5.4 through lupa, against plain Lua tables standing in for
the game's objects. UE4SS is not involved: FindAllOf, print and every object are mocks.
What this proves is the module's own logic - which volume it picks, what it writes and
what it leaves alone. Whether the game honours the writes is tested in the game.

Requires lupa:  pip install lupa

Usage:  python tools/test_weatherreset.py
"""

# pyright: reportAttributeAccessIssue=false, reportIndexIssue=false

import os
import unittest

import lupa.lua54 as lua54

SCRIPTS = os.path.normpath(
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "AdminMenuMod", "Scripts"))

MOCKS = r"""
registry = {}
printed = {}

function print(msg) printed[#printed + 1] = msg end

function FindAllOf(class)
    local list = registry[class]
    if list == nil or #list == 0 then return nil end
    return list
end

local function object(full, fields)
    local o = fields or {}
    o.full_name = full
    o.destroyed = false
    function o:IsValid() return not self.destroyed end
    function o:GetFullName() return self.full_name end
    return o
end

function make_preset(name, temperature)
    return object("VoyageWeatherPreset /Game/Data/WeatherPresets/" .. name .. "." .. name, {
        WeatherMask = 255,
        Climate = { Temperature = temperature, MinTemp = 15, MaxTemp = 34, Precipitation = 0,
                    Thunder = 1, CloudCoverage = 0.3, FogDensity = 0 },
        Wind = { Direction = 90, SpeedInKm = 12 },
    })
end

function make_cheat_preset()
    local p = make_preset("DA_WeatherPreset_Cheat_Default", 30.3)
    p.Climate = { Temperature = 30.3, MinTemp = -100, MaxTemp = 100, Precipitation = 71.5,
                  Thunder = 66.1, CloudCoverage = 0.6, FogDensity = 0 }
    p.Wind = { Direction = 10, SpeedInKm = 55 }
    return p
end

function make_volume(owner_name, preset, radius, priority)
    local level = "/Game/Maps/VoyageWorld2.VoyageWorld2:PersistentLevel."
    local owner = object("WeatherVolumeActor_C " .. level .. owner_name, {})
    owner.force_updated = false
    function owner:ForceUpdate() self.force_updated = true end
    local volume = object("VoyageWeatherVolume " .. level .. owner_name .. ".Volume", {
        Radius = radius, Priority = priority, Multiplier = 0, Modified = false,
        WeatherMask = 7, WeatherPreset = preset,
        Climate = { Temperature = 5, MinTemp = 1, MaxTemp = 2, Precipitation = 9,
                    Thunder = 0, CloudCoverage = 1, FogDensity = 0.5 },
        Wind = { Direction = 0, SpeedInKm = 99 },
    })
    function volume:GetOwner() return owner end
    volume.owner = owner
    return volume
end

-- Climate and Wind read back as copies, the way a struct property can come back by
-- value. Writing a field of the copy changes nothing; assigning the whole struct does.
function make_copying_volume(owner_name, preset, radius, priority)
    local volume = make_volume(owner_name, preset, radius, priority)
    local store = { Climate = volume.Climate, Wind = volume.Wind }
    volume.Climate = nil
    volume.Wind = nil
    setmetatable(volume, {
        __index = function(_, key)
            if store[key] ~= nil then
                local copy = {}
                for k, v in pairs(store[key]) do copy[k] = v end
                return copy
            end
        end,
        __newindex = function(t, key, value)
            if key == "Climate" or key == "Wind" then
                local saved = {}
                for k, v in pairs(value) do saved[k] = v end
                store[key] = saved
            else
                rawset(t, key, value)
            end
        end,
    })
    return volume
end

-- One field is served from a hidden store and every write to it is ignored, the way a
-- property that will not take a value behaves. The raw key is removed first: a key that
-- exists in the table itself would bypass the metatable.
local function make_unwritable(volume, field)
    local store = { [field] = volume[field] }
    volume[field] = nil
    setmetatable(volume, {
        __index = function(_, key) return store[key] end,
        __newindex = function(t, key, value)
            if key ~= field then rawset(t, key, value) end
        end,
    })
    return volume
end

function make_stubborn_priority_volume(owner_name, preset, radius, priority)
    return make_unwritable(make_volume(owner_name, preset, radius, priority), "Priority")
end

-- Climate reads back as a copy and the whole struct assignment is ignored too. Wind
-- still takes the whole struct assignment.
function make_stubborn_climate_volume(owner_name, preset, radius, priority)
    local volume = make_copying_volume(owner_name, preset, radius, priority)
    local meta = getmetatable(volume)
    local inner = meta.__newindex
    meta.__newindex = function(t, key, value)
        if key ~= "Climate" then inner(t, key, value) end
    end
    return volume
end

function make_stubborn_preset_volume(owner_name, preset, radius, priority)
    return make_unwritable(make_volume(owner_name, preset, radius, priority), "WeatherPreset")
end

function make_throwing_volume(owner_name, preset, radius, priority)
    local volume = make_volume(owner_name, preset, radius, priority)
    function volume:GetOwner() error("owner is gone") end
    return volume
end

function make_override(full)
    local actor = object(full, {})
    function actor:K2_DestroyActor() self.destroyed = true end
    return actor
end
"""

WORLD = "WeatherVolume_C_UAID_005056C00001181501_1393433783"
SNOW = "WeatherVolume_C_UAID_C87F5407A5526AFF02_1259557926"


class WeatherResetTest(unittest.TestCase):
    def setUp(self):
        self.lua = lua54.LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(MOCKS)
        self.lua.execute('package.path = "%s/?.lua;" .. package.path'
                         % SCRIPTS.replace("\\", "/"))
        self.g = self.lua.globals()
        # The parentheses cut the call to one value; a cached require returns only one.
        self.module = self.lua.eval('(require("weatherreset"))')

    def world(self, owner=WORLD, factory="make_volume"):
        preset = self.g.make_preset("DA_WeatherPreset_Default", 30)
        return self.g[factory](owner, preset, 1e10, 99.0)

    def snow(self):
        preset = self.g.make_preset("DA_WeatherPreset_Snow_Biome_Default", -40)
        return self.g.make_volume(SNOW, preset, 4.5e6, 1.0)

    def register(self, cls, *objects):
        self.g.registry[cls] = self.lua.table(*objects)

    def reset(self):
        return self.module.reset()

    def test_resets_world_volume_to_its_preset(self):
        world = self.world()
        self.register("VoyageWeatherVolume", world, self.snow())
        ok, message = self.reset()
        self.assertTrue(ok, message)
        self.assertEqual(world.Priority, -1.0)
        self.assertEqual(world.Multiplier, 1.0)
        self.assertEqual(world.WeatherMask, 255)
        self.assertEqual(world.Climate.Temperature, 30)
        self.assertEqual(world.Climate.MaxTemp, 34)
        self.assertEqual(world.Climate.Precipitation, 0)
        self.assertEqual(world.Climate.FogDensity, 0)
        self.assertEqual(world.Wind.Direction, 90)
        self.assertEqual(world.Wind.SpeedInKm, 12)
        self.assertTrue(world.Modified)
        self.assertIn("save", message)

    def test_leaves_regional_volumes_alone(self):
        snow = self.snow()
        self.register("VoyageWeatherVolume", self.world(), snow)
        self.reset()
        self.assertEqual(snow.Priority, 1.0)
        self.assertEqual(snow.Multiplier, 0)
        self.assertEqual(snow.Climate.Temperature, 5)
        self.assertFalse(snow.Modified)

    def test_no_world_volume_changes_nothing(self):
        snow = self.snow()
        self.register("VoyageWeatherVolume", snow)
        ok, message = self.reset()
        self.assertFalse(ok)
        self.assertIn("found 0", message)
        self.assertEqual(snow.Priority, 1.0)
        self.assertFalse(snow.Modified)

    def test_two_world_volumes_change_nothing(self):
        first = self.world()
        second = self.world(owner="WeatherVolume_C_UAID_FFFFFFFFFFFF_1")
        self.register("VoyageWeatherVolume", first, second)
        ok, message = self.reset()
        self.assertFalse(ok)
        self.assertIn("found 2", message)
        self.assertEqual(first.Priority, 99.0)
        self.assertEqual(second.Priority, 99.0)

    def test_ignores_templates_and_runtime_spawns(self):
        world = self.world()
        template = self.world(owner="Default__WeatherVolume_C_UAID_0_0")
        spawned = self.world(owner="WeatherVolumeActor_C281089158")
        self.register("VoyageWeatherVolume", template, spawned, world)
        ok, message = self.reset()
        self.assertTrue(ok, message)
        self.assertEqual(world.Priority, -1.0)
        self.assertEqual(template.Priority, 99.0)
        self.assertEqual(spawned.Priority, 99.0)

    def test_removes_preset_overrides_but_not_templates(self):
        self.register("VoyageWeatherVolume", self.world())
        live = self.g.make_override(
            "BP_WeatherVolumeActor_C /Game/Maps/VoyageWorld2.VoyageWorld2:"
            "PersistentLevel.BP_WeatherVolumeActor_C_2147480001")
        template = self.g.make_override(
            "BP_WeatherVolumeActor_C /Game/Blueprints/BP_WeatherVolumeActor."
            "Default__BP_WeatherVolumeActor_C")
        self.register("BP_WeatherVolumeActor_C", live, template)
        ok, message = self.reset()
        self.assertTrue(ok, message)
        self.assertTrue(live.destroyed)
        self.assertFalse(template.destroyed)
        self.assertIn("removed 1 preset override", message)

    def test_never_calls_force_update(self):
        world = self.world()
        self.register("VoyageWeatherVolume", world)
        self.reset()
        self.assertFalse(world.owner.force_updated)

    def test_copies_whole_struct_when_fields_come_back_as_copies(self):
        world = self.world(factory="make_copying_volume")
        self.register("VoyageWeatherVolume", world)
        ok, message = self.reset()
        self.assertTrue(ok, message)
        self.assertEqual(world.Climate.Temperature, 30)
        self.assertEqual(world.Wind.SpeedInKm, 12)

    def test_bad_preset_value_still_fixes_priority(self):
        world = self.world()
        world.WeatherPreset.Climate.Thunder = None
        self.register("VoyageWeatherVolume", world)
        ok, message = self.reset()
        self.assertFalse(ok)
        self.assertIn("Climate", message)
        self.assertEqual(world.Priority, -1.0)
        self.assertTrue(world.Modified)
        # Validation comes before writing, so Climate is untouched. Wind is a separate
        # attempt and still goes through.
        self.assertEqual(world.Climate.Temperature, 5)
        self.assertEqual(world.Wind.SpeedInKm, 12)

    def test_priority_that_will_not_take_aborts(self):
        world = self.world(factory="make_stubborn_priority_volume")
        self.register("VoyageWeatherVolume", world)
        ok, message = self.reset()
        self.assertFalse(ok)
        self.assertIn("could not set the weather priority", message)
        self.assertFalse(world.Modified)
        self.assertEqual(world.Multiplier, 0)
        self.assertEqual(world.Climate.Temperature, 5)

    def test_struct_that_will_not_take_is_reported(self):
        world = self.world(factory="make_stubborn_climate_volume")
        self.register("VoyageWeatherVolume", world)
        ok, message = self.reset()
        self.assertFalse(ok)
        self.assertIn("Climate", message)
        self.assertIn("did not take", message)
        self.assertEqual(world.Priority, -1.0)
        self.assertTrue(world.Modified)
        self.assertEqual(world.Wind.SpeedInKm, 12)

    def test_second_press_gives_same_result(self):
        world = self.world()
        self.register("VoyageWeatherVolume", world)
        first_ok, first_message = self.reset()
        second_ok, second_message = self.reset()
        self.assertTrue(first_ok, first_message)
        self.assertTrue(second_ok, second_message)
        self.assertEqual(world.Priority, -1.0)
        self.assertEqual(world.Multiplier, 1.0)
        self.assertEqual(world.Climate.Temperature, 30)
        self.assertTrue(world.Modified)

    def test_volume_that_throws_is_skipped(self):
        broken = self.world(owner="WeatherVolume_C_UAID_BAD_1",
                            factory="make_throwing_volume")
        world = self.world()
        self.register("VoyageWeatherVolume", broken, world)
        ok, message = self.reset()
        self.assertTrue(ok, message)
        self.assertEqual(world.Priority, -1.0)
        self.assertEqual(broken.Priority, 99.0)
        lines = list(self.g.printed.values())
        self.assertTrue(any("skipped a weather volume" in line for line in lines), lines)

    def test_mask_that_is_not_a_number_is_reported(self):
        world = self.world()
        world.WeatherPreset.WeatherMask = "x"
        self.register("VoyageWeatherVolume", world)
        ok, message = self.reset()
        self.assertFalse(ok)
        self.assertIn("WeatherMask", message)
        self.assertEqual(world.WeatherMask, 7)
        self.assertEqual(world.Priority, -1.0)

    def test_level_placed_override_is_not_removed(self):
        self.register("VoyageWeatherVolume", self.world())
        placed = self.g.make_override(
            "BP_WeatherVolumeActor_C /Game/Maps/VoyageWorld2.VoyageWorld2:"
            "PersistentLevel.BP_WeatherVolumeActor_C_UAID_005056C00001181501_1")
        self.register("BP_WeatherVolumeActor_C", placed)
        ok, message = self.reset()
        self.assertTrue(ok, message)
        self.assertFalse(placed.destroyed)
        self.assertNotIn("removed", message)

    def test_each_world_criterion_stops_a_decoy(self):
        world = self.world()
        wide_radius_preset = self.g.make_preset("DA_WeatherPreset_Default", 30)
        small = self.g.make_volume("WeatherVolume_C_UAID_AAAA_1", wide_radius_preset, 4.5e6, 99.0)
        other_preset = self.g.make_preset("DA_WeatherPreset_Snow_Biome_Default", -40)
        wrong_preset = self.g.make_volume("WeatherVolume_C_UAID_BBBB_2", other_preset, 1e10, 99.0)
        self.register("VoyageWeatherVolume", world, small, wrong_preset)
        ok, message = self.reset()
        self.assertTrue(ok, message)
        self.assertEqual(world.Priority, -1.0)
        self.assertEqual(small.Priority, 99.0)
        self.assertFalse(small.Modified)
        self.assertEqual(wrong_preset.Priority, 99.0)
        self.assertFalse(wrong_preset.Modified)

    def test_override_with_unreadable_name_is_not_removed(self):
        self.register("VoyageWeatherVolume", self.world())
        unnamed = self.g.make_override("BP_WeatherVolumeActor_C unused")
        self.lua.execute("function unnamed_fail(a) function a:GetFullName() error('no name') end end")
        self.g.unnamed_fail(unnamed)
        self.register("BP_WeatherVolumeActor_C", unnamed)
        ok, message = self.reset()
        self.assertTrue(ok, message)
        self.assertFalse(unnamed.destroyed)
        self.assertNotIn("removed", message)

    def customized_world(self):
        world = self.g.make_volume(WORLD, self.g.make_cheat_preset(), 1e10, 99.0)
        world.Climate.Temperature = -100
        return world

    def test_customize_preset_is_restored_to_default(self):
        world = self.customized_world()
        default = self.g.make_preset("DA_WeatherPreset_Default", 30)
        self.register("VoyageWeatherVolume", world)
        self.register("VoyageWeatherPreset", self.g.make_cheat_preset(), default)
        ok, message = self.reset()
        self.assertTrue(ok, message)
        self.assertEqual(world.WeatherPreset.full_name, default.full_name)
        self.assertEqual(world.Climate.Temperature, 30)
        self.assertEqual(world.Climate.MaxTemp, 34)
        self.assertEqual(world.Climate.Precipitation, 0)
        self.assertEqual(world.Wind.Direction, 90)
        self.assertEqual(world.Wind.SpeedInKm, 12)
        self.assertEqual(world.Priority, -1.0)
        self.assertEqual(world.Multiplier, 1.0)
        self.assertTrue(world.Modified)

    def test_customize_without_default_preset_changes_nothing(self):
        world = self.customized_world()
        cheat = world.WeatherPreset
        template = self.g.make_preset("Default__DA_WeatherPreset_Default", 30)
        self.register("VoyageWeatherVolume", world)
        self.register("VoyageWeatherPreset", template)
        live = self.g.make_override(
            "BP_WeatherVolumeActor_C /Game/Maps/VoyageWorld2.VoyageWorld2:"
            "PersistentLevel.BP_WeatherVolumeActor_C_2147480001")
        self.register("BP_WeatherVolumeActor_C", live)
        ok, message = self.reset()
        self.assertFalse(ok)
        self.assertIn("Customize", message)
        self.assertEqual(world.Priority, 99.0)
        self.assertEqual(world.WeatherPreset.full_name, cheat.full_name)
        self.assertFalse(world.Modified)
        self.assertFalse(live.destroyed)

    def test_default_preset_lookup_ignores_templates(self):
        world = self.customized_world()
        # Short name is exactly the default preset's, so only the isTemplate check on the
        # full name (which contains Default__) can reject it.
        template = self.g.make_preset("DA_WeatherPreset_Default", 99)
        template.full_name = "VoyageWeatherPreset /Game/X.Default__Y_C:DA_WeatherPreset_Default"
        live = self.g.make_preset("DA_WeatherPreset_Default", 30)
        self.register("VoyageWeatherVolume", world)
        self.register("VoyageWeatherPreset", template, live)
        ok, message = self.reset()
        self.assertTrue(ok, message)
        self.assertEqual(world.WeatherPreset.full_name, live.full_name)
        self.assertEqual(world.Climate.Temperature, 30)

    def test_other_presets_are_still_not_world_volumes(self):
        world = self.customized_world()
        rain = self.g.make_preset("DA_WeatherPreset_Rain", 10)
        decoy = self.g.make_volume("WeatherVolume_C_UAID_CCCC_3", rain, 1e10, 99.0)
        default = self.g.make_preset("DA_WeatherPreset_Default", 30)
        self.register("VoyageWeatherVolume", world, decoy)
        self.register("VoyageWeatherPreset", default)
        ok, message = self.reset()
        self.assertTrue(ok, message)
        self.assertEqual(world.Priority, -1.0)
        self.assertEqual(decoy.Priority, 99.0)
        self.assertFalse(decoy.Modified)
        self.assertEqual(decoy.WeatherPreset.full_name, rain.full_name)

    def test_stray_cheat_preset_on_another_volume_is_reported(self):
        world = self.world()
        regional = self.g.make_volume("WeatherVolume_C_UAID_DDDD_4",
                                      self.g.make_cheat_preset(), 4.5e6, 99.0)
        self.register("VoyageWeatherVolume", world, regional)
        ok, message = self.reset()
        self.assertFalse(ok)
        self.assertIn("custom weather", message)
        self.assertEqual(world.Priority, -1.0)
        self.assertEqual(regional.Priority, 99.0)
        self.assertEqual(regional.WeatherPreset.full_name,
                         "VoyageWeatherPreset /Game/Data/WeatherPresets/"
                         "DA_WeatherPreset_Cheat_Default.DA_WeatherPreset_Cheat_Default")
        self.assertFalse(regional.Modified)
        lines = list(self.g.printed.values())
        self.assertTrue(any("still has the admin menu's custom weather" in line
                            for line in lines), lines)

    def test_preset_that_will_not_take_is_reported(self):
        world = self.g.make_stubborn_preset_volume(
            WORLD, self.g.make_cheat_preset(), 1e10, 99.0)
        default = self.g.make_preset("DA_WeatherPreset_Default", 30)
        self.register("VoyageWeatherVolume", world)
        self.register("VoyageWeatherPreset", default)
        ok, message = self.reset()
        self.assertFalse(ok)
        self.assertIn("WeatherPreset", message)
        self.assertEqual(world.Priority, -1.0)
        self.assertEqual(world.Climate.Temperature, 30)
        self.assertTrue(world.Modified)


if __name__ == "__main__":
    unittest.main(verbosity=2)
