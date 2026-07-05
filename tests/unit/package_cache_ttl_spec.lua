local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local registry_cache = require("typst.package.registry_cache")
local config = require("typst.config")
local completion_packages = require("typst.completion.packages")
local package_cache = require("typst.package.cache")
local registry = require("typst.package.registry")
local registry_scan = require("typst.package.registry_scan")

local original_now = registry_cache._now_ms
local original_registry_now = registry._now_ms
local original_cached_packages = package_cache.cached_packages
local original_root_signatures = registry_scan.root_signatures
local original_scan_roots = registry_scan.scan_roots
local original_scan_roots_async = registry_scan.scan_roots_async
local original_system = vim.system

local now = 1000
local signature_calls = 0
local scan_calls = 0

local ok, err = xpcall(function()
    registry_cache._now_ms = function()
        return now
    end

    rawset(registry_scan, "root_signatures", function()
        signature_calls = signature_calls + 1
        return { packages = "sig" }
    end)
    rawset(registry_scan, "scan_roots", function()
        scan_calls = scan_calls + 1
        return {
            {
                namespace = "preview",
                name = "alpha",
                version = "1.0.0",
                spec = "@preview/alpha:1.0.0",
            },
        }
    end)
    rawset(registry_scan, "scan_roots_async", function(_, _, callback)
        scan_calls = scan_calls + 1
        vim.schedule(function()
            callback({
                {
                    namespace = "preview",
                    name = "alpha",
                    version = "1.0.0",
                    spec = "@preview/alpha:1.0.0",
                },
            })
        end)
        return {}
    end)
    local cache = registry_cache.new()
    local first = cache:cached_packages(
        { "/packages" },
        { prefix = "@preview/alpha", max = 1, ttl_ms = 100 }
    )
    assert(
        #first == 1,
        "first package cache lookup should return scanned records"
    )
    assert(
        signature_calls == 1,
        "first package cache lookup should read root signatures"
    )
    assert(scan_calls == 1, "first package cache lookup should scan roots")

    now = now + 50
    local second = cache:cached_packages(
        { "/packages" },
        { prefix = "@preview/alpha", max = 1, ttl_ms = 100 }
    )
    assert(#second == 1, "fresh package cache lookup should return records")
    assert(
        signature_calls == 1,
        "fresh package cache lookup should not recalculate root signatures"
    )
    assert(
        scan_calls == 1,
        "fresh package cache lookup should not rescan roots"
    )

    now = now + 100
    local expired = cache:cached_packages(
        { "/packages" },
        { prefix = "@preview/alpha", max = 1, ttl_ms = 100 }
    )
    assert(#expired == 1, "expired package cache lookup should return records")
    assert(
        signature_calls == 1,
        "expired package cache lookup should serve stale records immediately"
    )
    assert(
        vim.wait(1000, function()
            return scan_calls == 2
        end, 10),
        "expired package cache lookup should refresh through async scanning"
    )
    assert(
        signature_calls == 1,
        "expired async package refresh should not validate root signatures on the hot path"
    )

    cache:cached_packages({ "/packages" }, {
        prefix = "@preview/alpha",
        max = 1,
        ttl_ms = 100,
        force_refresh = true,
    })
    assert(scan_calls == 3, "force_refresh should rescan package roots")

    local memory_cache = registry_cache.new()
    signature_calls = 0
    scan_calls = 0
    local cold_memory = memory_cache:cached_packages({ "/packages" }, {
        prefix = "@preview/alpha",
        max = 1,
        ttl_ms = 100,
        memory_only = true,
        schedule_refresh = false,
    })
    assert(#cold_memory == 0, "cold memory-only package read should miss")
    assert(
        signature_calls == 0,
        "cold memory-only package read should not read root signatures"
    )
    assert(
        scan_calls == 0,
        "cold memory-only package read should not scan package roots"
    )

    local warmed = memory_cache:cached_packages({ "/packages" }, {
        prefix = "@preview/alpha",
        max = 1,
        ttl_ms = 100,
    })
    assert(#warmed == 1, "normal package read should warm memory cache")
    now = now + 101
    signature_calls = 0
    scan_calls = 0
    local expired_memory = memory_cache:cached_packages({ "/packages" }, {
        prefix = "@preview/alpha",
        max = 1,
        ttl_ms = 100,
        memory_only = true,
        schedule_refresh = false,
    })
    assert(
        #expired_memory == 1,
        "expired memory-only package read should serve stale records"
    )
    assert(
        signature_calls == 0,
        "expired memory-only package read should not validate signatures"
    )
    assert(
        scan_calls == 0,
        "expired memory-only package read should not scan roots"
    )

    registry.reset()
    signature_calls = 0
    scan_calls = 0
    registry.prewarm({
        force = true,
        roots = { "/packages" },
        schedule = true,
        ttl_ms = 100,
    })
    assert(
        scan_calls == 0,
        "scheduled package prewarm should not scan synchronously"
    )
    assert(
        vim.wait(1000, function()
            return scan_calls == 1
        end, 10),
        "scheduled package prewarm should use async package scanning"
    )
    assert(
        signature_calls == 0,
        "scheduled package prewarm should not validate root signatures on the hot path"
    )
    local asynchronously_prewarmed = registry.cached_packages({
        roots = { "/packages" },
        prefix = "@preview/alpha",
        max = 1,
        memory_only = true,
        schedule_refresh = false,
    })
    assert(
        #asynchronously_prewarmed == 1,
        "scheduled package prewarm should populate the in-memory package snapshot"
    )
    rawset(registry_scan, "root_signatures", function()
        error("hot package reads must not validate root signatures")
    end)
    rawset(registry_scan, "scan_roots", function()
        error("hot package reads must not scan package roots synchronously")
    end)
    rawset(registry_scan, "scan_roots_async", function()
        error("memory-only hot package reads must not schedule refresh work")
    end)
    local hot_path_read = registry.cached_packages({
        roots = { "/packages" },
        prefix = "@preview/alpha",
        max = 1,
        memory_only = true,
        schedule_refresh = false,
    })
    assert(
        #hot_path_read == 1,
        "package completion hot path should serve the prewarmed snapshot without scanning"
    )

    config.setup({
        executable = "typst",
        completion = {
            package_cache_prewarm = false,
        },
    })
    registry.reset()
    registry._now_ms = function()
        return now
    end

    local info_calls = 0
    local completed_info_calls = 0
    rawset(vim, "system", function(_command, _opts, callback)
        info_calls = info_calls + 1
        local call = info_calls
        vim.schedule(function()
            if call < 3 then
                callback({
                    code = 1,
                    stdout = "",
                    stderr = "temporary failure",
                })
            else
                callback({
                    code = 0,
                    stdout = vim.json.encode({
                        packages = {
                            ["package-path"] = "/package-path",
                            ["package-cache-path"] = "/package-cache-path",
                        },
                    }),
                    stderr = "",
                })
            end
            completed_info_calls = completed_info_calls + 1
        end)
        return {
            kill = function() end,
        }
    end)

    registry.package_roots()
    assert(
        vim.wait(1000, function()
            return completed_info_calls == 1
        end, 10),
        "first typst info failure should be attempted"
    )
    registry.package_roots()
    assert(
        info_calls == 1,
        "typst info failure should be cached until retry delay"
    )

    now = now + 1001
    registry.package_roots()
    assert(
        vim.wait(1000, function()
            return completed_info_calls == 2
        end, 10),
        "typst info should retry after first backoff"
    )
    now = now + 4999
    registry.package_roots()
    assert(
        info_calls == 2,
        "second typst info failure should use longer backoff"
    )

    now = now + 1
    registry.package_roots()
    assert(
        vim.wait(1000, function()
            return completed_info_calls == 3
        end, 10),
        "typst info should retry after second backoff"
    )
    local roots = registry.package_roots()
    assert(
        vim.tbl_contains(roots, "/package-path"),
        "successful typst info should populate package roots"
    )
    registry.package_roots()
    assert(info_calls == 3, "successful typst info should be cached")

    local universe_path =
        typst_test_cache_path("package-cache-ttl-universe.json")
    rawset(package_cache, "cached_packages", function()
        return {}
    end)
    config.setup({
        root = root,
        completion = {
            package_cache_prewarm = false,
            package_cache_ttl_ms = 60000,
            universe_index_paths = { universe_path },
        },
    })
    completion_packages.reset()

    vim.fn.mkdir(vim.fn.fnamemodify(universe_path, ":h"), "p")
    vim.fn.writefile({
        vim.json.encode({
            packages = {
                {
                    spec = "@preview/cache-old:1.0.0",
                    description = "old universe package",
                },
            },
        }),
    }, universe_path)

    local first_universe = completion_packages.items({
        include_packages = true,
        package_memory_only = false,
    }, "@preview/cache")
    assert(
        #first_universe == 1
            and first_universe[1].word == "@preview/cache-old:1.0.0",
        "Universe index completion should read the initial package"
    )

    vim.fn.writefile({
        vim.json.encode({
            packages = {
                {
                    spec = "@preview/cache-newer-with-long-name:2.0.0",
                    description = "new universe package",
                },
            },
        }),
    }, universe_path)

    local refreshed_universe = completion_packages.items({
        include_packages = true,
        package_memory_only = false,
    }, "@preview/cache")
    assert(
        #refreshed_universe == 1
            and refreshed_universe[1].word
                == "@preview/cache-newer-with-long-name:2.0.0",
        "Universe index completion should invalidate fresh TTL cache when the file signature changes"
    )
end, debug.traceback)

registry_cache._now_ms = original_now
registry._now_ms = original_registry_now
package_cache.cached_packages = original_cached_packages
registry_scan.root_signatures = original_root_signatures
registry_scan.scan_roots = original_scan_roots
registry_scan.scan_roots_async = original_scan_roots_async
vim.system = original_system
registry.reset()

if not ok then
    error(err)
end

local fs_ok, fs_err = xpcall(function()
    local uv = vim.uv or vim.loop

    local function write_package(package_root, version, description)
        local dir = ("%s/preview/event-fixture/%s"):format(
            package_root,
            version
        )
        vim.fn.mkdir(dir, "p")
        vim.fn.writefile({
            "[package]",
            'name = "event-fixture"',
            ('version = "%s"'):format(version),
            ('description = "%s"'):format(description or version),
            'entrypoint = "lib.typ"',
        }, dir .. "/typst.toml")
        vim.fn.writefile({ "#let event-fixture() = none" }, dir .. "/lib.typ")
    end

    local package_root = typst_test_cache_path("package-fs-event")
    vim.fn.delete(package_root, "rf")
    write_package(package_root, "1.0.0")

    local cache = registry_cache.new()
    local first = cache:cached_packages({ package_root }, {
        name = "event-fixture",
        ttl_ms = 60000,
        max = 10,
    })
    assert(#first == 1, "initial package cache scan should find one version")

    if uv and type(uv.new_fs_event) == "function" then
        vim.wait(100, function()
            return false
        end, 10)
        write_package(package_root, "1.0.0", "updated by fs event")
        assert(
            vim.wait(3000, function()
                local records = cache:cached_packages({ package_root }, {
                    name = "event-fixture",
                    ttl_ms = 60000,
                    max = 10,
                    memory_only = true,
                    schedule_refresh = false,
                })
                return records[1]
                    and records[1].description == "updated by fs event"
            end, 20),
            "package fs_event watcher should refresh the in-memory package snapshot"
        )
    end

    cache:clear()
end, debug.traceback)

if not fs_ok then
    error(fs_err)
end

vim.cmd("qa!")
