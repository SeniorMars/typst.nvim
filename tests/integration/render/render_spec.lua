local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")
local config = require("typst.config")
local util = require("typst.core.util")
typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("render-output"),
    render = {
        output_dir = typst_test_cache_path("render-cache"),
        output_format = "svg",
    },
})

local main = root .. "/tests/fixtures/basic/main.typ"
vim.cmd.edit(main)
typst.project.set_main(main)
local main_bufnr = vim.api.nvim_get_current_buf()
typst.render.cache_clear({ force = true })

local event = nil
vim.api.nvim_create_autocmd("User", {
    pattern = "TypstRenderCreated",
    callback = function(args)
        event = args.data
    end,
})

local rendered = nil
local run = typst.render.equation(
    { expression = "alpha + beta", open = false },
    function(result)
        rendered = result
    end
)

assert(run.ok and run.pending, "render_equation should start an async render")
assert(
    vim.wait(10000, function()
        return rendered ~= nil
    end, 20),
    "render_equation did not finish"
)
assert(rendered.ok, "render_equation should succeed")
assert(
    rendered.kind == "equation",
    "rendered result should report equation kind"
)
assert(rendered.format == "svg", "rendered result should use configured format")
assert(
    vim.fn.filereadable(rendered.path) == 1,
    "rendered equation output should exist"
)
assert(
    event and event.kind == "equation",
    "TypstRenderCreated event should report equation kind"
)
assert(
    vim.tbl_contains(run.command or {}, "-"),
    "XDG-backed equation render should compile generated source through stdin"
)
assert(
    run.source_path
        and util.path_within(
            run.source_path,
            config.default_render_source_dir()
        ),
    "default equation render source should live under the XDG render source cache"
)
assert(
    vim.fn.filereadable(run.source_path) == 0,
    "finished equation render should remove its XDG wrapper source"
)

local cached =
    typst.render.equation({ expression = "alpha + beta", open = false })
assert(
    cached.ok and cached.cached,
    "second matching equation render should use cache"
)
assert(
    cached.path == rendered.path,
    "cached render should reuse the same output path"
)

vim.fn.delete(typst_test_cache_path("render-cache/manifest.json"))
package.loaded["typst.workflows.render"] = nil
local reloaded_render = require("typst.workflows.render")
local render_cache = require("typst.workflows.render.cache")
local project = require("typst.project").get(0)
local unmanifested_result = nil
local unmanifested_run = reloaded_render.equation(
    project,
    { expression = "alpha + beta", open = false },
    function(result)
        unmanifested_result = result
    end,
    function() end
)
assert(
    unmanifested_run.pending == true,
    "unmanifested render file should be treated as a cache miss"
)
assert(
    unmanifested_run.cached ~= true,
    "unmanifested render file should not be returned as a disk cache hit"
)
assert(
    vim.wait(10000, function()
        return unmanifested_result ~= nil
    end, 20),
    "unmanifested cache miss render did not finish"
)
assert(
    unmanifested_result.ok == true,
    "unmanifested cache miss render should rebuild the preview"
)

local prune_dir = typst_test_cache_path("render-cache-prune-owned")
vim.fn.mkdir(prune_dir, "p")
local expired_output = prune_dir .. "/expired-page.svg"
vim.fn.writefile({ "<svg></svg>" }, expired_output)
local prune_manifest = {
    entries = {
        page = {
            key = "page",
            kind = "page",
            path = expired_output,
            source_path = main,
            cached_at = 1,
            used_at = 1,
        },
    },
}
render_cache.prune_manifest(
    prune_dir,
    prune_manifest,
    { ttl_ms = 1, max_entries = 128, max_bytes = 1024 * 1024 },
    10000
)
assert(
    vim.fn.filereadable(main) == 1,
    "render cache pruning must not delete page source files outside the cache"
)
assert(
    vim.fn.filereadable(expired_output) == 0,
    "render cache pruning should delete expired cache outputs"
)
assert(
    prune_manifest.entries.page == nil,
    "expired render cache manifest entries should be removed"
)

typst.render.cache_clear()
local first_evicted = nil
typst.render.equation(
    { expression = "gamma", open = false, cache = { max_entries = 1 } },
    function(result)
        first_evicted = result
    end
)
assert(
    vim.wait(10000, function()
        return first_evicted ~= nil
    end, 20),
    "first bounded cache render did not finish"
)
local first_evicted_path = first_evicted.path
local second_evicted = nil
typst.render.equation(
    { expression = "delta", open = false, cache = { max_entries = 1 } },
    function(result)
        second_evicted = result
    end
)
assert(
    vim.wait(10000, function()
        return second_evicted ~= nil
    end, 20),
    "second bounded cache render did not finish"
)
assert(second_evicted.ok, "second bounded cache render should succeed")
assert(
    vim.tbl_count(typst.render.cache_entries()) == 1,
    "render cache should honor max_entries"
)
assert(
    vim.fn.filereadable(first_evicted_path) == 0,
    "render cache eviction should remove stale output files"
)

local function render_cache_manifest_entries()
    local path = typst_test_cache_path("render-cache/manifest.json")
    if vim.fn.filereadable(path) ~= 1 then
        return {}
    end
    local ok, decoded =
        pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
    if ok and type(decoded) == "table" then
        return decoded.entries or {}
    end
    return {}
end

typst.render.cache_clear()
local ttl_old = nil
typst.render.equation(
    { expression = "alpha + gamma", open = false, cache = { ttl_ms = 1 } },
    function(result)
        ttl_old = result
    end
)
assert(
    vim.wait(10000, function()
        return ttl_old ~= nil
    end, 20),
    "old TTL render did not finish"
)
vim.wait(20, function()
    return false
end, 20)
local ttl_new = nil
typst.render.equation(
    { expression = "alpha + delta", open = false, cache = { ttl_ms = 1 } },
    function(result)
        ttl_new = result
    end
)
assert(
    vim.wait(10000, function()
        return ttl_new ~= nil
    end, 20),
    "new TTL render did not finish"
)
local ttl_entries = render_cache_manifest_entries()
assert(
    ttl_old and vim.fn.filereadable(ttl_old.path) == 0,
    "render disk TTL pruning should remove expired output files"
)
assert(
    ttl_new
        and ttl_entries[ttl_new.key]
        and vim.fn.filereadable(ttl_new.path) == 1,
    "render disk TTL pruning should retain the fresh manifest entry"
)

typst.render.cache_clear()
local byte_first = nil
typst.render.equation(
    { expression = "beta + gamma", open = false },
    function(result)
        byte_first = result
    end
)
assert(
    vim.wait(10000, function()
        return byte_first ~= nil
    end, 20),
    "first byte-budget render did not finish"
)
local byte_budget =
    math.max(1, ((vim.uv or vim.loop).fs_stat(byte_first.path).size * 2) - 1)
local byte_second = nil
typst.render.equation({
    expression = "beta + delta",
    open = false,
    cache = { max_bytes = byte_budget },
}, function(result)
    byte_second = result
end)
assert(
    vim.wait(10000, function()
        return byte_second ~= nil
    end, 20),
    "second byte-budget render did not finish"
)
local byte_entries = render_cache_manifest_entries()
assert(
    byte_first and vim.fn.filereadable(byte_first.path) == 0,
    "render disk byte pruning should remove the oldest oversized output"
)
assert(
    byte_second
        and byte_entries[byte_second.key]
        and vim.fn.filereadable(byte_second.path) == 1,
    "render disk byte pruning should retain the newest output within budget"
)

local image = root .. "/tests/fixtures/basic/phase4-image.svg"
assert(vim.fn.writefile({
    '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="12"></svg>',
}, image) == 0, "failed to write image")
vim.api.nvim_buf_set_lines(0, 0, 1, false, { '#image("phase4-image.svg")' })
vim.api.nvim_win_set_cursor(0, { 1, 9 })
local image_result = typst.render.image({ open = false })
assert(image_result.ok, "render_image should resolve image under cursor")
assert(image_result.kind == "image", "image preview should report image kind")
assert(
    image_result.path == image,
    "image preview should resolve relative paths from buffer directory"
)
assert(image_result.format == "svg", "image preview should report extension")
assert(
    image_result.dimensions.width == "10",
    "image preview should expose SVG width metadata"
)
assert(
    image_result.dimensions.height == "12",
    "image preview should expose SVG height metadata"
)

local display_calls = 0
typst.providers.register("render", "phase4-display", {
    display = function(result)
        display_calls = display_calls + 1
        return {
            terminal = "test-terminal",
            path = result.path,
        }
    end,
})
assert(
    vim.tbl_contains(typst.providers.names("render"), "phase4-display"),
    "render provider should be listed"
)
local displayed = typst.render.image({
    path = image,
    display_provider = "phase4-display",
})
assert(displayed.ok, "display-provider image render should succeed")
assert(display_calls == 1, "display provider should be called once")
assert(
    displayed.display and displayed.display.terminal == "test-terminal",
    "display result should be retained"
)

local old_kitty = vim.env.KITTY_WINDOW_ID
vim.env.KITTY_WINDOW_ID = "unit-test"
local terminal_displayed = typst.render.image({
    path = image,
    display_provider = "terminal",
})
vim.env.KITTY_WINDOW_ID = old_kitty
assert(terminal_displayed.ok, "built-in terminal image display should succeed")
assert(
    terminal_displayed.display.provider == "kitty",
    "terminal display should auto-detect kitty"
)
assert(
    vim.api.nvim_buf_is_valid(terminal_displayed.display.buffer),
    "terminal display should create a buffer"
)

local kitty_path_transfer = typst.render.image({
    path = image,
    display_provider = "kitty",
    max_inline_image_bytes = 1,
})
assert(kitty_path_transfer.ok, "kitty terminal image display should succeed")
assert(
    kitty_path_transfer.display.provider == "kitty",
    "kitty display should use the kitty graphics protocol"
)
assert(
    kitty_path_transfer.display_error == nil,
    "kitty display should use file transfer instead of inline image bytes"
)

local oversized_terminal = typst.render.image({
    path = image,
    display_provider = "iterm",
    max_inline_image_bytes = 1,
})
assert(
    oversized_terminal.ok,
    "oversized terminal image should still return image metadata"
)
assert(
    tostring(oversized_terminal.display_error):find("too large", 1, true),
    "oversized terminal image should avoid synchronous inline encoding"
)

local old_system = vim.system
local system_calls = 0
vim.system = function(command)
    system_calls = system_calls + 1
    return old_system(command)
end
local inline_terminal = typst.render.image({
    path = image,
    display_provider = "iterm",
})
vim.system = old_system
assert(
    inline_terminal.ok,
    "inline terminal display should still return image metadata"
)
assert(
    inline_terminal.display and inline_terminal.display.provider == "iterm",
    "iterm display should use inline image bytes"
)
assert(
    system_calls == 0,
    "inline terminal display should encode image bytes without vim.system"
)

typst.providers.register("render", "phase4-render", {
    render = function(project, opts)
        return {
            ok = true,
            kind = opts.kind,
            provider = "phase4-render",
            path = typst_test_cache_path("render-cache/provider.")
                .. (opts.format or "svg"),
        }
    end,
})
local provider_page = typst.render.page({
    provider = "phase4-render",
    open = false,
})
assert(provider_page.ok, "render provider should handle page previews")
assert(
    provider_page.provider == "phase4-render",
    "provider result should be returned"
)
assert(provider_page.kind == "page", "provider should receive render kind")

typst.providers.register("render", "phase4-pending-render", {
    render = function(project, opts, callback)
        vim.schedule(function()
            callback({
                ok = true,
                kind = opts.kind,
                provider = "phase4-pending-render",
                path = opts.output_path,
            })
        end)
        return {
            ok = true,
            pending = true,
            kind = opts.kind,
            provider = "phase4-pending-render",
            path = opts.output_path,
        }
    end,
})
local pending_provider_done = nil
local pending_provider_page = typst.render.page({
    provider = "phase4-pending-render",
    output_path = typst_test_cache_path("render-cache/pending-provider.svg"),
}, function(result)
    pending_provider_done = result
end)
assert(
    pending_provider_page.pending and pending_provider_page.buffer == nil,
    "pending render provider result should not open a preview buffer"
)
assert(
    vim.wait(1000, function()
        return pending_provider_done ~= nil
    end, 10),
    "pending render provider should complete"
)
assert(
    pending_provider_done.buffer ~= nil,
    "async render provider completion should open the rendered preview"
)

typst.providers.register("render", "phase4-failing-render", {
    render = function(project, opts)
        return {
            ok = false,
            kind = opts.kind,
            provider = "phase4-failing-render",
            reason = "synthetic_failure",
            message = "synthetic render failure",
            path = opts.output_path,
        }
    end,
})
local failing_provider_page = typst.render.page({
    provider = "phase4-failing-render",
    output_path = typst_test_cache_path("render-cache/failing-provider.svg"),
})
assert(
    failing_provider_page.ok == false and failing_provider_page.buffer == nil,
    "failing render provider result should not open a preview buffer"
)

local async_rendered = nil
local async_render_calls = 0
typst.providers.register("render", "phase4-async-render", {
    render = function(project, opts, callback)
        async_render_calls = async_render_calls + 1
        vim.schedule(function()
            callback({
                ok = true,
                kind = opts.kind,
                provider = "phase4-async-render",
                path = opts.output_path,
                project = project.root,
            })
        end)
        return {
            ok = true,
            pending = true,
            kind = opts.kind,
            provider = "phase4-async-render",
            path = opts.output_path,
        }
    end,
})
local async_render_pending = typst.render.page(
    { provider = "phase4-async-render", open = false },
    function(result)
        async_rendered = result
    end
)
assert(
    async_render_pending.ok and async_render_pending.pending,
    "async render provider should return pending"
)
local blocked_render = typst.render.page({
    provider = "phase4-async-render",
    open = false,
})
assert(
    not blocked_render.ok and blocked_render.reason == "active_output",
    "pending render provider should reserve its output path"
)
assert(
    async_render_calls == 1,
    "active output collision should not invoke the render provider again"
)
assert(
    vim.wait(1000, function()
        return async_rendered ~= nil
    end, 10),
    "async render provider callback did not run"
)
assert(async_rendered.ok, "async render provider should finish successfully")

local process = require("typst.core.process")
local original_system = process.system
local original_spawn = process.spawn
local page_runs = 0
local changed_page_path = nil
local page_cache_ok, page_cache_err = xpcall(function()
    vim.api.nvim_set_current_buf(main_bufnr)
    typst.render.cache_clear()
    local function fake_page_render(command, on_exit)
        page_runs = page_runs + 1
        local output = command[#command]
        vim.fn.writefile({ ("page render %d"):format(page_runs) }, output)
        vim.schedule(function()
            on_exit({
                code = 0,
                stdout = "",
                stderr = "",
            })
        end)
        return {
            is_closing = function()
                return true
            end,
        }
    end

    process.spawn = function(command, _opts, handlers)
        return fake_page_render(command, handlers and handlers.on_exit)
    end

    process.system = function(command, _opts, on_exit)
        return fake_page_render(command, on_exit)
    end

    local first_page = nil
    local first_run = typst.render.page({ open = false }, function(result)
        first_page = result
    end)
    assert(
        first_run.ok and first_run.pending,
        "page render should start with the fake process"
    )
    assert(
        vim.wait(1000, function()
            return first_page ~= nil
        end, 10),
        "first fake page render did not finish"
    )
    assert(
        first_page.ok and page_runs == 1,
        "first fake page render should run once"
    )

    local cached_page = typst.render.page({ open = false })
    assert(
        cached_page.ok and cached_page.cached,
        "matching page render should use cache"
    )
    assert(
        cached_page.path == first_page.path,
        "cached page render should reuse the first path"
    )
    assert(page_runs == 1, "cached page render should not spawn a process")

    local extra_arg_page = nil
    local extra_arg_run = typst.render.page({
        open = false,
        extra_args = { "--input", "variant=extra" },
    }, function(result)
        extra_arg_page = result
    end)
    assert(
        extra_arg_run.ok and extra_arg_run.pending,
        "page render with extra args should start with the fake process"
    )
    assert(
        vim.wait(1000, function()
            return extra_arg_page ~= nil
        end, 10),
        "extra-arg fake page render did not finish"
    )
    assert(extra_arg_page.ok, "extra-arg fake page render should succeed")
    assert(
        page_runs == 2,
        "different render extra_args should bypass the existing cache entry"
    )
    assert(
        extra_arg_page.path ~= first_page.path,
        "different render extra_args should use a distinct cache key"
    )
    local cached_extra_arg_page = typst.render.page({
        open = false,
        extra_args = { "--input", "variant=extra" },
    })
    assert(
        cached_extra_arg_page.ok and cached_extra_arg_page.cached,
        "matching render extra_args should reuse their cache entry"
    )
    assert(
        page_runs == 2,
        "matching render extra_args should not spawn another process"
    )

    vim.api.nvim_buf_set_lines(
        0,
        0,
        1,
        false,
        { "= Changed page cache content" }
    )
    local changed_page = nil
    typst.render.page({ open = false }, function(result)
        changed_page = result
    end)
    assert(
        vim.wait(1000, function()
            return changed_page ~= nil
        end, 10),
        "changed fake page render did not finish"
    )
    assert(changed_page.ok, "changed fake page render should succeed")
    assert(
        page_runs == 3,
        "changed page contents should invalidate the page render cache"
    )
    assert(
        changed_page.path ~= first_page.path,
        "changed page contents should use a new page cache key"
    )
    changed_page_path = changed_page.path
end, debug.traceback)
process.system = original_system
process.spawn = original_spawn
if not page_cache_ok then
    error(page_cache_err)
end

local cleared = typst.render.cache_clear()
assert(cleared.ok, "render_cache_clear should succeed")
local rogue_cache_file = typst_test_cache_path("render-cache/not-owned.svg")
assert(
    vim.fn.writefile({ "not owned" }, rogue_cache_file) == 0,
    "failed to write rogue render cache file"
)
local safe_cleared = typst.render.cache_clear()
assert(safe_cleared.ok, "render_cache_clear should keep clearing safely")
assert(
    changed_page_path and vim.fn.filereadable(changed_page_path) == 0,
    "render_cache_clear should delete manifest-owned render outputs"
)
assert(
    vim.fn.filereadable(rogue_cache_file) == 1,
    "render_cache_clear should not delete files absent from the cache manifest"
)
local forced_clear = typst.render.cache_clear({ force = true })
assert(
    forced_clear.ok and forced_clear.forced,
    "forced render clear should succeed"
)
assert(
    vim.fn.isdirectory(typst_test_cache_path("render-cache")) == 0,
    "forced render_cache_clear should remove the cache directory"
)

typst.reset()
local mismatch_root = typst_test_cache_path("render-root-mismatch")
local mismatch_main = mismatch_root .. "/main.typ"
assert(
    vim.fn.mkdir(mismatch_root, "p") == 1
        or vim.fn.isdirectory(mismatch_root) == 1,
    "failed to create mismatch project root"
)
assert(
    vim.fn.writefile({ "= Mismatch root" }, mismatch_main) == 0,
    "failed to write mismatch root main file"
)
typst.setup({
    root = mismatch_root,
    render = {
        output_dir = typst_test_cache_path("render-cache"),
        output_format = "svg",
    },
})
vim.cmd.edit(mismatch_main)
typst.project.set_main(mismatch_main)
local mismatch_cache_dir = typst_test_cache_path("render-cache")
assert(
    vim.fn.mkdir(mismatch_cache_dir, "p") == 1
        or vim.fn.isdirectory(mismatch_cache_dir) == 1,
    "failed to create mismatch render cache"
)
assert(
    vim.fn.writefile({ "stale" }, mismatch_cache_dir .. "/stale.svg") == 0,
    "failed to write mismatch render cache file"
)
local mismatch_cleared = typst.render.cache_clear()
assert(mismatch_cleared.ok, "project-root render_cache_clear should succeed")
assert(
    mismatch_cleared.path == mismatch_cache_dir,
    "render_cache_clear should resolve relative output_dir against project root"
)
assert(
    vim.fn.filereadable(mismatch_cache_dir .. "/stale.svg") == 1,
    "render_cache_clear should not delete unmanifested project-root cache files"
)
local forced_mismatch_cleared = typst.render.cache_clear({ force = true })
assert(
    not forced_mismatch_cleared.ok
        and forced_mismatch_cleared.reason == "unsafe_cache_dir",
    "forced project-root render_cache_clear should fail without ownership proof"
)
assert(
    vim.fn.isdirectory(mismatch_cache_dir) == 1,
    "forced render_cache_clear should preserve unowned project-root cache directories"
)
assert(
    vim.fn.filereadable(mismatch_cache_dir .. "/stale.svg") == 1,
    "forced render_cache_clear should preserve unowned project-root files"
)

typst.reset()
typst.setup({
    root = mismatch_root,
    render = {
        output_dir = ".",
        output_format = "svg",
    },
})
vim.cmd.edit(mismatch_main)
typst.project.set_main(mismatch_main)
local root_marker = mismatch_root .. "/keep.typ"
assert(
    vim.fn.writefile({ "= Keep" }, root_marker) == 0,
    "failed to write project-root safety marker"
)
local forced_root_clear = typst.render.cache_clear({ force = true })
assert(
    not forced_root_clear.ok and forced_root_clear.reason == "unsafe_cache_dir",
    "forced render_cache_clear should refuse the project root"
)
assert(
    vim.fn.filereadable(root_marker) == 1,
    "forced render_cache_clear must not delete project-root files"
)

vim.cmd("qa!")
