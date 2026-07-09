local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local manager = require("typst.runtime.resource_manager")
local typst = require("typst")

typst.reset({ force = true })

local module_name = "typst.resources.outputs"
local original_loaded = package.loaded[module_name]
local searchers = package.searchers or package.loaders
local inserted = false

local function failing_searcher(name)
    if name ~= module_name then
        return nil
    end
    return function()
        error("synthetic outputs module load failure")
    end
end

local ok, err = xpcall(function()
    package.loaded[module_name] = nil
    table.insert(searchers, 1, failing_searcher)
    inserted = true

    local snapshot = manager.snapshot()
    assert(
        snapshot.global
            and snapshot.global.output_locks
            and snapshot.global.output_locks.ok == false,
        "snapshot should report output lock load failures structurally"
    )
    assert(
        tostring(snapshot.global.output_locks.error):find(
            "synthetic outputs module load failure",
            1,
            true
        ),
        "snapshot should include the protected output lock error"
    )
end, debug.traceback)

if inserted then
    table.remove(searchers, 1)
end
package.loaded[module_name] = original_loaded
typst.reset({ force = true })

if not ok then
    error(err)
end

vim.cmd("qa!")
