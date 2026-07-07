local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")
local exports = require("typst.api.exports")
local spec = require("typst.api.spec")

local function assert_spec_global_names()
    for _, global in ipairs(spec.globals or {}) do
        assert(
            type(global.name) == "string" and global.name:match("^typst_nvim_"),
            "API globals must use the typst_nvim_ prefix"
        )
    end
end

local function clear_spec_globals()
    for _, global in ipairs(spec.globals or {}) do
        _G[global.name] = nil
    end
end

assert_spec_global_names()

typst.reset({ force = true })
for _, global in ipairs(spec.globals or {}) do
    assert(
        _G[global.name] == nil,
        "reset should remove owned global: " .. global.name
    )
end

typst.setup({
    completion = {
        package_cache_prewarm = false,
    },
    root_markers = {},
})
local owned = exports.owned_globals()
for _, global in ipairs(spec.globals or {}) do
    assert(
        type(_G[global.name]) == "function",
        "setup should reinstall API global: " .. global.name
    )
    assert(owned[global.name] == true, "missing ownership for " .. global.name)
end

package.loaded["typst.api.exports"] = nil
local reloaded_exports = require("typst.api.exports")
local reloaded_owned = reloaded_exports.owned_globals()
for _, global in ipairs(spec.globals or {}) do
    assert(
        reloaded_owned[global.name] == true,
        "reloaded exports should preserve ownership for " .. global.name
    )
end
local reloaded_install = reloaded_exports.install_globals()
assert(
    #(reloaded_install.skipped or {}) == 0,
    "reloaded exports should not treat owned globals as collisions"
)
exports = reloaded_exports

typst.reset({ force = true })
clear_spec_globals()

local user_global = function()
    return "user-owned"
end
_G.typst_nvim_omnifunc = user_global
local install = exports.install_globals()
assert(
    _G.typst_nvim_omnifunc == user_global,
    "install_globals should not overwrite a user-owned global"
)
local skipped_collision = false
for _, skipped in ipairs(install.skipped or {}) do
    if
        skipped.name == "typst_nvim_omnifunc"
        and skipped.reason == "collision"
    then
        skipped_collision = true
    end
end
assert(skipped_collision, "global collision should be reported")
assert(
    exports.owned_globals().typst_nvim_omnifunc == nil,
    "collided global should not be marked owned"
)
local collision_status = exports.global_status()
assert(
    collision_status.skipped_count >= 1,
    "global_status should expose skipped globals"
)
local status_saw_collision = false
for _, skipped in ipairs(collision_status.skipped or {}) do
    if
        skipped.name == "typst_nvim_omnifunc"
        and skipped.reason == "collision"
    then
        status_saw_collision = true
    end
end
assert(
    status_saw_collision,
    "global_status should preserve global collision details"
)

local reset = exports.reset_globals()
assert(
    _G.typst_nvim_omnifunc == user_global,
    "reset_globals should preserve non-owned user globals"
)
for _, removed in ipairs(reset.removed or {}) do
    assert(
        removed ~= "typst_nvim_omnifunc",
        "reset_globals should not remove user-owned globals"
    )
end

clear_spec_globals()
exports.install_globals()
for _, global in ipairs(spec.globals or {}) do
    assert(
        type(_G[global.name]) == "function",
        "install_globals should install " .. global.name
    )
end

local original_fold_expr = require("typst.edit.folds").expr
local original_omnifunc = require("typst.completion").omnifunc
local original_formatexpr = require("typst.edit.formatexpr").formatexpr
local fold_lnum = nil
local omnifunc_args = nil
local formatexpr_args = nil
require("typst.completion").omnifunc = function(findstart, base)
    omnifunc_args = { findstart = findstart, base = base }
    return findstart == 1 and 0 or {}
end
require("typst.edit.formatexpr").formatexpr = function(lnum, count)
    formatexpr_args = { lnum = lnum, count = count }
    return 0
end
require("typst.edit.folds").expr = function(lnum)
    fold_lnum = lnum
    return "="
end
assert(
    _G.typst_nvim_omnifunc(1, "al") == 0
        and omnifunc_args.findstart == 1
        and omnifunc_args.base == "al",
    "typst_nvim_omnifunc should forward omnifunc arguments"
)
vim.v.lnum = 3
local expected_format_count = vim.v.count
assert(
    _G.typst_nvim_formatexpr() == 0
        and formatexpr_args.lnum == 3
        and formatexpr_args.count == expected_format_count,
    "typst_nvim_formatexpr should pass vim.v.lnum and vim.v.count"
)
vim.v.lnum = 7
assert(
    _G.typst_nvim_foldexpr() == "=" and fold_lnum == 7,
    "typst_nvim_foldexpr should pass vim.v.lnum to folds.expr"
)
require("typst.completion").omnifunc = original_omnifunc
require("typst.edit.formatexpr").formatexpr = original_formatexpr
require("typst.edit.folds").expr = original_fold_expr

assert(
    type(_G.typst_nvim_foldtext()) == "string",
    "typst_nvim_foldtext should call folds.foldtext"
)
assert(
    type(_G.typst_nvim_indentexpr()) == "number",
    "typst_nvim_indentexpr should call indent.indent"
)

typst.reset({ force = true })
clear_spec_globals()
local preview_stop_calls = 0
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("api-globals-retained-reset-output"),
    preview = {
        open = function()
            return true
        end,
        stop = function()
            preview_stop_calls = preview_stop_calls + 1
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
local main = root .. "/tests/fixtures/basic/main.typ"
vim.cmd.edit(main)
typst.project.set_main(main)
assert(typst.viewer.preview() == true, "retained-reset fixture should preview")
local user_foldexpr = function()
    return "user-fold"
end
_G.typst_nvim_foldexpr = user_foldexpr
local retained_reset = typst.reset({ reason = "api-globals-retained-reset" })
assert(
    retained_reset.retained_projects == true,
    "retained-reset fixture should retain projects"
)
assert(preview_stop_calls == 1, "retained reset should try preview stop")
assert(
    _G.typst_nvim_foldexpr == user_foldexpr,
    "retained reset should preserve user replacement global"
)
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("api-globals-retained-reset-output"),
    preview = {
        open = function()
            return true
        end,
    },
})
assert(
    _G.typst_nvim_foldexpr == user_foldexpr,
    "setup after retained reset should not overwrite user replacement global"
)
local forced_reset = typst.reset({ force = true })
assert(
    forced_reset.retained_projects == false,
    "force reset should not retain projects for global cleanup fixture"
)
assert(
    _G.typst_nvim_foldexpr == user_foldexpr,
    "non-retained reset should preserve non-owned user replacement global"
)
for _, global in ipairs(spec.globals or {}) do
    if global.name ~= "typst_nvim_foldexpr" then
        assert(
            _G[global.name] == nil,
            "non-retained reset should remove owned global: " .. global.name
        )
    end
end
_G.typst_nvim_foldexpr = nil

vim.cmd("qa!")
