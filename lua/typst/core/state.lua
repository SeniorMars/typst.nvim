local log = require("typst.core.log")
local util = require("typst.core.util")
local xdg = require("typst.core.xdg")

local M = {}

-- Small persisted state store for choices that should survive a Neovim restart.
-- It deliberately stays outside project state: a buffer can be closed before
-- its explicit main is needed again.
local cache = nil

local function state_path()
    return xdg.state_dir("state.json")
end

local function empty_state()
    return {
        version = 1,
        explicit_mains = {},
    }
end

local function read_state()
    if cache then
        return cache
    end

    local path = state_path()
    local ok, lines = pcall(vim.fn.readfile, path)
    if not ok then
        cache = empty_state()
        return cache
    end

    local decoded_ok, decoded =
        pcall(vim.json.decode, table.concat(lines, "\n"))
    if not decoded_ok or type(decoded) ~= "table" then
        log.add("warn", "failed to read typst.nvim state", { path = path })
        cache = empty_state()
        return cache
    end

    decoded.explicit_mains = type(decoded.explicit_mains) == "table"
            and decoded.explicit_mains
        or {}
    cache = decoded
    return cache
end

local function write_state(state)
    local path = state_path()

    local ok, err = util.atomic_writefile({ vim.json.encode(state) }, path)
    if not ok then
        log.add(
            "warn",
            "failed to write typst.nvim state",
            { path = path, error = err }
        )
        return false
    end

    return true
end

local function explicit_key(path)
    return util.path_key(path)
end

local function explicit_entry(state, buffer_path)
    local key = explicit_key(buffer_path)
    local main = state.explicit_mains[key]
    if type(main) == "string" and main ~= "" then
        return key, main
    end

    -- Older state files and paths opened through different spellings may not
    -- use the current path_key. Recover them once, then rewrite under the
    -- canonical key in explicit_main().
    local normalized = util.normalize(buffer_path)
    main = state.explicit_mains[normalized]
    if type(main) == "string" and main ~= "" then
        return normalized, main
    end

    for candidate, value in pairs(state.explicit_mains) do
        if
            type(value) == "string"
            and value ~= ""
            and util.same_path(candidate, normalized)
        then
            return candidate, value
        end
    end
end

--- Return the persisted explicit main file for a buffer path.
---@param buffer_path string Buffer path used as the persistence key.
---@return string? main Readable persisted main file, or nil when absent/stale.
function M.explicit_main(buffer_path)
    local normalized = util.normalize(buffer_path)
    local state = read_state()
    local key, main = explicit_entry(state, normalized)
    if type(main) ~= "string" or main == "" then
        return nil
    end

    main = util.normalize(main)
    if util.readable(main) then
        local current_key = explicit_key(normalized)
        if key ~= current_key then
            state.explicit_mains[key] = nil
            state.explicit_mains[current_key] = main
            write_state(state)
        end
        return main
    end

    state.explicit_mains[key] = nil
    write_state(state)
    return nil
end

--- Persist an explicit main file for a buffer path.
---@param buffer_path string Buffer path used as the persistence key.
---@param main string Main file path to persist.
---@return string main Normalized main file path.
function M.set_explicit_main(buffer_path, main)
    local normalized = util.normalize(buffer_path)
    local resolved = util.normalize(main)
    local state = read_state()
    state.explicit_mains[explicit_key(normalized)] = resolved
    write_state(state)
    return resolved
end

--- Clear a persisted explicit main file for a buffer path.
---@param buffer_path string Buffer path used as the persistence key.
---@return string? previous Previously persisted main file.
function M.clear_explicit_main(buffer_path)
    local normalized = util.normalize(buffer_path)
    local state = read_state()
    local key, previous = explicit_entry(state, normalized)
    if key then
        state.explicit_mains[key] = nil
    end
    if previous ~= nil then
        write_state(state)
    end
    return previous
end

--- Move a persisted explicit-main entry after a buffer file rename.
---@param from_path string Old buffer path.
---@param to_path string New buffer path.
---@return string? previous Persisted main file moved to the new key.
function M.move_explicit_main(from_path, to_path)
    local from = util.normalize(from_path)
    local to = util.normalize(to_path)
    local state = read_state()
    local from_key, previous = explicit_entry(state, from)
    local to_key = explicit_key(to)

    if from_key == to_key then
        return previous
    end

    if previous == nil then
        return nil
    end

    state.explicit_mains[from_key] = nil
    state.explicit_mains[to_key] = previous
    write_state(state)
    return previous
end

--- Clear the in-memory persisted-state cache.
function M.reset_cache()
    cache = nil
end

return M
