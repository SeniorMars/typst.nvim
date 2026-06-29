local M = {}

local tables = require("typst.core.tables")

local uv = vim.uv or vim.loop
local MAX_SAMPLES = 256

local metrics = {}
local unpack = tables.unpack

local function pack(...)
    return {
        n = select("#", ...),
        ...,
    }
end

local function traceback(err)
    if debug and debug.traceback then
        return debug.traceback(err, 2)
    end
    return err
end

local function now_ns()
    if uv and type(uv.hrtime) == "function" then
        return uv.hrtime()
    end
    return math.floor(os.clock() * 1000000000)
end

local function percentile(sorted, fraction)
    if #sorted == 0 then
        return 0
    end

    local index = math.ceil(#sorted * fraction)
    index = math.max(1, math.min(#sorted, index))
    return sorted[index]
end

function M.start()
    return now_ns()
end

function M.record(name, elapsed_ms, fields)
    if type(name) ~= "string" or name == "" then
        return
    end

    elapsed_ms = tonumber(elapsed_ms) or 0
    local metric = metrics[name]
    if not metric then
        metric = {
            count = 0,
            total_ms = 0,
            min_ms = elapsed_ms,
            max_ms = elapsed_ms,
            samples = {},
        }
        metrics[name] = metric
    end

    metric.count = metric.count + 1
    metric.total_ms = metric.total_ms + elapsed_ms
    metric.min_ms = math.min(metric.min_ms, elapsed_ms)
    metric.max_ms = math.max(metric.max_ms, elapsed_ms)
    metric.last_ms = elapsed_ms
    metric.last_fields = type(fields) == "table" and vim.deepcopy(fields) or nil

    metric.samples[#metric.samples + 1] = elapsed_ms
    if #metric.samples > MAX_SAMPLES then
        table.remove(metric.samples, 1)
    end
end

function M.finish(name, started, fields)
    if type(started) ~= "number" then
        return
    end
    M.record(name, (now_ns() - started) / 1000000, fields)
end

function M.time(name, fn, fields)
    local started = M.start()
    local result = pack(xpcall(fn, traceback))
    M.finish(name, started, fields)

    if not result[1] then
        error(result[2], 0)
    end

    return unpack(result, 2, result.n)
end

function M.snapshot()
    local out = {}
    for name, metric in pairs(metrics) do
        local samples = vim.deepcopy(metric.samples or {})
        table.sort(samples)
        out[name] = {
            count = metric.count,
            total_ms = metric.total_ms,
            mean_ms = metric.count > 0 and metric.total_ms / metric.count or 0,
            min_ms = metric.min_ms or 0,
            max_ms = metric.max_ms or 0,
            p50_ms = percentile(samples, 0.50),
            p95_ms = percentile(samples, 0.95),
            last_ms = metric.last_ms or 0,
            last_fields = vim.deepcopy(metric.last_fields),
            sample_count = #samples,
        }
    end
    return out
end

function M.report()
    local lines = {}
    local snapshot = M.snapshot()
    local names = vim.tbl_keys(snapshot)
    table.sort(names)

    for _, name in ipairs(names) do
        local metric = snapshot[name]
        lines[#lines + 1] = ("%s count=%d mean=%.2fms p50=%.2fms p95=%.2fms max=%.2fms"):format(
            name,
            metric.count,
            metric.mean_ms,
            metric.p50_ms,
            metric.p95_ms,
            metric.max_ms
        )
    end

    return lines
end

function M.reset()
    metrics = {}
end

return M
