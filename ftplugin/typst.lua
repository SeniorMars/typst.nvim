if vim.b.typst_nvim_no_attach == 1 then
    return
end

if vim.b.did_typst_nvim_ftplugin == 1 then
    return
end

vim.b.did_typst_nvim_ftplugin = 1

local bufnr = vim.api.nvim_get_current_buf()
local undo_command = ('lua require("typst").project.detach(%d)'):format(bufnr)

--- Register ftplugin undo through the shared project detach path.
local function install_undo()
    -- Attach installs options, mappings, autocmds, conceal, and syntax state
    -- through shared lifecycle helpers. Route ftplugin undo through the same
    -- detach path so :setfiletype reloads and plugin teardown restore state in
    -- one place.
    local undo = vim.b[bufnr].undo_ftplugin
    if type(undo) == "string" and undo:find(undo_command, 1, true) then
        return
    end

    vim.b[bufnr].undo_ftplugin = (
        type(undo) == "string" and undo ~= "" and (undo .. " | ") or ""
    ) .. undo_command
end

--- Attach the current Typst buffer when it is still a real filetype buffer.
local function attach()
    if
        not vim.api.nvim_buf_is_valid(bufnr)
        or vim.b[bufnr].did_typst_nvim_ftplugin ~= 1
        or vim.bo[bufnr].filetype ~= "typst"
    then
        return
    end

    local hidden_policy = vim.bo[bufnr].bufhidden
    local hidden_destructively = hidden_policy == "unload"
        or hidden_policy == "delete"
        or hidden_policy == "wipe"
    -- Do not attach transient hidden buffers that Neovim is about to destroy;
    -- project state and buffer-local autocmds would outlive the buffer.
    if hidden_destructively and #vim.fn.win_findbuf(bufnr) == 0 then
        return
    end

    install_undo()
    require("typst").project.attach(bufnr)
end

attach()
vim.schedule(attach)
