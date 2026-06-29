local M = {}

--- Install render workflow methods on the public API table.
---@param api table Public API table mutated in place.
---@param notify fun(message:string, level?:vim.log.levels|integer) Notification sink passed to render operations.
function M.install(api, notify)
    local function render_fragment(opts, callback)
        opts = opts or {}
        local state = api.project.get(opts.bufnr)
        return require("typst.project.services.operations").render_fragment(
            state,
            opts,
            callback,
            notify
        )
    end

    local function render_equation(opts, callback)
        opts = opts or {}
        local state = api.project.get(opts.bufnr)
        return require("typst.project.services.operations").render_equation(
            state,
            opts,
            callback,
            notify
        )
    end

    local function render_image(opts)
        opts = opts or {}
        local state = api.project.get(opts.bufnr)
        return require("typst.project.services.operations").render_image(
            state,
            opts,
            nil,
            notify
        )
    end

    local function render_page(opts, callback)
        opts = opts or {}
        local state = api.project.get(opts.bufnr)
        return require("typst.project.services.operations").render_page(
            state,
            opts,
            callback,
            notify
        )
    end

    local function render_cache_clear(opts)
        opts = opts or {}
        if opts.project == nil and opts.root == nil then
            opts = vim.tbl_extend("force", opts, {
                project = api.project.get(opts.bufnr),
            })
        end
        return require("typst.workflows.render").cache_clear(opts, notify)
    end

    local function render_cache_entries()
        return require("typst.workflows.render").cache_entries()
    end

    api.render = {
        fragment = render_fragment,
        equation = render_equation,
        image = render_image,
        page = render_page,
        cache_clear = render_cache_clear,
        cache_entries = render_cache_entries,
    }
end

return M
