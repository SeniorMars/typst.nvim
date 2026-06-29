local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")

typst.reset()
typst.setup({
    root = root,
    completion = {
        include_paths = true,
        path_scan_max = 200,
        path_scan_entry_max = 2000,
        path_scan_cache_ms = 1000,
    },
})

local completion = require("typst.completion")
local completion_match = require("typst.completion.match")
local config = require("typst.config")
local paths = require("typst.completion.paths")

assert(
    completion_match.prefix("Alpha.typ", "al"),
    "completion_match.prefix should match case-insensitive prefixes"
)
assert(
    not completion_match.prefix("Beta.typ", "al"),
    "completion_match.prefix should reject non-prefix candidates"
)

local scan_root = typst_test_cache_path("completion-path-cache")
vim.fn.delete(scan_root, "rf")
vim.fn.mkdir(scan_root, "p")
vim.fn.writefile({ '#import ""' }, scan_root .. "/main.typ")

local bufnr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(bufnr, scan_root .. "/main.typ")
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { '#import ""' })
vim.api.nvim_set_current_buf(bufnr)
vim.bo[bufnr].filetype = "typst"

local original_dir = vim.fs.dir
local listing = {
    { "alpha.typ", "file" },
    { "assets", "directory" },
    { "photo.png", "file" },
}
local scans = 0

local function has_word(items, word)
    for _, item in ipairs(items) do
        if item.word == word then
            return true
        end
    end
    return false
end

local function complete(base)
    return paths.items({
        bufnr = bufnr,
        path_kind = "import",
        pos = { 0, 9 },
    }, base or "")
end

local function wait_for_directory_signature_change(dir)
    local before = vim.uv.fs_stat(dir)
    local before_mtime = before and before.mtime or {}
    local attempt = 0
    assert(
        vim.wait(1000, function()
            attempt = attempt + 1
            vim.fn.writefile({ "" }, ("%s/touch-%d.typ"):format(dir, attempt))
            local after = vim.uv.fs_stat(dir)
            if not after then
                return false
            end
            local after_mtime = after and after.mtime or {}
            return after_mtime.sec ~= before_mtime.sec
                or after_mtime.nsec ~= before_mtime.nsec
                or (before and after.size ~= before.size)
        end, 10),
        "test directory signature should change"
    )
end

local ok, err = xpcall(function()
    vim.fs.dir = function(path)
        scans = scans + 1
        assert(path == scan_root, "path completion should scan the file dir")
        local index = 0
        return function()
            index = index + 1
            local entry = listing[index]
            if entry then
                return entry[1], entry[2]
            end
        end
    end

    paths.reset()
    local first = complete("")
    local second = complete("a")
    local third = complete("al")
    assert(
        has_word(first, "alpha.typ"),
        "path completion should include Typst files"
    )
    assert(
        has_word(first, "assets/"),
        "path completion should include directories"
    )
    assert(
        not has_word(first, "photo.png"),
        "import path completion should keep extension filtering"
    )
    assert(
        has_word(second, "alpha.typ"),
        "cached path completion should filter cached entries by typed prefix"
    )
    assert(
        has_word(third, "alpha.typ"),
        "cached path completion should reuse scans across normal typing"
    )
    assert(
        scans == 1,
        "path completion should reuse recent directory scans across typed prefixes"
    )

    paths.reset()
    complete("")
    assert(scans == 2, "path completion reset should invalidate scan cache")

    completion.reset()
    complete("")
    assert(scans == 3, "completion reset should invalidate path scan cache")

    config.setup({
        root = root,
        completion = {
            include_paths = true,
            path_scan_max = 2,
            path_scan_entry_max = 3,
            path_scan_cache_ms = 1000,
        },
    })
    paths.reset()
    local yielded = 0
    vim.fs.dir = function(path)
        scans = scans + 1
        assert(path == scan_root, "path completion should scan the file dir")
        local index = 0
        return function()
            index = index + 1
            if index > 10000 then
                return nil
            end
            yielded = yielded + 1
            return ("entry-%05d.typ"):format(index), "file"
        end
    end
    local capped = complete("")
    assert(
        yielded == 3,
        "path_scan_entry_max should cap raw directory iterator consumption"
    )
    assert(#capped <= 2, "path_scan_max should cap returned path items")

    config.setup({
        root = root,
        completion = {
            include_paths = true,
            path_scan_max = 200,
            path_scan_entry_max = 2000,
            path_scan_cache_ms = 0,
        },
    })
    vim.fs.dir = function(path)
        scans = scans + 1
        assert(path == scan_root, "path completion should scan the file dir")
        local index = 0
        return function()
            index = index + 1
            local entry = listing[index]
            if entry then
                return entry[1], entry[2]
            end
        end
    end
    paths.reset()
    complete("")
    complete("")
    assert(scans == 6, "path_scan_cache_ms=0 should disable path scan caching")

    config.setup({
        root = root,
        completion = {
            include_paths = true,
            path_scan_max = 200,
            path_scan_entry_max = 2000,
            path_scan_cache_ms = 1000,
        },
    })
    paths.reset()
    local before_changed = complete("b")
    assert(scans == 7, "path cache should scan after re-enable")
    assert(
        not has_word(before_changed, "beta.typ"),
        "path cache should cache the current prefix result before directory change"
    )
    listing[#listing + 1] = { "beta.typ", "file" }
    wait_for_directory_signature_change(scan_root)
    local changed = complete("b")
    assert(
        scans == 8,
        "path cache should rescan when directory signature changes"
    )
    assert(
        has_word(changed, "beta.typ"),
        "changed directory scan should expose fresh entries"
    )
end, debug.traceback)

vim.fs.dir = original_dir
assert(ok, err)

vim.cmd("qa!")
