"""Offline tests for weatherreset.lua.

Runs the module in a real Lua 5.4 through lupa, against plain Lua tables standing in for
the game's objects. UE4SS is not involved: FindAllOf, print and every object are mocks.
What this proves is the module's own logic - which volume it picks, what it writes and
what it leaves alone. Whether the game honours the writes is tested in the game.

Requires lupa:  pip install lupa

Usage:  python tools/test_weatherreset.py
"""

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
        Climate = { Temperature = temperature, MinTemp = 15, MaxTemp = 30, Precipitation = 0,
                    Thunder = 1, CloudCoverage = 0.3, FogDensity = 0 },
        Wind = { Direction = 90, SpeedInKm = 12 },
    })
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

    def world(self, owner=WORLD, factory="make_volume"):
        preset = self.g.make_preset("DA_WeatherPreset_Default", 30)
        return self.g[factory](owner, preset, 1e10, 99.0)

    def snow(self):
        preset = self.g.make_preset("DA_WeatherPreset_Snow_Biome_Default", -40)
        return self.g.make_volume(SNOW, preset, 4.5e6, 1.0)

    def register(self, cls, *objects):
        self.g.registry[cls] = self.lua.table(*objects)

    def reset(self):
        return self.lua.require("weatherreset")[0].reset()

    def test_resets_world_volume_to_its_preset(self):
        world = self.world()
        self.register("VoyageWeatherVolume", world, self.snow())
        ok, message = self.reset()
        self.assertTrue(ok, message)
        self.assertEqual(world.Priority, -1.0)
        self.assertEqual(world.Multiplier, 1.0)
        self.assertEqual(world.WeatherMask, 255)
        self.assertEqual(world.Climate.Temperature, 30)
        self.assertEqual(world.Climate.MaxTemp, 30)
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


if __name__ == "__main__":
    unittest.main(verbosity=2)
