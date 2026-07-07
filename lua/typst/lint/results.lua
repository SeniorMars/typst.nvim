return require("typst.diagnostics.tool_result").new({
    source = "lint",
    generation_field = "lint_generation",
    stale_message = "A newer lint request finished first",
    publish_failed_message = "Typst lint diagnostics could not be published",
    invalid_result_message = "Lint provider returned no result",
})
