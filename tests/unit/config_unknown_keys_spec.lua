local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")
local config = require("typst.config")
local log = require("typst.core.log")

typst.reset()
log.clear()
local original_notify = vim.notify
local notifications = {}
local notify_ok, notify_err = xpcall(function()
    rawset(vim, "notify", function(message, level)
        notifications[#notifications + 1] = {
            message = message,
            level = level,
        }
    end)
    typst.setup({
        diagnostic = {
            source = "always",
        },
    })
    local unknown = config.last_unknown_keys()
    assert(
        vim.tbl_contains(unknown, "diagnostic"),
        "unknown top-level config keys should be recorded"
    )

    local saw_warning = false
    for _, entry in ipairs(log.entries()) do
        if
            entry.level == "warn"
            and entry.message == "unknown Typst config keys"
            and vim.tbl_contains(entry.fields.keys or {}, "diagnostic")
        then
            saw_warning = true
            break
        end
    end
    assert(saw_warning, "unknown config keys should warn by default")
    assert(
        notifications[1]
            and notifications[1].level == vim.log.levels.WARN
            and notifications[1].message:find("diagnostic", 1, true),
        "unknown config keys should be visible through vim.notify"
    )
end, debug.traceback)
rawset(vim, "notify", original_notify)
assert(notify_ok, notify_err)

local notify_failure_ok, notify_failure_err = xpcall(function()
    rawset(vim, "notify", function()
        error("synthetic notify failure")
    end)
    typst.setup({
        diagnostic = {
            source = "always",
        },
    })
end, debug.traceback)
rawset(vim, "notify", original_notify)
assert(
    notify_failure_ok,
    notify_failure_err
        or "unknown-key notification failures should not abort setup"
)

local strict_ok, strict_err = pcall(function()
    typst.setup({
        validation = "strict",
        diagnostics = {
            soruce = "always",
        },
    })
end)
assert(not strict_ok, "strict validation should reject unknown config keys")
assert(
    tostring(strict_err):find("diagnostics.soruce", 1, true),
    "strict validation should include the full unknown config path"
)

local empty_main_ok, empty_main_err = pcall(function()
    typst.setup({
        main = {
            [""] = "main.typ",
        },
    })
end)
assert(not empty_main_ok, "empty main mapping keys should be rejected")
assert(
    tostring(empty_main_err):find(
        "main table keys must be non-empty strings",
        1,
        true
    ),
    "empty main mapping keys should report a friendly validation error"
)

local previous_cwd = vim.fn.getcwd()
local duplicate_root = typst_test_cache_path("unknown-keys-main-duplicates")
vim.fn.mkdir(duplicate_root .. "/docs", "p")
vim.cmd.cd(vim.fn.fnameescape(duplicate_root))
local duplicate_ok, duplicate_err = pcall(function()
    typst.setup({
        main = {
            docs = "main.typ",
            ["./docs"] = "book.typ",
        },
    })
end)
vim.cmd.cd(vim.fn.fnameescape(previous_cwd))
assert(
    not duplicate_ok,
    "duplicate normalized main mapping roots should be rejected"
)
assert(
    tostring(duplicate_err):find(
        "duplicate main table key after normalization",
        1,
        true
    ),
    "duplicate normalized main mapping roots should report a clear error"
)

local relative_main_base_ok, relative_main_base_err = pcall(function()
    typst.setup({
        main_base_dir = "docs",
        main = {
            chapters = "main.typ",
        },
    })
end)
assert(not relative_main_base_ok, "relative main_base_dir should be rejected")
assert(
    tostring(relative_main_base_err):find(
        "main_base_dir must be an absolute path",
        1,
        true
    ),
    "relative main_base_dir should report a clear validation error"
)

local mutation_root = typst_test_cache_path("config-main-mutation")
vim.fn.mkdir(mutation_root .. "/docs", "p")
vim.cmd.cd(vim.fn.fnameescape(mutation_root))
local callback = function() end
local user_opts = {
    main = {
        ["./docs"] = "main.typ",
    },
    preview = {
        open = callback,
    },
}
typst.setup(user_opts)
vim.cmd.cd(vim.fn.fnameescape(previous_cwd))
assert(
    user_opts.main["./docs"] == "main.typ",
    "setup should not mutate caller-owned main mapping keys"
)
assert(
    vim.tbl_count(user_opts.main) == 1,
    "setup should not add normalized keys to caller-owned main mappings"
)
assert(
    user_opts.preview.open == callback,
    "setup copy should preserve callback references in user opts"
)

local compile_profile_ok, compile_profile_err = pcall(function()
    typst.setup({
        validation = "strict",
        compile = {
            profiles = {
                draft = {
                    outpt_dir = "build",
                },
            },
        },
    })
end)
assert(
    not compile_profile_ok,
    "strict validation should reject unknown compile profile keys"
)
assert(
    tostring(compile_profile_err):find(
        "compile.profiles.draft.outpt_dir",
        1,
        true
    ),
    "compile profile unknown-key errors should include the full profile path"
)

local export_profile_ok, export_profile_err = pcall(function()
    typst.setup({
        validation = "strict",
        exports = {
            profiles = {
                web = {
                    outpt_format = "svg",
                },
            },
        },
    })
end)
assert(
    not export_profile_ok,
    "strict validation should reject unknown export profile keys"
)
assert(
    tostring(export_profile_err):find(
        "exports.profiles.web.outpt_format",
        1,
        true
    ),
    "export profile unknown-key errors should include the full profile path"
)

log.clear()
typst.setup({
    validation = "off",
    diagnostic = {
        source = "always",
    },
})
assert(
    vim.tbl_contains(config.last_unknown_keys(), "diagnostic"),
    "disabled validation should still expose the latest unknown keys"
)
for _, entry in ipairs(log.entries()) do
    assert(
        entry.message ~= "unknown Typst config keys",
        "validation=off should suppress unknown-key warnings"
    )
end

typst.setup({
    integrations = {
        tinymist = {
            client_names = { "tinymist_custom" },
            capabilities = {
                workspace = {
                    configuration = true,
                },
            },
            settings = {
                formatterMode = "typstyle",
            },
        },
    },
    main = {
        ["."] = "main.typ",
    },
    root_markers = { ".git", "typst.toml", "custom.marker" },
    compile = {
        profiles = {
            draft = {
                output_dir = typst_test_cache_path("unknown-keys-draft"),
            },
        },
        fragments = {
            templates = {
                custom = {
                    prefix = "#let body = [",
                    suffix = "]",
                },
            },
        },
    },
    exports = {
        profiles = {
            web = {
                output_format = "svg",
            },
        },
    },
    format = {
        provider = function() end,
    },
    lint = {
        provider = function() end,
    },
    grammar = {
        provider = function() end,
    },
    preview = {
        provider = function() end,
    },
    render = {
        provider = function() end,
    },
    bibliography = {
        attachment_fields = { "pdf", "file", "custom_file" },
        attachment_paths = { "{key}.pdf", "papers/{key}.pdf" },
    },
    syntax = {
        packages = {
            ["@preview/example"] = {
                name = "example",
            },
        },
    },
    viewer = {
        providers = {
            custom_viewer = {
                open = "viewer",
            },
        },
    },
})
assert(
    #config.last_unknown_keys() == 0,
    "documented map-like config sections should not be flagged unknown"
)
