local core = require("typst.ui.context_menu_core")
local package_provider = require("typst.package.cache")
local semver = require("typst.core.semver")

local M = {}

local function cached_newer_package_versions(package)
    local spec = package_provider.parse_spec(package)
    if not spec or not spec.version then
        return {}
    end

    local versions = {}
    local seen = {}
    for _, record in
        ipairs(package_provider.cached_packages({
            namespace = spec.namespace,
            name = spec.name,
        }))
    do
        if
            record.namespace == spec.namespace
            and record.name == spec.name
            and record.version
            and semver.compare(spec.version, record.version) < 0
            and not seen[record.version]
        then
            seen[record.version] = true
            versions[#versions + 1] = record.version
        end
    end

    semver.sort(versions)
    return versions, spec
end

function M.add_update_action(actions, package, ctx, bufnr)
    if not package or not ctx or ctx.kind ~= "package" or not ctx.range then
        return
    end

    local versions, spec = cached_newer_package_versions(package)
    if not spec or #versions == 0 then
        return
    end

    core.add_action(actions, {
        id = "package_update_version",
        title = ("Update package version for %s"):format(spec.spec),
        kind = "package",
        context = ctx,
        run = function(run_opts)
            run_opts = run_opts or {}
            local function apply_version(version)
                if not version then
                    return nil
                end

                local replacement = ("@%s/%s:%s"):format(
                    spec.namespace,
                    spec.name,
                    version
                )
                local result = core.replace_range(bufnr, ctx.range, replacement)
                if result then
                    core.notify(("Updated package to %s"):format(result))
                end
                return result
            end

            if run_opts.version then
                return apply_version(run_opts.version)
            end

            if run_opts.open == false then
                return vim.deepcopy(versions)
            end

            vim.ui.select(versions, {
                prompt = ("Typst package versions: %s"):format(spec.spec),
                format_item = function(version)
                    return ("@%s/%s:%s"):format(
                        spec.namespace,
                        spec.name,
                        version
                    )
                end,
            }, apply_version)

            return versions
        end,
    })
end

return M
