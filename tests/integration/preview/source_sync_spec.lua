local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")
local util = require("typst.core.util")
typst.reset()

local forwarded_project = nil
local forwarded_position = nil

typst.setup({
    root = root,
    output_dir = typst_test_cache_path("preview-source-sync-output"),
    preview = {
        forward = function(project, position)
            forwarded_project = project
            forwarded_position = position
            return "preview-forwarded"
        end,
        capabilities = {
            inverse = true,
            source_maps = true,
        },
    },
})

local main = root .. "/tests/fixtures/basic/main.typ"
vim.cmd.edit(main)
local project = typst.project.set_main(main)

local done = false
typst.compiler.compile({}, function(result)
    assert(result.code == 0, "compile failed before preview source-sync test")
    done = true
end)

assert(
    vim.wait(10000, function()
        return done
    end, 20),
    "Typst compile did not finish before preview source-sync test"
)

local forward_event = nil
local inverse_event = nil
vim.api.nvim_create_autocmd("User", {
    pattern = "TypstPreviewForwarded",
    callback = function(args)
        forward_event = args.data
    end,
})
vim.api.nvim_create_autocmd("User", {
    pattern = "TypstPreviewInverse",
    callback = function(args)
        inverse_event = args.data
    end,
})

local capabilities = typst.viewer.preview_capabilities()
assert(
    capabilities.forward == true,
    "configured preview forward callback should advertise forward support"
)
assert(
    capabilities.inverse == true,
    "configured preview source maps should advertise inverse support"
)
assert(
    capabilities.source_maps == true,
    "configured preview source maps should be exposed"
)

local forward = typst.viewer.view_forward({ line = 3, column = 5 })
assert(
    forward == "preview-forwarded",
    "view_forward should fall back to preview forward callback"
)
assert(
    forwarded_project == project,
    "preview forward callback should receive project"
)
assert(
    forwarded_position.line == 3,
    "preview forward callback should receive line"
)
assert(
    forwarded_position.column == 5,
    "preview forward callback should receive column"
)
assert(forward_event, "TypstPreviewForwarded should be emitted")
assert(forward_event.line == 3, "preview forward event should include line")
assert(forward_event.column == 5, "preview forward event should include column")
assert(
    forward_event.preview_backend == "callback-forward",
    "preview forward event should expose recorded backend"
)

vim.cmd.edit(root .. "/tests/fixtures/basic/chapter.typ")
local inverse = typst.viewer.preview_inverse({
    path = main,
    line = 3,
    column = 2,
    notify = false,
})
assert(
    inverse and inverse.path == main,
    "preview inverse should return the source location"
)
assert(
    vim.api.nvim_buf_get_name(0) == main,
    "preview inverse should edit the requested source file"
)
local cursor = vim.api.nvim_win_get_cursor(0)
assert(cursor[1] == 3, "preview inverse should jump to requested line")
assert(cursor[2] == 1, "preview inverse should use 1-based input columns")
assert(inverse_event, "TypstPreviewInverse should be emitted")
assert(
    inverse_event.path == main,
    "preview inverse event should include source path"
)
assert(inverse_event.line == 3, "preview inverse event should include line")
assert(inverse_event.column == 2, "preview inverse event should include column")

local main_bufnr = vim.fn.bufnr(main)
vim.cmd.edit(root .. "/tests/fixtures/basic/chapter.typ")
local original_edit_existing_or_path = util.edit_existing_or_path
local helper_path = nil
util.edit_existing_or_path = function(path)
    helper_path = path
    vim.api.nvim_set_current_buf(main_bufnr)
    return main_bufnr
end
local reused_inverse = typst.viewer.preview_inverse({
    path = main,
    line = 2,
    column = 1,
    notify = false,
})
util.edit_existing_or_path = original_edit_existing_or_path
assert(
    reused_inverse and reused_inverse.path == main,
    "preview inverse should return reused source location"
)
assert(
    helper_path == main,
    "preview inverse should route source jumps through the path-identity buffer helper"
)
assert(
    vim.api.nvim_get_current_buf() == main_bufnr,
    "preview inverse should reuse an equivalent loaded source buffer"
)

vim.cmd.edit(root .. "/tests/fixtures/basic/chapter.typ")
vim.cmd(("TypstPreviewInverse %s 1 1"):format(vim.fn.fnameescape(main)))
assert(
    vim.api.nvim_buf_get_name(0) == main,
    "TypstPreviewInverse command should edit the requested source file"
)

local unicode_path = typst_test_cache_path("preview-source-sync-unicode.typ")
vim.fn.writefile({ "= Unicode", "αβ preview" }, unicode_path)
local unicode_inverse = typst.viewer.preview_inverse({
    path = unicode_path,
    line = 2,
    column = 2,
    notify = false,
})
assert(
    unicode_inverse and unicode_inverse.path == unicode_path,
    "preview inverse should accept Unicode source paths"
)
cursor = vim.api.nvim_win_get_cursor(0)
assert(cursor[1] == 2, "preview inverse should jump to the Unicode source line")
assert(
    cursor[2] == 0,
    "preview inverse should clamp middle-byte columns to a UTF-8 boundary"
)

typst.reset({ force = true })

local source_map_forward_position = nil
local source_map_inverse_location = nil
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("preview-source-map-output"),
    preview = {
        source_maps = {
            provider = "native-source-map",
            forward = function(_project, position)
                source_map_forward_position = position
                return "source-map-forwarded"
            end,
            inverse = function(_project, source_location)
                source_map_inverse_location = source_location
                return source_location
            end,
            capabilities = {
                source_maps = true,
            },
        },
    },
})

vim.cmd.edit(main)
project = typst.project.set_main(main)
done = false
typst.compiler.compile({}, function(result)
    assert(result.code == 0, "compile failed before preview source-map test")
    done = true
end)
assert(
    vim.wait(10000, function()
        return done
    end, 20),
    "Typst compile did not finish before preview source-map test"
)
forward_event = nil
inverse_event = nil

capabilities = typst.viewer.preview_capabilities()
assert(
    capabilities.forward == true,
    "source-map forward callback should advertise forward support"
)
assert(
    capabilities.inverse == true,
    "source-map inverse callback should advertise inverse support"
)
assert(
    capabilities.source_maps == true,
    "source-map capability should be exposed"
)
assert(
    capabilities.source_sync_provider == "native-source-map",
    "source-map provider label should be exposed"
)
assert(
    capabilities.configured_source_map_forward == true,
    "source-map forward callback should be reported separately"
)

local source_map_forward = typst.viewer.view_forward({ line = 4, column = 6 })
assert(
    source_map_forward == "source-map-forwarded",
    "view_forward should use preview.source_maps.forward"
)
assert(
    source_map_forward_position.line == 4,
    "source-map forward callback should receive line"
)
assert(
    source_map_forward_position.column == 6,
    "source-map forward callback should receive column"
)
assert(
    typst_test_preview(project).last_backend == "native-source-map-forward",
    "source-map forward should record provider backend"
)
assert(
    forward_event and forward_event.backend == "native-source-map",
    "source-map forward event should expose provider backend"
)

local source_map_inverse = typst.viewer.preview_inverse({
    path = main,
    line = 5,
    column = 3,
    notify = false,
})
assert(
    source_map_inverse == source_map_inverse_location,
    "preview inverse should use preview.source_maps.inverse"
)
assert(
    source_map_inverse_location.path == main,
    "source-map inverse callback should receive source path"
)
assert(
    typst_test_preview(project).last_backend == "native-source-map-inverse",
    "source-map inverse should record provider backend"
)
assert(
    inverse_event and inverse_event.backend == "native-source-map",
    "source-map inverse event should expose provider backend"
)

typst.reset({ force = true })

local provider_forward_request = nil
local provider_inverse_request = nil
local provider_adapter = require("typst.integrations.provider_adapter")
local original_provider_invoke = provider_adapter.invoke
local source_map_context_checks = 0
provider_adapter.invoke = function(provider, methods, context, request, control)
    if control and control.kind == "source_map" then
        source_map_context_checks = source_map_context_checks + 1
        assert(
            control.args and context == control.args[1],
            "source-map adapter context should match provider argument"
        )
    end
    return original_provider_invoke(
        provider,
        methods,
        context,
        request,
        control
    )
end

typst.providers.register("source_map", "registered-source-map", {
    name = "registered-source-map",
    capabilities = function()
        return { source_maps = true }
    end,
    generate = function()
        return { ok = true }
    end,
    forward = function(_project, request)
        provider_forward_request = request
        return "provider-forwarded"
    end,
    inverse = function(_project, request)
        provider_inverse_request = request
        return request.location
    end,
    browser_inverse = function(_project, request)
        return request.location
    end,
})

typst.setup({
    root = root,
    output_dir = typst_test_cache_path("preview-source-map-provider-output"),
    preview = {
        source_maps = {
            provider = "registered-source-map",
        },
    },
})

vim.cmd.edit(main)
project = typst.project.set_main(main)
done = false
typst.compiler.compile({}, function(result)
    assert(result.code == 0, "compile failed before source-map provider test")
    done = true
end)
assert(
    vim.wait(10000, function()
        return done
    end, 20),
    "Typst compile did not finish before source-map provider test"
)

capabilities = typst.viewer.preview_capabilities()
assert(
    capabilities.source_sync_provider == "registered-source-map",
    "registered source-map provider should be reported"
)
assert(
    capabilities.forward == true and capabilities.inverse == true,
    "registered source-map provider should infer direct sync from methods"
)
assert(
    capabilities.source_maps == true,
    "registered source-map provider should advertise map generation"
)
assert(
    capabilities.browser_click == true,
    "partial source-map capability declarations should not hide browser-click support"
)

local provider_forward = typst.viewer.view_forward({ line = 6, column = 7 })
assert(
    provider_forward == "provider-forwarded",
    "view_forward should use registered source-map provider"
)
assert(
    provider_forward_request.line == 6 and provider_forward_request.column == 7,
    "registered source-map provider should receive forward request"
)

local provider_inverse = typst.viewer.preview_inverse({
    path = main,
    line = 7,
    column = 8,
    notify = false,
})
assert(
    provider_inverse == provider_inverse_request.location,
    "preview inverse should use registered source-map provider"
)
assert(
    provider_inverse.path == main
        and provider_inverse.line == 7
        and provider_inverse.column == 8,
    "registered source-map provider should receive inverse request"
)
assert(
    source_map_context_checks >= 2,
    "source-map provider invocations should use a stable context"
)
provider_adapter.invoke = original_provider_invoke

vim.cmd("qa!")
