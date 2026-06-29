local source_comments = require("typst.package.source_comments")
local util = require("typst.core.util")

local M = {}

local uv = vim.uv or vim.loop

local function trim(value)
    if type(value) ~= "string" then
        return nil
    end

    value = vim.trim(value)
    if value == "" then
        return nil
    end

    return value
end

function M.scan_files(root, max_depth)
    root = util.canonical(root)
    local files = {}

    local function walk(dir, rel, depth)
        if depth > max_depth then
            return
        end

        dir = util.canonical(dir)
        if not util.path_within(dir, root) then
            return
        end

        local scan = uv.fs_scandir(dir)
        if not scan then
            return
        end

        while true do
            local name, kind = uv.fs_scandir_next(scan)
            if not name then
                break
            end

            local path = util.join(dir, name)
            local relative = rel == "" and name or util.join(rel, name)
            if kind == "file" then
                path = util.canonical(path)
                if util.path_within(path, root) then
                    files[#files + 1] = {
                        path = path,
                        relative = util.relpath(path, root),
                        name = name,
                    }
                end
            elseif kind == "directory" then
                walk(path, relative, depth + 1)
            end
        end
    end

    walk(root, "", 0)
    table.sort(files, function(left, right)
        return left.relative < right.relative
    end)
    return files
end

function M.package_resource_file(root, value, opts)
    opts = opts or {}
    if type(value) ~= "string" or value == "" then
        return nil, "invalid_path"
    end
    if value:match("^https?://") then
        return nil, "url"
    end

    local package_root = util.canonical(root)
    local path = util.canonical(util.resolve_path(value, package_root))
    if not util.path_within(path, package_root) then
        return nil, opts.outside_reason or "resource_outside_package"
    end
    if opts.readable and vim.fn.filereadable(path) ~= 1 then
        return nil, opts.missing_reason or "missing_resource"
    end

    return {
        path = path,
        relative = util.relpath(path, package_root),
        name = util.basename(path),
        advertised = opts.advertised == true,
    }
end

function M.detect_readme(files)
    for _, file in ipairs(files) do
        if file.name:lower():match("^readme") then
            return file
        end
    end
end

function M.detect_manuals(files)
    local manuals = {}
    for _, file in ipairs(files) do
        local rel = file.relative:lower()
        local ext = rel:match("%.([%w]+)$")
        if ext and ({ md = true, typ = true, pdf = true })[ext] then
            if
                rel:find("manual", 1, true)
                or rel:find("docs" .. util.path_sep(), 1, true)
            then
                manuals[#manuals + 1] = file
            end
        end
    end
    return manuals
end

function M.local_doc_file(root, value)
    return M.package_resource_file(root, value, {
        advertised = true,
        readable = true,
        outside_reason = "doc_path_outside_package",
        missing_reason = "missing_doc_path",
    })
end

function M.sanitize_resource_hints(root, hints)
    local sanitized = {}
    local errors = {}
    for key, value in pairs(hints or {}) do
        if type(value) == "string" then
            if value:match("^https?://") then
                sanitized[key] = value
            else
                local file, reason = M.package_resource_file(root, value, {
                    outside_reason = ("typst_docs_%s_outside_package"):format(
                        key
                    ),
                    missing_reason = ("typst_docs_%s_missing"):format(key),
                })
                if file then
                    sanitized[key] = file.relative
                elseif reason ~= "invalid_path" and reason ~= "url" then
                    errors[key] = reason
                end
            end
        elseif type(value) ~= "table" then
            sanitized[key] = value
        end
    end
    return sanitized, errors
end

function M.add_advertised_manual(manuals, root, value, links)
    if type(value) ~= "string" or value == "" then
        return manuals
    end

    if value:match("^https?://") then
        links.manual = value
        return manuals
    end

    local manual = M.local_doc_file(root, value)
    if not manual then
        return manuals
    end

    local result = { manual }
    local seen = {
        [manual.path] = true,
    }
    for _, candidate in ipairs(manuals) do
        if not seen[candidate.path] then
            result[#result + 1] = candidate
            seen[candidate.path] = true
        end
    end
    return result
end

function M.read_text_file(file)
    if not file or vim.fn.filereadable(file.path) ~= 1 then
        return nil
    end

    return table.concat(vim.fn.readfile(file.path), "\n")
end

function M.summary_from_readme(readme)
    if not readme then
        return nil
    end

    for paragraph in (readme .. "\n\n"):gmatch("(.-)\n%s*\n") do
        paragraph = vim.trim(paragraph:gsub("\n", " "))
        if
            paragraph ~= ""
            and not paragraph:match("^#")
            and not paragraph:match("^%!%[")
        then
            return paragraph
        end
    end
end

M.package_typ_files = source_comments.package_typ_files
M.scan_member_file = source_comments.scan_member_file

return M
