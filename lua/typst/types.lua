---@meta typst.types

---@class TypstProject
---@field key string Stable registry key built from root and main.
---@field root string Normalized project root path.
---@field main string Normalized Typst main file path.
---@field services TypstProjectServices Per-project service tables.
---@field bufs table<integer, true> Attached buffers.
---@field resolutions table<integer, table> Per-buffer resolution metadata.
---@field last_resolution table? Last project resolution metadata.
---@field root_source string? Source that selected `root`.
---@field main_source string? Source that selected `main`.
---@field compiler_provider TypstProviderBinding? Active compiler binding.
---@field _typst_project_pruned boolean? Registry prune marker used during detach.
---@field _typst_project_pruned_reason string? Reason recorded when pruned.
---@field _typst_project_pruned_event_emitted boolean? Project-pruned event guard.

---@class TypstCompilerResult
---@field ok boolean?
---@field code integer? Process/operation exit code when available.
---@field stdout string?
---@field stderr string?
---@field output string?
---@field path string?
---@field artifacts table[]?
---@field outputs table[]?
---@field diagnostics table?
---@field by_buffer table<integer, table[]>?
---@field stale boolean? Result was superseded by a newer run.
---@field stopped boolean? Operation reached a stop transition.
---@field idle boolean? Stop was requested while no process/watcher was active.
---@field forced boolean? Stop required forced termination.
---@field orphaned boolean? Process could not be confirmed stopped.
---@field watch boolean? Result belongs to a watch cycle or watcher.
---@field cycle integer? Watch cycle number.
---@field generation integer? Compiler generation.
---@field watch_generation integer? Watcher generation.
---@field cycle_generation integer? Watch cycle generation.
---@field reason string?
---@field message string?
---@field error string?
---@field active_output string?
---@field deps_path string?

---@class TypstProviderBinding
---@field provider table
---@field builtin boolean
---@field external boolean
---@field name string?

---@class TypstCompileProvider
---@field compile fun(project:TypstProject|table, callback?:fun(result:TypstCompilerResult), run_config?:table):unknown
---@field start fun(project:TypstProject|table, callback?:fun(result:TypstCompilerResult), run_config?:table):unknown
---@field stop fun(project:TypstProject|table, callback?:fun(result:TypstCompilerResult)):unknown
---@field status fun(project:TypstProject|table):string?
---@field output fun(project:TypstProject|table, run_config?:table):string?
---@field name string?

---@class TypstProjectServices
---@field operations TypstProjectOperationsService
---@field compiler TypstProjectCompilerService
---@field diagnostics TypstProjectDiagnosticsService
---@field preview TypstProjectPreviewService
---@field artifacts TypstProjectArtifactsService
---@field graph TypstProjectGraphService
---@field index TypstProjectIndexService
---@field viewer TypstProjectViewerService
---@field invalidation TypstProjectInvalidationService

---@class TypstProjectServicePatch
---@field clear string[]?
---@field _clear string[]?

---@class TypstProjectOperationRecord
---@field id integer
---@field kind string
---@field generation integer
---@field started_at integer
---@field retained_at integer?
---@field handle any?
---@field result table?

---@class TypstProjectOperationsService
---@field active_by_id table<integer, TypstProjectOperationRecord>
---@field active_by_kind table<string, table<integer, TypstProjectOperationRecord>>
---@field retained_by_id table<integer, TypstProjectOperationRecord>
---@field retained_by_kind table<string, table<integer, TypstProjectOperationRecord>>
---@field generations table<string, integer>
---@field last table<string, table>
---@field next_id integer

---@class TypstProjectCompilerService
---@field status string
---@field generation integer
---@field watch_generation integer
---@field watch_cycle_generation integer
---@field output string?
---@field output_lease table?
---@field process any?
---@field watcher TypstCompilerWatcher?
---@field process_operation table?
---@field watcher_operation table?
---@field stopping_compile table?
---@field last_result TypstCompilerResult?
---@field last_profile string?
---@field last_cwd string?
---@field watch_cycle integer?
---@field watch_cycle_status string?
---@field last_cycle_generation integer?

---@class TypstProjectCompilerServicePatch: TypstProjectServicePatch
---@field status string?
---@field generation integer?
---@field watch_generation integer?
---@field watch_cycle_generation integer?
---@field output string?
---@field output_lease table?
---@field process any?
---@field watcher TypstCompilerWatcher?
---@field process_operation table?
---@field watcher_operation table?
---@field stopping_compile table?
---@field last_result TypstCompilerResult?
---@field last_profile string?
---@field last_cwd string?
---@field watch_cycle integer?
---@field watch_cycle_status string?
---@field last_cycle_generation integer?

---@class TypstProjectDiagnosticsService
---@field buffers table<integer, true>
---@field last table?

---@class TypstProjectDiagnosticsServicePatch: TypstProjectServicePatch
---@field buffers table<integer, true>?
---@field last table?

---@class TypstProjectPreviewService
---@field active boolean
---@field active_backend string?
---@field active_mode string?
---@field active_url string?
---@field active_output string?
---@field active_export table?
---@field active_transport string?
---@field active_shell string?
---@field active_server_port integer?
---@field last_backend string?
---@field last_url string?
---@field last_output string?
---@field last_export table?
---@field last_error table?
---@field last_result table?
---@field stopping boolean?
---@field status string?

---@class TypstProjectPreviewServicePatch: TypstProjectServicePatch
---@field active boolean?
---@field active_backend string?
---@field active_mode string?
---@field active_url string?
---@field active_output string?
---@field active_export table?
---@field active_transport string?
---@field active_shell string?
---@field active_server_port integer?
---@field last_backend string?
---@field last_url string?
---@field last_output string?
---@field last_export table?
---@field last_error table?
---@field last_result table?
---@field stopping boolean?
---@field status string?

---@class TypstProjectArtifactsService
---@field items table[]
---@field output string?
---@field last table?

---@class TypstProjectArtifactsServicePatch: TypstProjectServicePatch
---@field items table[]?
---@field output string?
---@field last table?

---@class TypstProjectGraphService
---@field files table<string, table|boolean>
---@field file_sources table<string, table|string>
---@field dependencies table<string, table|boolean>
---@field dependency_sources table<string, table|string>

---@class TypstProjectGraphServicePatch: TypstProjectServicePatch
---@field files table<string, table|boolean>?
---@field file_sources table<string, table|string>?
---@field dependencies table<string, table|boolean>?
---@field dependency_sources table<string, table|string>?

---@class TypstProjectIndexService
---@field files table<string, table>
---@field bibliographies table<string, table>
---@field graph table
---@field generation integer?
---@field dirty_reason string?

---@class TypstProjectViewerService: table

---@class TypstProjectViewerServicePatch: TypstProjectServicePatch

---@class TypstProjectInvalidationService
---@field generation integer
---@field counters table<string, integer>
---@field subscribers table
---@field history table
---@field last table?

---@class TypstProjectInvalidationServicePatch: TypstProjectServicePatch
---@field generation integer?
---@field counters table<string, integer>?
---@field subscribers table?
---@field history table?
---@field last table?

---@class TypstCompilerWatcher
---@field handle any
---@field operation table?
---@field generation integer
---@field cycle integer?
---@field cycle_generation integer?
---@field current_cycle table?
---@field callback fun(result:TypstCompilerResult)?
---@field output string?
---@field deps_path string?
---@field deps_signature string?
---@field stopping boolean?
---@field exit_cleanup boolean?
---@field stop_callbacks fun(result:TypstCompilerResult)[]?
---@field restart_pending table?
---@field kill_timer userdata?
---@field stdout string?
---@field stderr string?
---@field line_buffers table<string, string>?
---@field stream_queue table[]?
---@field stream_queue_scheduled boolean?
---@field last_cycle_id integer?
---@field last_cycle_generation integer?
---@field last_cycle_status string?
---@field currently_compiling boolean?
---@field watch_output string?
---@field watch_output_wait_ms integer?
---@field watch_structured_args string[]?
---@field typst_version string?
---@field structured_output_seen boolean?
---@field unrecognized_status_lines integer?
---@field last_unrecognized_status_line string?

---@class TypstStoppingCompile
---@field handle any
---@field callbacks fun(result:TypstCompilerResult)[]
---@field deps_path string?
---@field kill_timer userdata?
---@field finished boolean?
---@field exit_cleanup boolean?

---@class TypstCacheRegistryStats
---@field total integer
---@field loaded integer
---@field unloaded integer
---@field reset integer
---@field clear integer
---@field reload integer
---@field optional integer
---@field required integer
---@field entries table[]

local M = {}

return M
