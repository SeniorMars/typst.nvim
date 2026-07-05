local log = require("typst.core.log")

local M = {}

-- Context action aggregator for cursor-sensitive Typst actions.
--
-- Actions are returned as data with small run closures so callers can show a
-- menu, inspect available actions, or execute with `open = false` in tests/API.

local function context_core()
    return require("typst.ui.context_menu_core")
end

local function package_context()
    return require("typst.package.context")
end

local function package_info()
    return require("typst.package.info")
end

local function package_templates()
    return require("typst.package.templates")
end

local function follow()
    return require("typst.navigation.follow")
end

local function context_completion()
    return require("typst.ui.context_completion")
end

local function context_transforms()
    return require("typst.ui.context_menu_transforms")
end

---Collect symbol-specific context actions.
---@param actions table[] list receiving discovered actions.
---@param ctx table cursor context resolved from package and query parsing.
---@param bufnr integer buffer number.
local function add_symbol_actions(actions, ctx, bufnr)
    local core = context_core()
    local action = require("typst.ui.symbol_variants").action(ctx, {
        bufnr = bufnr,
        replace_range = core.replace_range,
    })
    if action then
        core.add_action(actions, action)
    end
end

--- Collect context actions available at a Typst cursor position.
---@param opts? table Context options, including buffer, position, semantic lookup, and timeout.
---@return TypstContextAction[] actions Actions that can be displayed or executed.
---@return table|nil context Parsed package/query context at the cursor.
---@return TypstFollowTarget|table|nil target Resolved navigation target, if any.
function M.actions(opts)
    opts = opts or {}
    local core = context_core()
    local bufnr = core.normalize_bufnr(opts.bufnr)
    local pos = core.current_context_pos(opts)
    local ctx = package_context().resolve(
        vim.tbl_extend("force", opts, { bufnr = bufnr, pos = pos })
    )
    local target = pos
            and follow().resolve({
                bufnr = bufnr,
                pos = pos,
                semantic = opts.semantic,
                timeout_ms = opts.timeout_ms,
            })
        or nil
    -- Resolve semantic target once and fan it out to bibliography, labels, and
    -- media actions so each action does not re-run Tinymist/index fallback.
    local actions = {}
    local query = core.context_query(ctx)
    local package = core.package_query(ctx, target)

    if ctx and ctx.kind == "package" then
        core.add_action(actions, {
            id = "package_info",
            title = "Open package info",
            kind = "package",
            context = ctx,
            run = function(run_opts)
                run_opts = run_opts or {}
                return package_info().info({
                    query = ctx.query,
                    open = run_opts.open,
                    open_winid = run_opts.open_winid,
                    jump_winid = run_opts.jump_winid,
                    target_winid = run_opts.target_winid,
                })
            end,
        })
    elseif ctx and ctx.kind == "package_member" then
        core.add_action(actions, {
            id = "package_member_info",
            title = ("Show package resource for %s"):format(
                ctx.qualified_name or ctx.query
            ),
            kind = "package",
            context = ctx,
            run = function(run_opts)
                run_opts = run_opts or {}
                return package_info().info({
                    bufnr = bufnr,
                    winid = opts.winid,
                    open = run_opts.open,
                    open_winid = run_opts.open_winid,
                    jump_winid = run_opts.jump_winid,
                    target_winid = run_opts.target_winid,
                })
            end,
        })
    elseif query and require("typst.metadata.symbol_search").lookup(query) then
        core.add_action(actions, {
            id = "symbol_info",
            title = ("Show symbol info for %s"):format(query),
            kind = "symbol",
            context = ctx,
            run = function(run_opts)
                run_opts = run_opts or {}
                return require("typst.metadata.symbol").info({
                    bufnr = bufnr,
                    winid = opts.winid,
                    query = query,
                    open = run_opts.open,
                    open_winid = run_opts.open_winid,
                    jump_winid = run_opts.jump_winid,
                    target_winid = run_opts.target_winid,
                })
            end,
        })
        if ctx then
            add_symbol_actions(actions, ctx, bufnr)
        end
    end

    if package and not (ctx and ctx.kind == "package") then
        core.add_action(actions, {
            id = "package_info",
            title = "Open package info",
            kind = "package",
            context = ctx,
            run = function(run_opts)
                run_opts = run_opts or {}
                return package_info().info({
                    query = package,
                    open = run_opts.open,
                    open_winid = run_opts.open_winid,
                    jump_winid = run_opts.jump_winid,
                    target_winid = run_opts.target_winid,
                })
            end,
        })
    end

    if package then
        require("typst.ui.context_menu_packages").add_update_action(
            actions,
            package,
            ctx,
            bufnr
        )
        package_templates().add(actions, package, {
            add_action = core.add_action,
            notify = core.notify,
            open_file_at = core.open_file_at,
        })
        core.add_action(actions, {
            id = "package_source",
            title = "Open package source",
            kind = "source",
            context = ctx,
            run = function(run_opts)
                run_opts = run_opts or {}
                return package_info().source({
                    query = package,
                    open = run_opts.open,
                    open_winid = run_opts.open_winid,
                    jump_winid = run_opts.jump_winid,
                    target_winid = run_opts.target_winid,
                })
            end,
        })
        core.add_action(actions, {
            id = "package_open",
            title = "Open package page",
            kind = "online",
            context = ctx,
            run = function(run_opts)
                run_opts = run_opts or {}
                return package_info().open({
                    query = package,
                    open = run_opts.open,
                })
            end,
        })
    end

    context_completion().add_color_actions(actions, bufnr, pos)
    context_completion().add_font_actions(actions, bufnr, pos)
    context_transforms().add_heading_actions(actions, bufnr, pos)
    context_transforms().add_equation_actions(actions, bufnr, pos)
    context_completion().add_signature_actions(actions, bufnr, pos)

    if target then
        require("typst.bibliography.actions").add(actions, target, {
            add_action = core.add_action,
            notify = core.notify,
            open_file_at = core.open_file_at,
            open_url = core.open_url,
        })
        require("typst.ui.label_actions").add(actions, target, bufnr, {
            add_action = core.add_action,
            notify = core.notify,
        })
        require("typst.ui.context_references").add_definition_actions(
            actions,
            target,
            bufnr,
            pos,
            opts
        )
        require("typst.ui.context_menu_media").add_path_actions(actions, target)
        require("typst.ui.context_menu_media").add_image_actions(
            actions,
            target
        )

        core.add_action(actions, {
            id = "follow",
            title = core.target_title(target),
            kind = target.kind,
            target = target,
            run = function(run_opts)
                run_opts = run_opts or {}
                return follow().follow({
                    bufnr = bufnr,
                    pos = pos,
                    semantic = opts.semantic,
                    timeout_ms = opts.timeout_ms,
                    open = run_opts.open,
                    open_winid = run_opts.open_winid,
                    jump_winid = run_opts.jump_winid,
                    target_winid = run_opts.target_winid,
                })
            end,
        })
        core.add_action(actions, {
            id = "copy_target",
            title = ("Copy %s"):format(target.kind or "target"),
            kind = "copy",
            target = target,
            run = function()
                return core.copy_target(target)
            end,
        })
    end

    return actions, ctx, target
end

--- Execute one context action returned by `actions`.
---@param action TypstContextAction|nil Action table with a `run` closure.
---@param opts? table Options passed to the action runner.
---@return any result Action-specific result.
function M.execute(action, opts)
    if not action or type(action.run) ~= "function" then
        return nil
    end

    log.add("info", "context action executed", {
        id = action.id,
        title = action.title,
        kind = action.kind,
    })
    return action.run(opts or {})
end

--- Open the context-action picker or return actions for programmatic callers.
---@param opts? table Context options; `open=false` skips UI selection.
---@return TypstContextAction[] actions Actions discovered at the cursor.
---@return table|nil context Parsed package/query context at the cursor.
---@return TypstFollowTarget|table|nil target Resolved navigation target, if any.
function M.open(opts)
    opts = opts or {}
    local actions, ctx, target = M.actions(opts)
    -- `open = false` is the programmatic path: keep the same action discovery
    -- logic without forcing a UI prompt.
    if opts.open == false then
        return actions, ctx, target
    end

    if #actions == 0 then
        context_core().notify(
            "No Typst context actions available",
            vim.log.levels.WARN
        )
        return actions, ctx, target
    end

    vim.ui.select(actions, {
        prompt = "Typst context",
        format_item = function(action)
            return action.title
        end,
    }, function(action)
        if action then
            M.execute(action, opts.action_opts)
        end
    end)
    return actions, ctx, target
end

return M
