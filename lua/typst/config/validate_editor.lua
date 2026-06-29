local keymaps = require("typst.config.keymaps")
local schema = require("typst.config.schema")

local M = {}

local validate_string_list = schema.string_list
local validate_string = schema.string
local validate_tool_provider = schema.tool_provider

local package_semantic_proof_values = {
    auto = true,
    required = true,
    off = true,
}

--- Validate syntax feature configuration.
---@param syntax table `syntax` configuration section.
function M.syntax(syntax)
    if type(syntax) ~= "table" then
        error("typst.nvim: syntax must be a table")
    end

    if type(syntax.package_extensions) ~= "boolean" then
        error("typst.nvim: syntax.package_extensions must be a boolean")
    end

    if
        type(syntax.package_semantic_proof) ~= "string"
        or not package_semantic_proof_values[syntax.package_semantic_proof]
    then
        error(
            'typst.nvim: syntax.package_semantic_proof must be "auto", "required", or "off"'
        )
    end

    validate_string(
        syntax.package_highlight_group,
        "syntax.package_highlight_group"
    )

    if
        type(syntax.package_highlight_priority) ~= "number"
        or syntax.package_highlight_priority < 0
    then
        error(
            "typst.nvim: syntax.package_highlight_priority must be a non-negative number"
        )
    end

    if type(syntax.packages) ~= "table" then
        error("typst.nvim: syntax.packages must be a table")
    end

    for package, spec in pairs(syntax.packages) do
        if type(package) ~= "string" or package == "" then
            error("typst.nvim: syntax.packages keys must be non-empty strings")
        end

        local prefix = ("syntax.packages.%s"):format(package)
        if type(spec) ~= "table" then
            error(("typst.nvim: %s must be a table"):format(prefix))
        end

        if spec.enabled ~= nil and type(spec.enabled) ~= "boolean" then
            error(
                ("typst.nvim: %s.enabled must be a boolean or nil"):format(
                    prefix
                )
            )
        end

        if spec.name ~= nil then
            validate_string(spec.name, ("%s.name"):format(prefix))
        end

        if spec.highlight_group ~= nil then
            validate_string(
                spec.highlight_group,
                ("%s.highlight_group"):format(prefix)
            )
        end

        if spec.capture ~= nil then
            validate_string(spec.capture, ("%s.capture"):format(prefix))
        end

        if
            spec.priority ~= nil
            and (type(spec.priority) ~= "number" or spec.priority < 0)
        then
            error(
                ("typst.nvim: %s.priority must be a non-negative number or nil"):format(
                    prefix
                )
            )
        end

        validate_string_list(spec.members or {}, ("%s.members"):format(prefix))
    end
end

--- Validate completion configuration.
---@param completion table `completion` configuration section.
function M.completion(completion)
    if type(completion) ~= "table" then
        error("typst.nvim: completion must be a table")
    end

    if type(completion.include_packages) ~= "boolean" then
        error("typst.nvim: completion.include_packages must be a boolean")
    end

    if type(completion.include_templates) ~= "boolean" then
        error("typst.nvim: completion.include_templates must be a boolean")
    end

    validate_string_list(
        completion.universe_index_paths,
        "completion.universe_index_paths"
    )

    if type(completion.include_paths) ~= "boolean" then
        error("typst.nvim: completion.include_paths must be a boolean")
    end

    if type(completion.include_csl_styles) ~= "boolean" then
        error("typst.nvim: completion.include_csl_styles must be a boolean")
    end

    validate_string_list(completion.csl_styles, "completion.csl_styles")

    if type(completion.include_raw_languages) ~= "boolean" then
        error("typst.nvim: completion.include_raw_languages must be a boolean")
    end

    validate_string_list(completion.raw_languages, "completion.raw_languages")

    if type(completion.include_colors) ~= "boolean" then
        error("typst.nvim: completion.include_colors must be a boolean")
    end

    validate_string_list(completion.color_names, "completion.color_names")

    if type(completion.include_fonts) ~= "boolean" then
        error("typst.nvim: completion.include_fonts must be a boolean")
    end

    validate_string_list(completion.font_families, "completion.font_families")

    if
        type(completion.font_scan_timeout_ms) ~= "number"
        or completion.font_scan_timeout_ms < 0
    then
        error(
            "typst.nvim: completion.font_scan_timeout_ms must be a non-negative number"
        )
    end

    if
        type(completion.path_scan_max) ~= "number"
        or completion.path_scan_max < 0
    then
        error(
            "typst.nvim: completion.path_scan_max must be a non-negative number"
        )
    end

    if
        type(completion.path_scan_entry_max) ~= "number"
        or completion.path_scan_entry_max < 0
    then
        error(
            "typst.nvim: completion.path_scan_entry_max must be a non-negative number"
        )
    end

    if
        type(completion.path_scan_cache_ms) ~= "number"
        or completion.path_scan_cache_ms < 0
    then
        error(
            "typst.nvim: completion.path_scan_cache_ms must be a non-negative number"
        )
    end

    if
        type(completion.csl_scan_max) ~= "number"
        or completion.csl_scan_max < 0
    then
        error(
            "typst.nvim: completion.csl_scan_max must be a non-negative number"
        )
    end

    if
        type(completion.scan_cache_ttl_ms) ~= "number"
        or completion.scan_cache_ttl_ms < 0
    then
        error(
            "typst.nvim: completion.scan_cache_ttl_ms must be a non-negative number"
        )
    end

    if
        type(completion.package_scan_max) ~= "number"
        or completion.package_scan_max < 0
    then
        error(
            "typst.nvim: completion.package_scan_max must be a non-negative number"
        )
    end

    if
        type(completion.package_cache_ttl_ms) ~= "number"
        or completion.package_cache_ttl_ms < 0
    then
        error(
            "typst.nvim: completion.package_cache_ttl_ms must be a non-negative number"
        )
    end

    if type(completion.package_cache_prewarm) ~= "boolean" then
        error("typst.nvim: completion.package_cache_prewarm must be a boolean")
    end
end

--- Validate picker configuration.
---@param picker table `picker` configuration section.
function M.picker(picker)
    if type(picker) ~= "table" then
        error("typst.nvim: picker must be a table")
    end

    validate_tool_provider(picker.provider, "picker.provider", {
        "auto",
        "ui_select",
        "telescope",
        "fzf_lua",
        "fzf_vim",
        "snacks",
        "custom",
    }, "picker")
    validate_string_list(picker.kinds, "picker.kinds")

    if
        picker.custom ~= nil
        and type(picker.custom) ~= "function"
        and type(picker.custom) ~= "table"
    then
        error("typst.nvim: picker.custom must be a function, table, or nil")
    end

    for _, backend in ipairs({ "telescope", "fzf_lua", "fzf_vim", "snacks" }) do
        if type(picker[backend]) ~= "table" then
            error(("typst.nvim: picker.%s must be a table"):format(backend))
        end
    end
end

--- Validate structural-action configuration.
---@param structural_actions table `structural_actions` configuration section.
function M.structural_actions(structural_actions)
    if type(structural_actions) ~= "table" then
        error("typst.nvim: structural_actions must be a table")
    end

    if
        type(structural_actions.timeout_ms) ~= "number"
        or structural_actions.timeout_ms < 0
    then
        error(
            "typst.nvim: structural_actions.timeout_ms must be a non-negative number"
        )
    end

    if type(structural_actions.patterns) ~= "table" then
        error("typst.nvim: structural_actions.patterns must be a table")
    end

    for name, patterns in pairs(structural_actions.patterns) do
        if type(patterns) ~= "table" then
            error(
                ("typst.nvim: structural_actions.patterns.%s must be a list"):format(
                    name
                )
            )
        end

        for _, pattern in ipairs(patterns) do
            if type(pattern) ~= "string" or pattern == "" then
                error(
                    ("typst.nvim: structural_actions.patterns.%s must contain strings"):format(
                        name
                    )
                )
            end
        end
    end
end

--- Validate fold configuration.
---@param folds table `folds` configuration section.
function M.folds(folds)
    if type(folds) ~= "table" then
        error("typst.nvim: folds must be a table")
    end

    if type(folds.enabled) ~= "boolean" then
        error("typst.nvim: folds.enabled must be a boolean")
    end

    if folds.mode ~= "expr" and folds.mode ~= "manual" then
        error("typst.nvim: folds.mode must be 'expr' or 'manual'")
    end

    if type(folds.foldlevel) ~= "number" or folds.foldlevel < 0 then
        error("typst.nvim: folds.foldlevel must be a non-negative number")
    end

    if type(folds.foldtext) ~= "boolean" then
        error("typst.nvim: folds.foldtext must be a boolean")
    end

    if folds.text ~= nil and type(folds.text) ~= "function" then
        error("typst.nvim: folds.text must be a function or nil")
    end

    for _, name in ipairs({
        "headings",
        "imports",
        "comments",
        "content_blocks",
        "code_blocks",
        "calls",
        "equations",
        "raw_blocks",
        "arrays",
        "dictionaries",
        "bibliography",
    }) do
        if type(folds[name]) ~= "boolean" then
            error(("typst.nvim: folds.%s must be a boolean"):format(name))
        end
    end
end

--- Validate table-of-contents configuration.
---@param toc table `toc` configuration section.
function M.toc(toc)
    if type(toc) ~= "table" then
        error("typst.nvim: toc must be a table")
    end

    if toc.mode ~= "window" and toc.mode ~= "quickfix" then
        error("typst.nvim: toc.mode must be 'window' or 'quickfix'")
    end

    if
        toc.position ~= "left"
        and toc.position ~= "right"
        and toc.position ~= "top"
        and toc.position ~= "bottom"
    then
        error(
            "typst.nvim: toc.position must be 'left', 'right', 'top', or 'bottom'"
        )
    end

    if type(toc.width) ~= "number" or toc.width < 1 then
        error("typst.nvim: toc.width must be a positive number")
    end

    if type(toc.height) ~= "number" or toc.height < 1 then
        error("typst.nvim: toc.height must be a positive number")
    end

    if type(toc.auto_close) ~= "boolean" then
        error("typst.nvim: toc.auto_close must be a boolean")
    end

    if type(toc.follow_cursor) ~= "boolean" then
        error("typst.nvim: toc.follow_cursor must be a boolean")
    end

    if type(toc.highlight_current) ~= "boolean" then
        error("typst.nvim: toc.highlight_current must be a boolean")
    end

    if type(toc.auto_refresh) ~= "boolean" then
        error("typst.nvim: toc.auto_refresh must be a boolean")
    end

    if type(toc.follow_delay_ms) ~= "number" or toc.follow_delay_ms < 0 then
        error("typst.nvim: toc.follow_delay_ms must be a non-negative number")
    end

    if type(toc.refresh_delay_ms) ~= "number" or toc.refresh_delay_ms < 0 then
        error("typst.nvim: toc.refresh_delay_ms must be a non-negative number")
    end

    if type(toc.visible_layers) ~= "table" then
        error("typst.nvim: toc.visible_layers must be a table")
    end

    for layer, visible in pairs(toc.visible_layers) do
        if type(layer) ~= "string" or layer == "" then
            error(
                "typst.nvim: toc.visible_layers keys must be non-empty strings"
            )
        end
        if type(visible) ~= "boolean" then
            error(
                ("typst.nvim: toc.visible_layers.%s must be a boolean"):format(
                    layer
                )
            )
        end
    end

    keymaps.validate_toc(toc.mappings)
end

--- Validate indentation configuration.
---@param indent table `indent` configuration section.
function M.indent(indent)
    if type(indent) ~= "table" then
        error("typst.nvim: indent must be a table")
    end

    if type(indent.enabled) ~= "boolean" then
        error("typst.nvim: indent.enabled must be a boolean")
    end

    if type(indent.formatexpr) ~= "boolean" then
        error("typst.nvim: indent.formatexpr must be a boolean")
    end
end

--- Validate matchparen configuration.
---@param matchparen table `matchparen` configuration section.
function M.matchparen(matchparen)
    if type(matchparen) ~= "table" then
        error("typst.nvim: matchparen must be a table")
    end

    if type(matchparen.enabled) ~= "boolean" then
        error("typst.nvim: matchparen.enabled must be a boolean")
    end
end

--- Validate insert-mapping configuration.
---@param imaps table `imaps` configuration section.
function M.imaps(imaps)
    if type(imaps) ~= "table" then
        error("typst.nvim: imaps must be a table")
    end

    if type(imaps.enabled) ~= "boolean" then
        error("typst.nvim: imaps.enabled must be a boolean")
    end

    if type(imaps.builtins) ~= "boolean" then
        error("typst.nvim: imaps.builtins must be a boolean")
    end

    if type(imaps.mappings) ~= "table" then
        error("typst.nvim: imaps.mappings must be a list")
    end

    for index, entry in ipairs(imaps.mappings) do
        local prefix = ("imaps.mappings[%d]"):format(index)
        if type(entry) ~= "table" then
            error(("typst.nvim: %s must be a table"):format(prefix))
        end
        validate_string(entry.lhs, ("%s.lhs"):format(prefix))
        if type(entry.rhs) ~= "string" and type(entry.rhs) ~= "function" then
            error(
                ("typst.nvim: %s.rhs must be a string or function"):format(
                    prefix
                )
            )
        end
        if entry.modes ~= nil then
            validate_string_list(entry.modes, ("%s.modes"):format(prefix))
        end
        if entry.condition ~= nil and type(entry.condition) ~= "function" then
            error(
                ("typst.nvim: %s.condition must be a function or nil"):format(
                    prefix
                )
            )
        end
        if entry.priority ~= nil and type(entry.priority) ~= "number" then
            error(
                ("typst.nvim: %s.priority must be a number or nil"):format(
                    prefix
                )
            )
        end
        if entry.description ~= nil then
            validate_string(
                entry.description,
                ("%s.description"):format(prefix)
            )
        end
    end
end

--- Validate edit/navigation mapping configuration.
---@param mappings table `mappings` configuration section.
function M.mappings(mappings)
    keymaps.validate(mappings)
end

--- Validate log configuration.
---@param log table `log` configuration section.
function M.log(log)
    if type(log) ~= "table" then
        error("typst.nvim: log must be a table")
    end

    if type(log.max_entries) ~= "number" or log.max_entries < 0 then
        error("typst.nvim: log.max_entries must be a non-negative number")
    end
end

return M
