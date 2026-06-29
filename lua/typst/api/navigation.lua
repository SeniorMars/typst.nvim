local util = require("typst.core.util")

local M = {}

local function client_supports_hover(client, bufnr)
    if type(client.supports_method) ~= "function" then
        return true
    end

    local ok, supported =
        pcall(client.supports_method, client, "textDocument/hover", bufnr)
    return ok and supported ~= false
end

--- Install navigation, diagnostics, and hover methods on the public API table.
---@param api table Public API table mutated in place.
---@param notify fun(message:string, level?:vim.log.levels|integer) Notification sink for user-facing actions.
---@param normalize_bufnr fun(bufnr?:integer):integer Shared buffer resolver used before LSP calls.
function M.install(api, notify, normalize_bufnr)
    local function files(opts)
        opts = opts or {}
        local state = api.project.get(opts.bufnr)
        return require("typst.navigation.lists").files(
            state,
            opts,
            notify,
            require("typst.core.log")
        )
    end

    local function toc_open_impl(opts)
        opts = opts or {}
        local state = api.project.get(opts.bufnr)
        local events = require("typst.core.events")
        local toc = require("typst.navigation.toc")
        local items = toc.open(state, opts)
        events.emit("TypstTocCreated", state, {
            items = #items,
        })
        if opts.open ~= false then
            events.emit("TypstTocActivated", state, {
                items = #items,
            })
        end
        notify(("TOC: %d item%s"):format(#items, #items == 1 and "" or "s"))
        return items
    end

    local function toc_open(opts)
        return toc_open_impl(opts)
    end

    local function toc_refresh(opts)
        return toc_open_impl(opts)
    end

    local function toc_toggle(opts)
        opts = opts or {}
        local toc = require("typst.navigation.toc")
        local mode = opts.quickfix and "quickfix"
            or opts.mode
            or require("typst.config").get().toc.mode
        if mode == "quickfix" and toc.close_quickfix() then
            notify("TOC closed")
            return {}
        elseif toc.close_current() then
            notify("TOC closed")
            return {}
        end

        local state = api.project.get(opts.bufnr)
        if toc.is_open(state) then
            toc.close(state)
            notify("TOC closed")
            return {}
        end

        return toc_open_impl(opts)
    end

    local function labels(opts)
        opts = opts or {}
        local state = api.project.get(opts.bufnr)
        return require("typst.navigation.lists").labels(state, opts, notify)
    end

    local function citations(opts)
        opts = opts or {}
        local state = api.project.get(opts.bufnr)
        return require("typst.navigation.lists").citations(state, opts, notify)
    end

    local function bibliography_diagnostics(opts)
        opts = opts or {}
        opts.project = opts.project or api.project.get(opts.bufnr)
        local result = require("typst.bibliography").diagnostics(opts)
        notify(
            ("Bibliography diagnostics: %d item%s"):format(
                result.diagnostics,
                result.diagnostics == 1 and "" or "s"
            )
        )
        return result
    end

    local function symbols(opts)
        opts = opts or {}
        local state = api.project.get(opts.bufnr)
        return require("typst.navigation.lists").symbols(state, opts, notify)
    end

    local function follow(opts)
        opts = opts or {}
        local function report(target)
            if not target then
                notify("No Typst target under cursor", vim.log.levels.WARN)
                return
            end

            local label = target.path
                    and util.relpath(
                        target.path,
                        api.project.get(opts.bufnr).root
                    )
                or target.url
                or target.spec
                or target.name
                or target.kind
            notify(("Followed %s"):format(label))
        end
        return require("typst.navigation.follow").follow(
            vim.tbl_extend("force", opts, {
                callback = function(target)
                    report(target)
                end,
            })
        )
    end

    local function hover(opts)
        opts = opts or {}
        local bufnr = normalize_bufnr(opts.bufnr)
        local get_clients = vim.lsp and vim.lsp.get_clients
        local hover = vim.lsp and vim.lsp.buf and vim.lsp.buf.hover
        if type(get_clients) ~= "function" or type(hover) ~= "function" then
            return false
        end
        if not vim.api.nvim_buf_is_valid(bufnr) then
            return false
        end

        for _, client in ipairs(get_clients({ bufnr = bufnr })) do
            if client_supports_hover(client, bufnr) then
                vim.api.nvim_buf_call(bufnr, hover)
                return true
            end
        end

        return false
    end

    local function diagnostics(opts)
        opts = opts or {}
        local state = api.project.get(opts.bufnr)
        local items = require("typst.diagnostics").quickfix(state, opts)
        notify(
            ("Diagnostics: %d item%s"):format(#items, #items == 1 and "" or "s")
        )
        return items
    end

    local function errors(opts)
        return diagnostics(opts)
    end

    api.navigation = vim.tbl_extend("force", api.navigation or {}, {
        files = files,
        toc = toc_open_impl,
        toc_open = toc_open,
        toc_refresh = toc_refresh,
        toc_toggle = toc_toggle,
        labels = labels,
        citations = citations,
        symbols = symbols,
        follow = follow,
        hover = hover,
    })

    api.diagnostics = {
        quickfix = diagnostics,
        errors = errors,
        bibliography = bibliography_diagnostics,
    }
end

return M
