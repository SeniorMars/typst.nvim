local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")
typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("motions-output"),
})

local fixture = root .. "/tests/fixtures/basic/editing.typ"
vim.cmd.edit(fixture)
vim.bo.filetype = "typst"
typst.project.attach(0)

local motions = require("typst.edit.motions")

vim.api.nvim_win_set_cursor(0, { 1, 0 })
assert(motions.next_heading(), "next heading motion failed")
assert(
    vim.api.nvim_win_get_cursor(0)[1] == 5,
    "next heading did not jump to the second heading"
)

assert(motions.previous_heading(), "previous heading motion failed")
assert(
    vim.api.nvim_win_get_cursor(0)[1] == 1,
    "previous heading did not jump to the first heading"
)

vim.api.nvim_win_set_cursor(0, { 1, 0 })
assert(motions.next_heading_end(), "next heading end motion failed")
cursor = vim.api.nvim_win_get_cursor(0)
assert(
    cursor[1] == 1 and cursor[2] == 17,
    "next heading end did not jump to the first heading end"
)

vim.api.nvim_win_set_cursor(0, { 6, 0 })
assert(motions.previous_heading_end(), "previous heading end motion failed")
cursor = vim.api.nvim_win_get_cursor(0)
assert(
    cursor[1] == 5 and cursor[2] == 5,
    "previous heading end did not jump to the previous heading end"
)

vim.api.nvim_win_set_cursor(0, { 11, 0 })
assert(motions.next_block(), "next block motion failed")
cursor = vim.api.nvim_win_get_cursor(0)
assert(
    cursor[1] == 13 and cursor[2] == 1,
    "next block did not jump to the following function call"
)

vim.api.nvim_win_set_cursor(0, { 1, 0 })
assert(motions.next_block_end(), "next block end motion failed")
cursor = vim.api.nvim_win_get_cursor(0)
assert(
    cursor[1] == 1 and cursor[2] == 17,
    "next block end did not jump to the first function call end"
)

vim.api.nvim_win_set_cursor(0, { 17, 0 })
assert(motions.previous_block(), "previous block motion failed")
cursor = vim.api.nvim_win_get_cursor(0)
assert(
    cursor[1] == 15 and cursor[2] == 0,
    "previous block did not jump to the raw block start"
)

vim.api.nvim_win_set_cursor(0, { 17, 0 })
assert(motions.previous_block_end(), "previous block end motion failed")
cursor = vim.api.nvim_win_get_cursor(0)
assert(
    cursor[1] == 14 and cursor[2] == 14,
    "previous block end did not jump to the previous function call end"
)

vim.api.nvim_win_set_cursor(0, { 1, 0 })
assert(motions.next_equation(), "next equation motion failed")
local cursor = vim.api.nvim_win_get_cursor(0)
assert(
    cursor[1] == 3 and cursor[2] == 5,
    "next equation did not jump to inline math"
)

vim.api.nvim_win_set_cursor(0, { 1, 0 })
assert(motions.next_equation_end(), "next equation end motion failed")
cursor = vim.api.nvim_win_get_cursor(0)
assert(
    cursor[1] == 3 and cursor[2] == 11,
    "next equation end did not jump to inline math end"
)

vim.api.nvim_win_set_cursor(0, { 1, 0 })
assert(motions.next_equation({ count = 2 }), "counted equation motion failed")
cursor = vim.api.nvim_win_get_cursor(0)
assert(
    cursor[1] == 7 and cursor[2] == 0,
    "counted equation motion did not jump to block math"
)

vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.cmd("normal 2]n")
cursor = vim.api.nvim_win_get_cursor(0)
assert(
    cursor[1] == 7 and cursor[2] == 0,
    "counted equation mapping did not jump to block math"
)

vim.api.nvim_win_set_cursor(0, { 10, 0 })
assert(motions.previous_equation(), "previous equation motion failed")
cursor = vim.api.nvim_win_get_cursor(0)
assert(
    cursor[1] == 7 and cursor[2] == 0,
    "previous equation did not jump to block math start"
)

vim.api.nvim_win_set_cursor(0, { 10, 0 })
assert(motions.previous_equation_end(), "previous equation end motion failed")
cursor = vim.api.nvim_win_get_cursor(0)
assert(
    cursor[1] == 9 and cursor[2] == 0,
    "previous equation end did not jump to block math end"
)

vim.api.nvim_win_set_cursor(0, { 11, 0 })
vim.cmd("normal 2]m")
cursor = vim.api.nvim_win_get_cursor(0)
assert(
    cursor[1] == 13 and cursor[2] == 7,
    "counted block mapping did not jump to the second structural block"
)

vim.api.nvim_win_set_cursor(0, { 17, 0 })
vim.cmd("normal 3[[")
cursor = vim.api.nvim_win_get_cursor(0)
assert(
    cursor[1] == 1 and cursor[2] == 0,
    "counted previous heading mapping did not jump three headings back"
)

vim.api.nvim_win_set_cursor(0, { 1, 0 })
assert(
    motions.next_equation_end({ count = 2 }),
    "counted equation end motion failed"
)
cursor = vim.api.nvim_win_get_cursor(0)
assert(
    cursor[1] == 9 and cursor[2] == 0,
    "counted equation end motion did not jump to block math end"
)

vim.api.nvim_win_set_cursor(0, { 1, 0 })
assert(motions.next_raw_block(), "next raw block motion failed")
cursor = vim.api.nvim_win_get_cursor(0)
assert(
    cursor[1] == 15 and cursor[2] == 0,
    "next raw block did not jump to raw block"
)

vim.api.nvim_win_set_cursor(0, { 17, 0 })
assert(motions.previous_raw_block(), "previous raw block motion failed")
cursor = vim.api.nvim_win_get_cursor(0)
assert(
    cursor[1] == 15 and cursor[2] == 0,
    "previous raw block did not jump to raw block"
)

vim.api.nvim_win_set_cursor(0, { 11, 0 })
assert(motions.next_heading(), "wrapped heading motion failed")
cursor = vim.api.nvim_win_get_cursor(0)
assert(
    cursor[1] == 1 and cursor[2] == 0,
    "next heading did not wrap with wrapscan"
)

vim.cmd("clearjumps")
vim.api.nvim_win_set_cursor(0, { 1, 0 })
assert(motions.next_heading(), "next heading before jumplist test failed")
assert(
    vim.api.nvim_win_get_cursor(0)[1] == 5,
    "next heading before jumplist test jumped to wrong line"
)
vim.cmd("normal! \15")
cursor = vim.api.nvim_win_get_cursor(0)
assert(
    cursor[1] == 1 and cursor[2] == 0,
    "Typst motion should add the previous cursor to the jumplist"
)

assert(vim.fn.maparg("]m", "n") ~= "", "next block mapping missing")
assert(vim.fn.maparg("[m", "n") ~= "", "previous block mapping missing")
assert(vim.fn.maparg("][", "n") ~= "", "next heading end mapping missing")
assert(vim.fn.maparg("[]", "n") ~= "", "previous heading end mapping missing")
assert(vim.fn.maparg("]M", "n") ~= "", "next block end mapping missing")
assert(vim.fn.maparg("]n", "n") ~= "", "next equation mapping missing")
assert(vim.fn.maparg("]N", "n") ~= "", "next equation end mapping missing")
assert(vim.fn.maparg("]r", "n") ~= "", "next raw block mapping missing")
assert(vim.fn.maparg("]/", "n") ~= "", "next comment mapping missing")
assert(
    vim.fn.maparg("]n", "o") ~= "",
    "next equation operator-pending mapping missing"
)
assert(vim.fn.maparg("]n", "x") ~= "", "next equation visual mapping missing")

vim.fn.setreg("0", "")
vim.api.nvim_win_set_cursor(0, { 3, 0 })
vim.cmd("silent normal y]n")
assert(
    vim.fn.getreg("0") == "Text ",
    ("operator-pending equation motion yanked wrong text: %q"):format(
        vim.fn.getreg("0")
    )
)

vim.fn.setreg("0", "")
vim.api.nvim_win_set_cursor(0, { 3, 0 })
vim.cmd("silent normal y2]n")
assert(
    vim.fn.getreg("0") == "Text $x + y$ end.\n\n== Two\n\n",
    ("counted operator-pending equation motion yanked wrong text: %q"):format(
        vim.fn.getreg("0")
    )
)

vim.api.nvim_win_set_cursor(0, { 3, 0 })
vim.cmd("normal v]n")
cursor = vim.api.nvim_win_get_cursor(0)
assert(
    cursor[1] == 3 and cursor[2] == 5,
    "visual equation motion should extend to the next equation start"
)
vim.cmd("normal! \27")

local scratch = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(scratch)
vim.bo[scratch].filetype = "typst"
vim.api.nvim_buf_set_lines(scratch, 0, -1, false, {
    "Alpha",
    "// first comment",
    "Beta",
    "// second comment",
})

vim.api.nvim_win_set_cursor(0, { 1, 0 })
assert(motions.next_comment(), "next comment motion failed")
cursor = vim.api.nvim_win_get_cursor(0)
assert(
    cursor[1] == 2 and cursor[2] == 0,
    "next comment did not jump to the first comment"
)

assert(motions.next_comment(), "second next comment motion failed")
cursor = vim.api.nvim_win_get_cursor(0)
assert(
    cursor[1] == 4 and cursor[2] == 0,
    "next comment did not jump to the second comment"
)

assert(motions.previous_comment(), "previous comment motion failed")
cursor = vim.api.nvim_win_get_cursor(0)
assert(
    cursor[1] == 2 and cursor[2] == 0,
    "previous comment did not jump to the first comment"
)

local current_win = vim.api.nvim_get_current_win()
local current_buf = vim.api.nvim_get_current_buf()
vim.api.nvim_win_set_cursor(current_win, { 1, 0 })
local target_buf = vim.api.nvim_create_buf(false, true)
vim.bo[target_buf].filetype = "typst"
vim.api.nvim_buf_set_lines(target_buf, 0, -1, false, {
    "= One",
    "text",
    "== Two",
})
vim.cmd("vsplit")
local target_win = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_buf(target_win, target_buf)
vim.api.nvim_win_set_cursor(target_win, { 1, 0 })
vim.api.nvim_set_current_win(current_win)
assert(
    motions.next_heading({
        bufnr = target_buf,
        winid = target_win,
        notify = false,
    }),
    "targeted heading motion should use the supplied window"
)
cursor = vim.api.nvim_win_get_cursor(target_win)
assert(
    cursor[1] == 3 and cursor[2] == 0,
    "targeted heading motion should move the target window"
)
assert(
    vim.api.nvim_get_current_buf() == current_buf
        and vim.api.nvim_win_get_cursor(current_win)[1] == 1,
    "targeted heading motion should not move the current window"
)

vim.cmd("qa!")
