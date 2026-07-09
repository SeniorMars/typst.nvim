local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local telemetry = require("typst.core.telemetry")
local completion = require("typst.completion")

telemetry.reset()

local raw_items = completion.complete({
    context = "raw_language",
    base = "lu",
    limit = 5,
})
assert(
    type(raw_items) == "table",
    "raw-language completion should return items"
)

local markup_items = completion.complete({
    context = "markup",
    base = "tabl",
    include_tinymist = false,
    limit = 5,
})
assert(type(markup_items) == "table", "markup completion should return items")

local metrics = telemetry.snapshot()
assert(
    metrics["completion.complete"] and metrics["completion.complete"].count == 2,
    "completion.complete should record each completion request"
)
assert(
    metrics["completion.source.raw"]
        and metrics["completion.source.raw"].last_fields.context
            == "raw_language",
    "raw-language completion should record raw source timing"
)
assert(
    metrics["completion.source.stdlib"]
        and metrics["completion.source.stdlib"].last_fields.context
            == "markup",
    "markup completion should record stdlib source timing"
)
