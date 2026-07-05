local M = {}

--- Install artifact, eval, template, development, and semantic API methods.
---@param api table Public API table mutated in place.
---@param notify fun(message:string, level?:vim.log.levels|integer) Notification sink passed through to workflows.
---@param normalize_bufnr fun(bufnr?:integer):integer Shared buffer resolver for selection-sensitive workflows.
function M.install(api, notify, normalize_bufnr)
    local api_context = require("typst.api.context")

    local function project_or_error(opts, operation)
        local ctx = api_context.project(opts or {}, {
            create = true,
            require_typst = true,
            settle_pending = true,
            operation = operation,
        }, notify)
        if not ctx.ok then
            return nil, ctx.error
        end
        return ctx.project, nil
    end

    local function export(opts, callback)
        opts = opts or {}
        local state, err = project_or_error(opts, "artifact.export")
        if not state then
            return nil, err
        end
        return require("typst.project.services.operations").export(
            state,
            opts,
            callback,
            notify
        )
    end

    local function artifacts(opts)
        opts = opts or {}
        local state, err = project_or_error(opts, "artifact.list")
        if not state then
            return nil, err
        end
        return require("typst.workflows.artifacts").artifacts(state, opts)
    end

    local function artifact_open(opts)
        opts = opts or {}
        local state, err = project_or_error(opts, "artifact.open")
        if not state then
            return nil, err
        end
        return require("typst.workflows.artifacts").open(state, opts, notify)
    end

    local function artifact_clean(opts)
        opts = opts or {}
        local state, err = project_or_error(opts, "artifact.clean")
        if not state then
            return nil, err
        end
        return require("typst.workflows.artifacts").clean(state, opts, notify)
    end

    local function eval(opts, callback)
        opts = opts or {}
        local state, err = project_or_error(opts, "evaluation.eval")
        if not state then
            return nil, err
        end
        return require("typst.project.services.operations").eval(
            state,
            opts,
            callback,
            notify
        )
    end

    local function eval_selection(opts, callback)
        opts = opts or {}
        opts.bufnr = normalize_bufnr(opts.bufnr)
        local state, err = project_or_error(opts, "evaluation.selection")
        if not state then
            return nil, err
        end
        return require("typst.project.services.operations").eval_selection(
            state,
            opts,
            callback,
            notify
        )
    end

    local function inspect(opts, callback)
        opts = opts or {}
        local state, err = project_or_error(opts, "evaluation.inspect")
        if not state then
            return nil, err
        end
        return require("typst.project.services.operations").inspect(
            state,
            opts,
            callback,
            notify
        )
    end

    local function init(opts, callback)
        return require("typst.workflows.templates").init(
            opts or {},
            callback,
            notify
        )
    end

    local function templates(opts)
        return require("typst.workflows.templates").templates(opts or {})
    end

    ---@return any, any?
    local function profile(opts, callback)
        opts = opts or {}
        local state, err = project_or_error(opts, "development.profile")
        if not state then
            return nil, err
        end
        return require("typst.project.services.operations").profile(
            state,
            opts,
            callback,
            notify
        )
    end

    ---@return any, any?
    local function test(opts, callback)
        opts = opts or {}
        local state, err = project_or_error(opts, "development.test")
        if not state then
            return nil, err
        end
        return require("typst.project.services.operations").test(
            state,
            opts,
            callback,
            notify
        )
    end

    ---@return any, any?
    local function bench(opts, callback)
        opts = opts or {}
        local state, err = project_or_error(opts, "development.bench")
        if not state then
            return nil, err
        end
        return require("typst.project.services.operations").bench(
            state,
            opts,
            callback,
            notify
        )
    end

    ---@return any, any?
    local function coverage(opts, callback)
        opts = opts or {}
        local state, err = project_or_error(opts, "development.coverage")
        if not state then
            return nil, err
        end
        return require("typst.project.services.operations").coverage(
            state,
            opts,
            callback,
            notify
        )
    end

    local function inlay_hints_toggle(opts)
        opts = opts or {}
        return require("typst.integrations.semantic").inlay_hints_toggle(
            nil,
            opts,
            notify
        )
    end

    local function code_action(opts)
        opts = opts or {}
        local state, err = project_or_error(opts, "semantic.code_action")
        if not state then
            return nil, err
        end
        return require("typst.integrations.semantic").code_action(
            state,
            opts,
            notify
        )
    end

    local function color_info(opts)
        opts = opts or {}
        local state, err = project_or_error(opts, "semantic.color_info")
        if not state then
            return nil, err
        end
        return require("typst.integrations.semantic").color_info(state, opts)
    end

    local function color_presentation(opts)
        opts = opts or {}
        local state, err = project_or_error(opts, "semantic.color_presentation")
        if not state then
            return nil, err
        end
        return require("typst.integrations.semantic").color_presentation(
            state,
            opts,
            notify
        )
    end

    local function document_links(opts)
        opts = opts or {}
        local state, err = project_or_error(opts, "semantic.document_links")
        if not state then
            return nil, err
        end
        return require("typst.integrations.semantic").document_links(
            state,
            opts
        )
    end

    local function code_lens(opts)
        opts = opts or {}
        local state, err = project_or_error(opts, "semantic.code_lens")
        if not state then
            return nil, err
        end
        return require("typst.integrations.semantic").code_lens(
            state,
            opts,
            notify
        )
    end

    local function workspace_symbols(opts)
        opts = opts or {}
        local state, err = project_or_error(opts, "semantic.workspace_symbols")
        if not state then
            return nil, err
        end
        return require("typst.integrations.semantic").workspace_symbols(
            state,
            opts
        )
    end

    local function references(opts)
        opts = opts or {}
        local state, err = project_or_error(opts, "semantic.references")
        if not state then
            return nil, err
        end
        return require("typst.integrations.semantic").references(state, opts)
    end

    local function rename_preview(opts)
        opts = opts or {}
        local state, err = project_or_error(opts, "semantic.rename_preview")
        if not state then
            return nil, err
        end
        return require("typst.integrations.semantic").rename_preview(
            state,
            opts
        )
    end

    local function selection_expand(opts)
        opts = opts or {}
        local state, err = project_or_error(opts, "semantic.selection_expand")
        if not state then
            return nil, err
        end
        return require("typst.integrations.semantic").selection_expand(
            state,
            opts
        )
    end

    local function on_enter(opts)
        opts = opts or {}
        local state, err = project_or_error(opts, "semantic.on_enter")
        if not state then
            return nil, err
        end
        return require("typst.integrations.semantic").on_enter(
            state,
            opts,
            notify
        )
    end

    local function html_preview(opts, callback)
        opts = vim.tbl_extend(
            "force",
            { format = "html", open = true },
            opts or {}
        )
        return export(opts, callback)
    end

    local function presentation(opts, callback)
        opts = vim.tbl_extend(
            "force",
            { profile = "presentation", format = "pdf", open = true },
            opts or {}
        )
        return export(opts, callback)
    end

    api.artifact = {
        export = export,
        html_preview = html_preview,
        presentation = presentation,
        list = artifacts,
        open = artifact_open,
        clean = artifact_clean,
    }
    api.evaluation = {
        eval = eval,
        selection = eval_selection,
        inspect = inspect,
    }
    api.template = {
        init = init,
        list = templates,
    }
    api.development = {
        profile = profile,
        test = test,
        bench = bench,
        coverage = coverage,
    }
    api.semantic = {
        inlay_hints_toggle = inlay_hints_toggle,
        code_action = code_action,
        color_info = color_info,
        color_presentation = color_presentation,
        document_links = document_links,
        code_lens = code_lens,
        workspace_symbols = workspace_symbols,
        references = references,
        rename_preview = rename_preview,
        selection_expand = selection_expand,
        on_enter = on_enter,
    }
end

return M
