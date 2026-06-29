local manifest_reader = require("typst.package.manifest")
local registry = require("typst.package.registry")
local resources = require("typst.package.resources")
local semver = require("typst.core.semver")
local util = require("typst.core.util")

local M = {}

local uv = vim.uv or vim.loop

-- Local Typst package resolver.
--
-- Prefer cached package metadata when the Typst package cache exists, but keep a
-- useful Universe-link result when the package is not installed locally.

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

local scan_files = resources.scan_files
local package_resource_file = resources.package_resource_file
local detect_readme = resources.detect_readme
local detect_manuals = resources.detect_manuals
local local_doc_file = resources.local_doc_file
local sanitize_resource_hints = resources.sanitize_resource_hints
local add_advertised_manual = resources.add_advertised_manual
local read_text_file = resources.read_text_file
local summary_from_readme = resources.summary_from_readme
local package_typ_files = resources.package_typ_files
local scan_member_file = resources.scan_member_file

function M.package_roots()
    return registry.package_roots()
end

function M.parse_spec(query)
    query = trim(query)
    if not query then
        return nil
    end

    query = query:gsub("[\"']", "")
    query = query:gsub("^#import%s+", "")

    local namespace, name, version =
        query:match("^@([%w_%-]+)/([%w_%-%.]+):([%w_%.%-%+]+)$")
    if not namespace then
        namespace, name, version =
            query:match("^([%w_%-]+)/([%w_%-%.]+):([%w_%.%-%+]+)$")
    end
    if not namespace then
        namespace, name = query:match("^@([%w_%-]+)/([%w_%-%.]+)$")
    end
    if not namespace then
        namespace, name = query:match("^([%w_%-]+)/([%w_%-%.]+)$")
    end
    if not namespace then
        name, version = query:match("^([%w_%-%.]+):([%w_%.%-%+]+)$")
        namespace = name and "preview" or nil
    end
    if not namespace then
        name = query:match("^([%w_%-%.]+)$")
        namespace = name and "preview" or nil
    end

    if not namespace or not name then
        return nil
    end

    return {
        namespace = namespace,
        name = name,
        version = version,
        spec = version and ("@%s/%s:%s"):format(namespace, name, version)
            or ("@%s/%s"):format(namespace, name),
    }
end

function M.looks_like(query)
    return M.parse_spec(query) ~= nil
        and (query:find("@", 1, true) or query:find(":", 1, true)) ~= nil
end

local function package_dir(root, spec)
    if spec.version then
        return util.join(root, spec.namespace, spec.name, spec.version)
    end

    local base = util.join(root, spec.namespace, spec.name)
    local versions = {}
    local scan = uv.fs_scandir(base)
    if not scan then
        return nil
    end

    while true do
        local name, kind = uv.fs_scandir_next(scan)
        if not name then
            break
        end
        if kind == "directory" then
            versions[#versions + 1] = name
        end
    end

    semver.sort(versions)
    local version = versions[#versions]
    if not version then
        return nil
    end

    -- Fill in the concrete version once we choose the newest local package.
    -- Downstream titles, links, and completions should describe the package
    -- version the user can actually inspect.
    spec.version = version
    spec.spec = ("@%s/%s:%s"):format(spec.namespace, spec.name, version)
    return util.join(base, version)
end

local function find_cached_package(spec)
    for _, root in ipairs(M.package_roots()) do
        local dir = package_dir(root, spec)
        if dir and vim.fn.isdirectory(dir) == 1 then
            return dir, root
        end
    end
end

function M.cached_packages(opts)
    return registry.cached_packages(opts)
end

function M.prewarm(opts)
    return registry.prewarm(opts)
end

local function title(name)
    return (name:gsub("^%l", string.upper))
end

local function universe_result(spec)
    return {
        id = ("package.%s.%s.%s"):format(
            spec.namespace,
            spec.name,
            spec.version or "latest"
        ),
        kind = "package",
        name = spec.name,
        qualified_name = spec.spec,
        title = spec.version
                and ("%s %s"):format(title(spec.name), spec.version)
            or title(spec.name),
        summary = "Typst Universe package page.",
        resource_note = "No cached package was found; package resources are limited to Typst Universe links.",
        category = "package",
        package = spec,
        provider = "universe",
        provider_name = "Typst Universe",
        links = {
            reference = "https://typst.app/universe/package/" .. spec.name,
        },
    }
end

local function member_fallback(package_result, member)
    local fallback = vim.deepcopy(package_result)
    fallback.id = ("%s.%s"):format(package_result.id, member)
    fallback.kind = "package_member"
    fallback.name = member
    fallback.qualified_name = ("%s.%s"):format(
        package_result.qualified_name,
        member
    )
    fallback.title = ("%s in %s"):format(
        member,
        package_result.title or package_result.name
    )
    fallback.summary =
        "Package member source comments were not found; showing package resources."
    fallback.semantic = false
    return fallback
end

function M.lookup(query)
    local spec = M.parse_spec(query)
    if not spec then
        return nil
    end

    local dir, cache_root = find_cached_package(spec)
    if not dir then
        -- A missing local cache should not make :TypstPackageInfo useless; the
        -- user can still jump to the package's Universe page.
        return universe_result(spec)
    end

    dir = util.canonical(dir)
    cache_root = cache_root and util.canonical(cache_root) or cache_root
    local manifest_path = util.canonical(util.join(dir, "typst.toml"))
    local manifest = manifest_reader.read(manifest_path)
    local files = scan_files(dir, 3)
    local readme_file = detect_readme(files)
    local readme = read_text_file(readme_file)
    local raw_resource_hints = manifest.typst_docs or {}
    local resource_hints, resource_hint_errors =
        sanitize_resource_hints(dir, raw_resource_hints)
    local manuals = detect_manuals(files)
    local entrypoint_file, entrypoint_error =
        package_resource_file(dir, manifest.entrypoint or "lib.typ", {
            outside_reason = "entrypoint_outside_package",
        })
    local entrypoint = entrypoint_file and entrypoint_file.relative or nil
    local entrypoint_path = entrypoint_file and entrypoint_file.path or nil

    local links = {
        reference = "https://typst.app/universe/package/" .. spec.name,
    }
    if manifest.repository then
        links.repository = manifest.repository
    end
    if manifest.homepage then
        links.homepage = manifest.homepage
    end
    if resource_hints.online and resource_hints.online:match("^https?://") then
        links.online = resource_hints.online
    end

    manuals =
        add_advertised_manual(manuals, dir, raw_resource_hints.manual, links)
    local advertised_api = local_doc_file(dir, raw_resource_hints.api)
    if
        type(raw_resource_hints.api) == "string"
        and raw_resource_hints.api:match("^https?://")
    then
        links.api = raw_resource_hints.api
    end

    local package = vim.tbl_extend("force", spec, {
        name = manifest.name or spec.name,
        version = manifest.version or spec.version,
        namespace = spec.namespace,
        description = manifest.description,
        entrypoint = entrypoint,
        compiler = manifest.compiler,
        license = manifest.license,
        authors = manifest.authors,
        keywords = manifest.keywords,
        categories = manifest.categories,
        root = dir,
        cache_root = cache_root,
        manifest = manifest_path,
        readme = readme_file and readme_file.path or nil,
        api = advertised_api and advertised_api.relative or nil,
        resource_hints = resource_hints,
        resource_hint_errors = next(resource_hint_errors)
                and resource_hint_errors
            or nil,
        entrypoint_error = entrypoint_error ~= "invalid_path"
                and entrypoint_error
            or nil,
        manuals = manuals,
    })

    return {
        id = ("package.%s.%s.%s"):format(
            package.namespace,
            package.name,
            package.version or "latest"
        ),
        kind = "package",
        name = package.name,
        qualified_name = package.version and ("@%s/%s:%s"):format(
            package.namespace,
            package.name,
            package.version
        ) or ("@%s/%s"):format(package.namespace, package.name),
        title = package.version
                and ("%s %s"):format(title(package.name), package.version)
            or title(package.name),
        summary = package.description
            or summary_from_readme(readme)
            or "Cached Typst package.",
        readme = readme,
        resource_text = readme
            or package.description
            or "Cached Typst package.",
        category = "package",
        package = package,
        source = {
            kind = "package",
            path = entrypoint_path,
            root = dir,
            manifest = manifest_path,
            readme = package.readme,
            api = advertised_api and advertised_api.path or nil,
        },
        provider = "package",
        provider_name = "Typst package cache",
        links = links,
        manuals = manuals,
    }
end

function M.lookup_member(ctx)
    if type(ctx) ~= "table" or not ctx.package or not ctx.package.spec then
        return nil
    end

    local member = trim(ctx.query)
    if not member then
        return nil
    end

    local package_result = M.lookup(ctx.package.spec)
    if not package_result then
        return nil
    end
    if package_result.provider ~= "package" then
        return member_fallback(package_result, member)
    end

    local files = scan_files(package_result.package.root, 5)
    -- Member docs are mined from package source comments, not resolved through
    -- Typst itself. Scan the entrypoint first, then the rest of the package, and
    -- fall back to package-level resources when comments are absent.
    for _, file in
        ipairs(package_typ_files(files, package_result.package.entrypoint))
    do
        local result = scan_member_file(file, member, package_result)
        if result then
            if ctx.qualified_name then
                result.qualified_name = ctx.qualified_name
            end
            return result
        end
    end

    return member_fallback(package_result, member)
end

function M.reset()
    registry.reset()
end

return M
