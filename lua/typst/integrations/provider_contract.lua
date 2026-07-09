local M = {}

local aliases = {
    compile = "compiler",
    compiler = "compiler",
    format = "format",
    formatter = "format",
    lint = "lint",
    linter = "lint",
    artifact = "export",
    artifacts = "export",
    export = "export",
    exports = "export",
    init = "init",
    template = "init",
    templates = "init",
    semantic = "semantic",
    render = "render",
    renderer = "render",
    rendered_preview = "render",
    terminal_image = "render",
    index = "index",
    picker = "picker",
    toc = "toc",
    table_of_contents = "toc",
    view = "viewer",
    viewer = "viewer",
    preview = "preview",
    source_map = "source_map",
    source_maps = "source_map",
    sourcemap = "source_map",
    sourcemaps = "source_map",
    preview_source_map = "source_map",
    preview_source_maps = "source_map",
}

local methods = {
    compiler = { "compile", "start", "stop", "status", "output" },
    format = { "format", "run" },
    lint = { "lint", "run" },
    export = { "export", "run" },
    init = { "init", "run" },
    semantic = {
        "color_info",
        "document_links",
        "code_lens",
        "workspace_symbols",
        "references",
        "rename_preview",
        "run",
    },
    render = { "render", "display", "run" },
    index = { "index", "collect", "run" },
    picker = { "items", "run" },
    toc = { "toc", "items", "run" },
    viewer = { "open", "forward", "inverse", "run" },
    preview = { "open", "close", "forward", "inverse", "run" },
    source_map = {
        "generate",
        "resolve",
        "forward",
        "inverse",
        "browser_inverse",
        "run",
    },
}

local kind_stability = {
    compiler = "core",
    export = "experimental",
    format = "supported",
    index = "experimental",
    init = "experimental",
    lint = "supported",
    picker = "experimental",
    preview = "experimental",
    render = "experimental",
    semantic = "experimental",
    source_map = "experimental",
    toc = "experimental",
    viewer = "core",
}

local fixture_matrix = {
    "synchronous success",
    "synchronous failure",
    "callback success",
    "callback failure",
    "returned pending handle",
    "pending handle timeout",
    "cancellation before completion",
    "duplicate callback",
    "thrown provider error",
    "malformed or nil result",
}

local fixture_cases = {
    {
        id = "sync_success",
        label = "synchronous success",
        expected = "ok",
    },
    {
        id = "sync_failure",
        label = "synchronous failure",
        expected = "failure",
    },
    {
        id = "callback_success",
        label = "callback success",
        expected = "ok",
    },
    {
        id = "callback_failure",
        label = "callback failure",
        expected = "failure",
    },
    {
        id = "returned_pending_handle",
        label = "returned pending handle",
        expected = "pending",
    },
    {
        id = "pending_handle_timeout",
        label = "pending handle timeout",
        expected = "timeout",
    },
    {
        id = "cancellation_before_completion",
        label = "cancellation before completion",
        expected = "cancelled",
    },
    {
        id = "duplicate_callback",
        label = "duplicate callback",
        expected = "first_result",
    },
    {
        id = "thrown_provider_error",
        label = "thrown provider error",
        expected = "provider_error",
    },
    {
        id = "malformed_nil_result",
        label = "malformed or nil result",
        expected = "invalid_result",
    },
}

local conformance_cases = {
    {
        id = "sync_success",
        label = "synchronous success",
        required = true,
    },
    {
        id = "sync_failure",
        label = "synchronous failure",
        required = true,
    },
    {
        id = "callback_success",
        label = "asynchronous callback success",
        required = true,
    },
    {
        id = "callback_failure",
        label = "asynchronous callback failure",
        required = true,
    },
    {
        id = "returned_pending_handle",
        label = "returned pending handle",
        required = true,
    },
    {
        id = "pending_handle_timeout",
        label = "timeout or never-callback pending handle",
        required = true,
    },
    {
        id = "cancellation_before_completion",
        label = "cancel before completion",
        required = true,
    },
    {
        id = "duplicate_callback",
        label = "stale or duplicate terminal callback",
        required = true,
    },
    {
        id = "thrown_provider_error",
        label = "thrown provider error",
        required = true,
    },
    {
        id = "malformed_nil_result",
        label = "malformed or nil result",
        required = true,
    },
}

local result_contract = {
    version = 1,
    terminal_fields = {
        "ok",
        "code",
        "reason",
        "message",
        "stopped",
        "forced",
        "orphaned",
    },
    common_fields = {
        "ok",
        "pending",
        "code",
        "reason",
        "message",
        "error",
        "stale",
        "stopped",
        "forced",
        "orphaned",
        "output",
        "path",
    },
    handle_like_fields = {
        "path",
        "output",
        "diagnostics",
        "by_buffer",
        "artifacts",
        "outputs",
    },
    pending_field = "pending",
    cancel_signature = "cancel(self_or_opts, opts?) -> boolean, result?",
}

local structural_results = {
    source_map = { "path", "file", "filename", "line", "column" },
    lint = { "diagnostics", "by_buffer" },
    export = { "path", "output", "outputs", "artifacts" },
    render = { "path", "output", "outputs", "artifacts" },
    viewer = { "opened", "path", "output" },
    init = { "path", "files", "created", "template", "output" },
}

local function sorted_keys(tbl)
    local keys = vim.tbl_keys(tbl)
    table.sort(keys)
    return keys
end

function M.aliases()
    return vim.deepcopy(aliases)
end

function M.kinds()
    local seen = {}
    for _, kind in pairs(aliases) do
        seen[kind] = true
    end
    return sorted_keys(seen)
end

local function kinds_by_stability(stability)
    local out = {}
    for kind, value in pairs(kind_stability) do
        if value == stability then
            out[#out + 1] = kind
        end
    end
    table.sort(out)
    return out
end

function M.core_kinds()
    return kinds_by_stability("core")
end

function M.supported_kinds()
    return kinds_by_stability("supported")
end

function M.experimental_kinds()
    return kinds_by_stability("experimental")
end

function M.kind_stability(kind)
    kind = M.normalize_kind(kind)
    return kind_stability[kind]
end

function M.methods(kind)
    kind = M.normalize_kind(kind)
    return vim.deepcopy(methods[kind] or {})
end

function M.fixture_matrix()
    return vim.deepcopy(fixture_matrix)
end

function M.fixture_cases()
    return vim.deepcopy(fixture_cases)
end

function M.conformance_cases()
    return vim.deepcopy(conformance_cases)
end

function M.conformance_matrix()
    local matrix = {}
    for _, kind in ipairs(M.kinds()) do
        matrix[kind] = M.conformance_cases()
    end
    return matrix
end

function M.result_contract()
    return vim.deepcopy(result_contract)
end

function M.structural_results()
    return vim.deepcopy(structural_results)
end

function M.sdk_contract()
    return {
        version = 1,
        aliases = M.aliases(),
        kinds = M.kinds(),
        core_kinds = M.core_kinds(),
        supported_kinds = M.supported_kinds(),
        experimental_kinds = M.experimental_kinds(),
        kind_stability = vim.deepcopy(kind_stability),
        methods = vim.deepcopy(methods),
        result_contract = M.result_contract(),
        structural_results = M.structural_results(),
        fixture_cases = M.fixture_cases(),
        conformance_cases = M.conformance_cases(),
        conformance_matrix = M.conformance_matrix(),
    }
end

function M.normalize_kind(kind)
    if type(kind) ~= "string" or kind == "" then
        error("typst.nvim: provider kind must be a non-empty string")
    end

    local normalized = aliases[kind]
    if not normalized then
        error(("typst.nvim: unknown provider kind: %s"):format(kind))
    end

    return normalized
end

return M
