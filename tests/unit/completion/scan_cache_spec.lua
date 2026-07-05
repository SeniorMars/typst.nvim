local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")
typst.reset()
typst.setup({
    root = root,
    completion = {
        include_raw_languages = true,
        include_csl_styles = true,
        csl_scan_max = 20,
        scan_cache_ttl_ms = 1000,
    },
})
local completion_csl = require("typst.completion.csl")
local completion_raw = require("typst.completion.raw")
local core_cache = require("typst.core.cache")
local scan_cache = require("typst.core.scan_cache")
local config = require("typst.config")

local original_runtime_file = vim.api.nvim_get_runtime_file
local original_find = vim.fs.find

local ok, err = xpcall(function()
    local cache_entry = core_cache.entry({ value = true }, {
        signature = "scan",
        ttl_ms = 10,
        now_ms = 100,
    })
    assert(
        cache_entry.expires_at == 110,
        "core cache should calculate expiration from injected time"
    )
    assert(
        core_cache.is_fresh(cache_entry, {
            signature = "scan",
            ttl_ms = 10,
            now_ms = 109,
        }),
        "core cache should treat unexpired matching signatures as fresh"
    )
    assert(not core_cache.is_fresh(cache_entry, {
        signature = "scan",
        ttl_ms = 10,
        now_ms = 111,
    }), "core cache should expire entries after ttl_ms")
    assert(not core_cache.is_fresh(cache_entry, {
        signature = "changed",
        ttl_ms = 10,
        now_ms = 101,
    }), "core cache should invalidate changed signatures")
    assert(
        core_cache.is_fresh(
            core_cache.entry({}, {
                signature = "forever",
                ttl_ms = 0,
                now_ms = 100,
            }),
            {
                signature = "forever",
                ttl_ms = 0,
                now_ms = 100000,
            }
        ),
        "core cache ttl_ms=0 should remain fresh until signature changes"
    )

    local store = scan_cache.new()
    scan_cache.put(store, "scan", { "a" }, {
        signature = { "root", "v1" },
        ttl_ms = 10,
        now_ms = 100,
    })
    local scan_value, scan_fresh = scan_cache.peek(store, "scan", {
        signature = { "root", "v1" },
        ttl_ms = 10,
        now_ms = 109,
    })
    assert(
        scan_fresh and scan_value[1] == "a",
        "scan cache should return fresh values by signature and ttl"
    )
    scan_value, scan_fresh = scan_cache.peek(store, "scan", {
        signature = { "root", "v1" },
        ttl_ms = 10,
        now_ms = 111,
    })
    assert(
        not scan_fresh and scan_value[1] == "a",
        "scan cache peek should expose stale values for async refresh paths"
    )
    scan_value, scan_fresh = scan_cache.peek(store, "scan")
    assert(
        scan_fresh and scan_value[1] == "a",
        "scan cache peek without a signature should inspect stored values"
    )

    local runtime_scans = 0
    rawset(vim.api, "nvim_get_runtime_file", function(pattern)
        runtime_scans = runtime_scans + 1
        if pattern == "parser/*.so" then
            return { root .. "/parser/cachedraw.so" }
        end
        return {}
    end)

    completion_raw.reset()
    local raw_first = completion_raw.items({}, "cached")
    local raw_second = completion_raw.items({}, "cached")
    assert(
        raw_first[1] and raw_first[1].word == "cachedraw",
        "raw completion should include runtime parser languages"
    )
    assert(
        raw_second[1] and raw_second[1].word == "cachedraw",
        "raw completion should reuse cached runtime parser languages"
    )
    assert(
        runtime_scans == 3,
        "raw completion should scan runtime parser patterns once"
    )
    completion_raw.reset()
    completion_raw.items({}, "cached")
    assert(
        runtime_scans == 6,
        "raw completion reset should invalidate runtime parser cache"
    )
    local raw_clear = typst.project.clear_cache({ notify = false })
    assert(
        raw_clear.completion,
        "clear_cache should report completion cache reset"
    )
    completion_raw.items({}, "cached")
    assert(
        runtime_scans == 9,
        "clear_cache should invalidate raw runtime parser cache"
    )
    vim.cmd("TypstClearCache")
    completion_raw.items({}, "cached")
    assert(
        runtime_scans == 12,
        "TypstClearCache should invalidate raw runtime parser cache"
    )
    config.setup({
        root = root,
        completion = {
            include_raw_languages = true,
            scan_cache_ttl_ms = 1000,
        },
    })
    completion_raw.items({}, "cached")
    assert(
        runtime_scans == 15,
        "raw completion should invalidate cached parser scans after config generation changes"
    )
    config.setup({
        root = root,
        completion = {
            include_raw_languages = true,
            scan_cache_ttl_ms = 1,
        },
    })
    completion_raw.items({}, "cached")
    assert(runtime_scans == 18, "raw completion should scan after TTL setup")
    assert(
        vim.wait(1000, function()
            completion_raw.items({}, "cached")
            return runtime_scans == 21
        end, 5),
        "raw completion should expire parser scans after scan_cache_ttl_ms"
    )
    config.setup({
        root = root,
        completion = {
            include_raw_languages = true,
            include_csl_styles = true,
            csl_scan_max = 20,
            scan_cache_ttl_ms = 1000,
        },
    })
    local csl_root = typst_test_cache_path("completion-scan-cache")
    vim.fn.mkdir(csl_root, "p")
    local csl_path = csl_root .. "/cached-style.csl"
    vim.fn.writefile({ "<style/>" }, csl_path)

    local csl_scans = 0
    rawset(vim.fs, "find", function(_, opts)
        csl_scans = csl_scans + 1
        assert(opts.path == csl_root, "CSL scan should use the project root")
        return { csl_path }
    end)
    completion_csl.reset()
    local csl_opts = {
        project = {
            root = csl_root,
            main = csl_root .. "/main.typ",
        },
    }
    local csl_first = completion_csl.items(csl_opts, "cached", {
        version = "test",
    })
    local csl_second = completion_csl.items(csl_opts, "cached", {
        version = "test",
    })
    assert(
        csl_first[1] and csl_first[1].word == "cached-style.csl",
        "CSL completion should include project-local style files"
    )
    assert(
        csl_second[1] and csl_second[1].word == "cached-style.csl",
        "CSL completion should reuse cached project-local scans"
    )
    assert(csl_scans == 1, "CSL completion should scan each root once")
    completion_csl.reset()
    completion_csl.items(csl_opts, "cached", { version = "test" })
    assert(csl_scans == 2, "CSL completion reset should invalidate scan cache")
    local csl_clear = typst.project.clear_cache({ notify = false })
    assert(
        csl_clear.completion,
        "clear_cache should report completion cache reset"
    )
    completion_csl.items(csl_opts, "cached", { version = "test" })
    assert(csl_scans == 3, "clear_cache should invalidate CSL local scan cache")
    vim.cmd("TypstClearCache")
    completion_csl.items(csl_opts, "cached", { version = "test" })
    assert(
        csl_scans == 4,
        "TypstClearCache should invalidate CSL local scan cache"
    )
    config.setup({
        root = root,
        completion = {
            include_csl_styles = true,
            csl_scan_max = 20,
            scan_cache_ttl_ms = 1000,
        },
    })
    completion_csl.items(csl_opts, "cached", { version = "test" })
    assert(
        csl_scans == 5,
        "CSL completion should invalidate local scans after config generation changes"
    )
    config.setup({
        root = root,
        completion = {
            include_csl_styles = true,
            csl_scan_max = 20,
            scan_cache_ttl_ms = 1,
        },
    })
    completion_csl.items(csl_opts, "cached", { version = "test" })
    assert(csl_scans == 6, "CSL completion should scan after TTL setup")
    assert(
        vim.wait(1000, function()
            completion_csl.items(csl_opts, "cached", { version = "test" })
            return csl_scans == 7
        end, 5),
        "CSL completion should expire local scans after scan_cache_ttl_ms"
    )
end, debug.traceback)

vim.api.nvim_get_runtime_file = original_runtime_file
vim.fs.find = original_find

if not ok then
    vim.api.nvim_echo({ { tostring(err), "ErrorMsg" } }, true, {})
    vim.cmd("cquit")
end

vim.cmd("qa!")
