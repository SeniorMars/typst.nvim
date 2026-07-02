local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")
local lifecycle = require("typst.core.lifecycle")
local project = require("typst.project")
local project_services = require("typst.project.services")
local folds = require("typst.edit.folds")
local indent = require("typst.edit.indent")
local imaps = require("typst.edit.imaps")
local match_highlight = require("typst.edit.match_highlight")
local conceal = require("typst.conceal")
local syntax = require("typst.syntax")
local core_windows = require("typst.core.windows")

local originals = {
    folds = folds.apply,
    indent = indent.apply,
    imaps = imaps.apply,
    match_highlight = match_highlight.apply,
    conceal = conceal.apply,
    syntax = syntax.apply,
    project_get = project.get,
    all_for_buffer = core_windows.all_for_buffer,
}

local counts = {
    folds = 0,
    indent = 0,
    imaps = 0,
    match_highlight = 0,
    conceal = 0,
    syntax = 0,
}

local function counted(name)
    return function()
        counts[name] = counts[name] + 1
        return true
    end
end

local function has_buffer_map(bufnr, mode, lhs)
    for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(bufnr, mode)) do
        if mapping.lhs == lhs then
            return true
        end
    end
    return false
end

folds.apply = counted("folds")
indent.apply = counted("indent")
imaps.apply = counted("imaps")
match_highlight.apply = counted("match_highlight")
conceal.apply = counted("conceal")
syntax.apply = counted("syntax")

local ok, err = xpcall(function()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "= Feature Cache" })
    vim.bo[bufnr].filetype = "typst"

    local first_window_counts = {
        folds = counts.folds,
        conceal = counts.conceal,
        indent = counts.indent,
        imaps = counts.imaps,
        match_highlight = counts.match_highlight,
        syntax = counts.syntax,
    }
    local first = lifecycle.apply_buffer_features(bufnr, { force = true })
    assert(first.buffer == true, "forced apply should run buffer features")
    assert(
        counts.folds > first_window_counts.folds,
        "folds should run on first apply"
    )
    assert(
        counts.conceal > first_window_counts.conceal,
        "conceal should run on first apply"
    )
    assert(
        counts.indent > first_window_counts.indent,
        "indent should run on first apply"
    )
    assert(
        counts.imaps > first_window_counts.imaps,
        "imaps should run on first apply"
    )
    assert(
        counts.match_highlight > first_window_counts.match_highlight,
        "match highlight should run on first apply"
    )
    assert(
        counts.syntax > first_window_counts.syntax,
        "syntax should run on first apply"
    )

    local second_window_counts = {
        folds = counts.folds,
        conceal = counts.conceal,
        indent = counts.indent,
        imaps = counts.imaps,
        match_highlight = counts.match_highlight,
        syntax = counts.syntax,
    }
    local second = lifecycle.apply_buffer_features(bufnr)
    assert(
        second.buffer == false,
        "unchanged apply should skip buffer-local features"
    )
    assert(
        second.window == false,
        "unchanged apply should skip window-local features"
    )
    assert(
        counts.folds == second_window_counts.folds,
        "folds should not reapply when window state is unchanged"
    )
    assert(
        counts.conceal == second_window_counts.conceal,
        "conceal should not reapply when window state is unchanged"
    )
    assert(
        counts.indent == second_window_counts.indent,
        "indent should not reapply when unchanged"
    )
    assert(
        counts.imaps == second_window_counts.imaps,
        "imaps should not reapply when unchanged"
    )
    assert(
        counts.match_highlight == second_window_counts.match_highlight,
        "match highlight should not reapply when unchanged"
    )
    assert(
        counts.syntax == second_window_counts.syntax,
        "syntax should not reapply when unchanged"
    )

    local original_win = vim.api.nvim_get_current_win()
    local sibling_counts = {
        folds = counts.folds,
        conceal = counts.conceal,
    }
    local sibling_win = vim.api.nvim_open_win(bufnr, true, {
        relative = "editor",
        row = 0,
        col = 0,
        width = 30,
        height = 3,
        style = "minimal",
    })
    vim.api.nvim_set_current_win(sibling_win)
    local sibling_first = lifecycle.apply_buffer_features(bufnr)
    assert(
        sibling_first.window == true
            or (
                counts.folds > sibling_counts.folds
                and counts.conceal > sibling_counts.conceal
            ),
        "a second window displaying the same buffer should get its own window signature through open or explicit apply"
    )

    vim.api.nvim_set_current_win(original_win)
    local original_drift_counts = {
        folds = counts.folds,
        conceal = counts.conceal,
    }
    vim.wo[original_win].conceallevel = vim.wo[original_win].conceallevel == 3
            and 1
        or 3
    local original_drift = lifecycle.apply_buffer_features(bufnr)
    assert(
        original_drift.window == true,
        "window option drift should invalidate only the current window signature"
    )
    assert(
        counts.folds > original_drift_counts.folds
            and counts.conceal > original_drift_counts.conceal,
        "window-local features should reapply for the drifted window"
    )

    vim.api.nvim_set_current_win(sibling_win)
    local sibling_stable_counts = {
        folds = counts.folds,
        conceal = counts.conceal,
    }
    local sibling_stable = lifecycle.apply_buffer_features(bufnr)
    assert(
        sibling_stable.window == false,
        "window option drift in another window should not invalidate this window"
    )
    assert(
        counts.folds == sibling_stable_counts.folds
            and counts.conceal == sibling_stable_counts.conceal,
        "stable sibling window should not reapply window-local features"
    )

    local other_bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(other_bufnr, 0, -1, false, { "other" })
    local other_win = vim.api.nvim_open_win(other_bufnr, true, {
        relative = "editor",
        row = 4,
        col = 0,
        width = 30,
        height = 3,
        style = "minimal",
    })
    local all_window_counts = {
        folds = counts.folds,
        conceal = counts.conceal,
        indent = counts.indent,
        imaps = counts.imaps,
        match_highlight = counts.match_highlight,
        syntax = counts.syntax,
    }
    local all_windows =
        lifecycle.apply_buffer_features_all_windows(bufnr, { force = true })
    assert(
        all_windows.buffer == true,
        "all-window apply should still run buffer-local features once"
    )
    assert(
        all_windows.windows >= 2,
        "all-window apply should refresh every visible window for the buffer"
    )
    assert(
        counts.folds >= all_window_counts.folds + 2
            and counts.conceal >= all_window_counts.conceal + 2,
        "all-window apply should run window-local features in noncurrent windows"
    )
    assert(
        counts.indent == all_window_counts.indent + 1
            and counts.imaps == all_window_counts.imaps + 1
            and counts.match_highlight == all_window_counts.match_highlight + 1
            and counts.syntax == all_window_counts.syntax + 1,
        "all-window apply should run buffer-local features exactly once"
    )

    local stale_window_counts = {
        indent = counts.indent,
        imaps = counts.imaps,
        match_highlight = counts.match_highlight,
        syntax = counts.syntax,
    }
    core_windows.all_for_buffer = function()
        return { 999999 }
    end
    local stale_window_apply =
        lifecycle.apply_buffer_features_all_windows(bufnr, { force = true })
    core_windows.all_for_buffer = originals.all_for_buffer
    assert(
        stale_window_apply.buffer == true and stale_window_apply.windows == 0,
        "all-window apply should fall back to buffer-local setup when window list is stale"
    )
    assert(
        counts.indent == stale_window_counts.indent + 1
            and counts.imaps == stale_window_counts.imaps + 1
            and counts.match_highlight == stale_window_counts.match_highlight + 1
            and counts.syntax == stale_window_counts.syntax + 1,
        "stale window fallback should run buffer-local features once"
    )
    vim.api.nvim_win_close(other_win, true)
    vim.api.nvim_set_current_win(original_win)
    vim.api.nvim_win_close(sibling_win, true)

    local option_drift_counts = {
        folds = counts.folds,
        conceal = counts.conceal,
        indent = counts.indent,
        syntax = counts.syntax,
    }
    vim.wo.conceallevel = vim.wo.conceallevel == 3 and 1 or 3
    vim.wo.foldmethod = "manual"
    local option_drift = lifecycle.apply_buffer_features(bufnr)
    assert(
        option_drift.window == true,
        "window option changes should invalidate window feature signatures"
    )
    assert(
        option_drift.buffer == false,
        "window option changes should not invalidate buffer-local features"
    )
    assert(
        counts.folds > option_drift_counts.folds,
        "folds should reapply after owned window options change"
    )
    assert(
        counts.conceal > option_drift_counts.conceal,
        "conceal should reapply after owned window options change"
    )
    assert(
        counts.indent == option_drift_counts.indent
            and counts.syntax == option_drift_counts.syntax,
        "window option changes should not rerun buffer-local setup"
    )

    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "= Changed" })
    local changed_counts = {
        indent = counts.indent,
        imaps = counts.imaps,
        match_highlight = counts.match_highlight,
        syntax = counts.syntax,
    }
    local changed = lifecycle.apply_buffer_features(bufnr)
    assert(
        changed.buffer == true,
        "buffer changes should invalidate feature apply signatures"
    )
    assert(
        counts.indent > changed_counts.indent,
        "indent should reapply after buffer changes"
    )
    assert(
        counts.imaps > changed_counts.imaps,
        "imaps should reapply after buffer changes"
    )
    assert(
        counts.match_highlight > changed_counts.match_highlight,
        "match highlight should reapply after buffer changes"
    )
    assert(
        counts.syntax > changed_counts.syntax,
        "syntax should reapply after buffer changes"
    )

    local fake_project = {
        key = "feature-reapply-project",
        root = root,
        main = root .. "/tests/fixtures/basic/main.typ",
        bufs = {
            [bufnr] = true,
        },
    }
    project_services.ensure(fake_project)
    project.get = function(query_bufnr)
        if query_bufnr == bufnr then
            return fake_project
        end
        return originals.project_get(query_bufnr)
    end

    local attached_counts = {
        syntax = counts.syntax,
    }
    local attached = lifecycle.apply_buffer_features(bufnr)
    assert(
        attached.buffer == true,
        "attaching a project should invalidate feature apply signatures"
    )
    assert(
        counts.syntax > attached_counts.syntax,
        "syntax should apply once a project is visible"
    )

    local stable_project_counts = {
        syntax = counts.syntax,
    }
    local stable_project = lifecycle.apply_buffer_features(bufnr)
    assert(
        stable_project.buffer == false,
        "stable project signatures should skip buffer-local feature work"
    )
    assert(
        counts.syntax == stable_project_counts.syntax,
        "syntax should not reapply while the project signature is stable"
    )

    local project_index = project_services.index(fake_project)
    project_index.generation = (project_index.generation or 0) + 1
    local indexed = lifecycle.apply_buffer_features(bufnr)
    assert(
        indexed.buffer == true,
        "project index changes should invalidate feature apply signatures"
    )
    assert(
        counts.syntax > stable_project_counts.syntax,
        "syntax should reapply after project index changes"
    )
end, debug.traceback)

folds.apply = originals.folds
indent.apply = originals.indent
imaps.apply = originals.imaps
match_highlight.apply = originals.match_highlight
conceal.apply = originals.conceal
syntax.apply = originals.syntax
project.get = originals.project_get
core_windows.all_for_buffer = originals.all_for_buffer

if not ok then
    error(err)
end

local setup_ok, setup_err = xpcall(function()
    typst.reset()
    typst.setup({
        root = root,
        output_dir = typst_test_cache_path("setup-reapply-output"),
        mappings = {
            next_heading = "]h",
        },
    })

    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_buf_set_name(bufnr, root .. "/tests/fixtures/basic/main.typ")
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "= Setup Reapply" })
    vim.bo[bufnr].filetype = "typst"

    local state = typst.project.attach(bufnr)
    assert(state and state.bufs[bufnr], "buffer should attach before re-setup")
    assert(
        has_buffer_map(bufnr, "n", "]h"),
        "initial setup should install configured Typst mapping"
    )

    local indent_apply_count = 0
    indent.apply = function(...)
        indent_apply_count = indent_apply_count + 1
        return originals.indent(...)
    end

    typst.setup({
        root = root,
        output_dir = typst_test_cache_path("setup-reapply-output"),
        mappings = {
            enabled = false,
        },
    })

    assert(
        not has_buffer_map(bufnr, "n", "]h"),
        "setup should remove stale typst.nvim-owned mappings from attached buffers"
    )
    assert(
        indent_apply_count > 0,
        "setup should force-reapply buffer features for attached buffers"
    )
end, debug.traceback)

indent.apply = originals.indent
typst.reset()

if not setup_ok then
    error(setup_err)
end

vim.cmd("qa!")
