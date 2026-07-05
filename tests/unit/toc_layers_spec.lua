local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local toc = require("typst.edit.toc")
local typst = require("typst")

typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("toc-layers-output"),
})
local main = root .. "/tests/fixtures/basic/index-main.typ"
vim.cmd.edit(main)
local project =
    assert(typst.project.attach(0), "layered TOC fixture should attach")

local items = toc.collect(project, { backend = "treesitter" })
local function has_layer(layer, matcher)
    for _, item in ipairs(items) do
        if item.layer == layer and (not matcher or matcher(item)) then
            return true
        end
    end
    return false
end

assert(
    has_layer("label", function(item)
        return item.title == "sec:intro"
    end),
    "layered TOC should include labels"
)

assert(
    has_layer("reference", function(item)
        return item.title == "@sec:intro"
    end),
    "layered TOC should include references"
)

assert(
    not has_layer("reference", function(item)
        return item.title == "@doe2020"
    end),
    "layered TOC should not expose citation-targeted shorthand as label references"
)

assert(
    has_layer("citation", function(item)
        return item.title == "doe2020"
    end),
    "layered TOC should include bibliography keys"
)

assert(
    has_layer("file", function(item)
        return item.title:find("image: diagram.svg", 1, true) ~= nil
    end),
    "layered TOC should include image paths"
)

assert(
    has_layer("file", function(item)
        return item.title:find("read: data.json", 1, true) ~= nil
    end),
    "layered TOC should include data paths"
)

assert(
    has_layer("import", function(item)
        return item.title == "@preview/cetz:0.3.4"
    end),
    "layered TOC should include package imports"
)

assert(
    has_layer("todo", function(item)
        return item.title == "TODO: wire layered TOC"
    end),
    "layered TOC should include TODO comments"
)

assert(has_layer("figure"), "layered TOC should include figures")
assert(has_layer("table"), "layered TOC should include tables")
assert(has_layer("equation"), "layered TOC should include equations")

assert(
    has_layer("definition", function(item)
        return item.title == "local-card"
    end),
    "layered TOC should include local definitions"
)

toc.open(project, { open = false, mode = "quickfix", backend = "treesitter" })
local qf = vim.fn.getqflist({ title = 1, items = 1 })
assert(
    qf.title:match("typst.nvim TOC"),
    "layered TOC quickfix title was not set"
)

local qf_text = table.concat(
    vim.tbl_map(function(item)
        return item.text
    end, qf.items),
    "\n"
)
assert(
    qf_text:find("[todo] TODO: wire layered TOC", 1, true),
    "quickfix should show TODO layer"
)
assert(
    qf_text:find("[label] sec:intro", 1, true),
    "quickfix should show label layer"
)
assert(
    qf_text:find("[definition] local-card", 1, true),
    "quickfix should show definition layer"
)

toc.open(project, { backend = "treesitter" })
local toc_win = vim.api.nvim_get_current_win()
local toc_buf = vim.api.nvim_win_get_buf(toc_win)

local function lines()
    return vim.api.nvim_buf_get_lines(toc_buf, 0, -1, false)
end

local function text()
    return table.concat(lines(), "\n")
end

local function invoke_mapping(lhs)
    for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(toc_buf, "n")) do
        if mapping.lhs == lhs then
            assert(
                type(mapping.callback) == "function",
                "TOC mapping should use a Lua callback: " .. lhs
            )
            mapping.callback()
            return
        end
    end
    error("missing TOC mapping: " .. lhs)
end

toc.filter(project, "todo", { backend = "treesitter" })
assert(
    vim.b[toc_buf].typst_toc_filter == "todo",
    "TOC buffer should record the active filter"
)
local filtered = lines()
assert(#filtered >= 1, "TOC filter should render matching entries")
for _, line in ipairs(filtered) do
    assert(
        line:find("[todo]", 1, true),
        "TOC filter should render only matching TODO entries"
    )
end
assert(
    text():find("[todo] TODO: wire layered TOC", 1, true),
    "TOC filter should match layer/title text"
)

toc.clear_filter(project, { backend = "treesitter" })
assert(
    vim.b[toc_buf].typst_toc_filter == nil,
    "TOC clear_filter should clear the active filter"
)

local expanded = lines()
assert(
    #expanded > 1,
    "dedicated TOC should render heading children before collapse"
)
assert(
    expanded[1]:find("- Intro", 1, true),
    "heading with children should render expanded marker"
)

vim.api.nvim_win_set_cursor(toc_win, { 1, 0 })
invoke_mapping("za")
local collapsed = lines()
assert(
    #collapsed < #expanded,
    "collapsed heading should hide child TOC entries"
)
assert(
    collapsed[1]:find("+ Intro", 1, true),
    "collapsed heading should render collapsed marker"
)
assert(
    not text():find("[todo] TODO: wire layered TOC", 1, true),
    "collapsed heading should hide same-file layer children"
)

toc.open(project, { backend = "treesitter" })
local refreshed_collapsed = lines()
assert(
    refreshed_collapsed[1]:find("+ Intro", 1, true),
    "TOC refresh should preserve collapsed heading state"
)
assert(
    not text():find("[todo] TODO: wire layered TOC", 1, true),
    "TOC refresh should keep collapsed children hidden"
)
assert(
    vim.api.nvim_win_get_cursor(toc_win)[1] == 1,
    "TOC refresh should preserve the cursor entry"
)

invoke_mapping("za")
expanded = lines()
assert(
    #expanded > #collapsed,
    "second heading toggle should restore child TOC entries"
)

local todo_line = nil
for line, value in ipairs(expanded) do
    if value:find("[todo] TODO: wire layered TOC", 1, true) then
        todo_line = line
        break
    end
end
assert(todo_line, "expanded TOC should include TODO layer before layer toggle")
vim.api.nvim_win_set_cursor(toc_win, { todo_line, 0 })
invoke_mapping("L")
assert(
    not text():find("[todo] TODO: wire layered TOC", 1, true),
    "TOC layer toggle should hide current layer"
)

local nav_toc = require("typst.navigation.toc")
local telemetry = require("typst.core.telemetry")

typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("toc-follow-output"),
    toc = {
        follow_delay_ms = 10,
    },
})
main = root .. "/tests/fixtures/basic/main.typ"
vim.cmd("edit! " .. vim.fn.fnameescape(main))
typst.project.set_main(main)
project =
    assert(typst.project.attach(0), "TOC follow debounce fixture should attach")
local bufnr = vim.api.nvim_get_current_buf()

local old_is_open = nav_toc.is_open
local old_follow = nav_toc.follow
local open = false
local calls = 0
local followed_bufnr = nil
local expected_project_key = project.key

rawset(nav_toc, "is_open", function(attached)
    return open and attached and attached.key == expected_project_key
end)
rawset(nav_toc, "follow", function(attached, follow_bufnr)
    assert(
        attached and attached.key == expected_project_key,
        "debounced follow should keep project context"
    )
    calls = calls + 1
    followed_bufnr = follow_bufnr
    return true
end)
local function cursor_moved()
    vim.api.nvim_exec_autocmds("CursorMoved", {
        buffer = bufnr,
        modeline = false,
    })
end

local ok, err = xpcall(function()
    telemetry.reset()
    cursor_moved()
    vim.wait(60, function()
        return calls > 0
    end, 5)
    assert(calls == 0, "closed TOC should not schedule cursor follow")

    open = true
    for _ = 1, 8 do
        cursor_moved()
    end

    assert(
        vim.wait(1000, function()
            return calls == 1
        end, 5),
        "cursor follow debounce should collapse a burst into one follow"
    )
    assert(
        followed_bufnr == bufnr,
        "debounced follow should use the source buffer"
    )
    local follow_telemetry = telemetry.snapshot()
    assert(
        follow_telemetry["toc.follow.schedule"]
            and follow_telemetry["toc.follow.schedule"].count == 8,
        "cursor follow should record one schedule metric per open TOC cursor event"
    )
    assert(
        follow_telemetry["toc.follow.coalesced"]
            and follow_telemetry["toc.follow.coalesced"].count == 7,
        "cursor follow should record coalesced timer replacements"
    )
    assert(
        follow_telemetry["toc.follow.execute"]
            and follow_telemetry["toc.follow.execute"].count == 1,
        "cursor follow should execute only once after coalescing"
    )

    vim.wait(60, function()
        return calls > 1
    end, 5)
    assert(calls == 1, "cursor follow burst should not leak extra timer calls")
end, debug.traceback)

nav_toc.is_open = old_is_open
nav_toc.follow = old_follow

if not ok then
    error(err)
end

vim.cmd("qa!")
