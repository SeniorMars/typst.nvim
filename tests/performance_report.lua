local M = {}

local uv = vim.uv or vim.loop
local reports = {}

local function report_dir()
    return vim.env.TYPST_NVIM_PERF_REPORT_DIR
        or typst_test_cache_path("performance-reports")
end

local function percentile(sorted, fraction)
    if #sorted == 0 then
        return 0
    end

    local index = math.ceil(#sorted * fraction)
    index = math.max(1, math.min(#sorted, index))
    return sorted[index]
end

function M.scale()
    return tonumber(vim.env.TYPST_NVIM_PERF_BUDGET_SCALE or "") or 1
end

function M.elapsed_ms(fn)
    collectgarbage("collect")
    local start = uv.hrtime()
    local result = fn()
    return result, (uv.hrtime() - start) / 1000000
end

function M.assert_budget(spec, name, budget_ms, fn)
    local result, elapsed = M.elapsed_ms(fn)
    reports[spec] = reports[spec] or {}
    reports[spec][#reports[spec] + 1] = {
        name = name,
        elapsed_ms = elapsed,
        budget_ms = budget_ms,
        ratio = budget_ms > 0 and elapsed / budget_ms or 0,
    }
    assert(
        elapsed <= budget_ms,
        ("%s exceeded %.1fms budget: %.1fms"):format(name, budget_ms, elapsed)
    )
    print(("%s %.1fms <= %.1fms"):format(name, elapsed, budget_ms))
    return result, elapsed
end

function M.assert_p95_budget(spec, name, budget_ms, samples, fn)
    samples = math.max(1, tonumber(samples) or 1)
    local timings = {}
    local result = nil
    for _ = 1, samples do
        local elapsed
        result, elapsed = M.elapsed_ms(fn)
        timings[#timings + 1] = elapsed
    end

    table.sort(timings)
    local p95 = percentile(timings, 0.95)
    reports[spec] = reports[spec] or {}
    reports[spec][#reports[spec] + 1] = {
        name = name,
        p95_ms = p95,
        budget_ms = budget_ms,
        ratio = budget_ms > 0 and p95 / budget_ms or 0,
        samples = timings,
    }
    assert(
        p95 <= budget_ms,
        ("%s exceeded %.1fms p95 budget: %.1fms"):format(name, budget_ms, p95)
    )
    print(
        ("%s p95 %.1fms <= %.1fms (n=%d)"):format(
            name,
            p95,
            budget_ms,
            #timings
        )
    )
    return result, p95
end

function M.record_metric(spec, metric)
    reports[spec] = reports[spec] or {}
    reports[spec][#reports[spec] + 1] = metric
end

function M.write(spec)
    local metrics = reports[spec] or {}
    local dir = report_dir()
    vim.fn.mkdir(dir, "p")
    local path = ("%s/%s.json"):format(dir, spec)
    local payload = {
        spec = spec,
        generated_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        budget_scale = M.scale(),
        metrics = metrics,
    }
    local ok, err = require("typst.core.util").atomic_writefile({
        vim.json.encode(payload),
    }, path)
    assert(ok, "failed to write performance report: " .. vim.inspect(err))
    return path
end

return M
