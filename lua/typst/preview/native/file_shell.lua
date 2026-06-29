local files = require("typst.core.files")
local html = require("typst.preview.native.html")
local session = require("typst.preview.native.session")
local source_maps = require("typst.preview.source_maps")
local util = require("typst.core.util")

local M = {}

local function file_url(path)
    if vim.uri_from_fname then
        return vim.uri_from_fname(path)
    end
    return "file://" .. path:gsub(" ", "%%20")
end

local function write(path, text)
    local ok, err = files.ensure_parent(path)
    if not ok then
        return false, err
    end
    return files.writefile_checked(
        vim.split(text, "\n", { plain = true }),
        path
    )
end

local function state_payload(project, path, generation)
    local metadata = session.output_metadata(path)
    local source_sync = source_maps.route_state(project, {
        output = path,
        generation = generation,
    })
    if source_sync.browser_click then
        source_sync.browser_click = false
        source_sync.available = false
        source_sync.message = "Browser click source sync requires server mode"
        source_sync.transport = "file-shell"
    end
    return {
        ok = true,
        output = path,
        output_url = file_url(path),
        output_name = path and util.basename(path) or nil,
        output_format = metadata.output_format,
        output_kind = metadata.output_kind,
        output_size = metadata.output_size,
        main = project.main,
        root = project.root,
        generation = generation,
        mtime = metadata.mtime,
        source_sync = source_sync,
    }
end

local function write_state(state_path, payload)
    local ok, err = write(state_path, html.file_state(payload))
    if not ok then
        error(("typst.nvim: failed to write preview state: %s"):format(err))
    end
end

function M.write(project, path, browser, id, result)
    local dir = browser.output_dir
    local html_path = util.join(dir, id .. ".html")
    local state_path = util.join(dir, id .. ".state.js")
    local generation = session.generation(result)

    local route = {
        id = id,
        output = path,
        main = project.main,
        root = project.root,
        refresh_ms = browser.refresh_ms,
        state_url = file_url(state_path),
        style = vim.deepcopy(browser.style or {}),
        source_sync = source_maps.route_state(project, {
            output = path,
            generation = generation,
        }),
    }
    local ok, err = write(html_path, html.file_shell(route))
    if not ok then
        error(("typst.nvim: failed to write preview shell: %s"):format(err))
    end

    write_state(state_path, state_payload(project, path, generation))

    return {
        url = file_url(html_path),
        path = html_path,
        state_path = state_path,
        output = path,
        generation = generation,
        style = vim.deepcopy(browser.style or {}),
    }
end

function M.refresh(item, project, path, browser, id, result)
    item = item or M.write(project, path, browser, id, result)
    item.output = path or item.output
    item.generation = session.generation(result)
    write_state(
        item.state_path,
        state_payload(project, item.output, item.generation)
    )
    return item
end

function M.stop(item)
    if not item then
        return true
    end

    local payload = {
        ok = false,
        stopped = true,
        message = "Preview stopped",
    }
    local state_ok, state_err = write(item.state_path, html.file_state(payload))
    local shell_ok, shell_err = write(
        item.path,
        html.stopped_shell("Preview stopped", item.style, item.root)
    )

    if not state_ok then
        return false, state_err
    end
    if not shell_ok then
        return false, shell_err
    end
    return true
end

M.file_url = file_url

return M
