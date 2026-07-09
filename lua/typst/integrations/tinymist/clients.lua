local log = require("typst.core.log")
local buffer = require("typst.core.buffer")
local command_util = require("typst.core.command")
local path_util = require("typst.core.path")

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

local function normalize_bufnr(bufnr)
    if bufnr == nil or bufnr == 0 then
        return vim.api.nvim_get_current_buf()
    end
    return bufnr
end

--- Normalize optional buffer ids for Tinymist helpers.
---@param bufnr? integer Buffer id, where nil/0 means current buffer.
---@return integer bufnr Normalized buffer id.
function M.normalize_bufnr(bufnr)
    return normalize_bufnr(bufnr)
end

--- Resolve the typst.nvim project for a buffer without requiring Tinymist
--- feature modules to each know the project facade.
---@param bufnr? integer Buffer id, where nil/0 means current buffer.
---@return table? project Project state for the buffer, if attached.
function M.project_for_buffer(bufnr)
    local ok, project = pcall(require, "typst.project")
    if ok and type(project.get) == "function" then
        return project.get(normalize_bufnr(bufnr))
    end
end

local function root_compatible(client, root)
    local client_config = type(client) == "table" and client.config or nil
    local client_root = type(client_config) == "table" and client_config.root_dir
        or nil

    if type(root) ~= "string" or root == "" then
        return client_root == nil or client_root == ""
    end

    if client_root == nil or client_root == "" then
        return true
    end

    return path_util.same_path(client_root, root)
end

--- Check whether a Tinymist client can serve a project root.
---@param client table? Client-like LSP object.
---@param root string? Project root.
---@return boolean compatible True when the client root is absent or same-path.
function M.root_compatible(client, root)
    return root_compatible(client, root)
end

local function client_summary(client)
    local config = type(client) == "table" and client.config or nil
    return {
        id = type(client) == "table" and client.id or nil,
        name = type(client) == "table" and client.name or nil,
        root_dir = type(config) == "table" and config.root_dir or nil,
    }
end

local function client_summaries(list)
    local out = {}
    for _, client in ipairs(list or {}) do
        out[#out + 1] = client_summary(client)
    end
    return out
end

local function selection_failure(reason, fields)
    return vim.tbl_extend("force", {
        ok = false,
        provider = "tinymist",
        reason = reason,
    }, fields or {})
end

local function lsp_disabled_selection(mode, bufnr)
    if mode == "off" then
        return selection_failure("lsp_off", {
            mode = mode,
            bufnr = bufnr,
            message = "Tinymist Neovim LSP integration is disabled",
        })
    end

    if mode == "auto" and M.coc_active() then
        return selection_failure("lsp_off", {
            mode = mode,
            bufnr = bufnr,
            cause = "coc",
            message = "Tinymist Neovim LSP integration is disabled because coc.nvim is active",
        })
    end
end

--- Select one attached Tinymist client through the central policy path.
---@param opts? table Selection controls: `bufnr`, `project`, `client`, `method`, and `request`.
---@return table selection Structured selection result.
function M.select_client(opts)
    opts = opts or {}
    local bufnr = normalize_bufnr(opts.bufnr)
    local project = type(opts.project) == "table" and opts.project or nil
    local root = opts.root or (project and project.root) or nil
    local mode = M.lsp_mode()

    if opts.client == nil then
        local disabled = lsp_disabled_selection(mode, bufnr)
        if disabled then
            return disabled
        end

        if not vim.lsp.get_clients then
            return selection_failure("no_client", {
                mode = mode,
                bufnr = bufnr,
                message = "Neovim LSP client discovery is unavailable",
            })
        end
    end

    local candidates = opts.client and { opts.client } or M.clients(bufnr)
    if #candidates == 0 then
        return selection_failure("no_client", {
            mode = mode,
            bufnr = bufnr,
            method = opts.method,
            message = "Tinymist Neovim LSP client is not attached",
        })
    end

    local root_matches = {}
    if type(root) ~= "string" or root == "" then
        root_matches = candidates
    else
        for _, client in ipairs(candidates) do
            if root_compatible(client, root) then
                root_matches[#root_matches + 1] = client
            end
        end
    end
    if #root_matches == 0 then
        return selection_failure("wrong_root", {
            mode = mode,
            bufnr = bufnr,
            root = root,
            method = opts.method,
            clients = client_summaries(candidates),
            message = "Attached Tinymist clients do not match the project root",
        })
    end

    local matches = {}
    for _, client in ipairs(root_matches) do
        local exec_cmd_ok = opts.allow_exec_cmd == true
            and opts.method == "workspace/executeCommand"
            and type(client.exec_cmd) == "function"
        local request_ok = exec_cmd_ok
            or opts.request ~= "async"
            or type(client.request) == "function"
        local method_ok = exec_cmd_ok
            or not opts.method
            or M.supports_method(client, opts.method, bufnr)
        if request_ok and method_ok then
            matches[#matches + 1] = client
        end
    end
    if #matches == 0 then
        return selection_failure("unsupported", {
            mode = mode,
            bufnr = bufnr,
            root = root,
            method = opts.method,
            clients = client_summaries(root_matches),
            message = opts.method
                    and ("Tinymist %s is unavailable"):format(opts.method)
                or "Attached Tinymist clients do not support the requested operation",
        })
    end

    return {
        ok = true,
        provider = "tinymist",
        bufnr = bufnr,
        project = project,
        project_key = project and project.key or nil,
        root = root,
        method = opts.method,
        client = matches[1],
        clients = matches,
        candidates = candidates,
    }
end

--- Return attached Tinymist clients compatible with a project root.
---@param bufnr integer Buffer whose attached clients should be filtered.
---@param project? table Project state used to match client roots.
---@return table[] clients Matching Tinymist clients.
function M.clients_for_project(bufnr, project)
    local root = type(project) == "table" and project.root or nil
    if not root then
        return M.clients(bufnr)
    end

    return vim.tbl_filter(function(client)
        return root_compatible(client, root)
    end, M.clients(bufnr))
end

--- Check whether a buffer has an attached Tinymist client.
---@param bufnr integer Buffer to inspect.
---@param project? table Project state used to match client roots.
---@return boolean available True when at least one Tinymist client is attached.
function M.available(bufnr, project)
    return M.select_client({ bufnr = bufnr, project = project }).ok == true
end

local function start_command()
    local tinymist = tinymist_config()
    if tinymist.cmd ~= nil then
        return command_util.command_prefix(tinymist.cmd)
    end

    return { tinymist.path or "tinymist" }
end

--- Return the configured Tinymist start command prefix.
---@return string[] command Command prefix used for native Neovim LSP startup.
function M.start_command()
    return vim.deepcopy(start_command())
end

local function executable_available(command)
    local executable = command_util.command_executable(command)
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
        executable = command_util.command_executable(command),
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
    status.path = vim.fn.exepath(command_util.command_executable(command))
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

                return root_compatible(client, config.root_dir)
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

    if M.select_client({ bufnr = bufnr, project = project }).ok == true then
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
        if
            vim.api.nvim_buf_is_valid(bufnr)
            and M.select_client({ bufnr = bufnr, project = project }).ok
                == true
        then
            return true
        end
    end

    local main_bufnr = buffer.loaded_buffer_for_path(project.main)
    return main_bufnr
            and M.select_client({ bufnr = main_bufnr, project = project }).ok
                == true
        or false
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

        local selected = M.select_client({
            bufnr = bufnr,
            project = project,
            method = opts.method,
            request = opts.request,
        })
        if selected.ok and usable(selected.client, bufnr) then
            return selected.client, bufnr
        end
    end

    for bufnr in pairs(project.bufs or {}) do
        local client, attached_bufnr = check(bufnr)
        if client then
            return client, attached_bufnr
        end
    end

    local main_bufnr = project.main
            and buffer.loaded_buffer_for_path(project.main)
        or nil
    return check(main_bufnr)
end

return M
