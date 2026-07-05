local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local config = require("typst.config")
local docs = require("typst.config.docs")

local default_unknown =
    config._collect_unknown_keys_for_tests(config.defaults())
assert(
    #default_unknown == 0,
    "all default config keys should be accepted by unknown-key logic: "
        .. table.concat(default_unknown, ", ")
)

for _, item in ipairs(docs.schema()) do
    assert(
        config._known_path_for_tests(item.path),
        "generated schema path is not runtime-known: " .. item.path
    )
end

local bad_nested = config._collect_unknown_keys_for_tests({
    diagnostics = {
        typo = true,
    },
})
assert(
    vim.tbl_contains(bad_nested, "diagnostics.typo"),
    "invalid nested keys should be reported with their full path"
)

local bad_profile = config._collect_unknown_keys_for_tests({
    compile = {
        profiles = {
            draft = {
                unsupported = true,
            },
        },
    },
})
assert(
    vim.tbl_contains(bad_profile, "compile.profiles.draft.unsupported"),
    "compile profile keys should follow the same unknown-key contract"
)

local bad_export_profile = config._collect_unknown_keys_for_tests({
    exports = {
        profiles = {
            svg_preview = {
                unsupported = true,
            },
        },
    },
})
assert(
    vim.tbl_contains(
        bad_export_profile,
        "exports.profiles.svg_preview.unsupported"
    ),
    "export profile keys should follow the same unknown-key contract"
)

vim.cmd("qa!")
