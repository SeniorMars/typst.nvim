local compiler = require("typst.compiler")
local config = require("typst.config")
local fragment_helpers = require("typst.compiler.fragment_helpers")
local log = require("typst.core.log")
local output_path_util = require("typst.compiler.output_path")
local compiler_service = require("typst.project.services.compiler")
local util = require("typst.core.util")

local M = {}

local function explicit_source_dir(fragments, template_opts, opts)
    local source_dir = opts.source_dir
        or template_opts.source_dir
        or fragments.source_dir
    if type(source_dir) == "string" and source_dir ~= "" then
        return source_dir
    end
    return nil
end

local function use_stdin_source(fragments, template_opts, opts)
    return explicit_source_dir(fragments, template_opts, opts) == nil
end

local function stdin_source_path(stem)
    return ("<typst.nvim-fragment:%s>"):format(stem)
end

-- The selected text is wrapped by a user-configurable template and sent through
-- the normal compiler pipeline, but it owns separate compiler state so parent
-- project jobs are not confused with fragment jobs.
--- Compile selected buffer ranges as temporary Typst projects.
---@param parent table Parent project state used for root/config context.
---@param opts? table Fragment compile options; includes buffer and range fields.
---@param callback? fun(result:table) Terminal compile result callback.
---@param notify? fun(message:string, level?:vim.log.levels|integer) Notification sink.
---@return table|userdata|nil result Failure payload, compiler handle, or nil on early startup failure.
function M.compile_selected(parent, opts, callback, notify)
    opts = opts or {}
    callback = callback or opts.callback

    local bufnr = opts.bufnr
    local line1, line2 = fragment_helpers.selected_line_range(bufnr, opts)
    local range = { line1, line2 }
    local lines = vim.api.nvim_buf_get_lines(bufnr, line1 - 1, line2, false)
    if #lines == 0 then
        return fragment_helpers.failure(
            opts,
            notify,
            "empty_selection",
            "No Typst lines were selected",
            range
        )
    end

    local body = table.concat(lines, "\n")
    local run_config = config.for_run(opts.profile, { open = opts.open })
    local fragments = run_config.compile.fragments or {}
    local template_name = opts.template or opts.kind or fragments.default
    local template = template_name
        and fragments.templates
        and fragments.templates[template_name]
    if template == nil then
        return fragment_helpers.failure(
            opts,
            notify,
            "unknown_template",
            ("Unknown Typst fragment template %q"):format(template_name or ""),
            range,
            { template = template_name }
        )
    end

    local ctx = {
        bufnr = bufnr,
        project = parent,
        range = range,
        lines = vim.deepcopy(lines),
        template = template_name,
        profile = opts.profile,
    }
    local ok, source, template_opts =
        pcall(fragment_helpers.render_template, template, body, ctx)
    if not ok then
        return fragment_helpers.failure(
            opts,
            notify,
            "template_error",
            ("Typst fragment template %q failed: %s"):format(
                template_name,
                source
            ),
            range,
            { template = template_name }
        )
    end

    if type(source) ~= "string" or source == "" then
        return fragment_helpers.failure(
            opts,
            notify,
            "empty_fragment",
            ("Typst fragment template %q produced no source"):format(
                template_name
            ),
            range,
            { template = template_name }
        )
    end

    template_opts = template_opts or {}
    local stem = fragment_helpers.fragment_stem(template_name)
    fragment_helpers.apply_run_config(
        run_config,
        fragments,
        template_opts,
        opts,
        stem
    )

    run_config.compile.fragment = {
        template = template_name,
        range = range,
        source_buffer = bufnr,
        parent = parent.key,
    }

    local stdin_source = use_stdin_source(fragments, template_opts, opts)
    local source_path
    local source_dir
    if stdin_source then
        source_path = stdin_source_path(stem)
        run_config.compile.stdin = source
    else
        source_dir = fragment_helpers.resolve_source_dir(
            fragments,
            template_opts,
            opts,
            parent
        )
        -- Output path checks do not cover the generated .typ wrapper; keep that
        -- source inside the project root before writing anything.
        if not util.path_within(source_dir, parent.root) then
            return fragment_helpers.failure(
                opts,
                notify,
                "source_outside_root",
                ("Typst fragment source directory must be inside the project root: %s"):format(
                    source_dir
                ),
                range,
                { template = template_name, source_dir = source_dir }
            )
        end

        source_path = util.join(source_dir, stem .. ".typ")
    end

    local fragment = fragment_helpers.fragment_project(
        parent,
        source_path,
        bufnr,
        template_name,
        range
    )
    local output_ok, fragment_output =
        pcall(output_path_util.output_path, fragment, run_config)
    if not output_ok then
        return fragment_helpers.failure(
            opts,
            notify,
            "output_path_invalid",
            ("Invalid Typst fragment output path: %s"):format(fragment_output),
            range,
            {
                template = template_name,
                source = source_path,
                project = fragment,
                error = fragment_output,
            }
        )
    end

    if not stdin_source then
        if
            fragment_helpers.source_dir_auto_mark_allowed(source_dir, parent)
        then
            fragment_helpers.mark_owned_source_dir(source_dir)
        end
        local written, write_err =
            fragment_helpers.write_source(source_path, source)
        if not written then
            return fragment_helpers.failure(
                opts,
                notify,
                "write_failed",
                ("Failed to write Typst fragment: %s"):format(write_err),
                range,
                { template = template_name, source = source_path }
            )
        end
    end

    compiler_service.set(fragment, { output = fragment_output })
    log.add("info", "selected compile started", {
        template = template_name,
        source = source_path,
        source_mode = stdin_source and "stdin" or "file",
        parent = parent.main,
        range = range,
    })

    if opts.notify ~= false then
        fragment_helpers.notify_user(
            notify,
            ("Compiling selected Typst fragment [%s]"):format(template_name)
        )
    end

    local callback_seen = false
    local callback_result = nil
    local ok_compile, handle = pcall(
        compiler.compile,
        fragment,
        function(result)
            callback_seen = true
            callback_result = result
            if not stdin_source then
                fragment_helpers.cleanup_source(source_path)
            end
            if result.stale then
                return
            end

            if opts.notify ~= false then
                if result.code == 0 then
                    fragment_helpers.notify_user(
                        notify,
                        ("Compiled selected fragment %s"):format(
                            util.relpath(fragment_output, fragment.root)
                        )
                    )
                else
                    fragment_helpers.notify_user(
                        notify,
                        "Typst selected-fragment compile failed; use :TypstLog for details",
                        vim.log.levels.ERROR
                    )
                end
            end

            if callback then
                callback(result, fragment)
            end
        end,
        run_config
    )

    -- If the compiler coordinator errors before returning a handle, clean the
    -- generated wrapper immediately instead of leaving orphaned fragment state.
    if not ok_compile then
        if not stdin_source then
            fragment_helpers.cleanup_source(source_path)
        end
        compiler_service.set(fragment, {
            clear = { "process", "watcher" },
            status = "error",
            last_result = {
                code = 1,
                stderr = tostring(handle),
                stdout = "",
                stale = false,
            },
        })
        return fragment_helpers.failure(
            opts,
            notify,
            "compile_start_failed",
            ("Failed to start Typst fragment compile: %s"):format(handle),
            range,
            {
                template = template_name,
                source = source_path,
                output = fragment_output,
                project = fragment,
                error = handle,
            }
        )
    end

    if
        handle == nil
        and callback_seen
        and callback_result
        and callback_result.reason == "provider_error"
    then
        -- Providers can report a synchronous start failure through the callback
        -- path without producing a handle; normalize that to compile_start_failed.
        if not stdin_source then
            fragment_helpers.cleanup_source(source_path)
        end
        compiler_service.set(fragment, {
            clear = { "process", "watcher" },
            status = "error",
            last_result = vim.tbl_extend("force", {
                code = 1,
                stdout = "",
                stale = false,
            }, callback_result),
        })
        return fragment_helpers.failure(
            opts,
            notify,
            "compile_start_failed",
            ("Failed to start Typst fragment compile: %s"):format(
                callback_result.message or callback_result.error
            ),
            range,
            {
                template = template_name,
                source = source_path,
                output = fragment_output,
                project = fragment,
                error = callback_result.error or callback_result.message,
            }
        )
    end

    if handle == nil and not callback_seen then
        if not stdin_source then
            fragment_helpers.cleanup_source(source_path)
        end
        compiler_service.set(fragment, {
            clear = { "process", "watcher" },
            status = "error",
            last_result = {
                code = 1,
                stderr = "compiler provider returned no handle for the fragment compile",
                stdout = "",
                stale = false,
            },
        })
        return fragment_helpers.failure(
            opts,
            notify,
            "compile_start_failed",
            "Failed to start Typst fragment compile: compiler provider returned no handle",
            range,
            {
                template = template_name,
                source = source_path,
                output = fragment_output,
                project = fragment,
            }
        )
    end

    local result = {
        ok = true,
        handle = handle,
        project = fragment,
        parent = parent,
        template = template_name,
        source = source_path,
        source_mode = stdin_source and "stdin" or "file",
        source_text = source,
        output = fragment_output,
        range = range,
    }
    if type(handle) == "table" and type(handle.cancel) == "function" then
        result.cancel = function(cancel_opts)
            cancel_opts = cancel_opts or { reason = "cancelled" }
            if not stdin_source then
                fragment_helpers.cleanup_source(source_path)
            end
            compiler_service.set(fragment, {
                clear = { "process", "watcher" },
                last_result = {
                    code = 1,
                    stdout = "",
                    stderr = "",
                    stale = false,
                    stopped = true,
                    reason = cancel_opts.reason or "cancelled",
                },
                status = "idle",
            })
            return handle.cancel(cancel_opts)
        end
    end
    return result
end

return M
