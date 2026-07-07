local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local api_spec = require("typst.api.spec")
local runtime_spec = require("typst.api.runtime_spec")
local runtime_policies = require("typst.api.runtime").policies()

local function namespace(symbol)
    return symbol:match("^([^.]+)%.")
end

local function is_runtime_namespace(symbol)
    local ns = namespace(symbol)
    return ns == "compiler" or ns == "viewer"
end

for _, symbol in ipairs(api_spec.stable_runtime_symbols) do
    if is_runtime_namespace(symbol) then
        assert(
            runtime_spec.by_symbol[symbol] ~= nil,
            "stable runtime API lacks declarative endpoint policy: " .. symbol
        )
    end
end

local seen = {}
for _, endpoint in ipairs(runtime_spec.endpoints) do
    local symbol = endpoint.namespace .. "." .. endpoint.name
    assert(not seen[symbol], "duplicate runtime endpoint: " .. symbol)
    seen[symbol] = true
    assert(
        endpoint.operation == symbol,
        "runtime endpoint operation should match symbol: " .. symbol
    )
    assert(
        endpoint.stable == true or endpoint.experimental == true,
        "runtime endpoint must declare stable or experimental: " .. symbol
    )
    assert(
        endpoint.project ~= nil,
        "runtime endpoint must declare project policy: " .. symbol
    )
    assert(
        type(endpoint.result) == "table",
        "runtime endpoint must declare result policy: " .. symbol
    )

    if endpoint.handler.custom then
        assert(
            type(endpoint.handler.custom) == "string",
            "custom handler must be named: " .. symbol
        )
    else
        assert(
            type(endpoint.handler.module) == "string",
            "runtime endpoint handler must declare module: " .. symbol
        )
        assert(
            type(endpoint.handler.method) == "string",
            "runtime endpoint handler must declare method: " .. symbol
        )
        assert(
            type(endpoint.handler.call) == "string",
            "runtime endpoint handler must declare call style: " .. symbol
        )
        local ok, module = pcall(require, endpoint.handler.module)
        assert(ok, "runtime handler module should load: " .. symbol)
        assert(
            type(module[endpoint.handler.method]) == "function",
            "runtime handler method should exist: " .. symbol
        )
    end
end

for symbol, policy in pairs(runtime_policies) do
    assert(
        type(policy) == "table",
        "runtime policy must be a table: " .. symbol
    )
    if policy.project == false then
        assert(
            policy.operation == symbol,
            "project-free runtime policy must name its operation: " .. symbol
        )
    else
        assert(
            type(policy.operation) == "string" and policy.operation ~= "",
            "project runtime policy must name its operation: " .. symbol
        )
        assert(
            policy.operation == symbol,
            "runtime policy operation should match symbol: " .. symbol
        )
        if policy.passive == true or policy.source_path == true then
            assert(
                policy.create == false,
                "passive/source-path runtime policy must not create projects: "
                    .. symbol
            )
        end
        if policy.create == true then
            assert(
                policy.require_typst == true,
                "project-creating runtime policy must require Typst buffers: "
                    .. symbol
            )
            assert(
                policy.block_pending_resolution == true,
                "project-creating runtime action must block pending import-scan resolution: "
                    .. symbol
            )
        end
    end
end

assert(
    runtime_policies["compiler.status"].passive == true,
    "compiler.status should stay passive"
)
assert(
    runtime_policies["compiler.output"].passive == true,
    "compiler.output should stay passive"
)
assert(
    runtime_policies["viewer.view_inverse"].source_path == true,
    "viewer.view_inverse should use source-path policy"
)
assert(
    runtime_policies["viewer.capabilities"].project == false,
    "viewer.capabilities should avoid project resolution"
)

vim.cmd("qa!")
