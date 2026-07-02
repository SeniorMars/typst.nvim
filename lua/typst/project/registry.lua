local M = {}

-- Live project registry state. Project resolution and lifecycle modules should
-- go through this module instead of keeping their own ownership tables.

local projects = {}
local buffer_projects = {}

local function copy_map(tbl)
    local copy = {}
    for key, value in pairs(tbl) do
        copy[key] = value
    end
    return copy
end

local function encode_byte(char)
    return ("%%%02X"):format(char:byte())
end

function M.encode_key(key)
    if type(key) ~= "string" then
        return key
    end
    return (key:gsub("[^%w%._%-]", encode_byte))
end

function M.decode_key(key)
    if type(key) ~= "string" then
        return key
    end
    return (
        key:gsub("%%(%x%x)", function(hex)
            return string.char(tonumber(hex, 16))
        end)
    )
end

function M.all()
    return copy_map(projects)
end

function M.buffers()
    return copy_map(buffer_projects)
end

-- Internal escape hatch for project.store and invariant/debug tooling only.
-- Feature modules should use project/store snapshots or facade helpers.
function M.live_all()
    return projects
end

-- Internal escape hatch for project.store and invariant/debug tooling only.
-- Feature modules should use project/store snapshots or facade helpers.
function M.live_buffers()
    return buffer_projects
end

function M.get(key)
    if key == nil then
        return nil
    end
    return projects[key] or projects[M.decode_key(key)]
end

function M.resolve_key(key, opts)
    if key == nil then
        return nil
    end
    opts = opts or {}
    local decoded = M.decode_key(key)
    local raw_project = projects[key]
    local decoded_project = decoded ~= key and projects[decoded] or raw_project

    if opts.encoded == true then
        return decoded_project or raw_project, nil, decoded
    end

    if raw_project and decoded_project and raw_project ~= decoded_project then
        return nil, "ambiguous_project_key", decoded
    end

    return raw_project or decoded_project, nil, decoded
end

function M.get_encoded(key)
    if key == nil then
        return nil
    end
    return M.resolve_key(key, { encoded = true })
end

function M.set(key, project)
    projects[key] = project
    return project
end

function M.remove(key)
    local project = projects[key]
    projects[key] = nil
    for bufnr, mapped_key in pairs(buffer_projects) do
        if mapped_key == key then
            buffer_projects[bufnr] = nil
        end
    end
    return project
end

function M.key_for_buffer(bufnr)
    return buffer_projects[bufnr]
end

function M.project_for_buffer(bufnr)
    local key = buffer_projects[bufnr]
    return key and projects[key] or nil
end

function M.set_buffer(bufnr, key)
    buffer_projects[bufnr] = key
end

function M.clear_buffer(bufnr)
    local key = buffer_projects[bufnr]
    buffer_projects[bufnr] = nil
    return key
end

function M.reset()
    projects = {}
    buffer_projects = {}
end

return M
