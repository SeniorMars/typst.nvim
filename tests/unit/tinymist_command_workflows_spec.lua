local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")
typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("tinymist-command-workflows-output"),
})

local original_get_clients = vim.lsp.get_clients
local original_notify = vim.notify
local bufnr

local function wait_until(predicate, message)
    assert(vim.wait(1000, predicate, 10), message)
end

local function flush()
    vim.wait(20, function()
        return false
    end, 1, false)
end

local function line_text(row)
    return vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
end

local function lsp_char(line, byte_col)
    return vim.str_utfindex(line, "utf-16", byte_col)
end

local function text_range(line, needle)
    local start_byte = assert(line:find(needle, 1, true), needle) - 1
    return {
        start_byte = start_byte,
        end_byte = start_byte + #needle,
        lsp = {
            start = {
                line = 0,
                character = lsp_char(line, start_byte),
            },
            ["end"] = {
                line = 0,
                character = lsp_char(line, start_byte + #needle),
            },
        },
    }
end

local function workspace_edit(replacement)
    return {
        changes = {
            [vim.uri_from_bufnr(bufnr)] = {
                {
                    range = {
                        start = { line = 0, character = 0 },
                        ["end"] = { line = 0, character = 6 },
                    },
                    newText = replacement,
                },
            },
        },
    }
end

local function buffer_contains(needle)
    for _, candidate in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(candidate) then
            local ok, lines =
                pcall(vim.api.nvim_buf_get_lines, candidate, 0, -1, false)
            if ok and table.concat(lines, "\n"):find(needle, 1, true) then
                return true
            end
        end
    end
    return false
end

local ok, err = xpcall(function()
    local fixture = root .. "/tests/fixtures/basic/main.typ"
    vim.cmd.edit(fixture)
    vim.bo.filetype = "typst"
    typst.project.attach(0)
    bufnr = vim.api.nvim_get_current_buf()

    local exec_commands = {}
    local code_action_resolves = 0
    local color_presentation_requests = 0
    local on_enter_callbacks = {}

    local fake_client = {
        id = 101,
        name = "tinymist",
        offset_encoding = "utf-16",
        server_capabilities = {
            semanticTokensProvider = {
                full = true,
                legend = {
                    tokenTypes = { "function" },
                    tokenModifiers = {},
                },
            },
        },
    }

    function fake_client:supports_method(method)
        return method == "textDocument/codeAction"
            or method == "codeAction/resolve"
            or method == "textDocument/documentColor"
            or method == "textDocument/colorPresentation"
            or method == "experimental/onEnter"
            or method == "textDocument/semanticTokens/full"
            or method == "textDocument/semanticTokens/range"
    end

    function fake_client:exec_cmd(command)
        exec_commands[#exec_commands + 1] = command
    end

    function fake_client:request(method, params, callback)
        if method == "textDocument/codeAction" then
            callback(nil, {
                {
                    title = "Resolved export command",
                    kind = "quickfix",
                    data = { action = "export" },
                },
                {
                    title = "Replace prefix",
                    kind = "quickfix",
                    edit = workspace_edit("edited"),
                },
            })
            return true, 1
        end

        if method == "codeAction/resolve" then
            code_action_resolves = code_action_resolves + 1
            assert(
                params.title == "Resolved export command",
                "unexpected action passed to resolve"
            )
            callback(
                nil,
                vim.tbl_extend("force", params, {
                    command = {
                        title = "Export PDF",
                        command = "tinymist.exportPdf",
                        arguments = { "pdf" },
                    },
                })
            )
            return true, 2
        end

        if method == "textDocument/documentColor" then
            local line = line_text(0)
            local color = text_range(line, 'rgb("#ff0000")')
            callback(nil, {
                {
                    color = { red = 1, green = 0, blue = 0, alpha = 1 },
                    range = color.lsp,
                },
            })
            return true, 3
        end

        if method == "textDocument/colorPresentation" then
            color_presentation_requests = color_presentation_requests + 1
            local line = line_text(0)
            local color = text_range(line, 'rgb("#ff0000")')
            local extra = text_range(line, "0)")
            assert(
                params.range.start.character == color.lsp.start.character,
                "color presentation did not use the color under the cursor"
            )
            callback(nil, {
                {
                    label = 'rgb("#00ff00")',
                    textEdit = {
                        range = color.lsp,
                        newText = 'rgb("#00ff00")',
                    },
                    additionalTextEdits = {
                        {
                            range = {
                                start = extra.lsp.start,
                                ["end"] = {
                                    line = 0,
                                    character = extra.lsp.start.character + 1,
                                },
                            },
                            newText = "1",
                        },
                    },
                },
            })
            return true, 4
        end

        if method == "experimental/onEnter" then
            on_enter_callbacks[#on_enter_callbacks + 1] = callback
            return true, 10 + #on_enter_callbacks
        end

        error("unexpected Tinymist method: " .. method)
    end

    vim.lsp.get_clients = function(opts)
        if opts and opts.bufnr and opts.bufnr ~= bufnr then
            return {}
        end
        return { fake_client }
    end
    vim.notify = function() end

    assert(
        require("typst.integrations.tinymist.features").supports(
            bufnr,
            "textDocument/semanticTokens/full"
        ),
        "semantic-token capability should be visible through Tinymist client support"
    )

    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "prefix body" })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.cmd("TypstCodeAction")
    wait_until(function()
        return buffer_contains("Resolved export command")
            and buffer_contains("Replace prefix")
    end, "TypstCodeAction did not list Tinymist actions")

    vim.api.nvim_set_current_buf(bufnr)
    vim.cmd("TypstCodeAction 1")
    wait_until(function()
        return #exec_commands == 1
    end, "TypstCodeAction 1 did not resolve and execute the Tinymist command")
    assert(code_action_resolves == 1, "code action was not resolved")
    assert(
        exec_commands[1].command == "tinymist.exportPdf",
        "resolved Tinymist command was not executed"
    )

    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "prefix body" })
    vim.cmd("TypstCodeAction 2")
    wait_until(function()
        return line_text(0) == "edited body"
    end, "TypstCodeAction 2 did not apply the selected workspace edit")

    local color_line = 'é #paint(rgb("#ff0000"), extra: 0)'
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { color_line })
    local color = text_range(color_line, 'rgb("#ff0000")')
    vim.api.nvim_win_set_cursor(0, { 1, color.start_byte + 5 })
    vim.cmd("TypstColorPresentation 1")
    wait_until(
        function()
            return line_text(0) == 'é #paint(rgb("#00ff00"), extra: 1)'
        end,
        "TypstColorPresentation did not apply textEdit plus additionalTextEdits"
    )
    assert(
        color_presentation_requests == 1,
        "Tinymist colorPresentation request was not issued"
    )

    local on_enter_line = "/// doc"
    local insert_pos = {
        line = 0,
        character = lsp_char(on_enter_line, #on_enter_line),
    }
    local on_enter_edit = {
        range = {
            start = insert_pos,
            ["end"] = insert_pos,
        },
        newText = "\n/// ",
    }

    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { on_enter_line })
    vim.api.nvim_win_set_cursor(0, { 1, #on_enter_line })
    vim.cmd("TypstOnEnter")
    wait_until(function()
        return #on_enter_callbacks == 1
    end, "TypstOnEnter did not request experimental/onEnter")
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    on_enter_callbacks[1](nil, { edit = on_enter_edit })
    flush()
    assert(
        #vim.api.nvim_buf_get_lines(bufnr, 0, -1, false) == 1,
        "stale onEnter response should not edit after cursor movement"
    )

    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { on_enter_line })
    vim.api.nvim_win_set_cursor(0, { 1, #on_enter_line })
    vim.cmd("TypstOnEnter")
    wait_until(function()
        return #on_enter_callbacks == 2
    end, "second TypstOnEnter request was not issued")
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "/// changed" })
    on_enter_callbacks[2](nil, { edit = on_enter_edit })
    flush()
    assert(
        line_text(0) == "/// changed"
            and #vim.api.nvim_buf_get_lines(bufnr, 0, -1, false) == 1,
        "stale onEnter response should not edit after buffer changes"
    )

    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { on_enter_line })
    vim.api.nvim_win_set_cursor(0, { 1, #on_enter_line })
    vim.cmd("TypstOnEnter")
    wait_until(function()
        return #on_enter_callbacks == 3
    end, "third TypstOnEnter request was not issued")
    on_enter_callbacks[3](nil, { edit = on_enter_edit })
    wait_until(function()
        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        return #lines == 2 and lines[2] == "/// "
    end, "fresh onEnter response did not apply returned edit")
end, debug.traceback)

vim.lsp.get_clients = original_get_clients
vim.notify = original_notify

if not ok then
    vim.api.nvim_err_writeln(err)
    vim.cmd("cquit")
end

vim.cmd("qa!")
