local entries = require("typst.runtime.resource_manifest.entries")
local executor = require("typst.runtime.resource_manifest.executor")

local M = {}

M.runtime_hook_entries = entries.runtime_hook_entries
M.cache_reset_entries = entries.cache_reset_entries
M.phases = entries.phases
M.entries = entries.entries

M.reset_runtime_hooks = executor.reset_runtime_hooks
M.reset_cache_entry_results = executor.reset_cache_entry_results
M.reset_cache_entries = executor.reset_cache_entries
M.execute = executor.execute
M.summary = executor.summary

return M
