local config = require("typst.config")

local M = {}

local function prefix_filter(names, arglead)
    if type(arglead) ~= "string" or arglead == "" then
        return names
    end

    return vim.tbl_filter(function(name)
        return name:find(arglead, 1, true) == 1
    end, names)
end

function M.profile()
    return config.profile_names()
end

function M.project_key(arglead)
    local store = require("typst.project.store")
    local names = {}
    for key in pairs(store.all()) do
        names[#names + 1] = store.encode_key(key)
    end
    table.sort(names)
    return prefix_filter(names, arglead)
end

function M.retained_project_key(arglead)
    local store = require("typst.project.store")
    local compiler_service = require("typst.project.services.compiler")
    local retained = {}
    local other = {}
    for key, project in pairs(store.all()) do
        local compiler = compiler_service.get(project) or {}
        local encoded = store.encode_key(key)
        if compiler.status == "stopping_failed" then
            retained[#retained + 1] = encoded
        else
            other[#other + 1] = encoded
        end
    end
    table.sort(retained)
    table.sort(other)
    local names = vim.list_extend(retained, other)
    return prefix_filter(names, arglead)
end

function M.fragment_template(arglead)
    local fragments = config.unsafe_get().compile.fragments or {}
    local names = vim.tbl_keys(fragments.templates or {})
    table.sort(names)
    return prefix_filter(names, arglead)
end

function M.package(arglead)
    return require("typst.package").complete(arglead)
end

function M.symbol(arglead)
    return require("typst.metadata.symbol").complete(arglead)
end

function M.picker(arglead)
    return prefix_filter(
        require("typst.navigation.picker").kind_names(),
        arglead
    )
end

function M.citation(arglead)
    local names = {}
    for _, item in
        ipairs(require("typst.bibliography").search({ query = arglead }))
    do
        names[#names + 1] = item.key
    end
    return names
end

local surround_kinds =
    { "function", "content", "equation", "figure", "block", "strong", "emph" }

function M.surround(arglead)
    return prefix_filter(surround_kinds, arglead)
end

function M.insert(arglead)
    return prefix_filter(require("typst.edit.insert").kinds(), arglead)
end

function M.equation_numbering()
    return { "toggle", "on", "off" }
end

function M.delimiter()
    return { "content", "block", "group", "equation" }
end

function M.trailing_comma()
    return { "toggle", "add", "remove" }
end

function M.list_mode()
    return { "toggle", "bullet", "numbered" }
end

function M.equation_mode()
    return { "toggle", "inline", "block" }
end

function M.raw_mode()
    return { "toggle", "inline", "block" }
end

function M.preview_mode()
    return { "document", "slide" }
end

local function export_profiles()
    local names = {}
    local exports = config.unsafe_get().exports or {}
    local profiles = exports.profiles or exports
    for name in pairs(profiles) do
        if
            type(name) == "string"
            and name ~= "provider"
            and name ~= "default"
        then
            names[#names + 1] = name
        end
    end
    table.sort(names)
    return names
end

function M.preview_args(arglead)
    local formats = { "pdf", "png", "svg", "html", "bundle" }
    local candidates = {
        "document",
        "slide",
        "mode=document",
        "mode=slide",
        "native=browser",
        "native=viewer",
        "native=auto",
        "export=compile",
        "export=profile",
        "export=provider",
        "restart",
    }
    for _, format in ipairs(formats) do
        candidates[#candidates + 1] = "format=" .. format
    end
    for _, profile in ipairs(export_profiles()) do
        candidates[#candidates + 1] = "profile=" .. profile
    end
    table.sort(candidates)
    return prefix_filter(candidates, arglead)
end

function M.preview_format(arglead)
    return prefix_filter({ "pdf", "png", "svg", "html", "bundle" }, arglead)
end

function M.export(arglead)
    local names = { "pdf", "png", "svg", "html", "bundle" }
    for _, name in ipairs(export_profiles()) do
        names[#names + 1] = name
    end
    table.sort(names)
    return prefix_filter(names, arglead)
end

function M.eval_target()
    return { "paged", "html", "bundle" }
end

function M.render_format(arglead)
    return prefix_filter({ "svg", "png" }, arglead)
end

return M
