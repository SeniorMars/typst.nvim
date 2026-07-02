local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")
local api_context = require("typst.api.context")
local project = require("typst.project")
local store = require("typst.project.store")

typst.reset({ force = true })
typst.setup({
    root_markers = {},
})

local function notification_counter()
    local calls = {}
    return calls,
        function(message, level)
            calls[#calls + 1] = {
                message = message,
                level = level,
            }
        end
end

vim.cmd.enew()
local bufnr = vim.api.nvim_get_current_buf()
vim.bo[bufnr].filetype = ""

local before = vim.tbl_count(project.all())
local status, status_err = typst.compiler.status({ bufnr = bufnr })
local output, output_err = typst.compiler.current_output({
    bufnr = bufnr,
})
local compile, compile_err = typst.compiler.compile({
    bufnr = bufnr,
    notify = false,
})
local preview_status = typst.viewer.preview_status({
    bufnr = bufnr,
    notify = false,
    echo = false,
})
local after = vim.tbl_count(project.all())

assert(status == nil, "compiler.status should not invent non-Typst projects")
assert(
    type(status_err) == "table" and status_err.reason == "no_project",
    "compiler.status should return a structured no_project error"
)
assert(output == nil, "current_output should not invent non-Typst projects")
assert(
    type(output_err) == "table" and output_err.reason == "no_project",
    "current_output should return a structured no_project error"
)
assert(compile == nil, "compile should not invent non-Typst projects")
assert(
    type(compile_err) == "table" and compile_err.reason == "no_project",
    "compile should return a structured no_project error"
)
assert(
    type(preview_status) == "table"
        and preview_status.ok == false
        and preview_status.reason == "no_project",
    "preview_status should report no_project without throwing"
)
assert(after == before, "public API no-project paths should not grow registry")

local service_snapshot, service_err = typst.project.services({ bufnr = bufnr })
assert(service_snapshot == nil, "project.services should not invent a project")
assert(
    type(service_err) == "table" and service_err.reason == "no_project",
    "project.services should preserve structured no_project errors"
)

local passive_calls, passive_notify = notification_counter()
local passive_ctx = api_context.project({ bufnr = bufnr }, {
    create = false,
    passive = true,
    operation = "compiler.status",
}, passive_notify)
assert(not passive_ctx.ok, "passive no-project lookup should fail cleanly")
assert(
    #passive_calls == 0,
    "passive no-project lookup should not notify by default"
)

local override_calls, override_notify = notification_counter()
local override_ctx = api_context.project({ bufnr = bufnr, notify = true }, {
    create = false,
    passive = true,
    operation = "compiler.status",
}, override_notify)
assert(not override_ctx.ok, "passive notify override should fail cleanly")
assert(
    #override_calls == 1,
    "opts.notify=true should override passive no-notify policy"
)

local active_calls, active_notify = notification_counter()
local active_ctx = api_context.project({ bufnr = bufnr }, {
    create = true,
    require_typst = true,
    operation = "compiler.compile",
}, active_notify)
assert(not active_ctx.ok, "active no-project lookup should fail cleanly")
assert(#active_calls == 1, "active no-project lookup should notify by default")

local fixture_root = vim.fn.tempname()
vim.fn.mkdir(fixture_root, "p")
local main = fixture_root .. "/main.typ"
local chapter = fixture_root .. "/chapter.typ"
vim.fn.writefile({ "= Main", '#include "chapter.typ"' }, main)
vim.fn.writefile({ "= Chapter" }, chapter)

vim.cmd.edit(vim.fn.fnameescape(main))
vim.bo.filetype = "typst"
local attached = typst.project.set_main(main)
project.update_dependencies(attached, { main, chapter })

vim.cmd.enew()
vim.bo.filetype = ""

local status_by_key = typst.compiler.status({ key = attached.key })
assert(
    status_by_key == "idle",
    "compiler.status should resolve raw project keys outside Typst buffers"
)

local status_by_project_key = typst.compiler.status({
    project_key = attached.key,
})
assert(
    status_by_project_key == "idle",
    "compiler.status should resolve project_key aliases outside Typst buffers"
)

local status_by_encoded = typst.compiler.status({
    key = store.encode_key(attached.key),
    key_encoded = true,
})
assert(
    status_by_encoded == "idle",
    "compiler.status should resolve encoded project keys outside Typst buffers"
)

local original_compile_selected =
    require("typst.project.services.operations").compile_selected
local captured_selected = nil
require("typst.project.services.operations").compile_selected = function(
    state,
    opts
)
    captured_selected = { state = state, opts = opts }
    return { ok = true }
end
local selected_ok, selected_err = typst.compiler.compile_selected({
    project = attached,
    notify = false,
    bufnr = vim.api.nvim_get_current_buf(),
    line1 = 1,
    line2 = 1,
})
require("typst.project.services.operations").compile_selected =
    original_compile_selected
assert(selected_ok and selected_ok.ok == true, selected_err)
assert(
    captured_selected and captured_selected.state == attached,
    "compile_selected should respect explicit project options"
)
assert(
    captured_selected.opts.notify == false
        and captured_selected.opts.project == attached,
    "compile_selected should preserve caller options while normalizing bufnr"
)

local viewer_api = require("typst.viewer.api")
local original_view_inverse = viewer_api.view_inverse
local original_preview_inverse = viewer_api.preview_inverse
local inverse_state = nil
local preview_inverse_state = nil
viewer_api.view_inverse = function(state)
    inverse_state = state
    return { ok = true, path = chapter }
end
viewer_api.preview_inverse = function(state)
    preview_inverse_state = state
    return { ok = true, path = chapter }
end
local inverse = typst.viewer.view_inverse({ path = chapter, notify = false })
local preview_inverse =
    typst.viewer.preview_inverse({ path = chapter, notify = false })
viewer_api.view_inverse = original_view_inverse
viewer_api.preview_inverse = original_preview_inverse
assert(inverse and inverse.ok == true, "view_inverse should return result")
assert(
    inverse_state == attached,
    "view_inverse should resolve projects from source paths"
)
assert(
    preview_inverse and preview_inverse.ok == true,
    "preview_inverse should return result"
)
assert(
    preview_inverse_state == attached,
    "preview_inverse should resolve projects from source paths"
)

local count_before_unknown_path = vim.tbl_count(project.all())
local unknown_inverse, unknown_inverse_err = typst.viewer.view_inverse({
    path = fixture_root .. "/missing.typ",
    notify = false,
})
assert(
    unknown_inverse == nil
        and type(unknown_inverse_err) == "table"
        and unknown_inverse_err.reason == "source_path_not_in_project",
    "view_inverse should fail closed for unknown source paths"
)
assert(
    vim.tbl_count(project.all()) == count_before_unknown_path,
    "unknown source paths should not grow the project registry"
)

local readable_untracked = fixture_root .. "/untracked.typ"
vim.fn.writefile({ "= Untracked" }, readable_untracked)
vim.cmd.edit(vim.fn.fnameescape(main))
vim.bo.filetype = "typst"
typst.project.set_main(main)
local inverse_called_for_untracked_path = false
local preview_inverse_called_for_untracked_path = false
viewer_api.view_inverse = function()
    inverse_called_for_untracked_path = true
    return { ok = true }
end
viewer_api.preview_inverse = function()
    preview_inverse_called_for_untracked_path = true
    return { ok = true }
end
local focused_unknown_inverse, focused_unknown_err = typst.viewer.view_inverse({
    path = readable_untracked,
    notify = false,
})
local focused_preview_unknown_inverse, focused_preview_unknown_err =
    typst.viewer.preview_inverse({
        path = readable_untracked,
        notify = false,
    })
viewer_api.view_inverse = original_view_inverse
viewer_api.preview_inverse = original_preview_inverse
assert(
    focused_unknown_inverse == nil
        and type(focused_unknown_err) == "table"
        and focused_unknown_err.reason == "source_path_not_in_project",
    "readable untracked source paths should fail closed even from another Typst project"
)
assert(
    focused_preview_unknown_inverse == nil
        and type(focused_preview_unknown_err) == "table"
        and focused_preview_unknown_err.reason
            == "source_path_not_in_project",
    "preview inverse should fail closed for readable untracked source paths"
)
assert(
    inverse_called_for_untracked_path == false,
    "readable untracked source paths should not fall back to the focused Typst project"
)
assert(
    preview_inverse_called_for_untracked_path == false,
    "preview inverse should not fall back to the focused Typst project"
)

vim.cmd.enew()
vim.bo.filetype = ""
local rendered, render_err = typst.render.image({
    bufnr = vim.api.nvim_get_current_buf(),
    notify = false,
})
assert(rendered == nil, "render.image should require project context")
assert(
    type(render_err) == "table" and render_err.reason == "no_project",
    "render.image should return structured no_project errors"
)

local info_main = fixture_root .. "/info.typ"
vim.fn.writefile({ "= Info" }, info_main)
vim.cmd.edit(vim.fn.fnameescape(info_main))
vim.bo.filetype = "typst"
local info_state, info_lines = typst.ui.info({ echo = false })
assert(
    info_state
        and info_state.main
            == require("typst.core.util").normalize(info_main),
    "TypstInfo should attach from an unattached Typst buffer"
)
assert(
    type(info_lines) == "table" and #info_lines > 0,
    "TypstInfo should return report lines after attaching"
)

vim.cmd.enew()
vim.bo.filetype = ""
local no_info_state, no_info_lines = typst.ui.info({ echo = false })
assert(no_info_state == nil, "TypstInfo should not attach non-Typst buffers")
assert(
    type(no_info_lines) == "table"
        and table.concat(no_info_lines, "\n"):find("Buffer filetype", 1, true),
    "TypstInfo no-project diagnostics should include buffer context"
)

local registry = require("typst.project.registry")
registry.set("ambiguous%2Fkey", { key = "ambiguous%2Fkey" })
registry.set("ambiguous/key", { key = "ambiguous/key" })
local ambiguous = api_context.project({ key = "ambiguous%2Fkey" }, {
    operation = "compiler.status",
    passive = true,
})
assert(
    not ambiguous.ok and ambiguous.error.reason == "ambiguous_project_key",
    "api context should report ambiguous raw project keys"
)

typst.reset({ force = true })
