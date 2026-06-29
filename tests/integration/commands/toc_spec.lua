local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local index = require("typst.index")
local typst = require("typst")
local toc_module = require("typst.edit.toc")
local util = require("typst.core.util")
typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("toc-output"),
    toc = {
        refresh_delay_ms = 10,
        mappings = {
            jump = "o",
            preview = "P",
            close = "x",
            refresh = "R",
            toggle = "z",
            toggle_layer = "L",
            filter = "f",
            clear_filter = "F",
        },
    },
})

local main = root .. "/tests/fixtures/basic/main.typ"
vim.cmd("edit! " .. vim.fn.fnameescape(main))
local project = typst.project.set_main(main)
project = assert(typst.project.attach(0), "TOC test buffer should attach")

local done = false
typst.compiler.compile({}, function(result)
    assert(result.code == 0, "compile failed before TOC test")
    done = true
end)

assert(
    vim.wait(10000, function()
        return done
    end, 20),
    "Typst compile did not finish"
)

local items = toc_module.collect(project, { backend = "treesitter" })
local titles = vim.tbl_map(function(item)
    return item.title
end, items)

assert(vim.tbl_contains(titles, "Main"), "TOC missing main heading")
assert(
    vim.tbl_contains(titles, "Chapter"),
    "TOC missing included chapter heading"
)
assert(
    vim.tbl_contains(titles, "Appendix"),
    "TOC missing included appendix heading"
)

local old_index_collect = index.collect
index.collect = function()
    return {
        headings = {
            {
                title = "Non-Main Heading",
                level = 1,
                source = {
                    path = "A:\\Users\\Charlie\\Project\\chapter.typ",
                    lnum = 1,
                    col = 1,
                },
            },
            {
                title = "Windows Main Heading",
                level = 1,
                source = {
                    path = "c:\\users\\charlie\\project\\main.typ",
                    lnum = 2,
                    col = 1,
                },
            },
        },
    }
end
local windows_toc = toc_module.collect({
    root = "C:/Users/Charlie/Project",
    main = "C:/Users/Charlie/Project/main.typ",
}, {
    backend = "treesitter",
    layers = false,
})
index.collect = old_index_collect
assert(
    windows_toc[1] and windows_toc[1].title == "Windows Main Heading",
    "TOC sorting should treat Windows-equivalent paths as the project main"
)

index.collect = function()
    return {
        headings = {
            {
                title = "Windows Main Heading",
                level = 1,
                source = {
                    path = "C:/Users/Charlie/Project/main.typ",
                    lnum = 1,
                    col = 1,
                },
            },
        },
        todos = {
            {
                tag = "TODO",
                text = "same file",
                source = {
                    path = "c:\\users\\charlie\\project\\main.typ",
                    lnum = 2,
                    col = 1,
                },
            },
        },
    }
end
local windows_project = {
    key = "windows-toc",
    root = "C:/Users/Charlie/Project",
    main = "C:/Users/Charlie/Project/main.typ",
}
toc_module.open(windows_project, { backend = "treesitter" })
local windows_toc_buf = vim.api.nvim_get_current_buf()
local windows_toc_lines =
    vim.api.nvim_buf_get_lines(windows_toc_buf, 0, -1, false)
index.collect = old_index_collect
assert(
    windows_toc_lines[1]
        and windows_toc_lines[1]:find("- Windows Main Heading", 1, true),
    "TOC hierarchy should treat equivalent heading/layer paths as same-file children"
)
assert(
    windows_toc_lines[2]
        and windows_toc_lines[2]:match("^%s+%[todo%] TODO: same file"),
    "TOC same-file layer child should be indented under its equivalent-path heading"
)
toc_module.close(windows_project)

typst.navigation.toc({ open = false })
assert(
    not toc_module.is_open(project),
    "open=false should collect TOC without opening a window"
)

typst.navigation.toc({ backend = "treesitter" })
local toc_win = vim.api.nvim_get_current_win()
local toc_buf = vim.api.nvim_win_get_buf(toc_win)
assert(vim.b[toc_buf].typst_toc == true, "TOC should open a dedicated buffer")
assert(
    vim.bo[toc_buf].filetype == "typsttoc",
    "TOC buffer should use typsttoc filetype"
)
assert(
    vim.api.nvim_buf_line_count(toc_buf) >= 3,
    "TOC buffer should render headings"
)

local function has_mapping(bufnr, lhs)
    for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
        if mapping.lhs == lhs then
            return true
        end
    end
    return false
end

assert(has_mapping(toc_buf, "o"), "custom TOC jump mapping should be installed")
assert(
    has_mapping(toc_buf, "P"),
    "custom TOC preview mapping should be installed"
)
assert(
    has_mapping(toc_buf, "x"),
    "custom TOC close mapping should be installed"
)
assert(
    has_mapping(toc_buf, "R"),
    "custom TOC refresh mapping should be installed"
)
assert(
    has_mapping(toc_buf, "z"),
    "custom TOC heading-toggle mapping should be installed"
)
assert(
    has_mapping(toc_buf, "L"),
    "custom TOC layer-toggle mapping should be installed"
)
assert(
    has_mapping(toc_buf, "f"),
    "custom TOC filter mapping should be installed"
)
assert(
    has_mapping(toc_buf, "F"),
    "custom TOC clear-filter mapping should be installed"
)
assert(
    not has_mapping(toc_buf, "q"),
    "custom TOC close mapping should replace the default key"
)

local source_win = nil
for _, winid in ipairs(vim.api.nvim_list_wins()) do
    local bufnr = vim.api.nvim_win_get_buf(winid)
    if winid ~= toc_win and vim.b[bufnr].typst_toc ~= true then
        source_win = winid
        break
    end
end
assert(
    source_win,
    "TOC should leave a source window available for follow-cursor"
)

vim.api.nvim_set_current_win(source_win)
local source_buf = vim.api.nvim_win_get_buf(source_win)
vim.api.nvim_buf_set_lines(source_buf, -1, -1, false, { "", "== Live Refresh" })
vim.api.nvim_exec_autocmds(
    "TextChanged",
    { buffer = source_buf, modeline = false }
)
assert(
    vim.wait(1000, function()
        local toc_text = table.concat(
            vim.api.nvim_buf_get_lines(toc_buf, 0, -1, false),
            "\n"
        )
        return toc_text:find("Live Refresh", 1, true)
            and vim.api.nvim_get_current_win() == source_win
    end, 10),
    "open TOC should auto-refresh after source edits without stealing focus"
)

vim.api.nvim_set_current_win(source_win)
vim.cmd.edit(root .. "/tests/fixtures/basic/chapter.typ")
vim.api.nvim_win_set_cursor(0, { 1, 0 })
local followed =
    toc_module.follow(project, vim.api.nvim_get_current_buf(), { force = true })
assert(followed, "TOC follow should find the current dependency heading")
assert(
    toc_module.current_line(project) == followed,
    "TOC follow should record the current TOC line"
)
assert(
    vim.api.nvim_win_get_cursor(toc_win)[1] == followed,
    "TOC follow should move the TOC cursor"
)
local followed_text = vim.api.nvim_buf_get_lines(
    toc_buf,
    followed - 1,
    followed,
    false
)[1] or ""
assert(
    followed_text:find("Chapter", 1, true),
    "TOC follow should select the current section"
)
local toc_namespace = vim.api.nvim_get_namespaces()["typst.nvim.toc"]
assert(type(toc_namespace) == "number", "TOC namespace should be registered")
local function current_marker_line()
    local extmarks =
        vim.api.nvim_buf_get_extmarks(toc_buf, toc_namespace, 0, -1, {})
    local mark = extmarks[1]
    return mark and mark[2] + 1 or nil
end
assert(
    current_marker_line() == followed,
    "TOC follow should highlight the current section"
)
vim.api.nvim_set_current_win(toc_win)
toc_module.open(project, { backend = "treesitter" })
assert(
    toc_module.current_line(project) == followed,
    "TOC refresh from the TOC window should keep current state"
)
assert(
    current_marker_line() == followed,
    "TOC refresh from the TOC window should preserve current highlight"
)

local appendix_line = nil
for line, value in ipairs(vim.api.nvim_buf_get_lines(toc_buf, 0, -1, false)) do
    if value:find("Appendix", 1, true) then
        appendix_line = line
        break
    end
end
assert(appendix_line, "TOC should include appendix for preview test")

vim.api.nvim_set_current_win(toc_win)
vim.api.nvim_win_set_cursor(toc_win, { appendix_line, 0 })
local preview_callback = nil
for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(toc_buf, "n")) do
    if mapping.lhs == "P" then
        preview_callback = mapping.callback
        break
    end
end
assert(
    type(preview_callback) == "function",
    "TOC preview mapping should use a Lua callback"
)
local appendix_bufnr =
    vim.fn.bufadd(root .. "/tests/fixtures/basic/appendix.typ")
vim.fn.bufload(appendix_bufnr)
local original_edit_existing_or_path = util.edit_existing_or_path
local helper_path = nil
util.edit_existing_or_path = function(path)
    helper_path = path
    vim.api.nvim_set_current_buf(appendix_bufnr)
    return appendix_bufnr
end
local preview_ok, preview_err = pcall(preview_callback)
util.edit_existing_or_path = original_edit_existing_or_path
assert(preview_ok, preview_err)
assert(
    helper_path and helper_path:match("appendix%.typ$"),
    "TOC preview should route source jumps through the path-identity buffer helper"
)
assert(
    vim.api.nvim_get_current_win() == toc_win,
    "TOC preview should keep focus in the TOC window"
)
assert(
    vim.api
        .nvim_buf_get_name(vim.api.nvim_win_get_buf(source_win))
        :match("appendix%.typ$"),
    "TOC preview should open the selected entry in the source window"
)

typst.navigation.toc_toggle({ backend = "treesitter" })
assert(
    not vim.api.nvim_win_is_valid(toc_win),
    "TypstTocToggle should close the dedicated TOC window"
)

typst.navigation.toc({ open = false, mode = "quickfix", backend = "treesitter" })
local qf = vim.fn.getqflist({ title = 1, items = 1 })
assert(qf.title:match("typst.nvim TOC"), "TOC quickfix title was not set")
assert(#qf.items >= 3, "TOC quickfix did not receive headings")

typst.navigation.toc({ mode = "quickfix", backend = "treesitter" })
local qf_win = vim.fn.getqflist({ winid = 0 }).winid
assert(qf_win and qf_win > 0, "TOC should open a quickfix window")
local qf_buf = vim.api.nvim_win_get_buf(qf_win)
assert(vim.b[qf_buf].typst_toc == true, "TOC quickfix buffer should be marked")

assert(
    has_mapping(qf_buf, "o"),
    "custom quickfix TOC jump mapping should be installed"
)
assert(
    has_mapping(qf_buf, "x"),
    "custom quickfix TOC close mapping should be installed"
)
assert(
    has_mapping(qf_buf, "R"),
    "custom quickfix TOC refresh mapping should be installed"
)
assert(
    not has_mapping(qf_buf, "q"),
    "custom quickfix TOC close mapping should replace the default key"
)

toc_module.close_quickfix()

typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("toc-output"),
    toc = {
        mode = "window",
    },
})
vim.cmd("edit! " .. vim.fn.fnameescape(main))
local detach_project =
    assert(typst.project.attach(0), "TOC detach fixture should attach")
local detach_source_buf = vim.api.nvim_get_current_buf()
toc_module.open(detach_project, { backend = "treesitter" })
local detach_toc_win = vim.api.nvim_get_current_win()
assert(
    toc_module.is_open(detach_project),
    "dedicated TOC should be open before source detach"
)
typst.project.detach(detach_source_buf)
assert(
    not vim.api.nvim_win_is_valid(detach_toc_win),
    "dedicated TOC should close after last source detach"
)
assert(
    not toc_module.is_open(detach_project),
    "TOC state should report closed after last source detach"
)

typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("toc-output"),
    toc = {
        mode = "quickfix",
    },
})
vim.cmd("edit! " .. vim.fn.fnameescape(main))
local detach_qf_project =
    assert(typst.project.attach(0), "TOC quickfix detach fixture should attach")
local detach_qf_source_buf = vim.api.nvim_get_current_buf()
toc_module.open(
    detach_qf_project,
    { backend = "treesitter", mode = "quickfix" }
)
local detach_qf_win = vim.fn.getqflist({ winid = 0 }).winid
assert(
    detach_qf_win and detach_qf_win > 0,
    "TOC quickfix should be open before source detach"
)
typst.project.detach(detach_qf_source_buf)
assert(
    not vim.api.nvim_win_is_valid(detach_qf_win),
    "TOC quickfix should close after last source detach"
)
assert(
    not toc_module.quickfix_is_open(),
    "TOC quickfix state should report closed after last source detach"
)

vim.cmd("qa!")
