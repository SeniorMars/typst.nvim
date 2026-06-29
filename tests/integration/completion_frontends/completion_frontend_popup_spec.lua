local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")

local require_popup = vim.env.TYPST_NVIM_FRONTEND_POPUP_E2E == "1"

local function maybe_require(module)
    local ok, value = pcall(require, module)
    if require_popup then
        assert(ok, module .. " should be installed for frontend popup E2E")
    end
    return ok and value or nil
end

local function callback_result(label)
    return nil,
        {
            items = {
                {
                    label = label,
                    textEdit = {
                        range = {
                            start = { line = 0, character = 1 },
                            ["end"] = { line = 0, character = 5 },
                        },
                        newText = label .. "(${1:value})",
                    },
                    insertTextFormat = vim.lsp.protocol.InsertTextFormat.Snippet,
                    additionalTextEdits = {
                        {
                            range = {
                                start = { line = 0, character = 0 },
                                ["end"] = { line = 0, character = 0 },
                            },
                            newText = '#import "@preview/example:1.0.0"\n',
                        },
                    },
                    command = {
                        title = "resolve",
                        command = "tinymist.resolve",
                    },
                    sortText = "0000",
                },
            },
        }
end

local function setup_buffer()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.bo[bufnr].filetype = "typst"
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "#tabl" })
    vim.api.nvim_win_set_cursor(0, { 1, #"#tabl" })
    return bufnr
end

local function enter_insert(label)
    vim.api.nvim_feedkeys("i", "nt", false)
    assert(
        vim.wait(500, function()
            return vim.api.nvim_get_mode().mode:sub(1, 1) == "i"
        end, 10),
        label .. " popup test should enter insert mode"
    )
end

local function install_tinymist_mock(bufnr)
    local callbacks = {}
    local original_get_clients = vim.lsp.get_clients
    vim.lsp.get_clients = function(opts)
        if not opts or opts.bufnr ~= bufnr then
            return {}
        end
        return {
            {
                name = "tinymist",
                offset_encoding = "utf-16",
                supports_method = function()
                    return true
                end,
                request = function(_, _, _, callback)
                    callbacks[#callbacks + 1] = callback
                    return #callbacks
                end,
            },
        }
    end

    return callbacks,
        function()
            vim.lsp.get_clients = original_get_clients
        end
end

local function cmp_has_entries(cmp)
    return type(cmp.get_entries) == "function"
        and #(cmp.get_entries() or {}) > 0
end

local function result_has_semantic_item(result, label)
    for _, item in ipairs((result or {}).items or {}) do
        if item.label == label then
            return item.textEdit
                and item.insertTextFormat == vim.lsp.protocol.InsertTextFormat.Snippet
                and item.additionalTextEdits
                and item.command
                and item.command.command == "tinymist.resolve"
        end
    end
    return false
end

local function force_cmp_insert_mode()
    local ok, api = pcall(require, "cmp.utils.api")
    if not ok or type(api) ~= "table" then
        return function() end
    end

    local original_suitable = api.is_suitable_mode
    local original_insert = api.is_insert_mode
    api.is_suitable_mode = function()
        return true
    end
    api.is_insert_mode = function()
        return true
    end

    return function()
        api.is_suitable_mode = original_suitable
        api.is_insert_mode = original_insert
    end
end

local function run_cmp_popup()
    local cmp = maybe_require("cmp")
    if not cmp then
        return
    end
    assert(
        type(cmp.setup) == "function" or type(cmp.setup) == "table",
        "nvim-cmp should expose setup()"
    )
    assert(
        type(cmp.complete) == "function",
        "nvim-cmp should expose complete()"
    )
    assert(type(cmp.visible) == "function", "nvim-cmp should expose visible()")
    assert(
        type(cmp.register_source) == "function",
        "nvim-cmp should expose register_source()"
    )

    typst.reset()
    typst.setup({
        root = root,
        completion = {
            include_packages = false,
            include_templates = false,
            include_fonts = false,
        },
    })

    local bufnr = setup_buffer()
    local callbacks, restore_lsp = install_tinymist_mock(bufnr)
    local source_name = "typst_nvim_popup_cmp"
    local restore_cmp_mode = force_cmp_insert_mode()
    local refreshes = 0
    local refreshed_cmp_result = nil
    local source = typst.completion.cmp_source({
        context = "markup",
        bufnr = bufnr,
        limit = 20,
        cmp_refresh = function(_, request_opts)
            refreshes = refreshes + 1
            refreshed_cmp_result = {
                items = typst.completion.cmp(
                    vim.tbl_extend("force", request_opts, { base = "tabl" })
                ),
            }
            cmp.complete({
                reason = cmp.ContextReason and cmp.ContextReason.TriggerOnly
                    or nil,
                config = {
                    sources = {
                        { name = source_name },
                    },
                },
            })
            return true
        end,
    })
    cmp.register_source(source_name, source)
    cmp.setup({
        completion = { autocomplete = false },
        snippet = {
            expand = function() end,
        },
        sources = {
            { name = source_name },
        },
    })
    if cmp.setup.buffer then
        cmp.setup.buffer({
            sources = {
                { name = source_name },
            },
        })
    end

    cmp.complete({
        reason = cmp.ContextReason and cmp.ContextReason.Manual or nil,
        config = {
            sources = {
                { name = source_name },
            },
        },
    })
    assert(
        vim.wait(1000, function()
            return #callbacks == 1 and (cmp.visible() or cmp_has_entries(cmp))
        end, 10),
        "nvim-cmp completion session should open and issue Tinymist request"
    )

    local label = "table-cmp-popup-tinymist"
    callbacks[#callbacks](callback_result(label))
    local refreshed = vim.wait(1000, function()
        return refreshes == 1
    end, 10)
    assert(
        refreshed,
        "nvim-cmp completion session should invoke the frontend refresh path"
    )
    assert(
        result_has_semantic_item(refreshed_cmp_result, label),
        "nvim-cmp adapter output should contain Tinymist edit metadata after refresh"
    )

    pcall(cmp.abort)
    restore_cmp_mode()
    restore_lsp()
end

local function run_blink_popup()
    local blink = maybe_require("blink.cmp")
    if not blink then
        return
    end
    assert(type(blink.setup) == "function", "blink.cmp should expose setup()")
    assert(type(blink.show) == "function", "blink.cmp should expose show()")
    assert(
        type(blink.is_visible) == "function",
        "blink.cmp should expose is_visible()"
    )

    typst.reset()
    typst.setup({
        root = root,
        completion = {
            include_packages = false,
            include_templates = false,
            include_fonts = false,
        },
    })

    local bufnr = setup_buffer()
    local callbacks, restore_lsp = install_tinymist_mock(bufnr)
    local source_name = "typst_nvim_popup_blink"
    local blink_source = typst.completion.blink_source({
        context = "markup",
        bufnr = bufnr,
        limit = 20,
    })
    package.loaded["typst_test.blink_popup_source"] = {
        new = function()
            return blink_source
        end,
    }

    blink.setup({
        keymap = { preset = "none" },
        completion = {
            menu = { auto_show = false },
        },
        sources = {
            default = { source_name },
            providers = {
                [source_name] = {
                    name = "typst.nvim popup",
                    module = "typst_test.blink_popup_source",
                },
            },
        },
    })

    blink.show()
    assert(
        vim.wait(1000, function()
            return #callbacks == 1 and blink.is_visible()
        end, 10),
        "blink.cmp popup should open and issue Tinymist request"
    )

    local label = "table-blink-popup-tinymist"
    callbacks[#callbacks](callback_result(label))
    assert(
        vim.wait(1000, function()
            return blink.is_visible()
        end, 10),
        "blink.cmp popup should remain visible after Tinymist refresh"
    )
    assert(
        vim.wait(1000, function()
            return result_has_semantic_item({
                items = typst.completion.blink({
                    context = "markup",
                    bufnr = bufnr,
                    base = "tabl",
                    limit = 20,
                }),
            }, label)
        end, 10),
        "blink.cmp adapter output should contain Tinymist edit metadata after cache fill"
    )

    pcall(blink.hide)
    restore_lsp()
end

run_cmp_popup()
run_blink_popup()

vim.cmd("qa!")
