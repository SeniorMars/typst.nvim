local M = {}

local function first_paragraph(text)
    if type(text) ~= "string" or text == "" then
        return nil
    end

    local paragraph = text:match("^(.-)\n%s*\n") or text
    paragraph = paragraph:gsub("\n", " ")
    return vim.trim(paragraph)
end

local function append_nonempty(lines, value)
    if type(value) == "string" and value ~= "" then
        lines[#lines + 1] = value
    end
end

local function append_markdown(lines, text)
    if type(text) ~= "string" or text == "" then
        return
    end

    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        lines[#lines + 1] = line
    end
end

local function parameter_line(param)
    local name = param.name or "value"
    if param.variadic then
        name = ".." .. name
    end

    local parts = { ("`%s`"):format(name) }
    if param.input then
        parts[#parts + 1] = param.input
    end
    if param.required then
        parts[#parts + 1] = "required"
    end
    if param.default then
        parts[#parts + 1] = "default `" .. param.default .. "`"
    end
    if param.settable then
        parts[#parts + 1] = "settable"
    end

    local docs = first_paragraph(param.docs)
    if docs then
        return ("- %s: %s"):format(table.concat(parts, " · "), docs)
    end

    return "- " .. table.concat(parts, " · ")
end

function M.resource(result)
    local title = result.title
        or result.qualified_name
        or result.name
        or "Typst Package Resources"
    local lines = {
        "# " .. title,
        "",
    }

    append_nonempty(
        lines,
        result.qualified_name and ("`" .. result.qualified_name .. "`") or nil
    )
    if result.provider_name then
        lines[#lines + 1] = result.provider_name
    end
    if result.semantic == false then
        lines[#lines + 1] =
            "Syntactic fallback; semantic resolution was not available."
    end

    if result.signature then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "```typst"
        lines[#lines + 1] = result.signature
        lines[#lines + 1] = "```"
    end

    if result.deprecation then
        lines[#lines + 1] = ""
        lines[#lines + 1] = ("Deprecated: %s"):format(
            result.deprecation.message
        )
    end

    if result.package then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "## Package"
        lines[#lines + 1] = ""
        lines[#lines + 1] = "- Namespace: `"
            .. (result.package.namespace or "preview")
            .. "`"
        if result.package.version then
            lines[#lines + 1] = "- Version: `" .. result.package.version .. "`"
        end
        if result.package.entrypoint then
            lines[#lines + 1] = "- Entrypoint: `"
                .. result.package.entrypoint
                .. "`"
        end
        if result.package.api then
            lines[#lines + 1] = "- API: `" .. result.package.api .. "`"
        end
        if result.package.compiler then
            lines[#lines + 1] = "- Minimum Typst: `"
                .. result.package.compiler
                .. "`"
        end
        if result.package.license then
            lines[#lines + 1] = "- License: `" .. result.package.license .. "`"
        end
        if result.package.root then
            lines[#lines + 1] = "- Cache: `" .. result.package.root .. "`"
        end
    end

    if result.source and result.source.path then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "## Source"
        lines[#lines + 1] = ""
        lines[#lines + 1] = "- Source: `" .. result.source.path .. "`"
        if result.source.manifest then
            lines[#lines + 1] = "- Manifest: `" .. result.source.manifest .. "`"
        end
        if result.source.readme then
            lines[#lines + 1] = "- README: `" .. result.source.readme .. "`"
        end
        if result.source.api then
            lines[#lines + 1] = "- API: `" .. result.source.api .. "`"
        end
    end

    if result.manuals and #result.manuals > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "## Manuals"
        lines[#lines + 1] = ""
        for _, manual in ipairs(result.manuals) do
            lines[#lines + 1] = "- `" .. manual.relative .. "`"
        end
    end

    if result.source_comments then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "## Source Comments"
        lines[#lines + 1] = ""
        append_markdown(lines, result.source_comments)
    elseif result.readme then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "## README"
        lines[#lines + 1] = ""
        append_markdown(lines, result.readme)
    elseif result.resource_text then
        lines[#lines + 1] = ""
        append_markdown(lines, result.resource_text)
    elseif result.resource_note then
        lines[#lines + 1] = ""
        lines[#lines + 1] = result.resource_note
    elseif result.summary then
        lines[#lines + 1] = ""
        lines[#lines + 1] = result.summary
    end

    if result.glyph then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "## Glyph"
        lines[#lines + 1] = ""
        lines[#lines + 1] = result.glyph
    end

    if result.parameters and #result.parameters > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "## Parameters"
        lines[#lines + 1] = ""
        for _, param in ipairs(result.parameters) do
            lines[#lines + 1] = parameter_line(param)
        end
    end

    if result.returns then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "## Returns"
        lines[#lines + 1] = ""
        lines[#lines + 1] = result.returns
    end

    if result.variants and #result.variants > 0 then
        local variants = vim.deepcopy(result.variants)
        table.sort(variants)
        lines[#lines + 1] = ""
        lines[#lines + 1] = "## Variants"
        lines[#lines + 1] = ""
        for index, variant in ipairs(variants) do
            if index > 40 then
                lines[#lines + 1] = ("- ... %d more"):format(
                    #variants - index + 1
                )
                break
            end
            lines[#lines + 1] = "- `" .. variant .. "`"
        end
    end

    if result.links and next(result.links) ~= nil then
        local keys = vim.tbl_keys(result.links)
        table.sort(keys)
        lines[#lines + 1] = ""
        lines[#lines + 1] = "## Links"
        lines[#lines + 1] = ""
        for _, key in ipairs(keys) do
            lines[#lines + 1] = ("- %s: %s"):format(
                key:gsub("^%l", string.upper),
                result.links[key]
            )
        end
    end

    return lines
end

function M.search(results, query)
    local lines = {
        "# Typst Package Resource Search",
        "",
        ("Query: `%s`"):format(query),
        "",
    }

    if #results == 0 then
        lines[#lines + 1] = "No results."
        return lines
    end

    for index, result in ipairs(results) do
        local label = result.qualified_name or result.name or result.id
        local suffix = result.kind or "resource"
        if result.category then
            suffix = suffix .. " · " .. result.category
        end
        lines[#lines + 1] = ("%d. `%s` [%s]"):format(index, label, suffix)
        if result.summary then
            lines[#lines + 1] = "   " .. result.summary
        end
    end

    return lines
end

return M
