local M = {}

local function trim(value)
    if type(value) ~= "string" then
        return nil
    end

    value = vim.trim(value)
    if value == "" then
        return nil
    end

    return value
end

local function parse_doc_comment(line)
    return line:match("^%s*///%s?(.*)$")
end

local function declaration_name(line)
    return line:match("^%s*#let%s+([%a_][%w_%-]*)%s*%(")
        or line:match("^%s*#let%s+([%a_][%w_%-]*)%s*=")
end

local function declaration_signature(line, name)
    local call = line:match("^%s*#let%s+" .. vim.pesc(name) .. "%s*(%b())")
    if call then
        return name .. call
    end

    return name
end

local function first_paragraph(lines)
    local paragraph = {}
    for _, line in ipairs(lines) do
        local trimmed = vim.trim(line)
        if trimmed == "" then
            if #paragraph > 0 then
                break
            end
        elseif not trimmed:match("^#") then
            paragraph[#paragraph + 1] = trimmed
        end
    end

    if #paragraph == 0 then
        return nil
    end

    return table.concat(paragraph, " ")
end

local function parse_parameters(lines)
    local params = {}
    for _, line in ipairs(lines) do
        local name, docs = line:match("^%s*[-*]%s*`([^`]+)`%s*:%s*(.+)$")
        if name and docs then
            params[#params + 1] = {
                name = name,
                docs = docs,
            }
        end
    end
    return params
end

local function doc_text(lines)
    return trim(table.concat(lines, "\n"))
end

function M.package_typ_files(files, entrypoint)
    local typ_files = {}
    local seen = {}

    local function add(file)
        if file and file.relative:match("%.typ$") and not seen[file.path] then
            seen[file.path] = true
            typ_files[#typ_files + 1] = file
        end
    end

    for _, file in ipairs(files) do
        if file.relative == entrypoint then
            add(file)
            break
        end
    end

    for _, file in ipairs(files) do
        add(file)
    end

    return typ_files
end

function M.scan_member_file(file, member, package_result)
    if vim.fn.filereadable(file.path) ~= 1 then
        return nil
    end

    local leaf = member:match("([%a_][%w_%-]*)$")
    local lines = vim.fn.readfile(file.path)
    local docs = {}
    local doc_start = nil
    for index, line in ipairs(lines) do
        local comment = parse_doc_comment(line)
        if comment ~= nil then
            if #docs == 0 then
                doc_start = index
            end
            docs[#docs + 1] = comment
        else
            local name = declaration_name(line)
            if (name == member or name == leaf) and #docs > 0 then
                local package = package_result.package
                return {
                    id = ("%s.%s"):format(package_result.id, member),
                    kind = line:match(
                        "^%s*#let%s+" .. vim.pesc(name) .. "%s*%("
                    )
                            and "function"
                        or "local",
                    name = name,
                    qualified_name = ("%s.%s"):format(
                        package_result.qualified_name,
                        member
                    ),
                    title = member,
                    signature = declaration_signature(line, name),
                    summary = first_paragraph(docs),
                    source_comments = doc_text(docs),
                    parameters = parse_parameters(docs),
                    package = package,
                    source = {
                        kind = "package",
                        path = file.path,
                        root = package.root,
                        manifest = package.manifest,
                        readme = package.readme,
                        lnum = index,
                        col = 1,
                        doc_lnum = doc_start,
                    },
                    provider = "package",
                    provider_name = "Typst package source comments",
                    links = package_result.links,
                    manuals = package_result.manuals,
                    semantic = false,
                }
            end

            if comment == nil and trim(line) ~= nil then
                docs = {}
                doc_start = nil
            elseif name then
                docs = {}
                doc_start = nil
            end
        end
    end
end

return M
