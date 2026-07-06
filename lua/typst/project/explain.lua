local project_root = require("typst.project.root")
local util = require("typst.core.util")

local M = {}

local stage_labels = {
    root = "root detection",
    buffer_main = "buffer-local main",
    saved_main = "saved explicit main",
    directive = "document directive",
    configured_main = "configured main",
    [".typstmain"] = ".typstmain",
    existing_project_graph = "existing project graph",
    import_scan = "import scan",
    fallback = "fallback",
}

local function rel(path, root)
    if type(path) ~= "string" or path == "" then
        return nil
    end
    return util.relpath(path, root)
end

local function copy_stage(stage)
    local out = {}
    for _, key in ipairs({
        "stage",
        "status",
        "source",
        "root_source",
        "confidence",
        "line_limit",
        "max_files",
        "max_depth",
        "max_entries",
        "settled",
    }) do
        if stage[key] ~= nil then
            out[key] = stage[key]
        end
    end
    out.label = stage_labels[stage.stage] or stage.stage
    out.main = stage.main
    out.root = stage.root
    return out
end

local function stage_detail(stage, root)
    local details = {
        stage.status or "unknown",
    }
    if stage.source then
        details[#details + 1] = "source=" .. stage.source
    end
    if stage.confidence then
        details[#details + 1] = "confidence=" .. stage.confidence
    end
    if stage.main then
        details[#details + 1] = "main=" .. rel(stage.main, root)
    end
    if stage.root then
        details[#details + 1] = "root=" .. rel(stage.root, root)
    end
    if stage.stage == "import_scan" then
        if stage.line_limit then
            details[#details + 1] = ("line_limit=%d"):format(stage.line_limit)
        end
        if stage.max_files then
            details[#details + 1] = ("max_files=%s"):format(stage.max_files)
        end
        if stage.max_entries then
            details[#details + 1] = ("max_entries=%s"):format(stage.max_entries)
        end
    end
    return table.concat(details, " ")
end

local function import_scan_stage(stages)
    for _, stage in ipairs(stages or {}) do
        if stage.stage == "import_scan" then
            return stage
        end
    end
end

local function warning_lines(report)
    local warnings = {}
    if report.main_confidence == "low" then
        warnings[#warnings + 1] =
            "main confidence is low; set :TypstSetMain, vim.b.typst_main, config.main, or .typstmain for deterministic projects"
    end

    local scan = import_scan_stage(report.stages)
    if scan and (scan.status == "not_found" or scan.status == "deferred") then
        warnings[#warnings + 1] = ("import scan is heuristic: it reads only the first %d lines of each candidate and recognizes literal #include/#import paths"):format(
            scan.line_limit or report.import_scan_line_limit or 500
        )
    end
    if report.resolution_pending then
        warnings[#warnings + 1] =
            "resolution is still pending; command-time project lookup can force deferred import scan to settle"
    end
    return warnings
end

---Build a structured project-resolution explanation from live project metadata.
---@param state table Live project state or public snapshot-like table.
---@param bufnr? integer Buffer whose resolution should be explained.
---@param opts? table Explanation options.
---@return table report Structured report safe for public API/tests.
function M.report(state, bufnr, opts)
    opts = opts or {}
    local resolution = nil
    if
        bufnr
        and type(state.resolutions) == "table"
        and type(state.resolutions[bufnr]) == "table"
    then
        resolution = state.resolutions[bufnr]
    end
    resolution = resolution or state.last_resolution or {}

    local stages = {}
    for _, stage in ipairs(resolution.trace or {}) do
        stages[#stages + 1] = copy_stage(stage)
    end
    if #stages == 0 then
        stages[#stages + 1] = {
            stage = "current",
            label = "current resolution",
            status = "matched",
            source = resolution.main_source or state.main_source,
            root_source = resolution.root_source or state.root_source,
            confidence = resolution.main_confidence or state.main_confidence,
            main = state.main,
            root = state.root,
        }
    end

    local report = {
        ok = true,
        project_key = state.key,
        bufnr = bufnr,
        buffer = resolution.buffer,
        root = state.root,
        main = state.main,
        root_source = resolution.root_source or state.root_source,
        main_source = resolution.main_source or state.main_source,
        main_confidence = resolution.main_confidence
            or state.main_confidence
            or "unknown",
        main_confidence_source = resolution.main_confidence_source
            or state.main_confidence_source,
        resolution_pending = resolution.resolution_pending
            or state.resolution_pending,
        import_scan_line_limit = resolution.import_scan_line_limit
            or project_root.import_scan_line_limit(),
        import_scan_stats = project_root._import_scan_stats(),
        stages = stages,
    }
    report.warnings = warning_lines(report)
    if opts.lines ~= false then
        report.lines = M.lines(report)
    end
    return report
end

---Format a project-resolution explanation for command output.
---@param report table Structured report from `M.report`.
---@return string[] lines Human-readable report lines.
function M.lines(report)
    local lines = {
        "typst.nvim project explanation",
        ("  buffer: %s"):format(rel(report.buffer, report.root) or "<unknown>"),
        ("  root:   %s"):format(report.root or "<unknown>"),
        ("  main:   %s"):format(report.main or "<unknown>"),
        ("  root source: %s"):format(report.root_source or "<unknown>"),
        ("  main source: %s"):format(report.main_source or "<unknown>"),
        ("  main confidence: %s"):format(report.main_confidence or "unknown"),
        ("  resolution pending: %s"):format(
            report.resolution_pending or "none"
        ),
        ("  import scan line limit: %d"):format(
            report.import_scan_line_limit or 500
        ),
        "  resolver trace:",
    }
    for _, stage in ipairs(report.stages or {}) do
        lines[#lines + 1] = ("    - %s: %s"):format(
            stage.label or stage.stage or "stage",
            stage_detail(stage, report.root)
        )
    end
    if #report.warnings > 0 then
        lines[#lines + 1] = "  notes:"
        for _, warning in ipairs(report.warnings) do
            lines[#lines + 1] = "    - " .. warning
        end
    end
    return lines
end

return M
