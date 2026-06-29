local log = require("typst.core.log")
local output_policy = require("typst.core.output_policy")
local services = require("typst.project.services")
local util = require("typst.core.util")

local M = {}

-- Helpers for selected-fragment compilation.
--
-- Fragment projects mirror the parent root but have fresh service state. That
-- lets compile cleanup see a normal project object without mutating the parent
-- compiler slot.
local fragment_counter = 0

--- Return the sentinel path that marks a custom fragment source directory owned.
---@param dir string Fragment source directory.
---@return string path Sentinel path.
function M.source_sentinel_path(dir)
    return output_policy.fragment_source_sentinel_path(dir)
end

--- Mark a fragment source directory as owned by typst.nvim.
---@param dir string Fragment source directory.
---@return boolean ok True when the sentinel write succeeded.
---@return any error Error returned by the filesystem helper.
function M.mark_owned_source_dir(dir)
    return output_policy.mark_fragment_source_dir(dir)
end

--- Return whether typst.nvim may mark this fragment source dir as owned.
---@param dir string Candidate directory.
---@param state table Parent project state.
---@return boolean allowed True when auto-marking is safe.
function M.source_dir_auto_mark_allowed(dir, state)
    return output_policy.fragment_source_auto_mark_allowed(dir, state)
end

--- Decide whether recursive cleanup may delete a fragment source directory.
---@param dir string Candidate directory.
---@param state table Parent project state.
---@return boolean allowed True when recursive deletion is safe.
---@return string? reason Machine-readable refusal reason.
function M.source_dir_cleanup_allowed(dir, state)
    return output_policy.fragment_source_cleanup_allowed(dir, state)
end

--- Notify through the caller callback or the default typst.nvim notifier.
---@param notify? fun(message:string, level?:vim.log.levels|integer) Optional notification sink.
---@param message string Message to display.
---@param level? vim.log.levels|integer Notification level.
function M.notify_user(notify, message, level)
    if notify then
        notify(message, level)
    else
        vim.notify(
            message,
            level or vim.log.levels.INFO,
            { title = "typst.nvim" }
        )
    end
end

local function substitute_body(template, body)
    return (template:gsub("{body}", function()
        return body
    end))
end

local function render_fragment_table(template, body, ctx)
    if type(template.source) == "function" then
        local source = template.source(body, ctx)
        if type(source) ~= "string" then
            error("fragment template source callback must return a string")
        end
        return source
    end

    if type(template.source) == "string" then
        return substitute_body(template.source, body)
    end

    return (template.prefix or "") .. body .. (template.suffix or "")
end

--- Render selected Typst text through a fragment template.
---@param template string|table|function Fragment template specification.
---@param body string Selected source body.
---@param ctx table Template context passed to callback templates.
---@return string source Rendered temporary Typst source.
---@return table template_opts Template options used to adjust compile config.
function M.render_template(template, body, ctx)
    if type(template) == "function" then
        local rendered = template(body, ctx)
        if type(rendered) == "string" then
            return rendered, {}
        end

        if type(rendered) ~= "table" then
            error("fragment template callback must return a string or table")
        end

        return render_fragment_table(rendered, body, ctx), rendered
    end

    if type(template) == "string" then
        return substitute_body(template, body), {}
    end

    return render_fragment_table(template, body, ctx), template
end

--- Resolve and clamp the selected line range for fragment compilation.
---@param bufnr integer Source buffer.
---@param opts table Selection options that may include `line1` and `line2`.
---@return integer line1 First selected line, 1-based.
---@return integer line2 Last selected line, 1-based.
function M.selected_line_range(bufnr, opts)
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    local line1 = tonumber(opts.line1)
    local line2 = tonumber(opts.line2)

    if not line1 or not line2 then
        if bufnr == vim.api.nvim_get_current_buf() then
            line1 = vim.api.nvim_win_get_cursor(0)[1]
        else
            line1 = 1
        end
        line2 = line1
    end

    line1 = math.max(1, math.min(line_count, line1))
    line2 = math.max(1, math.min(line_count, line2))
    if line2 < line1 then
        line1, line2 = line2, line1
    end

    return line1, line2
end

--- Generate a unique output stem for a temporary fragment compile.
---@param template_name? string Template name used in the generated stem.
---@return string stem Basename-safe stem for fragment source/output files.
function M.fragment_stem(template_name)
    fragment_counter = fragment_counter + 1
    local safe_template = (template_name or "fragment"):gsub("[^%w_.-]", "_")
    return ("selected-%s-%d-%d"):format(
        safe_template,
        os.time(),
        fragment_counter
    )
end

local function fragment_output_dir(run_config, fragments, template_opts, opts)
    if opts.output_dir ~= nil then
        return opts.output_dir
    end

    if template_opts.output_dir ~= nil then
        return template_opts.output_dir
    end

    if fragments.output_dir ~= nil then
        return fragments.output_dir
    end

    return run_config.output_dir
end

--- Resolve the directory used for temporary fragment source files.
---@param fragments table Global fragment configuration.
---@param template_opts table Template-specific fragment options.
---@param opts table Runtime fragment options.
---@param state table Parent project state used for root-relative paths.
---@return string|nil path Absolute source directory, or nil for stdin-backed fragments.
function M.resolve_source_dir(fragments, template_opts, opts, state)
    local source_dir = opts.source_dir
        or template_opts.source_dir
        or fragments.source_dir
    if source_dir and source_dir ~= "" then
        return util.resolve_path(source_dir, state.root)
    end

    return nil
end

--- Apply fragment-specific output and compile settings to a run config.
---@param run_config table Mutable run configuration for the fragment compile.
---@param fragments table Global fragment configuration.
---@param template_opts table Template-specific fragment options.
---@param opts table Runtime fragment options.
---@param stem string Generated fragment output stem.
function M.apply_run_config(run_config, fragments, template_opts, opts, stem)
    run_config.output_dir =
        fragment_output_dir(run_config, fragments, template_opts, opts)
    run_config.output_name = opts.output_name
        or template_opts.output_name
        or stem
    run_config.output_format = opts.output_format
        or template_opts.output_format
        or run_config.output_format
    -- Temporary wrapper files are not real project dependencies; templates can
    -- opt back into deps when they intentionally want graph updates.
    run_config.compile.deps = false

    if template_opts.extra_args ~= nil then
        run_config.compile.extra_args = vim.deepcopy(template_opts.extra_args)
    end

    if opts.extra_args ~= nil then
        run_config.compile.extra_args = vim.deepcopy(opts.extra_args)
    end

    if template_opts.deps ~= nil then
        run_config.compile.deps = template_opts.deps
    end

    if opts.deps ~= nil then
        run_config.compile.deps = opts.deps
    end

    if template_opts.open ~= nil and opts.open == nil then
        run_config.compile.open = template_opts.open
    end
end

--- Write rendered fragment source to disk.
---@param path string Destination source path.
---@param source string Rendered Typst source.
---@return boolean ok True when the file was written.
---@return any error Error object when writing failed.
function M.write_source(path, source)
    local parent_ok, parent_err = util.ensure_parent(path)
    if not parent_ok then
        return false, parent_err
    end
    local lines = vim.split(source, "\n", { plain = true })
    if source:sub(-1) == "\n" then
        table.remove(lines)
    end

    local ok, result = util.writefile_checked(lines, path)
    if not ok then
        return false, result
    end

    return true
end

--- Delete a temporary fragment source file if it exists.
---@param path? string Fragment source path.
function M.cleanup_source(path)
    if path and vim.fn.filereadable(path) == 1 then
        local ok, err = util.delete_checked(path)
        if not ok then
            log.add(
                "warn",
                "failed to delete Typst fragment source",
                { path = path, error = err }
            )
        end
    end
end

--- Build an isolated project state for a temporary fragment source file.
---@param parent table Parent project state that supplies root and metadata.
---@param source_path string Temporary fragment source path.
---@param source_bufnr integer Source buffer where the selection came from.
---@param template_name string Fragment template name.
---@param range integer[] Selected source range.
---@return table project Isolated fragment project state.
function M.fragment_project(
    parent,
    source_path,
    source_bufnr,
    template_name,
    range
)
    local buffer_name = vim.api.nvim_buf_is_valid(source_bufnr)
            and vim.api.nvim_buf_get_name(source_bufnr)
        or nil

    local fragment = {
        key = ("%s::fragment::%s"):format(parent.key, source_path),
        root = parent.root,
        main = source_path,
        services = services.new_state(),
        bufs = {},
        resolutions = {},
        last_resolution = {
            buffer = buffer_name or source_path,
            root_source = parent.root_source or "parent project",
            main_source = ("selected fragment template %s"):format(
                template_name
            ),
        },
        root_source = parent.root_source,
        main_source = "selected fragment",
        fragment = {
            parent = parent.key,
            source_buffer = source_bufnr,
            source_path = buffer_name,
            template = template_name,
            range = range,
        },
    }
    -- Do not reuse parent.services: fragment outputs, diagnostics, and handles
    -- must remain isolated from the real document.
    services.set_graph(fragment, {
        files = {
            [source_path] = true,
        },
        file_sources = {
            [source_path] = "explicit",
        },
        dependencies = {},
        dependency_sources = {},
    })
    return fragment
end

--- Build and report a fragment compile failure result.
---@param opts table Runtime fragment options.
---@param notify? fun(message:string, level?:vim.log.levels|integer) Notification sink.
---@param reason string Machine-readable failure reason.
---@param message string User-facing failure message.
---@param range? integer[] Selected source range.
---@param extra? table Extra result fields.
---@return table result Failure payload.
function M.failure(opts, notify, reason, message, range, extra)
    local result = vim.tbl_extend("force", {
        ok = false,
        reason = reason,
        message = message,
        range = range,
    }, extra or {})

    log.add("warn", "selected compile failed", result)
    if opts.notify ~= false then
        M.notify_user(notify, message, vim.log.levels.WARN)
    end

    return result
end

return M
