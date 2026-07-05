local M = {}

local uv = vim.uv or vim.loop

-- Path identity helpers sit between Neovim buffers and external Typst tools.
-- They canonicalize through symlinks when possible, but also recognize
-- Windows-looking paths reported by tools so diagnostics and indexes can match
-- buffers even when Neovim itself is running on another platform.
function M.is_windows()
    return vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1
end

function M.path_sep()
    return M.is_windows() and "\\" or "/"
end

local function looks_like_windows_path(path)
    return type(path) == "string"
        and (path:match("^%a:") ~= nil or path:match("^[/\\][/\\]") ~= nil)
end

local function looks_like_windows_absolute(path)
    return type(path) == "string"
        and (path:match("^%a:[/\\]") ~= nil or path:match("^[/\\][/\\]") ~= nil)
end

local function normalize_foreign_windows_path(path)
    local normalized = path:gsub("\\", "/")
    if normalized:match("^//") then
        normalized = "//" .. normalized:gsub("^/+", ""):gsub("/+", "/")
    else
        normalized = normalized:gsub("/+", "/")
    end
    if normalized:match("^%a:") then
        normalized = normalized:sub(1, 1):upper() .. normalized:sub(2)
    end
    return normalized
end

--- Join trusted path components without letting absolute tails reset the base.
---
--- This is a lightweight string join for call sites that already validated
--- their components. Tail components have leading/trailing separators trimmed,
--- but are not validated for parent traversal. Use `join_checked()` or
--- `resolve_path()` when any tail component comes from user input, Typst
--- output, or a provider.
---
--- Invariant: local roots stay roots. `join("/", "tmp")` must be `/tmp`, not
--- `//tmp`, because double-slash paths are intentionally preserved for UNC-like
--- foreign paths elsewhere in this module.
function M.join(...)
    local parts = vim.iter({ ... })
        :flatten()
        :filter(function(part)
            return part ~= nil and part ~= ""
        end)
        :totable()

    if #parts == 0 then
        return ""
    end

    local sep = M.path_sep()
    local first = tostring(parts[1])
    local prefix = nil
    local joined = {}

    if first:match("^[/\\]+$") then
        prefix = sep
        first = ""
    elseif first:match("^%a:[/\\]*$") then
        prefix = first:sub(1, 2) .. sep
        first = ""
    else
        first = first:gsub("[/\\]+$", "")
    end

    if first ~= "" then
        joined[#joined + 1] = first
    end
    for index = 2, #parts do
        local part = tostring(parts[index])
        part = part:gsub("^[/\\]+", ""):gsub("[/\\]+$", "")
        if part ~= "" then
            joined[#joined + 1] = part
        end
    end

    local suffix = table.concat(joined, sep)
    if prefix then
        return suffix ~= "" and (prefix .. suffix) or prefix
    end
    return suffix
end

local function has_parent_segment(path)
    if type(path) ~= "string" then
        return false
    end
    for segment in path:gmatch("[^/\\]+") do
        if segment == ".." then
            return true
        end
    end
    return false
end

--- Safely join a base path with relative child components.
---@param base string Base directory that must contain the final path.
---@param ... string Relative path components.
---@return string|nil path Normalized joined path on success.
---@return table|nil error Failure payload with `reason` and `message`.
function M.join_checked(base, ...)
    if type(base) ~= "string" or base == "" then
        return nil,
            {
                reason = "invalid_base",
                message = "Base path is invalid",
            }
    end

    local parts = vim.iter({ ... })
        :flatten()
        :filter(function(part)
            return part ~= nil and part ~= ""
        end)
        :totable()

    for _, part in ipairs(parts) do
        if type(part) ~= "string" then
            return nil,
                {
                    reason = "invalid_component",
                    message = "Path component must be a string",
                    component = part,
                }
        end
        if M.is_absolute(part) or looks_like_windows_path(part) then
            return nil,
                {
                    reason = "absolute_component",
                    message = "Path component must be relative",
                    component = part,
                }
        end
        if has_parent_segment(part) then
            return nil,
                {
                    reason = "parent_component",
                    message = "Path component must not contain '..'",
                    component = part,
                }
        end
    end

    local joined = M.normalize(M.join(base, parts))
    if not M.path_within(M.canonical(joined), M.canonical(base)) then
        return nil,
            {
                reason = "outside_base",
                message = "Joined path escaped the base directory",
                path = joined,
                base = base,
            }
    end
    return joined
end

function M.normalize(path)
    if not path or path == "" then
        return path
    end

    if not M.is_windows() and looks_like_windows_path(path) then
        return normalize_foreign_windows_path(path)
    end

    local expanded = vim.fn.fnamemodify(path, ":p")
    local real = uv.fs_realpath(expanded)
    local normalized = vim.fs.normalize(real or expanded)
    if M.is_windows() and normalized:match("^%a:") then
        normalized = normalized:sub(1, 1):upper() .. normalized:sub(2)
    end
    return normalized
end

function M.basename(path)
    return vim.fn.fnamemodify(path, ":t")
end

function M.canonical(path)
    if not path or path == "" then
        return path
    end

    local normalized = M.normalize(path)
    local real = uv.fs_realpath(normalized)
    if real then
        return M.normalize(real)
    end

    local unresolved = {}
    local current = normalized
    -- Generated outputs and soon-to-exist sidecar files may not be present yet.
    -- Resolve the nearest existing parent so their future path still compares
    -- against the same project key after symlink normalization.
    while current and current ~= "" do
        local parent = vim.fs.dirname(current)
        if not parent or parent == current then
            break
        end

        table.insert(unresolved, 1, M.basename(current))
        current = parent
        real = uv.fs_realpath(current)
        if real then
            return M.normalize(M.join(real, unresolved))
        end
    end

    return normalized
end

function M.path_identity(path)
    if not path or path == "" then
        return path
    end

    local identity = vim.fs.normalize(path)
    if
        M.is_windows()
        or looks_like_windows_path(path)
        or looks_like_windows_path(identity)
    then
        identity = identity:gsub("\\", "/")
        if identity:match("^%a:") then
            identity = identity:sub(1, 1):upper() .. identity:sub(2)
        end
        identity = identity:lower()
    end

    return identity
end

function M.path_key(path)
    if not path or path == "" then
        return path
    end

    -- Do not pass foreign Windows paths through fnamemodify(":p"). On Unix that
    -- would turn "C:/..." into a path under the current directory instead of a
    -- stable identity from Typst/LSP output.
    if looks_like_windows_path(path) then
        return M.path_identity(path)
    end

    return M.path_identity(M.normalize(path))
end

local function comparison_key(path)
    if looks_like_windows_path(path) then
        return M.path_identity(path)
    end

    return M.path_identity(M.canonical(path))
end

function M.same_path(left, right)
    if not left or not right then
        return false
    end

    return comparison_key(left) == comparison_key(right)
end

function M.path_within(path, root)
    if not path or not root then
        return false
    end

    local path_key = comparison_key(path)
    local root_key = comparison_key(root)
    if path_key == root_key then
        return true
    end

    local trimmed_root = root_key:gsub("[/\\]+$", "")
    local prefix = trimmed_root .. "/"
    return path_key:sub(1, #prefix) == prefix
end

function M.dirname(path)
    return vim.fs.dirname(M.normalize(path))
end

function M.stem(path)
    return vim.fn.fnamemodify(path, ":t:r")
end

function M.with_extension(path, extension)
    return vim.fn.fnamemodify(path, ":r") .. "." .. extension
end

function M.is_absolute(path)
    if not path or path == "" then
        return false
    end

    if looks_like_windows_absolute(path) then
        return true
    end

    if M.is_windows() then
        return path:match("^%a:[/\\]") ~= nil
            or path:match("^[/\\][/\\]") ~= nil
    end

    return path:sub(1, 1) == "/"
end

function M.resolve_path(path, base)
    if not path or path == "" then
        return nil
    end

    if M.is_absolute(path) then
        return M.normalize(path)
    end

    return M.normalize(M.join(base or vim.fn.getcwd(), path))
end

function M.relpath(path, root)
    path = M.normalize(path)
    root = M.normalize(root)

    if vim.fs.relpath then
        return vim.fs.relpath(root, path) or path
    end

    local prefix = root .. M.path_sep()
    if path:sub(1, #prefix) == prefix then
        return path:sub(#prefix + 1)
    end

    return path
end

return M
