local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")
local providers = require("typst.integrations.providers")

local matrix_dir = typst_test_root_path("preview-matrix")
vim.fn.mkdir(matrix_dir, "p")
local compile_dir = matrix_dir .. "/compile"
local export_dir = matrix_dir .. "/exports"
local browser_dir = matrix_dir .. "/browser"
vim.fn.mkdir(compile_dir, "p")
vim.fn.mkdir(export_dir, "p")
vim.fn.mkdir(browser_dir, "p")

local target = vim.env.TYPST_NVIM_PREVIEW_MATRIX_TARGET or "browser-server"
local opener = vim.env.TYPST_NVIM_PREVIEW_MATRIX_OPEN
local wait_ms = tonumber(vim.env.TYPST_NVIM_PREVIEW_MATRIX_WAIT_MS) or 120000
local refresh_after_ms = tonumber(
    vim.env.TYPST_NVIM_PREVIEW_MATRIX_REFRESH_AFTER_MS
) or 2500
local stop_after_ms = tonumber(vim.env.TYPST_NVIM_PREVIEW_MATRIX_STOP_AFTER_MS)
    or math.max(wait_ms - 5000, refresh_after_ms + 5000)

local format = target == "viewer" and "pdf" or "svg"
local mode = target == "viewer" and "viewer" or "browser"
local server = target ~= "browser-file"
local main = matrix_dir .. "/main.typ"
local report_path = matrix_dir .. "/report.json"
local source_events = {}
local refreshes = {}
local export_generation = 0
local last_result = nil

local function json(value)
    return vim.json.encode(value)
end

local function write_report(extra)
    local report = vim.tbl_extend("force", {
        target = target,
        mode = mode,
        server = server,
        format = format,
        opener = opener,
        main = main,
        result = last_result,
        refreshes = refreshes,
        source_events = source_events,
    }, extra or {})
    vim.fn.writefile({ json(report) }, report_path)
end

local function write_svg(path)
    export_generation = export_generation + 1
    vim.fn.writefile({
        '<svg xmlns="http://www.w3.org/2000/svg" width="720" height="420" viewBox="0 0 720 420">',
        '<rect width="720" height="420" fill="#f8fafc"/>',
        '<rect x="32" y="32" width="656" height="356" rx="8" fill="#ffffff" stroke="#334155" stroke-width="2"/>',
        '<text x="56" y="105" font-size="34" font-family="sans-serif" fill="#0f172a">typst.nvim preview matrix</text>',
        ('<text x="56" y="160" font-size="24" font-family="sans-serif" fill="#475569">target: %s</text>'):format(
            target
        ),
        ('<text x="56" y="205" font-size="24" font-family="sans-serif" fill="#475569">generation: %d</text>'):format(
            export_generation
        ),
        '<text x="56" y="270" font-size="20" font-family="sans-serif" fill="#0f766e">Click inside this SVG when source sync is enabled.</text>',
        "</svg>",
    }, path)
end

local function write_pdf(path)
    export_generation = export_generation + 1
    vim.fn.writefile({
        "%PDF-1.4",
        "1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj",
        "2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj",
        "3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >> endobj",
        "4 0 obj << /Length 101 >> stream",
        "BT /F1 24 Tf 72 700 Td (typst.nvim preview matrix) Tj 0 -36 Td (viewer target) Tj 0 -36 Td (reload by rerunning harness) Tj ET",
        "endstream endobj",
        "5 0 obj << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> endobj",
        "xref",
        "0 6",
        "0000000000 65535 f ",
        "0000000009 00000 n ",
        "0000000058 00000 n ",
        "0000000115 00000 n ",
        "0000000262 00000 n ",
        "0000000414 00000 n ",
        "trailer << /Size 6 /Root 1 0 R >>",
        "startxref",
        "484",
        "%%EOF",
    }, path)
end

local function open_external(url)
    write_report({ opened = url })
    print("typst.nvim preview matrix opened: " .. url)
    print("report: " .. report_path)
    if not opener or opener == "" then
        return true
    end
    local command = opener:gsub("{url}", vim.fn.shellescape(url))
    vim.fn.jobstart({ vim.o.shell, vim.o.shellcmdflag, command }, {
        detach = true,
    })
    return true
end

local export_provider = {
    name = "preview-matrix-export",
    export = function(_project, opts, callback)
        if opts.format == "pdf" then
            write_pdf(opts.output_path)
        else
            write_svg(opts.output_path)
        end
        local result = {
            ok = true,
            path = opts.output_path,
            artifacts = {
                {
                    path = opts.output_path,
                    format = opts.format or format,
                },
            },
        }
        if callback then
            callback(result)
        end
        return result
    end,
}

local source_map_provider = {
    name = "preview-matrix-source-map",
    browser_inverse = function(_project, request)
        source_events[#source_events + 1] = request
        write_report({ source_event_count = #source_events })
        return {
            ok = true,
            path = main,
            line = 3,
            column = 1,
        }
    end,
}

providers.register("export", "preview-matrix-export", export_provider)
providers.register(
    "source_map",
    "preview-matrix-source-map",
    source_map_provider
)

vim.fn.writefile({
    "= typst.nvim preview matrix",
    "",
    "Click events should resolve back to this line when source sync is active.",
}, main)

typst.reset({ force = true })
typst.setup({
    root = matrix_dir,
    output_dir = compile_dir,
    viewer = {
        open = function(path)
            return open_external(path)
        end,
    },
    preview = {
        native = mode,
        export = {
            mode = "provider",
            provider = "preview-matrix-export",
            output_format = format,
            output_name = target,
            output_dir = export_dir,
        },
        source_maps = {
            provider = "preview-matrix-source-map",
        },
        browser = {
            server = server,
            output_dir = browser_dir,
            open = function(url)
                return open_external(url)
            end,
            export = {
                mode = "inherit",
            },
        },
    },
})
vim.cmd.edit(main)
local project = typst.project.set_main(main)
last_result = typst.viewer.preview({ mode = "document" })
write_report({ opened = last_result })
if mode == "browser" then
    local refresh_timer = assert(vim.uv.new_timer())
    refresh_timer:start(refresh_after_ms, 0, function()
        vim.schedule(function()
            local result =
                require("typst.integrations.typst_preview").refresh(project, {
                    code = 0,
                    generation = 2,
                    cycle = 1,
                })
            refreshes[#refreshes + 1] = result
            write_report({ refreshed = result })
        end)
    end)

    local stop_timer = assert(vim.uv.new_timer())
    stop_timer:start(stop_after_ms, 0, function()
        vim.schedule(function()
            local stopped = typst.viewer.preview_stop({ notify = false })
            write_report({ stopped = stopped })
        end)
    end)
end

print(("keeping matrix session alive for %d ms"):format(wait_ms))
vim.wait(wait_ms, function()
    return false
end, 1000)
write_report({ done = true })
