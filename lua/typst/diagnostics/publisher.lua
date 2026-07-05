local events = require("typst.core.events")
local log = require("typst.core.log")
local diagnostics_service = require("typst.project.services.diagnostics")
local quickfix = require("typst.diagnostics.quickfix")

local M = {}

local function diagnostic_total(by_buffer)
    local total = 0
    for _, diagnostics in pairs(by_buffer or {}) do
        total = total + #diagnostics
    end
    return total
end

local function valid_buffer(bufnr)
    return type(bufnr) == "number"
        and bufnr > 0
        and vim.api.nvim_buf_is_valid(bufnr)
end

local function scoped_quickfix_items(items, source)
    local out = {}
    for _, item in ipairs(items or {}) do
        local copy = vim.deepcopy(item)
        copy.user_data = copy.user_data or {}
        copy.user_data.typst =
            vim.tbl_extend("force", copy.user_data.typst or {}, {
                source = source,
                external_path = true,
            })
        out[#out + 1] = copy
    end
    return out
end

local function publish_buffers(ctx, project, key, by_buffer)
    local namespace = ctx.namespace_for(project, key)
    local buffers = ctx.source_buffers(project, key)
    local published = {}

    for bufnr, buffer_diagnostics in pairs(by_buffer or {}) do
        if valid_buffer(bufnr) then
            local diagnostics_for_buffer =
                vim.deepcopy(buffer_diagnostics or {})
            vim.diagnostic.set(namespace, bufnr, diagnostics_for_buffer)
            if #diagnostics_for_buffer > 0 then
                buffers[bufnr] = true
                published[bufnr] = diagnostics_for_buffer
            end
        else
            log.add("debug", "skipping diagnostics for invalid buffer", {
                bufnr = bufnr,
                source = key,
                main = project and project.main,
            })
        end
    end

    ctx.rebuild_diagnostic_buffers(project)
    return published
end

function M.publish(ctx, project, text, opts)
    opts = opts or {}
    local key = ctx.source_key(opts.source)

    local parse_ok, by_buffer, parse_meta = xpcall(function()
        return ctx.parse(project, text, opts)
    end, debug.traceback)
    if not parse_ok or type(by_buffer) ~= "table" then
        local err = {
            ok = false,
            reason = "diagnostics_parse_failed",
            message = "Typst diagnostic output could not be parsed",
            error = tostring(by_buffer),
            source = key,
        }
        log.add(
            "warn",
            "diagnostic parse failed; keeping previous diagnostics",
            {
                source = key,
                main = project and project.main,
                error = err.error,
            }
        )
        return nil, err
    end

    ctx.clear(project, { emit = false, source = key })
    local published = publish_buffers(ctx, project, key, by_buffer)

    local path_quickfix_items =
        scoped_quickfix_items(parse_meta and parse_meta.quickfix_items, key)
    local quickfix_items = quickfix.maybe_set(project, published, {
        extra_items = path_quickfix_items,
        source = key,
    })
    local diagnostic_state = diagnostics_service.get(project) or {}
    diagnostic_state.quickfix_by_source = diagnostic_state.quickfix_by_source
        or {}
    diagnostic_state.quickfix_by_source[key] = path_quickfix_items
    diagnostics_service.set(project, {
        last_publish = {
            source = key,
            added_buffers = parse_meta and parse_meta.added_buffers or 0,
            skipped_buffers = parse_meta and parse_meta.skipped_buffers or 0,
            skipped_by_cap = parse_meta and parse_meta.skipped_by_cap or 0,
            skipped_external_paths = parse_meta
                    and parse_meta.skipped_external_paths
                or 0,
            first_skipped_path = parse_meta and parse_meta.first_skipped_path
                or nil,
            external_paths = parse_meta and parse_meta.external_paths or nil,
            quickfix_only_diagnostics = parse_meta
                    and parse_meta.quickfix_only_diagnostics
                or 0,
            quickfix_items = #quickfix_items,
        },
    })
    events.emit("TypstDiagnosticsPublished", project, {
        diagnostics_count = diagnostic_total(published),
        diagnostic_buffers = vim.tbl_count(published),
        skipped_buffers = parse_meta and parse_meta.skipped_buffers or 0,
        quickfix_only_diagnostics = parse_meta
                and parse_meta.quickfix_only_diagnostics
            or 0,
    })
    return published
end

function M.publish_by_buffer(ctx, project, by_buffer, opts)
    opts = opts or {}
    local key = ctx.source_key(opts.source)
    ctx.clear(project, { emit = false, source = key })
    local published = publish_buffers(ctx, project, key, by_buffer)

    local items = quickfix.maybe_set(project, published, { source = key })
    local diagnostic_state = diagnostics_service.get(project) or {}
    diagnostic_state.quickfix_by_source = diagnostic_state.quickfix_by_source
        or {}
    diagnostic_state.quickfix_by_source[key] = {}
    diagnostics_service.set(project, {
        last_publish = {
            source = key,
            added_buffers = 0,
            skipped_buffers = 0,
            skipped_by_cap = 0,
            skipped_external_paths = 0,
            quickfix_only_diagnostics = 0,
            quickfix_items = #items,
        },
    })
    events.emit("TypstDiagnosticsPublished", project, {
        diagnostics_count = diagnostic_total(published),
        diagnostic_buffers = vim.tbl_count(published),
    })
    return published, items
end

return M
