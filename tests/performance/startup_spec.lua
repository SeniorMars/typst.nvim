local perf = require("tests.performance_report")

local root = vim.fn.getcwd()
local spec_name = "startup_spec"

local function clear_typst_modules()
    for module_name in pairs(package.loaded) do
        if module_name == "typst" or module_name:find("^typst%.") then
            package.loaded[module_name] = nil
        end
    end
    vim.g.loaded_typst_nvim = 1
end

local function setup_once(label, opts)
    clear_typst_modules()
    local typst = require("typst")
    local _, elapsed = perf.elapsed_ms(function()
        typst.setup(opts)
    end)
    local telemetry = require("typst.core.telemetry").snapshot()
    perf.record_metric(spec_name, {
        name = label,
        elapsed_ms = elapsed,
        telemetry_setup_ms = telemetry.setup and telemetry.setup.last_ms or nil,
        budget_ms = 0,
        ratio = 0,
    })
    typst.reset({ force = true, keep_telemetry = true })
    return elapsed
end

setup_once("setup.default", {
    root = root,
    output_dir = typst_test_cache_path("startup-default-output"),
    completion = {
        package_cache_prewarm = false,
    },
})
setup_once("setup.optional_features", {
    root = root,
    output_dir = typst_test_cache_path("startup-optional-output"),
    conceal = {
        enabled = true,
    },
    completion = {
        include_packages = true,
        include_templates = true,
        include_paths = true,
        include_csl_styles = true,
        include_raw_languages = true,
        include_colors = true,
        include_fonts = true,
        package_cache_prewarm = true,
    },
    folds = {
        enabled = true,
    },
    matchparen = {
        enabled = true,
    },
    toc = {
        follow_cursor = true,
    },
})
local path = perf.write(spec_name)
print(("startup benchmark report: %s"):format(path))

vim.cmd("qa!")
