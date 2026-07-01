local M = {}

local aliases = {
    compile = "compiler",
    compiler = "compiler",
    format = "format",
    formatter = "format",
    lint = "lint",
    linter = "lint",
    grammar = "grammar",
    artifact = "export",
    artifacts = "export",
    export = "export",
    exports = "export",
    eval = "eval",
    evaluator = "eval",
    init = "init",
    template = "init",
    templates = "init",
    profile = "profile",
    profiler = "profile",
    test = "test",
    tests = "test",
    bench = "bench",
    benchmark = "bench",
    coverage = "coverage",
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
    grammar = { "grammar", "run" },
    export = { "export", "run" },
    eval = { "eval", "run" },
    init = { "init", "run" },
    profile = { "profile", "run" },
    test = { "test", "run" },
    bench = { "bench", "run" },
    coverage = { "coverage", "run" },
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

local fixture_matrix = {
    "synchronous success",
    "synchronous failure",
    "callback success",
    "callback failure",
    "returned pending handle",
    "raw handle timeout",
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
        id = "raw_handle_timeout",
        label = "raw handle timeout",
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

local result_contract = {
    terminal_fields = {
        "ok",
        "code",
        "reason",
        "message",
        "stopped",
        "forced",
        "orphaned",
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
    grammar = { "diagnostics", "by_buffer" },
    export = { "path", "output", "outputs", "artifacts" },
    render = { "path", "output", "outputs", "artifacts" },
    viewer = { "opened", "path", "output" },
    eval = { "output", "stdout", "stderr", "text", "value", "values" },
    init = { "path", "files", "created", "template", "output" },
    profile = { "output", "stdout", "stderr", "text", "report" },
    test = { "output", "stdout", "stderr", "text", "report" },
    bench = { "output", "stdout", "stderr", "text", "report" },
    coverage = { "output", "stdout", "stderr", "text", "coverage" },
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
        methods = vim.deepcopy(methods),
        result_contract = M.result_contract(),
        structural_results = M.structural_results(),
        fixture_cases = M.fixture_cases(),
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
