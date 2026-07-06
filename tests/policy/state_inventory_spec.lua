local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local function read(path)
    return table.concat(vim.fn.readfile(root .. "/" .. path), "\n")
end

local aliases = {
    attachments = "typst.project.attachments",
    cache_registry = "typst.core.cache_registry",
    config = "typst.config",
    core_lifecycle = "typst.core.lifecycle",
    diagnostics = "typst.diagnostics",
    follow_buffer = "typst.preview.follow_buffer",
    log = "typst.core.log",
    match_query = "typst.conceal.match_query",
    matches = "typst.conceal.matches",
    outputs = "typst.resources.outputs",
    path_leases = "typst.core.path_leases",
    project = "typst.project",
    project_store = "typst.project.store",
    treesitter = "typst.core.treesitter",
}

local function require_name(name)
    if name == "typst" then
        return "typst"
    end
    if aliases[name] then
        return aliases[name]
    end
    if name:sub(1, 6) == "typst." then
        return name
    end
    return "typst." .. name
end

local function split_row(line)
    local cells = {}
    for cell in line:gmatch("|([^|]*)") do
        cells[#cells + 1] = vim.trim(cell)
    end
    return cells
end

local function code_spans(text)
    local spans = {}
    for code in tostring(text or ""):gmatch("`([^`]+)`") do
        spans[#spans + 1] = code
    end
    return spans
end

local function owner_modules(owner_cell)
    local modules = {}
    for _, code in ipairs(code_spans(owner_cell)) do
        modules[#modules + 1] = require_name(code)
    end
    return modules
end

local function module_for_function(target, owners)
    local module_part, method = target:match("^(.*)%.([%w_]+)$")
    if module_part and method then
        return require_name(module_part), method
    end
    if #owners == 1 then
        return owners[1], target
    end
    return nil, nil
end

local doc = read("docs/state.md")
assert(
    doc:find("State Ownership Inventory", 1, true),
    "state inventory should keep its title"
)

for line in doc:gmatch("[^\n]+") do
    if line:match("^| `%S") then
        local cells = split_row(line)
        local owners = owner_modules(cells[1])
        assert(
            #owners > 0,
            "state inventory row should name an owner: " .. line
        )

        for _, module_name in ipairs(owners) do
            local ok, module_or_err = pcall(require, module_name)
            assert(
                ok and type(module_or_err) == "table",
                ("state inventory owner `%s` should be requireable"):format(
                    module_name
                )
            )
        end

        for column = 3, 5 do
            for _, code in ipairs(code_spans(cells[column])) do
                local target = code:match("^([%w_%.]+)%s*%(")
                if target then
                    local module_name, method =
                        module_for_function(target, owners)
                    assert(
                        module_name and method,
                        "state inventory function must name a module or have one owner: "
                            .. code
                    )
                    local module = require(module_name)
                    assert(
                        type(module[method]) == "function",
                        ("state inventory function `%s` should exist on %s"):format(
                            method,
                            module_name
                        )
                    )
                end
            end
        end

        for _, code in ipairs(code_spans(cells[6])) do
            if code:match("_spec%.lua$") then
                local unit = root .. "/tests/unit/" .. code
                local policy = root .. "/tests/policy/" .. code
                assert(
                    vim.fn.filereadable(unit) == 1
                        or vim.fn.filereadable(policy) == 1,
                    "state inventory representative test should exist: " .. code
                )
            end
        end
    end
end

vim.cmd("qa!")
