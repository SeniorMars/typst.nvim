local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local required_examples = {
    "docs/examples/minimal.lua",
    "docs/examples/tinymist-detect.lua",
    "docs/examples/coc-tinymist.lua",
    "docs/examples/native-preview-browser.lua",
    "docs/examples/typst-preview-compat.lua",
    "docs/examples/custom-compiler-provider.lua",
    "docs/examples/custom-source-map-provider.lua",
    "docs/examples/completion-cmp.lua",
    "docs/examples/completion-blink.lua",
    "docs/examples/conceal-minimal.lua",
}

local executable_examples = {
    "docs/examples/minimal.lua",
    "docs/examples/tinymist-detect.lua",
    "docs/examples/coc-tinymist.lua",
    "docs/examples/native-preview-browser.lua",
    "docs/examples/custom-compiler-provider.lua",
    "docs/examples/custom-source-map-provider.lua",
    "docs/examples/conceal-minimal.lua",
}

local syntax_only_examples = {
    ["docs/examples/completion-cmp.lua"] = true,
    ["docs/examples/completion-blink.lua"] = true,
    ["docs/examples/typst-preview-compat.lua"] = true,
}

for _, path in ipairs(required_examples) do
    assert(vim.fn.filereadable(root .. "/" .. path) == 1, "missing " .. path)
    local text = table.concat(vim.fn.readfile(root .. "/" .. path), "\n")
    assert(
        not text:find("project%.services"),
        "examples must not inspect internal project service tables: " .. path
    )
    assert(
        not text:find("typst.project.store", 1, true),
        "examples must not require internal project store: " .. path
    )
    assert(
        not text:find("typst.project.registry", 1, true),
        "examples must not require internal project registry: " .. path
    )
    local chunk, err = loadfile(root .. "/" .. path)
    assert(chunk, ("invalid Lua example %s: %s"):format(path, tostring(err)))
end

local typst = require("typst")

local function reset_runtime()
    typst.reset({ force = true })
end

for _, path in ipairs(executable_examples) do
    reset_runtime()
    local ok, err = xpcall(function()
        dofile(root .. "/" .. path)
    end, debug.traceback)
    reset_runtime()
    assert(
        ok,
        ("example failed during setup %s: %s"):format(path, tostring(err))
    )
end

for path in pairs(syntax_only_examples) do
    assert(
        vim.tbl_contains(required_examples, path),
        "syntax-only example must still be listed as required: " .. path
    )
end

local function validate_custom_compiler_provider()
    reset_runtime()
    local original_system = vim.system
    local original_schedule = vim.schedule
    local system_callback
    local fake_handle = { killed = {} }
    function fake_handle:kill(signal)
        self.killed[#self.killed + 1] = signal
    end

    rawset(vim, "system", function(_cmd, _opts, callback)
        system_callback = callback
        return fake_handle
    end)
    rawset(vim, "schedule", function(callback)
        callback()
    end)
    local ok, err = xpcall(function()
        dofile(root .. "/docs/examples/custom-compiler-provider.lua")
        local providers = require("typst.integrations.providers")
        local provider = assert(
            providers.get("compiler", "example-compiler"),
            "custom compiler example should register its provider"
        )
        local project = {
            key = "docs-example",
            root = root,
            main = root .. "/tests/fixtures/basic/main.typ",
        }
        local start_result = provider.start(project, function()
            error("custom compiler example must not pretend to implement watch")
        end)
        assert(
            start_result
                and start_result.ok == false
                and start_result.reason == "unsupported",
            "custom compiler example should fail watch/start clearly"
        )

        local compile_result
        local pending = provider.compile(project, function(result)
            compile_result = result
        end)
        assert(
            pending and pending.pending and pending.handle == fake_handle,
            "custom compiler example should return a pending process handle"
        )

        local stop_result
        local stop_pending = provider.stop(project, function(result)
            stop_result = result
        end)
        assert(
            stop_pending and stop_pending.pending,
            "custom compiler stop should remain pending until process exit"
        )
        assert(
            stop_result == nil,
            "custom compiler stop must not report stopped before exit"
        )
        assert(
            fake_handle.killed[1] == 15,
            "custom compiler stop should terminate the active process"
        )

        assert(
            system_callback,
            "custom compiler example should start vim.system"
        )
        system_callback({ code = 143, stdout = "", stderr = "" })
        vim.wait(1000, function()
            return stop_result ~= nil
        end, 10, false)
        assert(
            stop_result and stop_result.stopped == true,
            "custom compiler stop should confirm stop after process exit"
        )
        assert(
            compile_result == nil,
            "custom compiler stop should not also emit a compile completion"
        )
    end, debug.traceback)

    vim.schedule = original_schedule
    vim.system = original_system
    reset_runtime()
    if not ok then
        error(err)
    end
end

validate_custom_compiler_provider()

local source_map_capability_methods = {
    forward = { "forward", "run" },
    inverse = { "inverse", "resolve", "run" },
    source_maps = { "generate", "resolve", "run" },
    browser_click = { "browser_inverse", "resolve", "run" },
}

local function has_any_method(provider, names)
    for _, name in ipairs(names or {}) do
        if type(provider[name]) == "function" then
            return true
        end
    end
    return false
end

local function validate_custom_source_map_provider()
    reset_runtime()
    local ok, err = xpcall(function()
        dofile(root .. "/docs/examples/custom-source-map-provider.lua")
        local providers = require("typst.integrations.providers")
        local provider = assert(
            providers.get("source_map", "main-start"),
            "custom source-map example should register its provider"
        )
        local caps = type(provider.capabilities) == "function"
                and provider.capabilities()
            or {}
        for capability, enabled in pairs(caps) do
            if enabled == true then
                assert(
                    has_any_method(
                        provider,
                        source_map_capability_methods[capability]
                    ),
                    ("source-map example advertises %s without a matching method"):format(
                        capability
                    )
                )
            end
        end
        assert(
            caps.browser_click == true,
            "custom source-map example should advertise browser clicks"
        )
        assert(
            caps.forward ~= true
                and caps.inverse ~= true
                and caps.source_maps ~= true,
            "custom source-map example should not advertise unsupported methods"
        )

        local result = provider.browser_inverse({
            main = root .. "/tests/fixtures/basic/main.typ",
        }, { page = "1", x = "10", y = "20" })
        assert(result.ok == true, "browser inverse example should succeed")
        assert(
            result.line == 1 and result.column == 1,
            "browser inverse example should map to file start"
        )
    end, debug.traceback)
    reset_runtime()
    if not ok then
        error(err)
    end
end

validate_custom_source_map_provider()

local readme = table.concat(vim.fn.readfile(root .. "/README.md"), "\n")
assert(
    readme:find("docs/examples", 1, true),
    "README should point workflow users to docs/examples"
)
assert(
    readme:find(":help typst-commands", 1, true),
    "README should direct command inventory to :help typst-commands"
)

vim.cmd("qa!")
