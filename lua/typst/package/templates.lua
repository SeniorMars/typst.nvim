local template_files = require("typst.package.template_files")

local M = {}

local function spec_for(record)
    if record.spec then
        return record.spec
    end
    if record.version then
        return ("@%s/%s:%s"):format(
            record.namespace,
            record.name,
            record.version
        )
    end
    return ("@%s/%s"):format(record.namespace, record.name)
end

local function template_context(package)
    local record = template_files.cached_record(package)
    if not record then
        return nil
    end

    local entrypoint, source, reason = template_files.entrypoint(record)
    return {
        record = record,
        spec = spec_for(record),
        entrypoint = entrypoint,
        source = source,
        reason = reason,
    }
end

local function invalid_context(ctx)
    return {
        ok = false,
        reason = ctx.reason,
        spec = ctx.spec,
        source = ctx.source,
        entrypoint = ctx.entrypoint,
    }
end

local function context_info(ctx)
    return {
        ok = true,
        spec = ctx.spec,
        source = ctx.source,
        entrypoint = ctx.entrypoint,
        record = ctx.record,
    }
end

function M.add(actions, package, helpers)
    local ctx = template_context(package)
    if not ctx then
        return
    end

    helpers.add_action(actions, {
        id = "template_info",
        title = "Show template info",
        kind = "template",
        run = function()
            if ctx.reason then
                return invalid_context(ctx)
            end
            return context_info(ctx)
        end,
    })
    helpers.add_action(actions, {
        id = "template_source",
        title = "Open template source",
        kind = "source",
        run = function(opts)
            opts = opts or {}
            if ctx.reason then
                return invalid_context(ctx)
            end
            return helpers.open_file_at(ctx.entrypoint, 1, 0, opts)
        end,
    })
    helpers.add_action(actions, {
        id = "template_init",
        title = "Initialize template",
        kind = "template",
        run = function(opts)
            opts = opts or {}
            if ctx.reason then
                return invalid_context(ctx)
            end
            if not opts.destination and not opts.directory then
                return context_info(ctx)
            end

            local init_opts = vim.tbl_extend("force", opts, {
                template = ctx.spec,
                copy = true,
                offline = true,
            })
            return require("typst.workflows.templates").init(
                init_opts,
                nil,
                helpers.notify
            )
        end,
    })
end

return M
