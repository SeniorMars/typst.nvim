local M = {}

-- Runtime API adapters that need initialized project state.
--
-- These wrappers normalize buffer/project lookup before delegating to services,
-- keeping public calls buffer-local even when compiler/viewer internals are
-- project-scoped.
--- Install runtime adapter entrypoints that depend on project state.
---@param api table Public API table that receives runtime-backed methods.
---@param notify? fun(message:string, level?:vim.log.levels|integer) Notification callback passed through to service operations.
---@param normalize_bufnr fun(bufnr?:integer):integer Buffer normalizer used before project lookup.
function M.install(api, notify, normalize_bufnr)
    local function compile(opts, callback)
        opts = opts or {}
        local state = api.project.get(opts.bufnr)
        return require("typst.project.services.operations").compile(
            state,
            opts,
            callback,
            notify
        )
    end

    local function compile_selected(opts, callback)
        opts = opts or {}
        local bufnr = normalize_bufnr(opts.bufnr)
        local state = api.project.get(bufnr)
        return require("typst.project.services.operations").compile_selected(
            state,
            vim.tbl_extend("force", opts, { bufnr = bufnr }),
            callback,
            notify
        )
    end

    local function compile_output(opts)
        opts = opts or {}
        local state = api.project.get(opts.bufnr)
        return require("typst.compiler.api").compile_output(state, opts)
    end

    local function watch(opts, callback)
        opts = opts or {}
        local state = api.project.get(opts.bufnr)
        return require("typst.project.services.operations").watch(
            state,
            opts,
            callback,
            notify
        )
    end

    local function stop(opts, callback)
        opts = opts or {}
        local state = api.project.get(opts.bufnr)
        return require("typst.project.services.operations").stop(
            state,
            callback,
            notify
        )
    end

    local function stop_all(opts, callback)
        return require("typst.project.services.operations").stop_all(
            opts,
            callback,
            notify
        )
    end

    local function view(opts)
        opts = opts or {}
        local state = api.project.get(opts.bufnr)
        return require("typst.viewer.api").view(state, opts, notify)
    end

    local function view_forward(opts)
        opts = opts or {}
        local state = api.project.get(opts.bufnr)
        return require("typst.viewer.api").view_forward(state, opts, notify)
    end

    local function view_inverse(opts)
        opts = opts or {}
        local state = api.project.get(opts.bufnr)
        return require("typst.viewer.api").view_inverse(state, opts, notify)
    end

    local function viewer_capabilities(opts)
        opts = opts or {}
        api.project.get(opts.bufnr)
        return require("typst.viewer.api").viewer_capabilities()
    end

    local function preview_capabilities(opts)
        opts = opts or {}
        local state = api.project.get(opts.bufnr)
        return require("typst.viewer.api").preview_capabilities(state)
    end

    local function clean(opts)
        opts = opts or {}
        local state = api.project.get(opts.bufnr)
        return require("typst.viewer.api").clean(state, opts, notify)
    end

    local function clean_preview(opts)
        opts = opts or {}
        local state = api.project.get(opts.bufnr)
        return require("typst.viewer.api").clean_preview(state, opts, notify)
    end

    local function preview(opts)
        opts = opts or {}
        local state = api.project.get(opts.bufnr)
        return require("typst.viewer.api").preview(state, opts, notify)
    end

    local function preview_open_browser(opts)
        opts = opts or {}
        local state = api.project.get(opts.bufnr)
        return require("typst.viewer.api").preview_open_browser(
            state,
            opts,
            notify
        )
    end

    local function preview_reload(opts)
        opts = opts or {}
        local state = api.project.get(opts.bufnr)
        return require("typst.viewer.api").preview_reload(state, opts, notify)
    end

    local function preview_status(opts)
        opts = opts or {}
        local state = api.project.get(opts.bufnr)
        return require("typst.viewer.api").preview_status(state, opts, notify)
    end

    local function preview_stop(opts)
        opts = opts or {}
        local state = api.project.get(opts.bufnr)
        return require("typst.viewer.api").preview_stop(state, opts, notify)
    end

    local function preview_toggle(opts)
        opts = opts or {}
        local state = api.project.get(opts.bufnr)
        return require("typst.viewer.api").preview_toggle(state, opts, notify)
    end

    local function preview_inverse(opts)
        opts = opts or {}
        local state = api.project.get(opts.bufnr)
        return require("typst.viewer.api").preview_inverse(state, opts, notify)
    end

    api.project.services = function(opts)
        opts = opts or {}
        local state = api.project.get(opts.bufnr)
        return require("typst.project.services").snapshot(state)
    end

    api.project.operations = function(opts)
        local snapshot = api.project.services(opts)
        return snapshot and snapshot.operations or nil
    end

    api.compiler = {
        compile = compile,
        compile_selected = compile_selected,
        output = compile_output,
        watch = watch,
        stop = stop,
        stop_all = stop_all,
        status = function(opts)
            opts = opts or {}
            local state = api.project.get(opts.bufnr)
            return require("typst.compiler").status(state)
        end,
        current_output = function(opts)
            opts = opts or {}
            local state = api.project.get(opts.bufnr)
            return require("typst.compiler").output(state)
        end,
    }

    api.viewer = {
        view = view,
        view_forward = view_forward,
        view_inverse = view_inverse,
        capabilities = viewer_capabilities,
        preview_capabilities = preview_capabilities,
        clean = clean,
        clean_preview = clean_preview,
        preview = preview,
        preview_open_browser = preview_open_browser,
        preview_reload = preview_reload,
        preview_status = preview_status,
        preview_stop = preview_stop,
        preview_toggle = preview_toggle,
        preview_inverse = preview_inverse,
    }
end

return M
