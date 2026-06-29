local cache = require("typst.package.cache")
local context = require("typst.package.context")
local info = require("typst.package.info")

local M = {
    context = context,
    cache = cache,
    info = info.info,
    open = info.open,
    readme = info.readme,
    source = info.source,
    resolve = info.resolve,
    complete = info.complete,
    lookup = cache.lookup,
    lookup_member = cache.lookup_member,
    cached_packages = cache.cached_packages,
    prewarm = cache.prewarm,
    package_roots = cache.package_roots,
    parse_spec = cache.parse_spec,
    looks_like = cache.looks_like,
    reset = info.reset,
}

return M
