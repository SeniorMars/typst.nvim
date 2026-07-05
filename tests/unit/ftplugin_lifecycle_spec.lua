local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")

vim.g.maplocalleader = ","
typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("ftplugin-lifecycle-output"),
})
local function run_typst_ftplugin()
    vim.bo.filetype = "typst"
    vim.cmd("source " .. vim.fn.fnameescape(root .. "/ftplugin/typst.lua"))
    vim.wait(100, function()
        return vim.bo.indentexpr == "v:lua.typst_nvim_indentexpr(v:lnum)"
    end, 5)
end

local function undo_ftplugin()
    local undo = vim.b.undo_ftplugin
    assert(
        type(undo) == "string"
            and undo:find('require("typst").project.detach', 1, true),
        "Typst undo_ftplugin missing"
    )
    vim.cmd(undo)
end

local untouched = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(untouched)
vim.api.nvim_buf_set_name(
    untouched,
    typst_test_cache_path("ftplugin-lifecycle/untouched.typ")
)
vim.fn.mkdir(vim.fs.dirname(vim.api.nvim_buf_get_name(untouched)), "p")
vim.fn.writefile({ "= Untouched" }, vim.api.nvim_buf_get_name(untouched))
vim.bo[untouched].indentexpr = "custom_indent()"
vim.bo[untouched].indentkeys = "custom-keys"
vim.bo[untouched].formatexpr = "custom_format()"
vim.bo[untouched].omnifunc = ""
vim.wo.foldmethod = "manual"
vim.wo.foldexpr = "0"
vim.wo.foldlevel = 3
vim.wo.foldtext = "custom_foldtext()"
vim.wo.conceallevel = 1
vim.keymap.set(
    "n",
    "gf",
    "<Nop>",
    { buffer = untouched, silent = true, desc = "previous gf" }
)

run_typst_ftplugin()
assert(
    vim.bo[untouched].indentexpr == "v:lua.typst_nvim_indentexpr(v:lnum)",
    "ftplugin should install indentexpr"
)
assert(
    vim.bo[untouched].indentkeys:find("0%]"),
    "ftplugin should install indentkeys"
)
assert(
    vim.bo[untouched].formatexpr == "v:lua.typst_nvim_formatexpr()",
    "ftplugin should install formatexpr"
)
assert(
    vim.bo[untouched].omnifunc == "v:lua.typst_nvim_omnifunc",
    "ftplugin should install omnifunc"
)
assert(vim.wo.foldmethod == "expr", "ftplugin should install foldmethod")
assert(
    vim.wo.foldexpr == "v:lua.typst_nvim_foldexpr()",
    "ftplugin should install foldexpr"
)
assert(vim.wo.foldlevel == 99, "ftplugin should install foldlevel")
assert(
    vim.wo.foldtext == "v:lua.typst_nvim_foldtext()",
    "ftplugin should install foldtext"
)
assert(vim.wo.conceallevel == 2, "ftplugin should install conceallevel")
assert(
    vim.fn.maparg("gf", "n", false, true).rhs == "<Plug>(typst-follow)",
    "ftplugin should install follow map"
)
assert(
    vim.fn.maparg(",ll", "n", false, true).rhs == "<Plug>(typst-watch)",
    "ftplugin should install VimTeX-style watch map"
)
assert(
    vim.fn.maparg(",lv", "n", false, true).rhs == "<Plug>(typst-view)",
    "ftplugin should install VimTeX-style view map"
)

vim.g.maplocalleader = ";"
undo_ftplugin()
assert(
    vim.bo[untouched].indentexpr == "custom_indent()",
    "detach should restore unchanged indentexpr"
)
assert(
    vim.bo[untouched].indentkeys == "custom-keys",
    "detach should restore unchanged indentkeys"
)
assert(
    vim.bo[untouched].formatexpr == "custom_format()",
    "detach should restore unchanged formatexpr"
)
assert(
    vim.bo[untouched].omnifunc == "",
    "detach should restore unchanged omnifunc"
)
assert(
    vim.wo.foldmethod == "manual",
    "detach should restore unchanged foldmethod"
)
assert(vim.wo.foldexpr == "0", "detach should restore unchanged foldexpr")
assert(vim.wo.foldlevel == 3, "detach should restore unchanged foldlevel")
assert(
    vim.wo.foldtext == "custom_foldtext()",
    "detach should restore unchanged foldtext"
)
assert(vim.wo.conceallevel == 1, "detach should restore unchanged conceallevel")
assert(
    vim.fn.maparg("gf", "n", false, true).rhs == "<Nop>",
    "detach should restore previous buffer map"
)
assert(
    vim.fn.maparg("gf", "n", false, true).noremap == 1,
    "detach should restore previous buffer map remap mode"
)
assert(
    vim.fn.maparg("gf", "n", false, true).silent == 1,
    "detach should restore previous buffer map silent flag"
)
assert(
    next(vim.fn.maparg(",ll", "n", false, true)) == nil,
    "detach should remove installed localleader maps even after leader changes"
)
assert(
    vim.b.did_typst_nvim_ftplugin == nil,
    "detach should clear the ftplugin guard"
)

vim.g.maplocalleader = ","
run_typst_ftplugin()
assert(
    vim.bo[untouched].indentexpr == "v:lua.typst_nvim_indentexpr(v:lnum)",
    "buffer should reattach after undo"
)
undo_ftplugin()

local changed = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(changed)
vim.api.nvim_buf_set_name(
    changed,
    typst_test_cache_path("ftplugin-lifecycle/changed.typ")
)
vim.fn.writefile({ "= Changed" }, vim.api.nvim_buf_get_name(changed))
vim.bo[changed].indentexpr = "base_indent()"
vim.bo[changed].indentkeys = "base-keys"
vim.bo[changed].formatexpr = "base_format()"
vim.bo[changed].omnifunc = ""
vim.wo.foldmethod = "manual"
vim.wo.foldexpr = "0"
vim.wo.foldlevel = 4
vim.wo.foldtext = "base_foldtext()"
vim.wo.conceallevel = 1

run_typst_ftplugin()
vim.bo[changed].indentexpr = "user_indent()"
vim.bo[changed].indentkeys = "user-keys"
vim.bo[changed].formatexpr = "user_format()"
vim.bo[changed].omnifunc = "user#complete"
vim.wo.foldmethod = "manual"
vim.wo.foldexpr = "1"
vim.wo.foldlevel = 7
vim.wo.foldtext = "user_foldtext()"
vim.wo.conceallevel = 0
vim.keymap.set(
    "n",
    "gf",
    "<Cmd>let g:typst_user_gf = 1<CR>",
    { buffer = changed, silent = true }
)

undo_ftplugin()
assert(
    vim.bo[changed].indentexpr == "user_indent()",
    "detach should preserve changed indentexpr"
)
assert(
    vim.bo[changed].indentkeys == "user-keys",
    "detach should preserve changed indentkeys"
)
assert(
    vim.bo[changed].formatexpr == "user_format()",
    "detach should preserve changed formatexpr"
)
assert(
    vim.bo[changed].omnifunc == "user#complete",
    "detach should preserve changed omnifunc"
)
assert(
    vim.wo.foldmethod == "manual",
    "detach should preserve changed foldmethod"
)
assert(vim.wo.foldexpr == "1", "detach should preserve changed foldexpr")
assert(vim.wo.foldlevel == 7, "detach should preserve changed foldlevel")
assert(
    vim.wo.foldtext == "user_foldtext()",
    "detach should preserve changed foldtext"
)
assert(vim.wo.conceallevel == 0, "detach should preserve changed conceallevel")
assert(
    vim.fn.maparg("gf", "n", false, true).rhs
        == "<Cmd>let g:typst_user_gf = 1<CR>",
    "detach should preserve changed buffer maps"
)

vim.cmd("qa!")
