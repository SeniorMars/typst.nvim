local config = require("typst.config")
local command_util = require("typst.core.command")

local M = {}

local function command_path(command)
    if type(command) ~= "string" or command == "" then
        return nil
    end
    local executable = vim.fn.exepath(command)
    if executable ~= "" then
        return executable
    end
    return command
end

local function executable_status(command)
    local executable = command_util.command_executable(command)
    local available = type(executable) == "string"
        and executable ~= ""
        and vim.fn.executable(executable) == 1
    return {
        executable = available,
        path = command_path(executable),
        command = command_util.command_display(command),
    }
end

local function treesitter_status()
    local parser = false
    local bufnr = vim.api.nvim_create_buf(false, true)
    if bufnr then
        pcall(vim.api.nvim_buf_set_lines, bufnr, 0, -1, false, { "" })
        local ok_parser, parsed =
            pcall(vim.treesitter.get_parser, bufnr, "typst")
        parser = ok_parser and parsed ~= nil
        pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
    local conceal_query_ok, conceal_query =
        pcall(vim.treesitter.query.get, "typst", "conceal")
    return {
        parser = parser == true,
        conceal_query = conceal_query_ok == true and conceal_query ~= nil,
    }
end

local function compiler_status(opts)
    local configured_provider = ((config.unsafe_get() or {}).compile or {}).provider
    if configured_provider == nil or configured_provider == "typst" then
        return {
            provider = "typst",
            ok = true,
            builtin = true,
            inspectable = true,
            watch = true,
            output_locks = true,
            outputless = false,
            output = true,
        }
    end
    if type(configured_provider) == "function" then
        return {
            provider = "callback",
            ok = true,
            builtin = false,
            inspectable = false,
            reason = "callback_uninspectable",
            message = "Compiler provider callback is configured; method shape is not inspected by capabilities()",
            watch = false,
            output_locks = true,
            outputless = false,
            output = false,
        }
    end

    local provider_binding = require("typst.compiler.provider_binding")
    local ok, provider, builtin = pcall(provider_binding.configured)
    if not ok then
        return {
            provider = "<error>",
            ok = false,
            reason = "provider_resolution_failed",
            message = tostring(provider),
            output_locks = true,
            watch = false,
            outputless = false,
            output = false,
        }
    end
    local label = provider_binding.label(provider, builtin)
    return {
        provider = label,
        ok = true,
        builtin = builtin == true,
        inspectable = true,
        watch = type(provider) == "table"
                and type(provider.start) == "function"
            or false,
        output_locks = true,
        outputless = type(provider) == "table" and provider.outputless == true,
        output = type(provider) == "table"
            and type(provider.output) == "function",
    }
end

local function tinymist_status()
    local ok, clients = pcall(require, "typst.integrations.tinymist.clients")
    if not ok then
        return {
            mode = (config.unsafe_get().integrations.tinymist or {}).lsp,
            attached = false,
            reason = "unavailable",
        }
    end
    local startability = clients.startability()
    return {
        mode = (config.unsafe_get().integrations.tinymist or {}).lsp,
        attached = #clients.clients(0) > 0,
        reason = startability.reason,
        startable = startability.ok == true,
    }
end

local function preview_status()
    local opts = config.unsafe_get()
    local native = opts.preview and opts.preview.native
    local provider = type(opts.preview) == "table" and opts.preview.provider
        or nil
    return {
        native_viewer = native == "viewer"
            or native == "view"
            or native == true
            or native == "auto",
        native_browser = native == "browser" or native == "auto",
        native_auto = native == "auto",
        typst_preview = provider == "typst-preview.nvim"
            or provider == "typst-preview",
    }
end

---Return a machine-readable snapshot of stable workflow capabilities.
---@param opts? table Reserved for future project-scoped capability checks.
---@return table capabilities Public capability summary.
function M.collect(opts)
    opts = opts or {}
    local current = config.unsafe_get()
    return {
        typst = executable_status(current.executable),
        treesitter = treesitter_status(),
        tinymist = tinymist_status(),
        compiler = compiler_status(opts),
        preview = preview_status(),
        diagnostics = {
            compiler = (current.diagnostics or {}).enabled ~= false
                and (current.diagnostics or {}).source ~= "off",
            source = (current.diagnostics or {}).source,
            external_paths = (current.diagnostics or {}).external_paths,
            max_external_buffers = (current.diagnostics or {}).max_external_buffers,
            overflow = (current.diagnostics or {}).overflow,
        },
    }
end

return M
