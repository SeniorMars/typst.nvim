local log = require("typst.core.log")
local util = require("typst.core.util")

local M = {}

local function tinymist_config()
    local ok, config = pcall(require, "typst.config")
    if not ok then
        return {}
    end

    local opts = config.unsafe_get()
    local integrations = opts.integrations or {}
    return integrations.tinymist or {}
end

local function configured_client_names()
    local out = {}
    local seen = {}
    local function add(name)
        if type(name) ~= "string" or name == "" or seen[name] then
            return
        end
        seen[name] = true
        out[#out + 1] = name
    end

    add("tinymist")
    local names = tinymist_config().client_names
    if type(names) == "table" then
        for _, name in ipairs(names) do
            add(name)
        end
    end
    return out
end

--- Return configured Tinymist client names, including the default `tinymist`.
---@return string[] names Client names recognized by typst.nvim.
function M.client_names()
    return configured_client_names()
end

local function matches_client_name(client)
    local name = client and client.name
    if type(name) ~= "string" then
        return false
    end
    for _, expected in ipairs(configured_client_names()) do
        if name == expected then
            return true
        end
    end
    return false
end

--- Check whether a Neovim LSP client matches configured Tinymist names.
---@param client table? Client-like LSP object.
---@return boolean matches True when the client is considered Tinymist-owned.
function M.matches_client_name(client)
    return matches_client_name(client)
end

--- Return the configured Tinymist LSP startup mode.
---@return '"off"'|'"detect"'|'"start"'|'"auto"' mode Normalized startup mode.
function M.lsp_mode()
    local tinymist = tinymist_config()
    local mode = tinymist.lsp

    if mode == false or mode == "off" then
        return "off"
    end

    if mode == "detect" then
        return "detect"
    end

    if mode == "start" then
        return "start"
    end

    return "auto"
end

--- Check whether typst.nvim should use Neovim's Tinymist LSP integration.
---@return boolean enabled True unless Tinymist LSP mode is explicitly off.
function M.lsp_enabled()
    return M.lsp_mode() ~= "off"
end

--- Return the Tinymist backend name used in reports.
---@return string backend Backend identifier.
function M.lsp_backend()
    return "nvim_lsp"
end

--- Check whether coc.nvim appears to own LSP startup for this session.
---@return boolean active True when coc.nvim service/commands are present.
function M.coc_active()
    local initialized = vim.g.coc_service_initialized
    if
        initialized == true
        or initialized == 1
        or initialized == "1"
        or initialized == "true"
    then
        return true
    end

    for _, probe in ipairs({ ":CocCommand", ":CocList", "*CocAction" }) do
        local ok, exists = pcall(vim.fn.exists, probe)
        if ok and exists ~= 0 then
            return true
        end
    end

    return false
end

--- Return attached Tinymist Neovim LSP clients for a buffer.
---@param bufnr integer Buffer whose attached clients should be filtered.
---@return table[] clients Attached Tinymist clients, empty when disabled/unavailable.
function M.clients(bufnr)
    local mode = M.lsp_mode()
    if mode == "off" or not vim.lsp.get_clients then
        return {}
    end

    if mode == "auto" and M.coc_active() then
        return {}
    end

    return vim.tbl_filter(function(client)
        return matches_client_name(client)
    end, vim.lsp.get_clients({ bufnr = bufnr }))
end

--- Check whether a buffer has an attached Tinymist client.
---@param bufnr integer Buffer to inspect.
---@return boolean available True when at least one Tinymist client is attached.
function M.available(bufnr)
    return #M.clients(bufnr) > 0
end

local function start_command()
    local tinymist = tinymist_config()
    if tinymist.cmd ~= nil then
        return util.command_prefix(tinymist.cmd)
    end

    return { tinymist.path or "tinymist" }
end

--- Return the configured Tinymist start command prefix.
---@return string[] command Command prefix used for native Neovim LSP startup.
function M.start_command()
    return vim.deepcopy(start_command())
end

local function executable_available(command)
    local executable = util.command_executable(command)
    return type(executable) == "string"
        and executable ~= ""
        and vim.fn.executable(executable) == 1
end

--- Report whether typst.nvim can start Tinymist in the current policy mode.
---@return table status Startability status with `ok`, `reason`, `mode`, and `command`.
function M.startability()
    local mode = M.lsp_mode()
    local command = start_command()
    local status = {
        ok = false,
        reason = mode,
        mode = mode,
        command = vim.deepcopy(command),
        executable = util.command_executable(command),
    }

    if mode == "off" or mode == "detect" then
        return status
    end

    if mode == "auto" and vim.g.typst_nvim_disable_tinymist_autostart == 1 then
        status.reason = "disabled"
        return status
    end

    if mode == "auto" and M.coc_active() then
        status.reason = "coc"
        return status
    end

    if not (vim.lsp and type(vim.lsp.start) == "function") then
        status.reason = "no_nvim_lsp_start"
        return status
    end

    if not executable_available(command) then
        status.reason = "missing_executable"
        return status
    end

    status.ok = true
    status.reason = "ok"
    status.path = vim.fn.exepath(util.command_executable(command))
    return status
end

local function nonempty_copy(value)
    if type(value) ~= "table" or next(value) == nil then
        return nil
    end
    return vim.deepcopy(value)
end

local function start_config(bufnr, project)
    local tinymist = tinymist_config()
    local command = start_command()
    local config = {
        name = "tinymist",
        cmd = command,
        root_dir = project and project.root or vim.fn.getcwd(),
        filetypes = { "typst" },
        single_file_support = true,
    }

    -- Empty Lua tables can serialize through LSP as arrays. Omit optional maps
    -- unless users configured actual fields so Tinymist receives object-shaped
    -- settings/init options.
    config.settings = nonempty_copy(tinymist.settings)
    config.init_options = nonempty_copy(tinymist.init_options)

    if tinymist.capabilities ~= nil then
        config.capabilities = vim.deepcopy(tinymist.capabilities)
    end

    if tinymist.on_attach ~= nil then
        config.on_attach = tinymist.on_attach
    end

    return config,
        {
            bufnr = bufnr,
            reuse_client = function(client, config)
                if not matches_client_name(client) then
                    return false
                end

                local client_config = client.config or {}
                if client_config.root_dir == nil or config.root_dir == nil then
                    return client_config.root_dir == nil
                        and config.root_dir == nil
                end
                return util.same_path(client_config.root_dir, config.root_dir)
            end,
        }
end

--- Ensure Tinymist is attached according to the configured startup mode.
---@param bufnr? integer Buffer that should receive/own the LSP client.
---@param project? table Project state used to select the LSP root.
---@return boolean ok True when Tinymist is attached or was started.
---@return string reason Attachment/startup status reason.
function M.ensure(bufnr, project)
    if not bufnr or bufnr == 0 then
        bufnr = vim.api.nvim_get_current_buf()
    end

    if M.available(bufnr) then
        return true, "attached"
    end

    local start = M.startability()
    if not start.ok then
        return false, start.reason
    end

    local config, opts = start_config(bufnr, project)
    local ok, client_id = pcall(vim.lsp.start, config, opts)
    if not ok then
        log.add("warn", "failed to start Tinymist Neovim LSP client", {
            bufnr = bufnr,
            root = config.root_dir,
            error = client_id,
        })
        return false, "start_failed"
    end

    if client_id then
        log.add("info", "started Tinymist Neovim LSP client", {
            bufnr = bufnr,
            root = config.root_dir,
            client_id = client_id,
        })
        return true, "started"
    end

    return false, "not_started"
end

--- Check whether any project buffer has an attached Tinymist client.
---@param project table Project state whose buffers/main file are inspected.
---@return boolean available True when Tinymist is attached to the project.
function M.available_for_project(project)
    for bufnr in pairs(project.bufs or {}) do
        if vim.api.nvim_buf_is_valid(bufnr) and M.available(bufnr) then
            return true
        end
    end

    local main_bufnr = util.loaded_buffer_for_path(project.main)
    return main_bufnr and M.available(main_bufnr) or false
end

--- Safely test whether a Tinymist client supports an LSP method.
---@param client table LSP client object.
---@param method string LSP method name.
---@param bufnr? integer Buffer number for method capability checks.
---@return boolean supported False only when the client explicitly rejects the method.
function M.supports_method(client, method, bufnr)
    if type(client.supports_method) ~= "function" then
        return true
    end

    local ok, supported = pcall(client.supports_method, client, method, bufnr)
    if ok then
        return supported ~= false
    end

    return true
end

--- Find the first usable Tinymist client attached to a project buffer.
---@param project table Project state whose buffers are searched.
---@param opts? table Selection options; `request="async"` requires `client.request`.
---@return table? client Matching Tinymist client.
---@return integer? bufnr Buffer the client is attached to.
function M.first_project_client(project, opts)
    opts = opts or {}
    if type(project) ~= "table" then
        return nil
    end

    local function usable(client, bufnr)
        if opts.request == "async" then
            return type(client.request) == "function"
        end

        if opts.method then
            return M.supports_method(client, opts.method, bufnr)
        end

        return true
    end

    local seen = {}
    local function check(bufnr)
        if not bufnr or bufnr <= 0 or seen[bufnr] then
            return nil
        end
        seen[bufnr] = true

        if
            not vim.api.nvim_buf_is_valid(bufnr)
            or not vim.api.nvim_buf_is_loaded(bufnr)
        then
            return nil
        end

        for _, client in ipairs(M.clients(bufnr)) do
            if usable(client, bufnr) then
                return client, bufnr
            end
        end
    end

    for bufnr in pairs(project.bufs or {}) do
        local client, attached_bufnr = check(bufnr)
        if client then
            return client, attached_bufnr
        end
    end

    local main_bufnr = project.main
            and util.loaded_buffer_for_path(project.main)
        or nil
    return check(main_bufnr)
end

return M
