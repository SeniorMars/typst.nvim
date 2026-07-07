local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local spec = require("typst.api.spec")
local typst = require("typst")

local function clear_spec_globals()
    for _, global in ipairs(spec.globals or {}) do
        _G[global.name] = nil
    end
end

typst.reset({ force = true })
clear_spec_globals()

typst.setup({
    root = root,
    output_dir = typst_test_cache_path("api-globals-retained-output"),
    preview = {
        open = function()
            return true
        end,
        stop = function()
            return {
                pending = true,
                on_finish_style = "colon",
                on_finish = function()
                    return nil
                end,
            }
        end,
    },
})

for _, global in ipairs(spec.globals or {}) do
    assert(type(_G[global.name]) == "function", "setup should install globals")
end

local main = root .. "/tests/fixtures/basic/main.typ"
vim.cmd.edit(main)
typst.project.set_main(main)
assert(typst.viewer.preview() == true, "fixture should open preview")
local retained = typst.reset({ reason = "api-globals-retained-reset" })
assert(retained.retained_projects == true, "reset should retain fixture")
for _, global in ipairs(spec.globals or {}) do
    assert(
        type(_G[global.name]) == "function",
        "retained reset should preserve owned global: " .. global.name
    )
end

local user_foldexpr = function()
    return "user-fold"
end
_G.typst_nvim_foldexpr = user_foldexpr

typst.setup({
    root = root,
    output_dir = typst_test_cache_path("api-globals-retained-output"),
})
assert(
    _G.typst_nvim_foldexpr == user_foldexpr,
    "setup should not overwrite user-replaced global"
)

local forced = typst.reset({ force = true })
assert(forced.retained_projects == false, "force reset should not retain")
assert(
    _G.typst_nvim_foldexpr == user_foldexpr,
    "force reset should preserve non-owned user global"
)
for _, global in ipairs(spec.globals or {}) do
    if global.name ~= "typst_nvim_foldexpr" then
        assert(
            _G[global.name] == nil,
            "force reset should remove owned global: " .. global.name
        )
    end
end
_G.typst_nvim_foldexpr = nil

vim.cmd("qa!")
