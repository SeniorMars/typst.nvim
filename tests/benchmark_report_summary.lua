local M = {}

local function sorted(values)
    table.sort(values)
    return values
end

local function percentile(values, fraction)
    if #values == 0 then
        return 0
    end
    local index = math.ceil(#values * fraction)
    index = math.max(1, math.min(#values, index))
    return values[index]
end

local function read_json(path)
    local ok, decoded =
        pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
    assert(
        ok and type(decoded) == "table",
        "invalid benchmark report: " .. path
    )
    return decoded
end

local function metric_value(metric)
    return metric.p95_ms or metric.elapsed_ms
end

function M.collect(report_root)
    local paths = vim.fn.globpath(report_root, "run-*/*.json", false, true)
    table.sort(paths)
    local grouped = {}
    local runs = {}

    for _, path in ipairs(paths) do
        local run = path:match("/(run%-%d+)/[^/]+%.json$")
            or path:match("\\(run%-%d+)\\[^\\]+%.json$")
            or "run-unknown"
        runs[run] = true
        local report = read_json(path)
        local spec = report.spec or vim.fn.fnamemodify(path, ":t:r")
        for _, metric in ipairs(report.metrics or {}) do
            local value = metric_value(metric)
            if type(value) == "number" then
                local key = spec .. "\0" .. tostring(metric.name)
                grouped[key] = grouped[key]
                    or {
                        spec = spec,
                        name = metric.name,
                        budget_ms = metric.budget_ms,
                        values = {},
                    }
                local item = grouped[key]
                item.values[#item.values + 1] = value
                if metric.budget_ms then
                    item.budget_ms = metric.budget_ms
                end
            end
        end
    end

    local metrics = {}
    for _, item in pairs(grouped) do
        local values = sorted(item.values)
        local max = values[#values] or 0
        metrics[#metrics + 1] = {
            spec = item.spec,
            name = item.name,
            samples = #values,
            min_ms = values[1] or 0,
            p50_ms = percentile(values, 0.50),
            p95_ms = percentile(values, 0.95),
            max_ms = max,
            budget_ms = item.budget_ms,
            worst_ratio = item.budget_ms
                    and item.budget_ms > 0
                    and max / item.budget_ms
                or nil,
        }
    end

    table.sort(metrics, function(left, right)
        if left.spec == right.spec then
            return tostring(left.name) < tostring(right.name)
        end
        return tostring(left.spec) < tostring(right.spec)
    end)
    local run_names = vim.tbl_keys(runs)
    table.sort(run_names)
    return {
        generated_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        report_root = report_root,
        runs = run_names,
        metrics = metrics,
    }
end

function M.write(report_root, output_path)
    local summary = M.collect(report_root)
    output_path = output_path or (report_root .. "/summary.json")
    local ok, err = require("typst.core.util").atomic_writefile({
        vim.json.encode(summary),
    }, output_path)
    assert(ok, "failed to write benchmark summary: " .. vim.inspect(err))
    return summary, output_path
end

return M
