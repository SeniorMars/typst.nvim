local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local package_provider = require("typst.package.cache")
local registry_scan = require("typst.package.registry_scan")
local typst = require("typst")
local util = require("typst.core.util")

local uv = vim.uv or vim.loop
local old_package_cache_path = vim.env.TYPST_PACKAGE_CACHE_PATH
local package_cache_dir = typst_test_cache_path("package-cache")
vim.fn.delete(package_cache_dir, "rf")

local function write_package_version(name, version)
    local dir = ("%s/preview/%s/%s"):format(package_cache_dir, name, version)
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile({
        "[package]",
        ('name = "%s"'):format(name),
        ('version = "%s"'):format(version),
        'entrypoint = "lib.typ"',
        ('description = "%s %s fixture."'):format(name, version),
    }, dir .. "/typst.toml")
    vim.fn.writefile(
        { ("#let package-version = %q"):format(version) },
        dir .. "/lib.typ"
    )
end

local function write_unsafe_resource_package()
    local dir = ("%s/preview/unsafe-resources/1.0.0"):format(package_cache_dir)
    local outside_dir = ("%s/preview/unsafe-resources/outside"):format(
        package_cache_dir
    )
    vim.fn.mkdir(dir, "p")
    vim.fn.mkdir(outside_dir, "p")
    vim.fn.writefile({ "#let safe = true" }, dir .. "/lib.typ")
    vim.fn.writefile({ "#let escaped = true" }, outside_dir .. "/lib.typ")
    vim.fn.writefile({ "# Escaped manual" }, outside_dir .. "/manual.md")
    vim.fn.writefile({ "#let escaped-api = true" }, outside_dir .. "/api.typ")
    vim.fn.writefile({ "# Escaped README" }, outside_dir .. "/README.md")

    local function link_hint(name, target)
        if not uv.fs_symlink then
            return nil
        end

        local link = dir .. "/" .. name
        local ok = pcall(uv.fs_symlink, target, link)
        if ok or vim.fn.filereadable(link) == 1 then
            return name
        end
    end

    local manual_hint = link_hint(
        "linked-manual.md",
        outside_dir .. "/manual.md"
    ) or "../outside/manual.md"
    local api_hint = link_hint("linked-api.typ", outside_dir .. "/api.typ")
        or "../outside/api.typ"
    local extra_hint = link_hint("linked-extra.md", outside_dir .. "/README.md")
        or "../outside/extra.md"
    local entrypoint_hint = link_hint(
        "linked-lib.typ",
        outside_dir .. "/lib.typ"
    ) or "../outside/lib.typ"

    vim.fn.writefile({
        "[package]",
        'name = "unsafe-resources"',
        'version = "1.0.0"',
        ('entrypoint = "%s"'):format(entrypoint_hint),
        'description = "Unsafe resource fixture."',
        "",
        "[tool.typst-docs]",
        ('manual = "%s"'):format(manual_hint),
        ('api = "%s"'):format(api_hint),
        ('extra = "%s"'):format(extra_hint),
    }, dir .. "/typst.toml")

    local readme_link = dir .. "/README.md"
    if vim.fn.filereadable(readme_link) ~= 1 and uv.fs_symlink then
        pcall(uv.fs_symlink, outside_dir .. "/README.md", readme_link)
    end
end

write_package_version("order-fixture", "0.9.0")
write_package_version("order-fixture", "0.10.0-rc.1")
write_package_version("order-fixture", "0.10.0")
write_package_version("prerelease-fixture", "1.0.0-alpha.9")
write_package_version("prerelease-fixture", "1.0.0-alpha.10")
write_package_version("prerelease-fixture", "1.0.0-beta.1")
write_unsafe_resource_package()

vim.env.TYPST_PACKAGE_CACHE_PATH = package_cache_dir
    .. (util.is_windows() and ";" or ":")
    .. root
    .. "/tests/fixtures/packages"

typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("package-output"),
})
local function place_on(needle)
    for row, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
        local col = line:find(needle, 1, true)
        if col then
            vim.api.nvim_win_set_cursor(0, { row, col - 1 })
            return line, col - 1
        end
    end
    error("fixture missing text: " .. needle)
end

local function package_versions(records, package_name)
    local versions = {}
    for _, record in ipairs(records) do
        if record.name == package_name then
            versions[#versions + 1] = record.version
        end
    end
    return versions
end

local package_records = package_provider.cached_packages({
    roots = { package_cache_dir },
    max = 50,
})
assert(
    vim.deep_equal(
        package_versions(package_records, "order-fixture"),
        { "0.9.0", "0.10.0-rc.1", "0.10.0" }
    ),
    "cached packages should list versions in semantic order"
)
assert(
    vim.deep_equal(
        package_versions(package_records, "prerelease-fixture"),
        { "1.0.0-alpha.9", "1.0.0-alpha.10", "1.0.0-beta.1" }
    ),
    "cached packages should order prerelease identifiers semantically"
)
package_records[1].name = "mutated"
local fresh_package_records = package_provider.cached_packages({
    roots = { package_cache_dir },
    max = 50,
})
assert(
    package_versions(fresh_package_records, "order-fixture")[1] == "0.9.0",
    "cached package records should be returned as copies"
)
local unsafe_cached_record
for _, record in ipairs(package_records) do
    if record.name == "unsafe-resources" then
        unsafe_cached_record = record
        break
    end
end
assert(
    unsafe_cached_record,
    "unsafe resource fixture should be present in cached package records"
)
unsafe_cached_record.resource_hint_errors.manual = "mutated"
local fresh_unsafe_cached_record
for _, record in
    ipairs(package_provider.cached_packages({
        roots = { package_cache_dir },
        max = 50,
    }))
do
    if record.name == "unsafe-resources" then
        fresh_unsafe_cached_record = record
        break
    end
end
assert(
    fresh_unsafe_cached_record.resource_hint_errors.manual
        == "typst_docs_manual_outside_package",
    "cached package records should return nested data as copies"
)

local named_records = package_provider.cached_packages({
    roots = { package_cache_dir },
    max = 50,
    namespace = "preview",
    name = "order-fixture",
})
assert(
    vim.deep_equal(
        package_versions(named_records, "order-fixture"),
        { "0.9.0", "0.10.0-rc.1", "0.10.0" }
    ),
    "cached packages should support indexed package-name lookups"
)

write_package_version("installed-after-cache", "0.1.0")
local refreshed_records = package_provider.cached_packages({
    roots = { package_cache_dir },
    max = 50,
    force_refresh = true,
})
assert(
    vim.deep_equal(
        package_versions(refreshed_records, "installed-after-cache"),
        { "0.1.0" }
    ),
    "cached package listing should notice newly installed packages"
)
local prefix_records = package_provider.cached_packages({
    roots = { package_cache_dir },
    max = 50,
    prefix = "@preview/installed",
})
assert(
    #prefix_records == 1 and prefix_records[1].name == "installed-after-cache",
    "cached packages should support indexed prefix lookups"
)
local limited_prefix_records = package_provider.cached_packages({
    roots = { package_cache_dir },
    max = 1,
    prefix = "@preview/installed",
})
assert(
    #limited_prefix_records == 1
        and limited_prefix_records[1].name == "installed-after-cache",
    "cached package limits should apply after deterministic prefix filtering"
)
local ordered_prefix_records = package_provider.cached_packages({
    roots = { package_cache_dir },
    max = 50,
    prefix = "@preview/order-fixture",
})
assert(
    vim.deep_equal(
        package_versions(ordered_prefix_records, "order-fixture"),
        { "0.9.0", "0.10.0-rc.1", "0.10.0" }
    ),
    "cached package prefix lookups should preserve semantic version ordering"
)

local original_root_signatures = registry_scan.root_signatures
local original_scan_roots = registry_scan.scan_roots
local scan_calls = 0
rawset(registry_scan, "root_signatures", function(...)
    scan_calls = scan_calls + 1
    error("memory-only package read should not calculate root signatures")
end)
rawset(registry_scan, "scan_roots", function(...)
    scan_calls = scan_calls + 1
    error("memory-only package read should not scan package roots")
end)
local ok_memory_only, memory_only_prefix_records =
    pcall(package_provider.cached_packages, {
        roots = { package_cache_dir },
        max = 50,
        memory_only = true,
        prefix = "@preview/order-fixture",
        schedule_refresh = false,
    })
registry_scan.root_signatures = original_root_signatures
registry_scan.scan_roots = original_scan_roots
assert(
    ok_memory_only,
    "memory-only package cache read should not rescan roots: "
        .. tostring(memory_only_prefix_records)
)
assert(
    scan_calls == 0
        and vim.deep_equal(
            package_versions(memory_only_prefix_records, "order-fixture"),
            { "0.9.0", "0.10.0-rc.1", "0.10.0" }
        ),
    "completion-path package cache reads should be pure in-memory lookups"
)

local unversioned =
    typst.package.info({ query = "@preview/order-fixture", open = false })
assert(
    unversioned.package.version == "0.10.0",
    "unversioned package lookup should select the newest stable version"
)

local prerelease_only =
    typst.package.info({ query = "@preview/prerelease-fixture", open = false })
assert(
    prerelease_only.package.version == "1.0.0-beta.1",
    "unversioned package lookup should select the newest prerelease when no stable version exists"
)

local package_completions =
    require("typst.package").complete("@preview/order-fixture")
assert(
    vim.deep_equal(package_completions, {
        "@preview/order-fixture:0.9.0",
        "@preview/order-fixture:0.10.0-rc.1",
        "@preview/order-fixture:0.10.0",
    }),
    "package completion should display versions in semantic order"
)

local package =
    typst.package.info({ query = "@preview/cetz:0.3.4", open = false })
assert(
    package and package.provider == "package",
    "TypstPackageInfo should resolve cached package resources"
)
assert(
    package.package.version == "0.3.4",
    "package info should expose the exact version"
)
assert(
    package.package.entrypoint == "src/lib.typ",
    "package info should read the manifest entrypoint"
)
assert(
    package.source.path:find("src/lib.typ", 1, true),
    "package info should expose local source"
)
assert(
    package.links.repository == "https://example.test/cetz.git",
    "package info should expose repository links"
)
assert(
    package.links.homepage == "https://example.test/cetz",
    "package info should expose homepage links"
)
assert(
    package.links.online == "https://example.test/cetz/docs",
    "package info should expose resource hint links"
)
assert(
    package.source.api:find("src/lib.typ", 1, true),
    "package info should expose advertised API source"
)
assert(
    package.readme:find("deterministic drawing package", 1, true),
    "package info should include README text"
)
assert(
    package.manuals
        and package.manuals[1].relative == "docs/manual.md"
        and package.manuals[1].advertised,
    "package info should prefer typst.nvim-specific advertised manuals"
)

local readme =
    typst.package.readme({ query = "@preview/cetz:0.3.4", open = false })
assert(
    readme and readme.path:match("README%.md$"),
    "TypstPackageReadme should return cached README metadata"
)

local source =
    typst.package.source({ query = "@preview/cetz:0.3.4", open = false })
assert(
    source and source.path == package.source.path,
    "TypstPackageSource should return package source"
)

local url = typst.package.open({ query = "@preview/cetz:0.3.4", open = false })
assert(
    url == "https://typst.app/universe/package/cetz",
    "TypstPackageOpen should return the Universe package page"
)

local unsafe_resources = typst.package.info({
    query = "@preview/unsafe-resources:1.0.0",
    open = false,
})
assert(
    unsafe_resources and unsafe_resources.provider == "package",
    "unsafe resource fixture should resolve from cache"
)
assert(
    unsafe_resources.package.entrypoint == nil
        and unsafe_resources.package.entrypoint_error
            == "entrypoint_outside_package",
    "package entrypoints outside the package root should be rejected"
)
assert(
    not unsafe_resources.source.path,
    "unsafe package entrypoints should not be exposed as source paths"
)
assert(not typst.package.source({
    query = "@preview/unsafe-resources:1.0.0",
    open = false,
}), "TypstPackageSource should not return entrypoints outside the package root")
assert(
    not unsafe_resources.package.readme,
    "README-like resources outside the package root should be ignored"
)
assert(
    not unsafe_resources.readme,
    "README text should not be read from outside the package root"
)
assert(
    not typst.package.readme({
        query = "@preview/unsafe-resources:1.0.0",
        open = false,
    }),
    "TypstPackageReadme should not return README-like resources outside the package root"
)
assert(
    not unsafe_resources.package.api,
    "unsafe typst-docs API paths should not be exposed"
)
assert(
    not unsafe_resources.source.api,
    "unsafe typst-docs API source paths should not be exposed"
)
assert(
    not unsafe_resources.links.manual,
    "unsafe typst-docs manual paths should not be exposed as links"
)
assert(
    not unsafe_resources.links.api,
    "unsafe typst-docs API paths should not be exposed as links"
)
assert(
    not unsafe_resources.manuals or #unsafe_resources.manuals == 0,
    "manual paths outside the package root should be ignored"
)
assert(
    unsafe_resources.package.resource_hint_errors
        and unsafe_resources.package.resource_hint_errors.manual == "typst_docs_manual_outside_package"
        and unsafe_resources.package.resource_hint_errors.api == "typst_docs_api_outside_package"
        and unsafe_resources.package.resource_hint_errors.extra
            == "typst_docs_extra_outside_package",
    "unsafe typst-docs paths should be tracked as rejected resource hints"
)

local package_fixture = root .. "/tests/fixtures/basic/package-doc.typ"
vim.cmd.edit(package_fixture)
vim.bo.filetype = "typst"
place_on("@preview/cetz")
local cursor_package = typst.package.info({ open = false })
assert(
    cursor_package and cursor_package.id == package.id,
    "TypstPackageInfo should resolve package imports"
)

place_on("canvas[Hello]")
local package_member = typst.package.info({ open = false })
assert(
    package_member and package_member.provider == "package",
    "TypstPackageInfo should resolve package members"
)
assert(
    package_member.kind == "function",
    "package member info should preserve declaration kind"
)
assert(
    package_member.name == "canvas",
    "package member info should expose the exported name"
)
assert(
    package_member.signature == "canvas(body)",
    "package member info should expose source signature"
)
assert(
    package_member.source_comments:find("Draws a fixture canvas", 1, true),
    "package member info should include source comments"
)
assert(
    package_member.semantic == false,
    "package member info should be marked as syntactic fallback"
)
assert(
    package_member.source.path:find("src/lib.typ", 1, true),
    "package member info should expose exact source"
)

place_on("cetz.canvas")
local alias_member = typst.package.info({ open = false })
assert(
    alias_member and alias_member.id == package_member.id,
    "module alias package members should resolve"
)
assert(
    alias_member.qualified_name == "cetz.canvas",
    "module alias info should preserve cursor qualification"
)

place_on("guide[Hello]")
local nested_member = typst.package.info({ open = false })
assert(
    nested_member and nested_member.provider == "package",
    "nested package imports should resolve"
)
assert(
    nested_member.name == "guide",
    "nested package info should expose the leaf declaration name"
)
assert(
    nested_member.signature == "guide(body)",
    "nested package info should use the leaf source signature"
)
assert(
    nested_member.source_comments:find("fixture guide", 1, true),
    "nested package info should include comments"
)
assert(
    nested_member.source.path:find("tools.typ", 1, true),
    "nested package info should expose submodule source"
)

place_on("stamp[Hello]")
local module_value_member = typst.package.info({ open = false })
assert(
    module_value_member and module_value_member.provider == "package",
    "module-value imports should resolve"
)
assert(
    module_value_member.name == "stamp",
    "module-value imports should expose the imported declaration"
)

place_on("tools.stamp")
local wildcard_member = typst.package.info({ open = false })
assert(
    wildcard_member and wildcard_member.provider == "package",
    "wildcard package imports should resolve"
)
assert(
    wildcard_member.qualified_name == "tools.stamp",
    "wildcard info should preserve dotted cursor text"
)

local member_source = typst.package.source({ open = false })
assert(
    member_source and member_source.path == wildcard_member.source.path,
    "TypstPackageSource should return member source"
)

local universe = typst.package.info({
    query = "@preview/missing-fixture:9.9.9",
    open = false,
})
assert(
    universe and universe.provider == "universe",
    "missing packages should fall back to Universe resources"
)
assert(
    universe.links.reference:find("/missing%-fixture", 1, false),
    "Universe fallback should expose package URL"
)

local bare = typst.package.info({ query = "cetz", open = false })
assert(
    bare and bare.provider == "package",
    "explicit package commands may resolve bare preview package names"
)

local rendered = typst.package.info({ query = "@preview/cetz:0.3.4" })
assert(
    rendered and rendered.provider == "package",
    "rendered package info should use cache"
)
local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
assert(
    text:find("## Package", 1, true),
    "package info buffer should include package metadata"
)
assert(
    text:find("## Manuals", 1, true),
    "package info buffer should include manuals"
)
assert(
    text:find("typst%-docs", 1, false) == nil,
    "package info buffer should not present resource hints as a standard"
)
assert(
    text:find("CeTZ Fixture", 1, true),
    "package info buffer should include README content"
)

vim.env.TYPST_PACKAGE_CACHE_PATH = old_package_cache_path
vim.cmd("qa!")
