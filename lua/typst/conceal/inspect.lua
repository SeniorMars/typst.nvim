local conceal_util = require("typst.conceal.util")

local M = {}

local range_text = conceal_util.range_text

local function range_label(range)
    return ("%d:%d-%d:%d"):format(
        range.start_row + 1,
        range.start_col,
        range.end_row + 1,
        range.end_col
    )
end

function M.inspect(bufnr, match)
    if not match then
        vim.notify(
            "No Typst conceal rule under cursor",
            vim.log.levels.WARN,
            { title = "typst.nvim" }
        )
        return nil
    end

    local lines = {
        ("Source:       %s"):format(
            match.source_text or range_text(bufnr, match.source)
        ),
        ("Replacement:  %s"):format(match.replacement),
        ("Resolved:     %s"):format(match.resolved_name),
        ("Symbol ID:    %s"):format(match.symbol_id or "n/a"),
        ("Category:     %s"):format(match.category),
        ("Kind:         %s"):format(match.kind),
        ("Provider:     %s"):format(match.provider),
        ("Version:      %s"):format(match.provider_version or "n/a"),
        ("Rule:         %s"):format(match.rule),
        ("Shadowing:    %s"):format(match.shadowed),
        ("Source range: %s"):format(range_label(match.source)),
        ("Reveal range: %s"):format(range_label(match.reveal)),
    }

    vim.api.nvim_echo(
        vim.tbl_map(function(line)
            return { line, "Normal" }
        end, lines),
        true,
        {}
    )
    return match
end

return M
