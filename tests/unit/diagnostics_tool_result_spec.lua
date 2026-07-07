local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local helper = require("typst.diagnostics.tool_result").new({
    source = "unit-tool",
    generation_field = "tool_generation",
    stale_message = "A newer tool request finished first",
    publish_failed_message = "Unit tool diagnostics could not be published",
    invalid_result_message = "Unit tool provider returned no result",
    normalize_output = function(output, fields)
        if output == "" then
            return output
        end
        if fields.prefix then
            return fields.prefix .. output
        end
        return output
    end,
    output_fields = function(result, provider_name)
        return {
            provider = result.provider or provider_name,
            prefix = result.prefix,
            code = result.code,
        }
    end,
})

local state = {
    root = root,
    main = root .. "/tests/fixtures/basic/main.typ",
    tool_generation = 2,
}

local stale = helper.publish_output(state, "ignored", {
    tool_generation = 1,
})
assert(
    stale.ok == false
        and stale.stale == true
        and stale.reason == "stale_result"
        and stale.generation == 1,
    "tool helper should reject stale generations structurally"
)

local invalid = helper.normalize_provider_result(state, nil, {
    tool_generation = 2,
}, "callback")
assert(
    invalid.ok == false
        and invalid.reason == "invalid_result"
        and invalid.provider == "callback",
    "tool helper should normalize invalid provider returns"
)

local normalized = helper.normalize_provider_result(state, {
    output = "",
    prefix = "unused",
    code = 0,
}, {
    tool_generation = 2,
}, "callback")
assert(
    normalized.ok == true
        and normalized.provider == "callback"
        and normalized.code == 0
        and normalized.diagnostics == 0
        and normalized.buffers == 0,
    "tool helper should preserve provider fields on successful publishes"
)

vim.cmd("qa!")
