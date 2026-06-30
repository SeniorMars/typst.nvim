local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")
typst.reset()
typst.setup({ root = root })

local config = require("typst.config")
local mappings = require("typst.edit.mappings")

local specs = mappings._specs_for_tests()
local defaults = config.snapshot().mappings

local function key_set(items)
    local out = {}
    for _, item in ipairs(items) do
        assert(
            type(item.key) == "string" and item.key ~= "",
            "missing spec key"
        )
        assert(
            type(item.plug) == "string"
                and item.plug:match("^<Plug>%((typst%-[-%w]+)%)$"),
            ("invalid plug for %s: %s"):format(item.key, tostring(item.plug))
        )
        assert(
            type(item.desc) == "string" and item.desc ~= "",
            ("missing desc for %s"):format(item.key)
        )
        assert(out[item.key] == nil, "duplicate mapping key: " .. item.key)
        out[item.key] = item
    end
    return out
end

local function assert_same_keys(label, actual_items, expected_table)
    local actual = key_set(actual_items)
    for key, _ in pairs(expected_table) do
        assert(
            actual[key],
            ("%s missing mapping spec for %s"):format(label, key)
        )
    end
    for key, _ in pairs(actual) do
        assert(
            expected_table[key] ~= nil,
            ("%s has spec for unknown config key %s"):format(label, key)
        )
    end
    return actual
end

local top_level_defaults = {}
for key, value in pairs(defaults) do
    if
        key ~= "enabled"
        and key ~= "repeat_transform"
        and key ~= "commands"
        and key ~= "insert"
        and key ~= "textobjects"
    then
        top_level_defaults[key] = value
    end
end

local top_level_specs = {}
vim.list_extend(top_level_specs, specs.motions)
vim.list_extend(top_level_specs, specs.normal)

local actual_top_level =
    assert_same_keys("top-level mappings", top_level_specs, top_level_defaults)
assert_same_keys("command mappings", specs.commands, defaults.commands)
assert_same_keys("insert mappings", specs.insert, defaults.insert)
assert_same_keys("textobject mappings", specs.textobjects, defaults.textobjects)

local plug_by_mode = {}
local function expect_plug_modes(spec_items, modes)
    for _, spec in ipairs(spec_items) do
        assert(
            plug_by_mode[spec.plug] == nil,
            "duplicate plug in mapping specs: " .. spec.plug
        )
        plug_by_mode[spec.plug] = modes
    end
end

expect_plug_modes(specs.motions, specs.motion_modes)
expect_plug_modes(specs.normal, { "n" })
expect_plug_modes(specs.commands, { "n" })
expect_plug_modes(specs.insert, { "i" })
expect_plug_modes(specs.textobjects, specs.textobject_modes)

assert(actual_top_level.hover.plug == "<Plug>(typst-hover)")
assert(actual_top_level.follow.plug == "<Plug>(typst-follow)")
assert(actual_top_level.match.plug == "<Plug>(typst-match)")

mappings.register_plugs()
for plug, modes in pairs(plug_by_mode) do
    for _, mode in ipairs(modes) do
        assert(
            vim.fn.maparg(plug, mode) ~= "",
            ("missing registered %s-mode plug %s"):format(mode, plug)
        )
    end
end

typst.reset({ force = true })
vim.cmd("qa!")
