local util = require("typst.core.util")
local completion_match = require("typst.completion.match")

local M = {}

function M.trim(value)
    if type(value) ~= "string" then
        return nil
    end

    value = vim.trim(value)
    if value == "" then
        return nil
    end

    return value
end

function M.lower(value)
    return type(value) == "string" and value:lower() or ""
end

function M.starts_with(value, prefix)
    return value:sub(1, #prefix) == prefix
end

---@param items table[] Completion item list to append to.
---@param seen table Seen-key set mutated by this helper.
---@param word string Candidate word.
---@param make_item fun(word:string):table Completion item factory.
---@param opts? {base?:string,key?:any,trim?:boolean,match_word?:string,match?:fun(word:string,base:string|nil):boolean}
---@return boolean added True when an item was appended.
function M.add_unique(items, seen, word, make_item, opts)
    opts = opts or {}
    local candidate = opts.trim ~= false and M.trim(word) or word
    if type(candidate) ~= "string" or candidate == "" then
        return false
    end

    local key = opts.key ~= nil and opts.key or candidate
    if seen[key] then
        return false
    end

    local matcher = opts.match or completion_match.prefix
    if not matcher(opts.match_word or candidate, opts.base) then
        return false
    end

    seen[key] = true
    items[#items + 1] = make_item(candidate)
    return true
end

function M.command_key(command)
    return table.concat(util.command_prefix(command), "\0")
end

function M.first_paragraph(text)
    if type(text) ~= "string" or text == "" then
        return nil
    end

    local paragraph = text:match("^(.-)\n%s*\n") or text
    paragraph = paragraph:gsub("\n", " ")
    return vim.trim(paragraph)
end

function M.info(parts)
    local lines = {}
    local indexes = {}
    for index in pairs(parts or {}) do
        if type(index) == "number" then
            indexes[#indexes + 1] = index
        end
    end
    table.sort(indexes)

    for _, index in ipairs(indexes) do
        local part = parts[index]
        part = M.trim(part)
        if part then
            lines[#lines + 1] = part
        end
    end

    return table.concat(lines, "\n\n")
end

function M.lsp_documentation(documentation)
    if type(documentation) == "string" then
        return documentation
    end

    if type(documentation) == "table" then
        return documentation.value or table.concat(documentation, "\n")
    end
end

function M.lsp_completion_word(item)
    local text_edit = item.textEdit
    if type(text_edit) == "table" then
        return text_edit.newText
            or (text_edit.insert and text_edit.insert.newText)
    end

    return item.insertText or item.label
end

return M
