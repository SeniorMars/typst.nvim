local M = {}

local function nil_error()
    return {
        resolution_error = "nil_error",
        protect_handler = true,
        handler_exception = "throw",
    }
end

local function payload_error()
    return {
        resolution_error = "payload",
        protect_handler = true,
        handler_exception = "payload",
    }
end

local function project_policy(fields)
    fields = vim.deepcopy(fields or {})
    fields.required = fields.required ~= false
    return fields
end

M.endpoints = {
    {
        namespace = "project",
        name = "services",
        operation = "project.services",
        experimental = true,
        project = project_policy({
            create = false,
            settle_pending = true,
            passive = true,
        }),
        handler = {
            module = "typst.project.services",
            method = "snapshot",
            call = "project_only",
        },
        result = nil_error(),
    },
    {
        namespace = "project",
        name = "operations",
        operation = "project.operations",
        experimental = true,
        project = project_policy({
            create = false,
            settle_pending = true,
            passive = true,
        }),
        handler = {
            custom = "project.operations",
        },
        result = nil_error(),
    },
    {
        namespace = "compiler",
        name = "compile",
        operation = "compiler.compile",
        stable = true,
        project = project_policy({
            create = true,
            require_typst = true,
            settle_pending = true,
            block_pending_resolution = true,
        }),
        args = {
            callback = true,
            pass_notify = true,
        },
        handler = {
            module = "typst.project.services.operations",
            method = "compile",
            call = "project_opts_callback_notify",
        },
        result = nil_error(),
    },
    {
        namespace = "compiler",
        name = "compile_selected",
        operation = "compiler.compile_selected",
        stable = true,
        project = project_policy({
            create = true,
            require_typst = true,
            settle_pending = true,
            block_pending_resolution = true,
        }),
        args = {
            callback = true,
            normalize_bufnr = true,
            pass_notify = true,
        },
        handler = {
            module = "typst.project.services.operations",
            method = "compile_selected",
            call = "project_opts_callback_notify",
        },
        result = nil_error(),
    },
    {
        namespace = "compiler",
        name = "output",
        operation = "compiler.output",
        stable = true,
        project = project_policy({
            create = false,
            settle_pending = true,
            passive = true,
        }),
        handler = {
            module = "typst.compiler.api",
            method = "compile_output",
            call = "project_opts",
        },
        result = nil_error(),
    },
    {
        namespace = "compiler",
        name = "watch",
        operation = "compiler.watch",
        stable = true,
        project = project_policy({
            create = true,
            require_typst = true,
            settle_pending = true,
            block_pending_resolution = true,
        }),
        args = {
            callback = true,
            pass_notify = true,
        },
        handler = {
            module = "typst.project.services.operations",
            method = "watch",
            call = "project_opts_callback_notify",
        },
        result = nil_error(),
    },
    {
        namespace = "compiler",
        name = "stop",
        operation = "compiler.stop",
        stable = true,
        project = project_policy({
            create = false,
            settle_pending = true,
        }),
        args = {
            callback = true,
            pass_notify = true,
        },
        handler = {
            module = "typst.project.services.operations",
            method = "stop",
            call = "project_callback_notify",
        },
        result = nil_error(),
    },
    {
        namespace = "compiler",
        name = "stop_all",
        operation = "compiler.stop_all",
        stable = true,
        project = false,
        args = {
            callback = true,
            pass_notify = true,
        },
        handler = {
            module = "typst.project.services.operations",
            method = "stop_all",
            call = "opts_callback_notify",
        },
        result = {
            protect_handler = true,
            handler_exception = "throw",
        },
    },
    {
        namespace = "compiler",
        name = "force_clear",
        operation = "compiler.force_clear",
        experimental = true,
        project = project_policy({
            create = false,
            settle_pending = false,
            notify = false,
        }),
        handler = {
            module = "typst.project.services.operations",
            method = "force_clear_compiler",
            call = "project_opts_notify",
        },
        result = vim.tbl_extend("force", payload_error(), {
            failure_fields = {
                code = 1,
                stale = false,
                stopped = false,
            },
            notify_on_resolution_error = true,
            notify_levels_by_reason = {
                ambiguous_project_key = "error",
                unknown_project_key = "error",
                no_project = "warn",
            },
        }),
    },
    {
        namespace = "compiler",
        name = "status",
        operation = "compiler.status",
        stable = true,
        project = project_policy({
            create = false,
            settle_pending = true,
            passive = true,
        }),
        handler = {
            module = "typst.compiler",
            method = "status",
            call = "project_only",
        },
        result = nil_error(),
    },
    {
        namespace = "compiler",
        name = "current_output",
        operation = "compiler.current_output",
        stable = true,
        project = project_policy({
            create = false,
            settle_pending = true,
            passive = true,
        }),
        handler = {
            module = "typst.compiler",
            method = "output",
            call = "project_only",
        },
        result = nil_error(),
    },
    {
        namespace = "viewer",
        name = "view",
        operation = "viewer.view",
        stable = true,
        project = project_policy({
            create = true,
            require_typst = true,
            settle_pending = true,
            block_pending_resolution = true,
        }),
        handler = {
            module = "typst.viewer.api",
            method = "view",
            call = "project_opts_notify",
        },
        result = nil_error(),
    },
    {
        namespace = "viewer",
        name = "view_forward",
        operation = "viewer.view_forward",
        stable = true,
        project = project_policy({
            create = true,
            require_typst = true,
            settle_pending = true,
            block_pending_resolution = true,
        }),
        handler = {
            module = "typst.viewer.api",
            method = "view_forward",
            call = "project_opts_notify",
        },
        result = nil_error(),
    },
    {
        namespace = "viewer",
        name = "view_inverse",
        operation = "viewer.view_inverse",
        stable = true,
        project = project_policy({
            create = false,
            settle_pending = true,
            source_path = true,
        }),
        handler = {
            module = "typst.viewer.api",
            method = "view_inverse",
            call = "project_opts_notify",
        },
        result = nil_error(),
    },
    {
        namespace = "viewer",
        name = "capabilities",
        operation = "viewer.capabilities",
        stable = true,
        project = false,
        handler = {
            module = "typst.viewer.api",
            method = "viewer_capabilities",
            call = "opts",
        },
        result = {
            protect_handler = true,
            handler_exception = "throw",
        },
    },
    {
        namespace = "viewer",
        name = "preview_capabilities",
        operation = "viewer.preview_capabilities",
        experimental = true,
        project = project_policy({
            create = false,
            settle_pending = true,
            passive = true,
        }),
        handler = {
            module = "typst.viewer.api",
            method = "preview_capabilities",
            call = "project_only",
        },
        result = nil_error(),
    },
    {
        namespace = "viewer",
        name = "clean",
        operation = "viewer.clean",
        experimental = true,
        project = project_policy({
            create = false,
            settle_pending = true,
        }),
        handler = {
            module = "typst.viewer.api",
            method = "clean",
            call = "project_opts_notify",
        },
        result = nil_error(),
    },
    {
        namespace = "viewer",
        name = "clean_preview",
        operation = "viewer.clean_preview",
        experimental = true,
        project = project_policy({
            create = false,
            settle_pending = true,
        }),
        handler = {
            module = "typst.viewer.api",
            method = "clean_preview",
            call = "project_opts_notify",
        },
        result = nil_error(),
    },
    {
        namespace = "viewer",
        name = "preview",
        operation = "viewer.preview",
        experimental = true,
        project = project_policy({
            create = true,
            require_typst = true,
            settle_pending = true,
            block_pending_resolution = true,
        }),
        handler = {
            module = "typst.viewer.api",
            method = "preview",
            call = "project_opts_notify",
        },
        result = nil_error(),
    },
    {
        namespace = "viewer",
        name = "preview_open_browser",
        operation = "viewer.preview_open_browser",
        experimental = true,
        project = project_policy({
            create = true,
            require_typst = true,
            settle_pending = true,
            block_pending_resolution = true,
        }),
        handler = {
            module = "typst.viewer.api",
            method = "preview_open_browser",
            call = "project_opts_notify",
        },
        result = nil_error(),
    },
    {
        namespace = "viewer",
        name = "preview_reload",
        operation = "viewer.preview_reload",
        experimental = true,
        project = project_policy({
            create = false,
            settle_pending = true,
        }),
        handler = {
            module = "typst.viewer.api",
            method = "preview_reload",
            call = "project_opts_notify",
        },
        result = nil_error(),
    },
    {
        namespace = "viewer",
        name = "preview_status",
        operation = "viewer.preview_status",
        experimental = true,
        project = project_policy({
            create = false,
            settle_pending = true,
            passive = true,
        }),
        handler = {
            module = "typst.viewer.api",
            method = "preview_status",
            call = "project_opts_notify",
        },
        result = {
            resolution_error = "status_payload",
            protect_handler = true,
            handler_exception = "payload",
        },
    },
    {
        namespace = "viewer",
        name = "preview_stop",
        operation = "viewer.preview_stop",
        experimental = true,
        project = project_policy({
            create = false,
            settle_pending = true,
        }),
        handler = {
            module = "typst.viewer.api",
            method = "preview_stop",
            call = "project_opts_notify",
        },
        result = nil_error(),
    },
    {
        namespace = "viewer",
        name = "preview_toggle",
        operation = "viewer.preview_toggle",
        experimental = true,
        project = project_policy({
            create = true,
            require_typst = true,
            settle_pending = true,
            block_pending_resolution = true,
        }),
        handler = {
            module = "typst.viewer.api",
            method = "preview_toggle",
            call = "project_opts_notify",
        },
        result = nil_error(),
    },
    {
        namespace = "viewer",
        name = "preview_inverse",
        operation = "viewer.preview_inverse",
        experimental = true,
        project = project_policy({
            create = false,
            settle_pending = true,
            source_path = true,
        }),
        handler = {
            module = "typst.viewer.api",
            method = "preview_inverse",
            call = "project_opts_notify",
        },
        result = nil_error(),
    },
}

local function symbol(endpoint)
    return ("%s.%s"):format(endpoint.namespace, endpoint.name)
end

M.by_symbol = {}
for _, endpoint in ipairs(M.endpoints) do
    M.by_symbol[symbol(endpoint)] = endpoint
    if endpoint.project ~= false and type(endpoint.project) == "table" then
        endpoint.project.operation = endpoint.project.operation
            or endpoint.operation
    end
end

function M.get(name)
    return M.by_symbol[name]
end

function M.policies()
    local out = {}
    for name, endpoint in pairs(M.by_symbol) do
        out[name] = endpoint.project == false
                and {
                    project = false,
                    operation = endpoint.operation,
                }
            or vim.deepcopy(endpoint.project or {})
    end
    return out
end

function M.status()
    local out = {
        endpoints = #M.endpoints,
        stable = 0,
        experimental = 0,
        passive = 0,
        create = 0,
        source_path = 0,
    }
    for _, endpoint in ipairs(M.endpoints) do
        if endpoint.stable then
            out.stable = out.stable + 1
        elseif endpoint.experimental then
            out.experimental = out.experimental + 1
        end
        if type(endpoint.project) == "table" then
            if endpoint.project.passive then
                out.passive = out.passive + 1
            end
            if endpoint.project.create then
                out.create = out.create + 1
            end
            if endpoint.project.source_path then
                out.source_path = out.source_path + 1
            end
        end
    end
    return out
end

return M
