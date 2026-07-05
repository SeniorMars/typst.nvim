local M = {}

local default_notify = require("typst.core.notify").default

local normalize_bufnr = require("typst.core.buffer").normalize_bufnr

function M.create(opts)
    opts = opts or {}
    local notify = opts.notify or default_notify
    local api = {}

    require("typst.api.exports").install(api, notify)
    require("typst.api.reports").install(api, notify)
    require("typst.api.runtime").install(api, notify, normalize_bufnr)
    require("typst.api.workflows").install(api, notify, normalize_bufnr)
    require("typst.api.render").install(api, notify)
    require("typst.api.navigation").install(api, notify, normalize_bufnr)
    return api
end

return M
