# Public API

This file describes the compatibility surface typst.nvim intends to preserve
while the Lua implementation stabilizes.

The documented surface is covered by `tests/unit/api_symbols_spec.lua`,
`tests/unit/commands_registration_spec.lua`, and
`tests/policy/api_docs_contract_spec.lua`.

## Versioning

`require("typst").api_version()` returns the stable public API level. The
current level is `1`. `require("typst").version()` returns a table containing
that same API level as `api` and `api_version`.
`require("typst").contract()` returns the versioned API/event contract,
including stable root symbols, documented `TypstEvent*` names, compatibility
aliases, and payload field names.

Within API level 1, only the stable functions listed below, command names,
event names, provider kinds, and result-table fields are additive unless the
project explicitly documents a migration. Namespaces can be installed without
being stable as a whole: `project`, `compiler`, and `viewer` are mixed
namespaces with explicit stable entry points, while editing, completion,
artifacts, metadata, providers, navigation, preview helpers, and development
workflows are pre-1.0 experimental unless a dotted symbol is listed in the
stable block. Internal modules under `typst.core`, `typst.resources`,
`typst.project.store`, `typst.project.registry`, `typst.project.services`,
`typst.runtime`, and `typst.internal` can still change unless promoted here.

### Pre-1.0 Tier Narrowing

Earlier drafts of this document described stability at a broad namespace
level. That was pre-freeze wording from the reset phase. API level 1 now uses
explicit dotted symbols as the compatibility source of truth while typst.nvim
remains pre-1.0. The installed namespaces are kept for compatibility, but
helpers such as artifact workflows, completion, editing transforms, metadata,
provider registry helpers, preview helpers, development workflows, and
`reset()` are demoted to experimental unless they appear in the stable symbol
list below. Use `stable_symbols()` and `experimental_symbols()` to audit the
current tier of an installed helper.

## Compatibility Policy

Stable API changes follow these rules:

- Stable symbols are explicit: they must be declared in `typst.api.spec`, not
  inferred from runtime-installed helper functions or namespace membership.
- `typst.api.spec` must assign every installed namespace a tier. Mixed
  namespaces can contain stable symbols, but unlisted methods remain
  experimental.
- Behavioral changes to stable functions, commands, event names, provider
  kinds, or documented result fields require a migration note in this file and
  the help docs.
- Removals or incompatible signature changes require either a compatibility
  alias for one minor release or an explicit API-level bump.
- Experimental symbols may change, but they must stay reported by
  `experimental_symbols()` until they are either promoted to the stable list or
  deliberately removed with a migration note.
- Provider kinds are part of the public API. New provider kinds must update
  `docs/provider-contracts.md`, provider contract tests, and the CI provider
  matrix in the same patch.

The release gate for this policy is `tests/run_api_stability.sh`, which checks
the runtime symbol lists against this document, command docs, alias policy, and
provider contract docs. The broader fake-provider behavior matrix is
`tests/run_provider_matrix.sh` and runs across Linux, macOS, and Windows in CI.

Process-backed async calls return a pending result table with `cancel()`.
Cancelling marks the result as `cancelled` and shuts down the originating
process tree. If shutdown cannot be confirmed, typst.nvim retains an orphaned
operation and settles cancellation callbacks once, while `on_finish()` callbacks
and cleanup wait for the real late process exit. Compiler and watcher runs
remain cancellable through `stop()` and `stop_all()`. External compiler provider
compile/watch/stop timeouts retain output leases until the provider confirms
exit or the user explicitly discards the retained state with
`compiler.force_clear({ key = project_key })` /
`:TypstCompilerForceClear[!] [project-key]`. The Lua `compiler.force_clear`
symbol is experimental while the command/result contract settles. Background
probes that do not return a result table, such as Tinymist completion requests,
package info, font scans, and metadata version detection, are cancelled by their
reset/clear-cache paths.

The Lua force-clear API accepts raw `project.key`, encoded `key_display` with
`key_encoded = true`, or a direct `project` object. The command form should use
the encoded `key_display` copied from `:TypstStatusAll!`, especially for
bufferless retained projects whose raw key may contain spaces, newlines, or path
separators. If Lua code is holding a project object, prefer `project = project`;
it is authoritative even when `key` is also present. Without `key_encoded =
true`, an ambiguous raw/encoded collision returns `ambiguous_project_key`
instead of guessing.

## Source and Destination Windows

Cursor-sensitive APIs use `bufnr`, `winid`, and `pos` only to resolve the
source context. For example, `navigation.follow({ bufnr = b, pos = { row, col }
})` follows the target under that buffer position even when another window is
current. If a non-current buffer is supplied without `pos` or a `winid` that
displays that buffer, source-position APIs return no action or a
`position_required` failure instead of reading the current window by accident.

Opening and jumping use a separate destination contract. File-target actions,
context actions, package/source actions, and viewer/preview inverse jumps open
in the current window by default. Pass `open_winid` to make a specific window
receive the opened file or jump. `jump_winid` and `target_winid` are accepted as
aliases for integration code, but `winid` remains the source-window option.

## Project Context Resolution

Project-scoped public Lua wrappers use one shared context policy. Passive
inspection APIs, such as `compiler.status()`, `compiler.current_output()`,
`viewer.preview_status()`, `project.services()`, and detailed report helpers,
reuse an attached project, an explicit `project`, or an explicit project key
(`key` or `project_key`, with `key_encoded = true` for command-safe encoded
keys). They do not create scratch projects from dashboards, statuslines,
timers, or other non-Typst buffers, and they do not notify by default when no
project exists. Cleanup APIs such as `viewer.clean()` and
`viewer.clean_preview()` also use no-create resolution, but remain action APIs.
Without a project they return `nil, { reason = "no_project", ... }` or a
result table whose `ok` is false and `reason` is `"no_project"`, depending on
the namespace. If an explicit key cannot be resolved, wrappers return
`unknown_project_key` or `ambiguous_project_key` instead of `no_project`.

Action APIs, such as compile, watch, preview, render, export, eval, navigation,
and semantic actions, may resolve or create project state only for Typst source
buffers. Calls from a non-Typst buffer fail closed with the same `no_project`
reason instead of silently compiling an unintended main. Integrations that call
typst.nvim from a dashboard, timer, statusline, or unrelated buffer should pass
`{ bufnr = typst_bufnr }`, `{ project = project }`, or an explicit project key.
`viewer.capabilities()` is project-free; preview capabilities are
project-scoped. Viewer and preview inverse-search wrappers also try
`opts.path`/`opts.source_path` against loaded buffers and existing project
graphs. When an explicit source path is supplied but is not associated with any
loaded buffer or existing project graph, they return
`source_path_not_in_project` instead of falling back to the focused project.

## Stable Entry Points

The supported setup entry point is:

```lua
require("typst").setup({
  -- options
})
```

The supported project attachment entry point is:

```lua
require("typst").project.attach(bufnr)
require("typst").project.detach(bufnr)
print(require("typst").api_version())
```

Flat workflow aliases were removed from the stable Lua API. Use the namespaced
APIs documented below.

The deliberately stable pre-1.0 Lua surface is narrow:

- setup and contract introspection on `require("typst")`;
- project attachment, main-file, project snapshot, cd, reload, and cache
  helpers;
- compiler compile/watch/stop/status/output helpers;
- viewer open, forward/inverse jump, and capability helpers.

No namespace is stable merely because it is installed. Use the symbol lists
below to distinguish stable, experimental, and internal surfaces.

Use `require("typst").stable_symbols()` to inspect the exact stable dotted
symbol list. Use `require("typst").experimental_symbols()` to audit installed
helpers that are intentionally not part of the stable API contract yet.

The following lists are checked in CI against the installed Lua API. Update the
code and this document together when the public symbol surface changes.

### Stable Symbols

<!-- typst.nvim stable-symbols:start -->
- `api_version`
- `compiler.compile`
- `compiler.compile_selected`
- `compiler.current_output`
- `compiler.output`
- `compiler.status`
- `compiler.stop`
- `compiler.stop_all`
- `compiler.watch`
- `contract`
- `experimental_symbols`
- `is_setup`
- `project.attach`
- `project.cd`
- `project.clear_cache`
- `project.detach`
- `project.edit_main`
- `project.get`
- `project.projects`
- `project.reload_state`
- `project.set_main`
- `project.snapshot`
- `project.toggle_main`
- `public_symbols`
- `setup`
- `stable_symbols`
- `version`
- `viewer.capabilities`
- `viewer.view`
- `viewer.view_forward`
- `viewer.view_inverse`
<!-- typst.nvim stable-symbols:end -->

### Experimental Symbols

<!-- typst.nvim experimental-symbols:start -->
- `artifact.clean`
- `artifact.export`
- `artifact.html_preview`
- `artifact.list`
- `artifact.open`
- `artifact.presentation`
- `bibliography.attachment`
- `bibliography.attachments`
- `bibliography.clear_diagnostics`
- `bibliography.diagnostics`
- `bibliography.diagnostics_namespace`
- `bibliography.expanded_fields`
- `bibliography.fields`
- `bibliography.foldexpr`
- `bibliography.indentexpr`
- `bibliography.insert`
- `bibliography.insert_text`
- `bibliography.open`
- `bibliography.parse_bibtex_file`
- `bibliography.parse_hayagriva_file`
- `bibliography.preview`
- `bibliography.rename_key`
- `bibliography.rename_plan`
- `bibliography.search`
- `bibliography.status`
- `compiler.force_clear`
- `completion.blink`
- `completion.blink_source`
- `completion.cmp`
- `completion.cmp_source`
- `completion.complete`
- `completion.native`
- `completion.omnifunc`
- `completion.signature`
- `conceal.custom`
- `conceal.disable`
- `conceal.enable`
- `conceal.inspect`
- `conceal.is_enabled`
- `conceal.refresh`
- `conceal.register`
- `conceal.toggle`
- `conceal.unregister`
- `context.open`
- `development.bench`
- `development.coverage`
- `development.profile`
- `development.test`
- `diagnostics.bibliography`
- `diagnostics.errors`
- `diagnostics.quickfix`
- `edit.add_trailing_comma`
- `edit.change_delimiter`
- `edit.change_delimiter_block`
- `edit.change_delimiter_content`
- `edit.change_delimiter_equation`
- `edit.change_delimiter_group`
- `edit.change_function`
- `edit.convert_equation`
- `edit.convert_raw`
- `edit.create_function`
- `edit.demote_heading`
- `edit.insert`
- `edit.insert_code`
- `edit.insert_content`
- `edit.insert_emph`
- `edit.insert_math`
- `edit.insert_raw`
- `edit.insert_strong`
- `edit.join_arguments`
- `edit.match`
- `edit.name_arguments`
- `edit.next_block`
- `edit.next_block_end`
- `edit.next_comment`
- `edit.next_equation`
- `edit.next_equation_end`
- `edit.next_heading`
- `edit.next_heading_end`
- `edit.next_raw_block`
- `edit.previous_block`
- `edit.previous_block_end`
- `edit.previous_comment`
- `edit.previous_equation`
- `edit.previous_equation_end`
- `edit.previous_heading`
- `edit.previous_heading_end`
- `edit.previous_raw_block`
- `edit.promote_heading`
- `edit.refresh_folds`
- `edit.remove_trailing_comma`
- `edit.select_textobject`
- `edit.smart_close`
- `edit.split_arguments`
- `edit.structural_action`
- `edit.surround`
- `edit.surround_block`
- `edit.surround_change_block`
- `edit.surround_change_call`
- `edit.surround_change_delimiter`
- `edit.surround_change_equation`
- `edit.surround_content`
- `edit.surround_delete_block`
- `edit.surround_delete_call`
- `edit.surround_delete_delimiter`
- `edit.surround_delete_equation`
- `edit.surround_emph`
- `edit.surround_equation`
- `edit.surround_figure`
- `edit.surround_function`
- `edit.surround_strong`
- `edit.toggle_arguments`
- `edit.toggle_bullet_list`
- `edit.toggle_delimiter_size`
- `edit.toggle_emph`
- `edit.toggle_equation_numbering`
- `edit.toggle_figure`
- `edit.toggle_fraction`
- `edit.toggle_label`
- `edit.toggle_label_reference`
- `edit.toggle_line_break`
- `edit.toggle_list`
- `edit.toggle_markup`
- `edit.toggle_numbered_list`
- `edit.toggle_reference`
- `edit.toggle_strong`
- `edit.toggle_trailing_comma`
- `edit.unwrap_function`
- `evaluation.eval`
- `evaluation.inspect`
- `evaluation.selection`
- `imaps.active`
- `imaps.lines`
- `imaps.list`
- `imaps.register`
- `imaps.unregister`
- `index.citations`
- `index.collect`
- `index.definitions`
- `index.glossary_entries`
- `index.headings`
- `index.imports`
- `index.labels`
- `index.mark_dirty`
- `index.paths`
- `index.reset`
- `index.todos`
- `invalidation.emit`
- `invalidation.emit_reason`
- `invalidation.generation`
- `invalidation.snapshot`
- `invalidation.subscribe`
- `match_highlight.disable`
- `match_highlight.enable`
- `match_highlight.is_enabled`
- `match_highlight.refresh`
- `match_highlight.toggle`
- `metadata.available_versions`
- `metadata.catalog`
- `metadata.emoji`
- `metadata.emoji_glyph`
- `metadata.emoji_names`
- `metadata.emoji_variants`
- `metadata.emojis`
- `metadata.shorthands`
- `metadata.signature`
- `metadata.stdlib`
- `metadata.stdlib_complete`
- `metadata.stdlib_constants_by_type`
- `metadata.stdlib_item`
- `metadata.stdlib_param_docs`
- `metadata.symbol`
- `metadata.symbol_deprecation`
- `metadata.symbol_glyph`
- `metadata.symbol_names`
- `metadata.symbol_variants`
- `navigation.citations`
- `navigation.files`
- `navigation.follow`
- `navigation.hover`
- `navigation.labels`
- `navigation.pick`
- `navigation.pick_items`
- `navigation.symbols`
- `navigation.toc`
- `navigation.toc_open`
- `navigation.toc_refresh`
- `navigation.toc_toggle`
- `package.cached_packages`
- `package.info`
- `package.lookup`
- `package.open`
- `package.prewarm`
- `package.readme`
- `package.source`
- `picker.items`
- `picker.open`
- `picker.open_item`
- `picker.pick`
- `project.invalidate`
- `project.invalidation_snapshot`
- `project.on_invalidate`
- `project.operations`
- `project.services`
- `providers.get`
- `providers.has`
- `providers.names`
- `providers.register`
- `providers.unregister`
- `render.cache_clear`
- `render.cache_entries`
- `render.equation`
- `render.fragment`
- `render.image`
- `render.page`
- `report`
- `reset`
- `semantic.code_action`
- `semantic.code_lens`
- `semantic.color_info`
- `semantic.color_presentation`
- `semantic.document_links`
- `semantic.inlay_hints_toggle`
- `semantic.on_enter`
- `semantic.references`
- `semantic.rename_preview`
- `semantic.selection_expand`
- `semantic.workspace_symbols`
- `symbol.info`
- `symbol.lookup`
- `symbol.search`
- `symbol.variants`
- `syntax.clear`
- `syntax.namespace`
- `syntax.package_extensions`
- `syntax.package_matches`
- `syntax.refresh`
- `template.init`
- `template.list`
- `tools.font_diagnostics`
- `tools.format`
- `tools.grammar`
- `tools.lint`
- `ui.bug_report`
- `ui.count`
- `ui.info`
- `ui.log`
- `ui.status`
- `ui.status_all`
- `ui.status_report`
- `ui.statusline`
- `viewer.clean`
- `viewer.clean_preview`
- `viewer.preview`
- `viewer.preview_capabilities`
- `viewer.preview_inverse`
- `viewer.preview_open_browser`
- `viewer.preview_reload`
- `viewer.preview_status`
- `viewer.preview_stop`
- `viewer.preview_toggle`
<!-- typst.nvim experimental-symbols:end -->

`project.set_main(path, bufnr, { persist = true })` saves the explicit main-file choice
for the current buffer path; `:TypstSetMain` uses this persistent mode. When a
buffer is renamed with `:saveas`, the saved choice follows the new buffer path.
Unreadable explicit main paths are ignored, and stale `vim.b.typst_main`
values are cleared when project state is re-resolved.
Stable project methods that return project state return copied public snapshots:
`project.attach`, `project.detach`, `project.get`, `project.projects`,
`project.reload_state`, `project.set_main`, `project.snapshot`, and
`project.toggle_main().state`. Mutating these snapshots never mutates the live
project registry.

### Migration: public project methods now return snapshots

Before this hardening release, some public project methods returned live project
tables. They now return copied public snapshots. Code that only reads identity,
root, main, output, status, files, dependencies, diagnostics, and artifacts
should continue to work. Code that mutates services, buffers, resolutions, or
compiler state must move behind a provider, a public command/API call, or an
internal typst.nvim module. User configs and external integrations should not
require `typst.project.store` or `typst.project.registry`; tests and internal
runtime modules may use those live-state modules deliberately.

Project-scoped public APIs resolve a snapshot back to live state by project key
and a session-local project instance token. If the backing project has been
pruned, or if the same root/main key has been recreated as a new project
instance, explicit snapshot inputs fail with `unknown_project_key` instead of
operating on copied or unrelated service tables.
Attached project tables expose `dependency_sources` and `file_sources` with
`explicit`, `compiler`, or `heuristic` values; existing project graph
attachment prefers explicit associations, then compiler-discovered edges, then
heuristic associations.
Unnamed Typst buffers can attach before they have a file name. They use a
scratch in-memory project rooted at the current working directory, and
`:saveas` re-resolves them into normal file-backed projects. Normal
`:TypstCompile`, `:TypstWatch`, and compile-mode preview reject scratch mains
until the buffer is saved. Stdin-backed fragment compiles such as
`:TypstCompileSelected` are intentionally allowed because the generated source
is sent to `typst compile -` rather than the synthetic scratch path.
- `require("typst").ui.count(opts)`
- `require("typst").tools.format(opts)`
- `require("typst").tools.lint(opts)`
- `require("typst").tools.grammar(opts)`
- `require("typst").tools.font_diagnostics(opts)`
- `require("typst").viewer.view(opts)`
- `require("typst").viewer.view_forward(opts)`
- `require("typst").viewer.view_inverse(opts)`
- `require("typst").viewer.capabilities(opts)`
- `require("typst").viewer.clean(opts)`
- `require("typst").viewer.clean_preview(opts)`
- `require("typst").viewer.preview(opts)`
- `require("typst").viewer.preview_capabilities(opts)`
- `require("typst").viewer.preview_inverse(opts)`
- `require("typst").viewer.preview_open_browser(opts)`
- `require("typst").viewer.preview_reload(opts)`
- `require("typst").viewer.preview_status(opts)`
- `require("typst").viewer.preview_stop(opts)`
- `require("typst").viewer.preview_toggle(opts)`
- `require("typst").navigation.toc(opts)`
- `require("typst").picker.open(opts)`
- `require("typst").picker.items(opts)`
- `require("typst").diagnostics.quickfix(opts)`
- `require("typst").diagnostics.errors(opts)`
- `require("typst").bibliography.diagnostics(opts)`
- `require("typst").context.open(opts)`
- `require("typst").package.info(opts)`
- `require("typst").package.open(opts)`
- `require("typst").package.readme(opts)`
- `require("typst").package.source(opts)`
- `require("typst").symbol.info(opts)`
- `require("typst").symbol.variants(opts)`
- `require("typst").completion.complete(opts)`
- `require("typst").completion.native(opts)`
- `require("typst").completion.cmp(opts)`
- `require("typst").completion.blink(opts)`
- `require("typst").completion.cmp_source(opts)`
- `require("typst").completion.blink_source(opts)`
- `require("typst").completion.omnifunc(findstart, base)`
- `require("typst").completion.signature(opts)`
- `require("typst").providers.register(kind, name, provider)`
- `require("typst").providers.unregister(kind, name)`
- `require("typst").providers.get(kind, name)`
- `require("typst").providers.names(kind)`
- `require("typst").ui.log()`

The public conceal namespace is:

- `require("typst").conceal.enable(bufnr)`
- `require("typst").conceal.disable(bufnr)`
- `require("typst").conceal.toggle(bufnr)`
- `require("typst").conceal.refresh(bufnr)`
- `require("typst").conceal.inspect(opts)`
- `require("typst").conceal.is_enabled(bufnr)`
- `require("typst").conceal.register(kind, name, replacement)`
- `require("typst").conceal.unregister(kind, name)`
- `require("typst").conceal.custom(kind)`

The public syntax namespace is:

- `require("typst").syntax.package_extensions(opts)`
- `require("typst").syntax.package_matches(opts)`
- `require("typst").syntax.refresh(bufnr)`
- `require("typst").syntax.clear(bufnr)`
- `require("typst").syntax.namespace()`

The public index namespace is:

- `require("typst").index.collect(opts)`
- `require("typst").index.headings(project_or_opts)`
- `require("typst").index.labels(project_or_opts)`
- `require("typst").index.citations(project_or_opts)`
- `require("typst").index.imports(project_or_opts)`
- `require("typst").index.todos(project_or_opts)`
- `require("typst").index.definitions(project_or_opts)`
- `require("typst").index.glossary_entries(project_or_opts)`
- `require("typst").index.paths(project_or_opts)`
- `require("typst").index.mark_dirty(project_or_opts, reason)`
- `require("typst").index.reset(project_or_opts)`

The public completion namespace is:

- `require("typst").completion.complete(opts)`
- `require("typst").completion.native(opts)`
- `require("typst").completion.cmp(opts)`
- `require("typst").completion.blink(opts)`
- `require("typst").completion.cmp_source(opts)`
- `require("typst").completion.blink_source(opts)`
- `require("typst").completion.omnifunc(findstart, base)`
- `require("typst").completion.signature(opts)`

The public bibliography namespace is:

- `require("typst").bibliography.diagnostics(opts)`
- `require("typst").bibliography.clear_diagnostics(opts)`
- `require("typst").bibliography.diagnostics_namespace()`
- `require("typst").bibliography.foldexpr(lnum, bufnr)`
- `require("typst").bibliography.indentexpr(lnum, bufnr)`
- `require("typst").bibliography.fields(path, key, lnum)`
- `require("typst").bibliography.expanded_fields(opts)`
- `require("typst").bibliography.search(opts)`
- `require("typst").bibliography.insert_text(key, opts)`
- `require("typst").bibliography.insert(opts)`
- `require("typst").bibliography.open(opts)`
- `require("typst").bibliography.preview(opts)`
- `require("typst").bibliography.attachment(opts)`
- `require("typst").bibliography.attachments(opts)`
- `require("typst").bibliography.rename_plan(opts)`
- `require("typst").bibliography.rename_key(opts)`
- `require("typst").bibliography.status(opts)`
- `require("typst").bibliography.parse_bibtex_file(path)`
- `require("typst").bibliography.parse_hayagriva_file(path)`

The public artifact/export namespace is:

- `require("typst").artifact.export(opts, callback)`
- `require("typst").artifact.list(opts)`
- `require("typst").artifact.open(opts)`
- `require("typst").artifact.clean(opts)`

The public evaluation namespace is:

- `require("typst").evaluation.eval({ expression = "..." }, callback)`
- `require("typst").evaluation.selection(opts, callback)`
- `require("typst").evaluation.inspect(opts, callback)`

The public template/development/semantic namespaces are:

- `require("typst").template.init(opts, callback)`
- `require("typst").template.list(opts)`
- `require("typst").development.profile(opts, callback)`
- `require("typst").development.test(opts, callback)`
- `require("typst").development.bench(opts, callback)`
- `require("typst").development.coverage(opts, callback)`
- `require("typst").semantic.inlay_hints_toggle(opts)`
- `require("typst").semantic.code_action(opts)`
- `require("typst").semantic.color_info(opts)`
- `require("typst").semantic.color_presentation(opts)`
- `require("typst").semantic.document_links(opts)`
- `require("typst").semantic.code_lens(opts)`
- `require("typst").semantic.workspace_symbols(opts)`
- `require("typst").semantic.references(opts)`
- `require("typst").semantic.rename_preview(opts)`
- `require("typst").semantic.selection_expand(opts)`
- `require("typst").semantic.on_enter(opts)`

The public rendered-preview namespace is:

- `require("typst").render.fragment(opts, callback)`
- `require("typst").render.equation(opts, callback)`
- `require("typst").render.image(opts)`
- `require("typst").render.page(opts, callback)`
- `require("typst").render.cache_clear(opts)`
- `require("typst").render.cache_entries()`

`require("typst").ui.log()` returns a copy of the in-memory structured log. Log
entries include `time`, `level`, `message`, and `fields`; compiler run fields
include command, cwd, root, main, and output where available.

Provider registration is the public extension registry for named Lua
providers. `register_provider(kind, name, provider)` stores a provider under
one of the supported kinds: `compiler`, `format`, `lint`, `grammar`, `viewer`,
`picker`, `toc`, `index`, `export`, `eval`, `init`, `profile`, `test`,
`bench`, `coverage`, `semantic`, or `render`. Aliases such as `compile`,
`formatter`, `linter`, `view`, `exports`, `template`, `benchmark`, and
`terminal_image` are
accepted. Registered provider names are valid string values in matching config
fields and per-call `opts.provider` where applicable, so a plugin can register
`"my-format"` and users can set `format.provider = "my-format"`.
`unregister_provider(kind, name)` removes and returns the provider,
`get_provider(kind, name)` returns the registered value, and
`provider_names(kind)` returns sorted registered names. The namespace
`require("typst").providers` exposes the same operations as `register`,
`unregister`, `get`, `has`, and `names`.

index providers extend the syntactic project index. A provider may be a
function `(project, opts) -> result` or a table with `collect(project, opts)`.
The result can contain normal index categories such as `labels`, `citations`,
`definitions`, `todos`, or an `items` array with `kind`, `name`, and source
location fields. Registering or unregistering an index provider invalidates the
aggregate index cache. Providers with mutable external state can call
`require("typst").index.mark_dirty(project, reason)` before collecting again.
Provider result, handle, timeout, and cancellation classification rules are
documented in `docs/provider-contracts.md`; internal project/service/watch
ownership rules are documented in `docs/architecture.md`.

`executable` may be a string executable or a list prefix. `viewer.provider`
selects the output viewer preset. Built-in presets currently include
`"generic"`, `"custom"`, `"zathura"`, `"sioyek"`, `"skim"`, `"sumatrapdf"`,
`"mupdf"`, `"evince"`, `"okular"`, and `"qpdfview"`, plus registered viewer
names. `viewer.open` may be a Lua callback, string executable, list prefix, or
`nil`; an explicit `viewer.open` overrides the selected preset. Command lists
are passed directly to `vim.system`; typst.nvim does not concatenate them
through a shell.

`compile.provider` is the supported compiler-provider extension point. The
named providers `"generic"` and `"task"` run command arrays from
`compile.generic` and `compile.task`; command arguments may include `{root}`,
`{main}`, `{output}`, `{profile}`, `{provider}`, `{source}`, and `{stdin}`
placeholders. `{source}` matches `{main}` for normal document compiles; for
stdin-backed selected fragments it is the originating buffer path when
available. `{stdin}` is `1` only when the command receives generated source on
stdin. Custom providers may be registered by name with
`register_provider("compiler", name, provider)` or supplied directly. They must
implement `compile`, `start`, `stop`, `status`, and `output`.
Project-specific task/generic providers are the Typst-native replacement for
Arara-style document automation: configure `compile.provider = "task"` or
`"generic"` to route `:TypstCompile` and `:TypstWatch` through a repository
task runner while keeping provider lifecycle state inside typst.nvim.
typst.nvim calls `output(project, run_config)` before custom `compile` and
`start` calls so provider output paths are visible in events, status, and
`:TypstInfo`.
typst.nvim tracks handles returned from custom `compile` and `start` calls in
the project compiler service as the active process or watcher. It also applies the standard `compiling`,
`watching`, `success`, `error`, and `idle` lifecycle states from synchronous or
asynchronous callback results. A returned compile/watch handle remains active
until that callback result arrives, or until `stop()` reports `stopped = true`.
typst.nvim calls `stop()` before switching between one-shot compile and watch
modes. Calling `stop()` while no compile or watcher is active is handled by
typst.nvim without delegating to the custom provider; the callback result still
has `stopped = true` for compatibility and additionally sets `idle = true`.
The default Typst provider parses `typst watch` compile-cycle markers. Each
cycle emits started/success/failure events, failed cycles publish diagnostics
from the current cycle only, later successful cycles clear stale diagnostics,
and event payloads include a monotonic `cycle_generation` that keeps increasing
across watcher restarts. The parser supports structured JSON-line watch events
when `compile.watch_structured_args` makes the configured executable or wrapper
emit them. Typst CLI 0.15 does not expose a stable structured watch-status
flag; otherwise Typst's current human-readable watch output is parsed through
fixture-gated best-effort profiles. Set `compile.watch_output = "structured"`
only for wrappers or future Typst versions that emit stable JSON-line watch
events, causing human-readable status lines to fail closed. If the watch
process exits after parsed cycles, the last cycle remains the build result and
no extra compile success/failure event is synthesized from the process exit.
Retained watch stdout/stderr is bounded. Unterminated
partial-line buffers are bounded too. Repeated watch restarts while the old
watcher is stopping are debounced into one replacement watcher. Completed watch
cycles notify optional `viewer.reload(project, result, opts)` and
`preview.refresh(project, result, opts)` callbacks with `opts.source == "watch"`
and `opts.watch == true`.
After a successful watch cycle, typst.nvim waits up to
`compile.watch_output_wait_ms` for the expected output file to become readable
before treating the cycle as a missing-output failure.
`compiler.compile_selected(opts, callback)` renders the requested line range
with `compile.fragments.templates`, then compiles that fragment through the
configured compiler provider. Generated source is passed through stdin by
default: the built-in Typst provider runs `typst compile -`, generic/task
providers receive stdin and `{main}` expands to `-`, and custom provider
callbacks can read the internal runtime field `run_config.compile.stdin`.
`compile.stdin` is not a public setup option. Generic/task `{source}` still
expands to the originating source path when it is known, and `{stdin}` expands
to `1` for stdin-backed fragment compiles. Providers can opt into file-backed
source wrappers with `compile.fragments.source_dir` or a template `source_dir`.
It returns a table with `ok`, `template`, `source`, `source_mode`,
`source_text`, `output`, `project`, and `range`; the callback receives
`(result, fragment_project)` when the compiler exits. Built-in fragment
templates cover `markup`, `math`, `code`, `full-page`, and `auto-sized`;
`document` and `auto` remain aliases for the last two behaviors. File-backed
generated sources are deleted after the compile resolves or if the compiler
provider fails to start; output artifacts remain available.

`export(opts, callback)` is the multi-artifact export API behind
`:TypstExport`. `opts.format` may be `pdf`, `png`, `svg`, `html`, or `bundle`
for the built-in Typst CLI path; arbitrary artifact formats should be modeled
as named `exports.profiles` entries. Explicit `opts.profile` selections win
over built-in format names, so a profile named `html` remains selectable. Each
profile entry may set `format`,
`output_name`, `output_dir`, `extra_args`, `inputs`, `font_paths`, `features`,
`creation_timestamp`, `package_path`, `package_cache_path`, `jobs`,
`diagnostic_format`, `timings`, `pages`, `pdf_standard`, `no_pdf_tags`, `ppi`,
and `pretty`. A profile entry may also set `command`, `cwd`, and
`stdout = true` to produce non-Typst-compile artifacts such as `txt`; command
placeholders include `{root}`, `{main}`, `{input}`, `{output}`,
`{output_dir}`, `{output_name}`, `{format}`, `{output_format}`,
`{typst_format}`, and `{profile}`. A profile entry may set `provider` to route
the whole export plan through a registered export provider; provider-owned
entries cannot be mixed with built-in/command entries in the same plan.
Successful exports are recorded in
`project.services.artifacts.items`; `artifacts(opts)` lists them,
`artifact_open(opts)` opens one, and `artifact_clean(opts)` deletes registered
generated artifacts.
`html_preview(opts)` is an HTML live-workflow helper over the same export
pipeline, and `presentation(opts)` targets a `presentation` export profile when
configured. Custom export providers register with `register_provider("export",
name, provider)` and implement `export(project, opts, callback)` or `run(...)`.

`eval(opts, callback)` runs `typst eval --in <main>` with
`opts.expression`; `eval_selection(opts, callback)` takes the requested range
from the current buffer; and `inspect(opts, callback)` evaluates the supplied
expression or cursor word and opens serialized JSON in a scratch buffer. Custom
evaluators can register the `eval` provider kind.

`init(opts, callback)` uses `typst init` for local or published templates.
When `opts.select = true` and no template is supplied, it opens the template
gallery and initializes the selected template. `templates(opts)` returns cached
template packages plus configured Universe-index template records with source,
template path, entrypoint, compiler, cache, and description metadata. Passing
`offline = true` or `copy = true` to `init` uses the cached-template copier,
which validates package containment, rejects recursive destination paths, stages
the copy, and renames it into place on success.

`profile(opts, callback)` compiles with Typst's `--timings` JSON output.
`test(opts)` runs `tinymist test`, `coverage(opts)` runs
`tinymist test --coverage`, and `bench(opts)` runs `crityp` by default when the
executables are available. Each returns an async result with `command`, `stdout`,
`stderr`, `code`, and an optional report buffer. Provider kinds are `profile`,
`test`, `bench`, and `coverage`, and custom providers still override the default
commands.

Semantic helpers expose stable commands around Tinymist/LSP behavior:
`inlay_hints_toggle(opts)`, `code_action(opts)`, `color_info(opts)`,
`color_presentation(opts)`, `document_links(opts)`, `code_lens(opts)`,
`workspace_symbols(opts)`, `references(opts)`, `rename_preview(opts)`,
`selection_expand(opts)`, and `on_enter(opts)`. `code_action` and
`color_presentation` list available Tinymist results by default and apply one
when passed an `index`; `on_enter` applies Tinymist's `experimental/onEnter`
edits only when explicitly called. A semantic provider can override individual
methods for richer package or workspace integrations.

Rendered-preview helpers are explicit, cached actions. `render_fragment(opts)`
renders selected or supplied Typst source, `render_equation(opts)` wraps an
expression in an auto-sized math document, `render.image(opts)` resolves an
image path under the cursor or from `opts.path` in the current Typst project,
and `render.page(opts)` renders one page from the current main file.
`render.image()` is project-backed for cache/output ownership; it is not a
project-free image display helper. `render.output_dir`, `render.output_format`,
`render.source_dir`, `render.cache`, and `render.open` control defaults.
Equation and fragment renders write generated wrapper sources under the
XDG-backed `render.source_dir` and pass them through stdin by default. Rendered
artifacts stay under the XDG-backed `render.output_dir`.
`render.cache_clear()`
removes manifest-owned cached artifacts from the render cache; pass
`{ force = true }` to remove the whole configured render cache directory. The
default renderer uses `typst compile` to SVG or PNG, then opens a
scratch-buffer report with artifact metadata. Built-in terminal image display
providers are available with
`display_provider = "terminal"`, `"kitty"`, `"wezterm"`, or `"iterm"` for Kitty,
WezTerm, and iTerm-style protocols. Kitty uses file transfer; iTerm/WezTerm
inline display is bounded by `render.max_inline_image_bytes` and uses the
built-in Lua base64 encoder. A custom render provider may still
implement `render(project, opts, callback)` to replace rendering or
`display(result, opts)` to replace display while keeping typst.nvim's render
cache and commands.

`format(opts)` formats the current buffer. `format.provider = "auto"` prefers
Tinymist formatting through a Neovim built-in LSP client named `tinymist`,
starting or reusing the client in the default `integrations.tinymist.lsp =
"auto"` mode when available and not blocked by coc.nvim detection. Use
`"detect"` for passive existing-client queries, `"off"` to disable typst.nvim
Tinymist LSP use, or `"start"` to force nvim-lsp startup.
`integrations.tinymist.path` sets the Tinymist executable path, and
`integrations.tinymist.cmd` can override it with a full command prefix.
When using `coc-tinymist`, configure Coc's `tinymist.serverPath` and
`tinymist.serverArgs`; typst.nvim does not read Coc settings and will not talk
to Coc's private LSP client.
`integrations.tinymist.capabilities` and `integrations.tinymist.on_attach` are
passed through to `vim.lsp.start()` for native Tinymist users who need custom
client capabilities or attach hooks.
Citation completion is separately controlled by `bibliography.completion`.
The default `"auto"` keeps project-index citation completion for offline/no-LSP
sessions and `include_tinymist = false`, but avoids adding fallback citation
candidates when a native Neovim Tinymist client is attached or coc.nvim appears
active. Use `"project"` to force fallback citation completion, or
`"tinymist"`/`"off"` to suppress it.
`format.provider` may also be a `"prose"` formatter that wraps plain prose
paragraphs with
`format.prose_width` or `opts.width`, or a
registered provider name, callback, or provider table exposing
`format(bufnr, project, opts)`.

`lint(opts)` runs the configured lint provider and returns a result table with
`diagnostics`, `buffers`, and `by_buffer` when diagnostics were parsed. The
default provider shells out to Typst compile with a temporary output path and
parses Typst human or short diagnostics. `lint.provider` may be `"typst"`, `"tinymist"`,
`"command"`, a registered provider name, callback, or a provider table exposing
`lint(bufnr, project, opts)`. Passing `{ open = true }` populates and opens
quickfix for the lint result.

`grammar(opts)` runs the configured external prose or grammar checker and
returns the same diagnostic result shape as `lint(opts)`. `grammar.provider`
may be `"command"`, `"textidote"`, `"vlty"`, a registered provider name,
callback, or a provider table exposing `grammar(bufnr, project, opts)`,
`check(...)`, or `run(...)`.
Generic command providers default to stdin; `textidote` and `vlty` default to
passing the current file path. `{file}`, `{main}`, and `{root}` placeholders in
`grammar.extra_args` are expanded before execution. textidote line/column
output and Vale/vlty-style JSON output are normalized before diagnostics are
published. Passing `{ open = true }` populates and opens quickfix for the
grammar result.

`font_diagnostics(opts)` scans current-buffer `font:` references and reports
families that are not in configured `completion.font_families` or `typst fonts`.
It returns a diagnostic result table and publishes warnings through a dedicated
diagnostic namespace. Passing `{ open = true }` populates and opens quickfix.

The bibliography diagnostics API, `bibliography_diagnostics(opts)`, checks the current project bibliography
workflow. It reports explicit undefined citations from `#cite(<key>)`, duplicate
bibliography keys, unused bibliography entries, and label/citation name
collisions through `require("typst").bibliography.diagnostics_namespace()`.
Passing `{ quickfix = true }` populates quickfix; `{ open = true }` also opens
it. `clear_diagnostics(opts)` clears only the bibliography namespace.
`bibliography.foldexpr()` and `bibliography.indentexpr()` provide conservative
BibTeX and Hayagriva fold/indent helpers for integrations that want Typst-aware
bibliography file behavior. `bibliography.expanded_fields(opts)` resolves
BibTeX `crossref` and `xdata` inheritance for a key,
`bibliography.search(opts)` searches keys and citation metadata,
`bibliography.insert_text(key, opts)` and `bibliography.insert(opts)` choose
markup, `#cite(<key>)`, or raw `<key>` insertion syntax from the current Typst
context,
`bibliography.preview(opts)` returns a formatted citation summary,
`bibliography.open(opts)` resolves or opens the bibliography entry,
`bibliography.attachment(opts)` and `bibliography.attachments(opts)` search configured PDF fields and path
patterns, `bibliography.rename_key(opts)` transactionally updates a
bibliography key and project citation references, and `bibliography.status(opts)`
returns project bibliography counts for health/status surfaces.

`viewer.forward` is the forward-search extension point. It may be a callback,
string executable, list prefix, or `nil`. Callback form receives
`(output_path, project, { line = line, column = column }, opts)`. Executable
form uses `viewer.forward_args`, which supports `{output}`, `{main}`, `{root}`,
`{line}`, and `{column}` placeholders. String/list executable forward commands
run only when the selected viewer declares `capabilities.forward` or
`capabilities.source_maps`; otherwise `view_forward()` returns an unsupported
result with `detail = "capability_required"` and can fall back to preview source
sync. Without a configured backend,
`view_forward()` tries a configured `preview.forward` callback and otherwise
returns `{ ok = false, reason = "unsupported" }` with the active provider and
its declared capabilities.

`viewer.inverse` is the viewer-side inverse-search extension point for source
locations reported by source-map-capable viewers. Callback form receives
`(project, { path = path, line = line, column = column, output = output },
opts)`. Executable form uses `viewer.inverse_args`, which supports `{source}`,
`{file}`, `{path}`, `{output}`, `{main}`, `{root}`, `{line}`, and `{column}`.
String/list executable inverse commands run only when the selected viewer
declares `capabilities.inverse` or `capabilities.source_maps`. When no callback
or command is configured, `view_inverse()` opens the reported source location
directly only if the selected viewer declares `capabilities.inverse` or
`capabilities.source_maps`. If the current buffer is unrelated,
`view_inverse({ path = ... })` resolves the project from a loaded source buffer
or existing project graph before returning `source_path_not_in_project`; it does
not create a scratch project from the current buffer. Built-in PDF viewer presets open or
reuse output but do not claim forward or inverse
synchronization by default.

`viewer.reload` is an optional watch-cycle notification callback for output
viewers. Callback form receives `(project, result, opts)`, where `result` is the
per-cycle compile payload and watch notifications pass `opts.source == "watch"`
and `opts.watch == true`. Provider entries may also define `reload`; it is used
when top-level `viewer.reload` is unset.

`preview.forward` and `preview.inverse` are source-sync extension points for
configured callback previews. `preview.capabilities` declares source-map,
forward, and inverse support. `preview_inverse()` opens the requested source
location when inverse support is available, resolving `opts.path` through
loaded buffers or existing project graphs when the current buffer is unrelated.
`preview_capabilities()` reports the effective preview source-sync surface.
When no callback is configured, preview open/stop/toggle use typst.nvim's native provider. `preview.native =
"viewer"` opens the configured output viewer, `"browser"` opens typst.nvim's
local browser preview shell, and `"auto"` tries browser preview with viewer
fallback. Set `preview.provider = "typst-preview.nvim"` only when explicit
compatibility delegation is wanted. In that mode, `:TypstPreviewSyncCursor` may
be used for `view_forward()`/`:TypstViewForward`. The galley preview workflow
and browser preview source-map integration are available when that external
command is available. `preview()` reuses an active project preview by default; pass
`{ restart = true }` or set `preview.reuse = false` to stop and reopen active
previews. Set `preview.follow_buffer = true` to make one active native browser
preview follow the focused Typst buffer's resolved project/main without opening
another browser tab. The default `preview.source_maps.provider = "typst-query"`
can source-sync SVG browser previews by querying Typst block positions and
matching them to local source text; it does not claim SyncTeX-style support for
normal Typst PDF output. Use typst-preview.nvim for live/incremental browser
frontend behavior, and typst.nvim native preview for project-aware viewer,
browser, export-profile, and cleanup workflows.

`preview.refresh` is an optional watch-cycle notification callback for preview
backends. Callback form receives `(project, result, opts)` with the same
per-cycle payload and watch options as `viewer.reload`.
`preview_open_browser()` opens the native browser target regardless of
`preview.native`, `preview_reload()` refreshes an active preview, and
`preview_status()` reports backend, transport, output, and preview cache state.
Browser opener failures preserve the attempted URL in preview state,
`preview_status({ bang = true })` lines, and `g:typst_nvim_last_preview_url`.
`preview.browser.app` optionally selects a local browser such as `"firefox"`,
`"chrome"`, `"safari"`, `"edge"`, or `"brave"`. With
`preview.browser.app = nil` and `preview.browser.commands = nil`, typst.nvim
uses the default OS URL opener. `preview.browser.commands` supplies explicit
opener command candidates for remote/WSL/SSH sessions; `{url}` is replaced with
the preview URL.
`preview.browser.reload_throttle_ms` limits automatic watch refresh frequency,
and `preview.browser.performance = "safari"` or `"fast"` applies opt-in
browser performance presets. The native browser shell defaults to 250ms state
polling and provides lightweight reload, zoom, fit, page, status/error, and
source-sync controls.
`clean_preview()` removes preview-owned cache artifacts while preserving an
active preview output by default. Native browser shell styling is controlled by
`preview.browser.style.variables`, `preview.browser.style.css`, and
`preview.browser.style.css_path`; `css_path` may be absolute or
project-relative, and shared styles should live under XDG config. Short
variable keys are emitted as `--typst-preview-{key}`.

`pick(opts)` opens normalized project and TOC items through the configured picker
backend. `picker.provider = "auto"` tries Telescope, fzf-lua, fzf.vim, Snacks, and then
`vim.ui.select`; it may also be `"ui_select"`, `"telescope"`, `"fzf_lua"`,
`"fzf_vim"`, `"snacks"`, `"custom"`, a registered provider name, callback, or provider
table. `pick_items(opts)` returns the backend-neutral items for custom
consumers. `kind = "toc"` consumes the same TOC model as `toc()`, including
registered custom TOC provider layers. Each item includes
`kind`, `name`, `label`, `detail`, `source`, `filename`, `lnum`, and `col`.
`kind = "bibliography"` returns dedicated bibliography entries with
`citation_key`, `fields`, and insertion-ready `insert_text`. Set
`citation_form = "function"` for `#cite(<key>)`, `citation_form = "label"` for
`<key>`, or omit it for shorthand `@key`.

The public editing helpers are:

- `require("typst").edit.next_heading(opts)`
- `require("typst").edit.previous_heading(opts)`
- `require("typst").edit.next_heading_end(opts)`
- `require("typst").edit.previous_heading_end(opts)`
- `require("typst").edit.next_block(opts)`
- `require("typst").edit.previous_block(opts)`
- `require("typst").edit.next_block_end(opts)`
- `require("typst").edit.previous_block_end(opts)`
- `require("typst").edit.next_equation(opts)`
- `require("typst").edit.previous_equation(opts)`
- `require("typst").edit.next_equation_end(opts)`
- `require("typst").edit.previous_equation_end(opts)`
- `require("typst").edit.next_raw_block(opts)`
- `require("typst").edit.previous_raw_block(opts)`
- `require("typst").edit.next_comment(opts)`
- `require("typst").edit.previous_comment(opts)`
- `require("typst").edit.match(opts)`
- `require("typst").edit.select_textobject(kind, part, opts)`
- `require("typst").edit.promote_heading(opts)`
- `require("typst").edit.demote_heading(opts)`
- `require("typst").edit.unwrap_function(opts)`
- `require("typst").edit.change_function(name, opts)`
- `require("typst").edit.change_delimiter(target, opts)`
- `require("typst").edit.change_delimiter_content(opts)`
- `require("typst").edit.change_delimiter_block(opts)`
- `require("typst").edit.change_delimiter_group(opts)`
- `require("typst").edit.change_delimiter_equation(opts)`
- `require("typst").edit.split_arguments(opts)`
- `require("typst").edit.join_arguments(opts)`
- `require("typst").edit.toggle_arguments(opts)`
- `require("typst").edit.name_arguments(opts)`
- `require("typst").edit.toggle_trailing_comma(style, opts)`
- `require("typst").edit.add_trailing_comma(opts)`
- `require("typst").edit.remove_trailing_comma(opts)`
- `require("typst").edit.toggle_label(opts)`
- `require("typst").edit.toggle_reference(opts)`
- `require("typst").edit.toggle_label_reference(opts)`
- `require("typst").edit.surround(kind, opts)`
- `require("typst").edit.surround_function(name, opts)`
- `require("typst").edit.surround_content(opts)`
- `require("typst").edit.surround_equation(opts)`
- `require("typst").edit.surround_figure(opts)`
- `require("typst").edit.surround_block(opts)`
- `require("typst").edit.surround_strong(opts)`
- `require("typst").edit.surround_emph(opts)`
- `require("typst").edit.insert("strong"|"emph"|"math"|"content"|"code"|"raw", opts)`
- `require("typst").edit.insert_strong(opts)`
- `require("typst").edit.insert_emph(opts)`
- `require("typst").edit.insert_math(opts)`
- `require("typst").edit.insert_content(opts)`
- `require("typst").edit.insert_code(opts)`
- `require("typst").edit.insert_raw(opts)`
- `require("typst").edit.toggle_markup("strong"|"emph", opts)`
- `require("typst").edit.toggle_strong(opts)`
- `require("typst").edit.toggle_emph(opts)`
- `require("typst").edit.toggle_figure(opts)`
- `require("typst").edit.toggle_list("toggle"|"bullet"|"numbered", opts)`
- `require("typst").edit.toggle_bullet_list(opts)`
- `require("typst").edit.toggle_numbered_list(opts)`
- `require("typst").edit.convert_equation(style, opts)`
- `require("typst").edit.toggle_equation_numbering(style, opts)`
- `require("typst").edit.convert_raw(style, opts)`

`convert_equation("toggle"|"inline"|"block", opts)` uses Tinymist code actions
when they succeed and otherwise falls back to a local Tree-sitter transform for
inline/display math.

`change_delimiter("content"|"block"|"group"|"equation", opts)` changes the
smallest surrounding delimiter pair while preserving its body. It uses the
same Typst-aware delimiter scanner as `%`, so comments, strings, and raw text
are skipped.

`split_arguments(opts)`, `join_arguments(opts)`, and `toggle_arguments(opts)`
format the parenthesized argument group of the surrounding function call.
Splitting creates one top-level argument per line with trailing commas. Joining
returns a multiline group to inline form when all top-level arguments are
single-line and no comments would be dropped.

`name_arguments(opts)` converts positional arguments in the surrounding call to
named arguments when a simple same-buffer local `#let` function declaration
provides parameter names. Variadic declarations, comments, spread arguments,
and calls without local parameter metadata are left unchanged.

`toggle_trailing_comma("toggle"|"add"|"remove", opts)` adds or removes the
top-level trailing comma of a multiline parenthesized argument group.
`add_trailing_comma(opts)` and `remove_trailing_comma(opts)` are explicit
wrappers. Groups with comments are left unchanged.

`toggle_label(opts)` converts `<name>` and `#label(<name>)` or
`#label("name")` between shorthand and explicit label form.
`toggle_reference(opts)` converts `@name` and `#ref(<name>)` between shorthand
and explicit reference form. `toggle_label_reference(opts)` dispatches to the
appropriate label or reference transform under the cursor.

`toggle_equation_numbering("toggle"|"on"|"off", opts)` toggles the equation
under the cursor between explicit `numbering: "(1)"` and `numbering: none`.
Dollar-math syntax is converted to `#math.equation(...)`; existing explicit
calls only have their `numbering` argument inserted or changed.

`convert_raw("toggle"|"inline"|"block", opts)` converts the raw text under the
cursor between inline and block form. Multi-line raw blocks are not collapsed
to inline form because doing so would change literal content.

`toggle_figure(opts)` unwraps a surrounding `#figure` body when the cursor is
inside one. Otherwise it wraps the current line, visual selection, or command
range in a `#figure[...]` content block.

`surround(kind, opts)` wraps the current line, visual selection, or command
range. Supported kinds are `function`, `content`, `equation`, `figure`,
`block`, `strong`, and `emph`; `function` requires `opts.name` or use
`surround_function(name, opts)`.

The public statusline helpers are:

- `require("typst").ui.status(bufnr)`
- `require("typst").ui.status_report(opts)`
- `require("typst").ui.bug_report(opts)`
- `require("typst").ui.statusline(opts)`

`status()` includes project identity, root/main decision sources, output,
diagnostic counts, last background command/cwd, active process or watcher PID,
project-specific Tinymist Neovim LSP visibility as `tinymist_lsp_backend`,
`tinymist_lsp_mode`, `tinymist_lsp_enabled`, and `tinymist_lsp_attached`, the effective
compiler diagnostics policy as `compiler_diagnostics`, and viewer/preview
backend details. The `status` field is read through the active compiler
provider's `status(project)` method. It also includes the last active compile
profile as `profile` when one was used, plus current-buffer `words`,
`characters`, and `characters_with_spaces` counts.
`compiler_diagnostics` is one of `fallback_active`,
`fallback_suppressed_by_tinymist`, `always`, or `off`.
`statusline({ profile = false })` hides the profile, and
`statusline({ words = true })` appends the current-buffer word count.

Status commands keep the VimTeX-like split between compact status and detailed
diagnostics:

```text
:TypstStatus       compact current-project status
:TypstStatus!      compact all-project status
:TypstStatusAll    all-project status
:TypstStatusAll!   all-project report in a scratch buffer
:TypstInfo!        detailed current-project report
```

- `:TypstStatus` echoes compact current-project status.
- `:TypstStatus!` echoes compact all-project status.
- `:TypstStatusAll` echoes all-project status explicitly.
- `:TypstStatusAll!` opens the all-project report in a scratch buffer.
- `:TypstInfo!` opens the detailed current-project report in a scratch buffer.

At the Lua level, `status_report({ bang = true })` returns the all-project
status table used by `:TypstStatus!`; without bang it returns compact
current-project status lines. Use `status_report({ detailed = true })` or
`info()` for the detailed current-project report. `info({ bang = true })` opens
that detailed project report in a scratch buffer. `reload_state()` detaches and
re-resolves the current buffer and reapplies typst.nvim buffer state without
stopping active compilers.
`clear_cache()` invalidates generated metadata selection, package resource cache
state, import-scan cache, project index cache, and conceal match caches.
`require("typst").report({ open = true })` and
`require("typst").ui.bug_report({ open = true })` generate the same redacted
JSON support artifact as `:TypstBugReport`; both are experimental support APIs
listed under `experimental_symbols()`, not stable API symbols. Reports are
pretty-printed by default and cap project, operation, telemetry, and log
sections; pass `pretty = false` or larger `max_*` limits only for local
debugging or maintainer-requested captures.
`metadata_version` may pin a bundled Typst metadata snapshot such as `"0.14.2"` or `"0.15.0"`;
when unset, typst.nvim uses the newest compatible bundled metadata and reports
version mismatches through catalog/status metadata.

The public conceal namespace controls buffer-local enablement, syntax-backed
punctuation categories, raw/list delimiter categories, function-wrapper
categories, and custom math symbol mappings. `conceal.custom.math` config maps
Typst math names to empty strings or exactly one-character native conceal
replacements. Runtime extensions can call
`require("typst").conceal.register("math", name, replacement)` and
`unregister("math", name)`; `conceal.custom("math")` returns the runtime
registry. Custom math mappings are resolved before generated Typst metadata,
respect the same shadowing and width-safety rules, and appear in
`:TypstConcealInspect` as user-provided rules. Shadowing considers local `#let`
bindings, function parameters, imports, aliases, and wildcard imports with a
Tree-sitter lexical approximation that respects declaration order and
block/content scopes, not semantic resolution. With `conceal.reveal = "node"`,
reveal is window-local: each split leaves only the candidate under that
window's cursor as source text.

The public syntax namespace exposes package-aware syntax extension helpers:

- `require("typst").syntax.package_extensions(opts)`
- `require("typst").syntax.package_matches(opts)`
- `require("typst").syntax.refresh(bufnr)`
- `require("typst").syntax.clear(bufnr)`

Package syntax extensions read exact imports from the project index, match them
against `syntax.packages`, and apply extmark-backed highlights for configured
package entry points. The default config includes `@preview/cetz` and links its
matches to `TypstPackageCetz`; custom specs can add package member names,
captures, highlight groups, and priorities. This is the package-specialization
path for cases where a Typst package needs editor behavior beyond the generic
Tree-sitter highlight query.

Package resource helpers accept either `{ query = "name" }` or no query to
resolve a package import or imported package member under the cursor. Passing
`{ open = false }` returns the normalized result table or URL without opening a
buffer or browser. Cached packages expose manifest, README, entrypoint, manual,
API, repository, homepage, typst.nvim-specific optional `[tool.typst-docs]`
resource hints, and Universe fields; missing packages return a Universe fallback
result. Cursor-based package resources also resolve imported package members,
including direct imports such as `#canvas`, module aliases such as
`#cetz.canvas`, nested item paths, module-value reimports, and unambiguous
wildcard package imports; when cached `///` source comments are found, the
result is marked with `semantic = false` and exposes the exact package source
path.
Symbol helpers expose generated symbol and emoji metadata: glyph, qualified
form, metadata version, category, and variants. They are symbol information, not
a package documentation subsystem.
`metadata.catalog()` exposes the selected Typst metadata manifest without
decoding the large artifacts. `metadata.symbol(name)`, `metadata.symbol_names()`,
`metadata.symbol_variants(name)`, `metadata.emoji(name)`,
`metadata.emoji_names()`, `metadata.stdlib()`, `metadata.stdlib_item(path)`,
`metadata.signature(path)`, and `metadata.shorthands()` expose lazy normalized
views over compact generated MessagePack payloads. The stdlib index contains
built-in global/math items, function and element parameters, returns, members,
constants, categories, and deprecations; full prose documentation and package
manuals remain outside the core catalog.
`context_menu({ open = false })` returns the available context actions without
showing UI. With UI enabled it uses `vim.ui.select` and can run package info,
symbol info, symbol variant insertion, package source/page actions, cached package-version
updates, follow-target, and copy-target actions. Package import targets add
`package_update_version` when a newer version of the same package is already in
the local Typst package cache. Template package targets add `template_info`,
`template_source`, and `template_init`; file path targets add `path_reveal`;
image path targets add `image_open` and `image_preview`; color targets add
`color_preview` and `color_replace`; font targets add `font_info` and
`font_replace`. Function-call targets add `function_signature` when signature
metadata is available. Label targets add `copy_label`, `label_references`, and
`label_rename`; syntactic label-rename fallback validates the current source
token before applying edits so stale context actions fail instead of rewriting
old byte ranges. Fallback rename results report `provider = "syntax"` and
`semantic = false`; Tinymist rename results report `provider = "tinymist"`.
Definition targets add `definition_references`, which prefers Tinymist semantic
references and falls back to project occurrences; heading targets add
`heading_promote` and `heading_demote`; equation targets add
`equation_convert` and `equation_numbering`; citation targets add
`citation_entry`, `copy_citation_key`, `citation_url`, `citation_doi`, and
`citation_pdf` actions when the resolved bibliography entry exposes URL/DOI
fields or a readable local PDF attachment.

`complete({ base = "...", context = "markup" | "math" | "parameter" | "csl_style" | "raw_language" | "color" | "font_family" })`
returns Vim completion item tables. In semantic Typst contexts it asks attached
Tinymist clients for `textDocument/completion` first, then falls back to the
project index, compact generated stdlib metadata, bundled symbol/emoji
metadata, cached packages, and configured/static fallback lists. Pass
`include_tinymist = false` to skip the LSP request and use only fallback
completion.
`completion.native(opts)` returns an LSP-style completion list,
`completion.cmp(opts)` returns nvim-cmp-shaped items, and
`completion.blink(opts)` returns blink.cmp-shaped items. `cmp_source(opts)` and
`blink_source(opts)` return small source objects that call the same completion
service; typst.nvim does not own or configure the completion frontend itself.
Typst buffers install `v:lua.typst_nvim_omnifunc` as `omnifunc` when no other
omnifunc is already set. The project-index fallback includes syntactic labels,
references, bibliography keys, local `#let` declarations, direct imports, local
module-alias members, local `#include` `.typ` traversal, and referenced file
paths. In math context, symbol
completions insert unqualified names such as `arrow.r`; outside math, explicit
symbol completions insert `sym.arrow.r`. Generated stdlib function/type,
parameter, return, member, shorthand, and deprecation metadata is bundled as a
lazy metadata snapshot from the pinned Typst Rust crates. Named-parameter and
signature fallback uses generated stdlib signatures plus simple local/imported
`#let function(...)` signatures from the project index. Parameter-value
fallback uses generated CastInfo constants for accepted values such as
`image(fit: "cover")` or `text(style: "italic")`.
Package completion scans cached Typst package roots and optional
`completion.universe_index_paths` JSON indexes when completing `@...` prefixes
or when requested with `include_packages = true`; template packages are labeled
separately and carry manifest/index template metadata. The filesystem path completion source is available with `context = "path"` and is detected automatically in
`#import`, `#include`, `image`, `bibliography`, `read`, and raw/data-style
string paths; disable it with `completion.include_paths = false`.
`completion.path_scan_entry_max` caps raw directory entries consumed per scan,
while `completion.path_scan_max` caps returned path completion items. Directory
scans are cached briefly with `completion.path_scan_cache_ms`; set it to `0` to
disable that cache. CSL bibliography style completion is available with
`context = "csl_style"` and is
detected automatically inside
`bibliography(..., style: "...")` and `cite(..., style: "...")`; it combines
bundled Typst style IDs, configured `completion.csl_styles`, and project-local
`.csl` files. Raw block language completion is available with
`context = "raw_language"` and is detected automatically after an opening
triple-backtick fence; it combines common language IDs,
`completion.raw_languages`, and installed Tree-sitter parser names. Color
completion is available with `context = "color"` and is detected automatically
in color-like arguments such as `fill:` and `stroke:`; it combines Typst
predefined colors, configured `completion.color_names`, and `color.map.*`
presets. Font family completion is available with `context = "font_family"`
and is detected automatically in `font:` arguments; it combines configured
`completion.font_families`, families discovered by `typst fonts`, and a small
embedded fallback set when the CLI scan is unavailable.
Project-index glossary entries complete from conservative `#let`
glossary/acronym/term data, including dictionary-style entry keys and
`key: "..."` fields.
`signature(opts)` returns signature metadata from local/project declarations or
compact generated stdlib signatures, while Tinymist remains the semantic
hover/signature source.
`typst.index.headings(project)`, `typst.index.labels(project)`,
`typst.index.citations(project)`, `typst.index.imports(project)`,
`typst.index.todos(project)`, `typst.index.definitions(project)`,
`typst.index.glossary_entries(project)`, and
`typst.index.paths(project)` expose the
same syntactic project index for external consumers. The index is cached per
project and per file using loaded-buffer changedticks or on-disk mtime/size.
Unnamed Typst buffers use their scratch project main path as the index key and
are rescanned by buffer changedtick, so fallback headings, labels, references,
definitions, and TODOs work before the buffer has a file name. It parses
multiline/concatenated BibTeX fields and nested or inline Hayagriva YAML fields
for citation metadata.
`typst.index.reset(project)` clears one project's cache and
`typst.index.reset()` clears all project index caches. Passing
`include_tinymist = true` to `typst.index.collect(...)` overlays Tinymist
document/workspace symbols and their references onto returned headings,
definitions, and references without changing the default syntactic cache used
by completion. This path is cache-first and nonblocking: a call returns the
syntactic index plus any Tinymist cache that is still valid for the current
project generation, and schedules an async refresh when semantic data is absent
or stale. The TOC buffer merges
heading/document-symbol entries with index layers for figures, tables,
equations, labels, references, citations, imports, file paths, TODO comments,
and local definitions. Set `toc.mode = "quickfix"` or pass
`{ mode = "quickfix" }` to use quickfix presentation. TOC buffers install
configurable `toc.mappings` for `jump`, `preview`, `close`, `refresh`,
`toggle`, `toggle_layer`, `filter`, and `clear_filter`. `preview` opens the
selected entry in the source window while keeping TOC focus; `toggle` and
`toggle_layer` expand/collapse headings and hide/show the current entry's
layer. `filter` and `clear_filter` narrow or restore the presented TOC entries
without changing the collected model. `toc.visible_layers` controls the initial
visible layer set.
`toc.follow_cursor` and `toc.highlight_current` move and highlight the visible
TOC entry for the current source section. `toc.auto_refresh` refreshes an open
TOC after attached source edits or writes, debounced by `toc.refresh_delay_ms`.
Manual and automatic refreshes preserve the TOC cursor entry, collapsed headings,
filters, and per-project layer visibility.
When the last buffer leaves a project because it is unloaded, deleted, wiped, or
hidden with a destructive `bufhidden` policy, typst.nvim closes that project's
TOC window or TOC-owned quickfix list before pruning project state.
Registered `toc` providers may add custom TOC layers by exposing
`collect(project, opts)` and returning entries with `title`, `layer`, and
source location fields.

## Commands

The public command surface is:

- `:TypstInfo`
- `:TypstInfo!`
- `:TypstReloadState`
- `:TypstClearCache`
- `:TypstLocks [output-or-lockdir]`
- `:TypstCleanLocks[!] [output-or-lockdir]`
- `:TypstSetMain [file]`
- `:TypstToggleMain`
- `:TypstEditMain`
- `:TypstFiles`
- `:TypstCd[!]`
- `:TypstCompile[!] [profile]`
- `:TypstCompileSS[!] [profile]`
- `:TypstCompileSelected [template]`
- `:TypstCompileOutput`
- `:TypstWatch[!] [profile]`
- `:TypstStop`
- `:TypstStopAll`
- `:TypstCompilerForceClear[!] [project-key]`
- `:TypstStatus[!]`
- `:TypstStatusAll[!]`
- `:TypstCount[!]`
- `:TypstFormat`
- `:TypstLint[!]`
- `:TypstGrammar[!]`
- `:TypstFontDiagnostics[!]`
- `:TypstView`
- `:TypstViewForward`
- `:TypstViewInverse [file] [line] [column]`
- `:TypstClean[!]`
- `:TypstExport[!] [profile|format]`
- `:TypstArtifacts`
- `:TypstArtifactOpen [format]`
- `:TypstArtifactClean [format]`
- `:TypstEval[!] {expression}`
- `:TypstEvalSelection[!]`
- `:TypstInspect[!] [expression]`
- `:TypstInit[!] [template] [directory]`
- `:TypstTemplates`
- `:TypstProfile[!] [profile]`
- `:TypstTest [args]`
- `:TypstBench [args]`
- `:TypstCoverage [args]`
- `:TypstInlayHintsToggle`
- `:TypstCodeAction [index]`
- `:TypstColorInfo`
- `:TypstColorPresentation [index]`
- `:TypstLinks`
- `:TypstCodeLens`
- `:TypstWorkspaceSymbols [query]`
- `:TypstReferences`
- `:TypstRenamePreview {name}`
- `:TypstSelectionExpand`
- `:TypstOnEnter`
- `:TypstHtmlPreview [profile]`
- `:TypstPresentation [profile]`
- `:TypstPreview [document|slide]`
- `:TypstPreviewOpenBrowser[!] [document|slide|profile=name|format=fmt]`
- `:TypstPreviewReload [document|slide|profile=name|format=fmt]`
- `:TypstPreviewStatus[!]`
- `:TypstCleanPreview[!] [format]`
- `:TypstPreviewInverse [file] [line] [column]`
- `:TypstPreviewStop`
- `:TypstPreviewToggle [document|slide]`
- `:TypstPreviewFragment[!] [svg|png]`
- `:TypstPreviewEquation[!] [expression]`
- `:TypstPreviewImage[!] [path]`
- `:TypstPreviewPage[!] [page]`
- `:TypstRenderCacheClear`
- `:TypstToc`
- `:TypstTocOpen`
- `:TypstTocRefresh`
- `:TypstTocToggle`
- `:TypstLabels`
- `:TypstCitations`
- `:TypstCitationInsert [key|query]`
- `:TypstCitationSearch [query]`
- `:TypstCitationOpen [key]`
- `:TypstCitationPreview [key]`
- `:TypstCitationRename [old-key] new-key`
- `:TypstBibliographyStatus`
- `:TypstBibliographyDiagnostics[!]`
- `:TypstBibliographyAttachments[!] [key|query]`
- `:TypstSymbols`
- `:TypstPick [kind]`
- `:TypstFollow`
- `:TypstContextMenu`
- `:TypstDiagnostics`
- `:TypstErrors`
- `:TypstPackageInfo [query]`
- `:TypstPackageOpen [query]`
- `:TypstPackageReadme [query]`
- `:TypstPackageSource [query]`
- `:TypstSymbolInfo [query]`
- `:TypstSymbolVariants [query]`
- `:TypstConcealEnable`
- `:TypstConcealDisable`
- `:TypstConcealToggle`
- `:TypstConcealRefresh`
- `:TypstConcealInspect`
- `:TypstPromoteHeading`
- `:TypstDemoteHeading`
- `:TypstRefreshFolds`
- `:TypstMatchHighlightEnable`
- `:TypstMatchHighlightDisable`
- `:TypstMatchHighlightToggle`
- `:TypstMatchHighlightRefresh`
- `:TypstUnwrapFunction`
- `:TypstChangeFunction {name}`
- `:TypstSurroundDeleteCall`
- `:TypstSurroundChangeCall {name}`
- `:TypstChangeDelimiter {content|block|group|equation}`
- `:TypstSurroundDeleteDelimiter [content|block|group|equation]`
- `:TypstSurroundChangeDelimiter {content|block|group|equation}`
- `:TypstSurroundDeleteBlock`
- `:TypstSurroundChangeBlock [content|block|group|equation]`
- `:TypstSurroundDeleteEquation`
- `:TypstSurroundChangeEquation [content|block|group|equation]`
- `:TypstSplitArguments`
- `:TypstJoinArguments`
- `:TypstToggleArguments`
- `:TypstNameArguments`
- `:TypstToggleTrailingComma [toggle|add|remove]`
- `:TypstAddTrailingComma`
- `:TypstRemoveTrailingComma`
- `:TypstToggleLabel`
- `:TypstToggleReference`
- `:TypstToggleLabelReference`
- `:TypstSurround {function|content|equation|figure|block|strong|emph} [name]`
- `:TypstSurroundFunction {name}`
- `:TypstSurroundContent`
- `:TypstSurroundEquation`
- `:TypstSurroundFigure`
- `:TypstSurroundBlock`
- `:TypstSurroundStrong`
- `:TypstSurroundEmph`
- `:TypstInsert [strong|emph|math|content|code|raw]`
- `:TypstImapsList[!]`
- `:TypstToggleStrong`
- `:TypstToggleEmph`
- `:TypstToggleFigure`
- `:TypstToggleList [toggle|bullet|numbered]`
- `:TypstToggleBulletList`
- `:TypstToggleNumberedList`
- `:TypstConvertEquation [toggle|inline|block]`
- `:TypstToggleEquationNumbering [toggle|on|off]`
- `:TypstToggleFraction`
- `:TypstToggleDelimiterSize`
- `:TypstToggleLineBreak`
- `:TypstCreateFunction {name}`
- `:TypstSmartClose`
- `:TypstConvertRaw [toggle|inline|block]`
- `:TypstDoctor`
- `:TypstBugReport[!] [path]`
- `:TypstCheckInvariants`
- `:TypstTelemetry`
- `:TypstTelemetryReset`
- `:TypstLog`

## Events

The plugin emits these public `User` events:

- `TypstEventInitPre`
- `TypstEventInitPost`
- `TypstEventConfigChanged`
- `TypstEventProjectAttach`
- `TypstEventBufferDetach`
- `TypstEventProjectDetach`
- `TypstEventProjectPruned`
- `TypstEventCompileStarted`
- `TypstEventCompiling`
- `TypstEventCompileSuccess`
- `TypstEventCompileFailed`
- `TypstEventCompileStopped`
- `TypstEventCompilerForceCleared`
- `TypstEventPreviewStarted`
- `TypstEventPreviewForwarded`
- `TypstEventPreviewInverse`
- `TypstEventPreviewStopped`
- `TypstEventViewInverse`
- `TypstEventArtifactCreated`
- `TypstEventArtifactsCleaned`
- `TypstEventRenderCreated`
- `TypstEventTocCreated`
- `TypstEventTocActivated`
- `TypstEventQuit`

For compatibility, the plugin also emits the older event names:

- `TypstProjectAttach`
- `TypstBufferDetach`
- `TypstProjectDetach`
- `TypstProjectPruned`
- `TypstCompileStarted`
- `TypstCompileSuccess`
- `TypstCompileFailed`
- `TypstCompileStopped`
- `TypstCompilerForceCleared`
- `TypstDiagnosticsPublished`
- `TypstDiagnosticsCleared`
- `TypstViewOpened`
- `TypstViewForwarded`
- `TypstViewInverse`
- `TypstOutputCleaned`
- `TypstArtifactCreated`
- `TypstArtifactsCleaned`
- `TypstRenderCreated`
- `TypstPreviewOpened`
- `TypstPreviewForwarded`
- `TypstPreviewInverse`
- `TypstPreviewStopped`

Event `data` contains `key`, `root`, `main`, `output`, `status`, `provider`,
`profile`, `cwd`, and `command`. `profile` and `command` are `nil` before any
profiled compile or background command has been run. Project attach events add
`event_kind`, `bufnr`, `buffer`, `reason`, and `remaining_buffers`.
`TypstEventProjectAttach` fires after project registry state is committed and
buffer project finalization has run; if a non-critical finalizer fails, the
event includes `finalization_ok = false` and `finalization_error`; successful
attach events include `finalization_ok = true`. Buffer detach events add
`event_kind`, `bufnr`, `buffer`, `reason`, `remaining_buffers`, and
`project_pruned`. `TypstEventBufferDetach` is the precise event for a buffer
leaving a project. `TypstEventProjectDetach` remains a compatibility alias for
that buffer-detach moment. `TypstEventProjectPruned` fires only when an empty
project is removed from typst.nvim's registry and includes `event_kind`,
`reason`, `remaining_buffers`, and `project_pruned`.
`TypstEventCompilerForceCleared` includes `key_display`, `output`,
`released_lease`, `stopped`, `forced`, `discarded`, `reason`, and
`lease_owner`. `forced` is true only when bang/`force = true` bypassed the
`stopping_failed` guard.
Diagnostic events include
`diagnostics_count` and `diagnostic_buffers`. View events include
`viewer_provider`, `viewer_backend`, and may include `viewer_command` and
`viewer_cwd` when an external viewer executable is used. `TypstViewForwarded`
also includes `line` and `column`. Preview events also include `backend`,
`preview_backend`, `preview_command`, `preview_cwd`, `preview_active`, and may
include `mode`, `preview_mode`, `path`, `line`, `column`, or `source_sync`.
Artifact-created events include artifact metadata such as `id`, `path`,
`canonical_path`, `format`, `signature`, `freshness`, `reason`, `producer`, and
`preview_export`. Artifact-cleaned events include `deleted`, `skipped`,
`failed`, and `producer`. Render events include `kind`, `path`, `source`,
`format`, and may include `page`. TOC events include `items`. Initialization
events include `provider`, `did_setup`, `first_setup`, and `reconfigure`; quit
events include `provider` and `projects`. First setup emits
`TypstEventInitPre` -> `TypstEventInitPost`. Reconfiguration emits
`TypstEventInitPre` -> `TypstEventConfigChanged` -> `TypstEventInitPost` after
configuration is installed and attached buffers are reapplied.

## Stable Mappings

The `<Plug>(typst-...)` mappings documented in `:help typst-mappings` are public.
Default buffer-local mappings may be changed by configuration, but the `<Plug>`
names should remain stable across compatible releases.

The default `%` mapping calls `<Plug>(typst-match)`, which jumps between
matching `()`, `[]`, `{}`, `$` math delimiters, and triple-backtick raw fences.
Motion plugs include heading start/end, structural block start/end, equation
start/end, raw-block, and comment navigation with `<Plug>(typst-next-...)` and
`<Plug>(typst-previous-...)` names matching the documented mappings. Motion
plugs are registered for normal, operator-pending, and visual modes. They accept
Vim counts such as `2]m` and `3[[`.
The default `.` mapping repeats the last successful Typst structural edit while
it remains the last buffer change, and otherwise falls back to native
dot-repeat. Multi-token structural edits are undo-joined into one undo step. It
can be disabled or remapped with `mappings.repeat_transform`.
Counted transform calls repeat through the same undo chain, range-capable
transforms honor visual and command ranges, and structural edits preserve user
registers.
VimTeX-style workflow plugs include `<Plug>(typst-watch)`,
`<Plug>(typst-compile)`, `<Plug>(typst-stop)`, `<Plug>(typst-view)`,
`<Plug>(typst-view-forward)`, `<Plug>(typst-errors)`,
`<Plug>(typst-compile-output)`, `<Plug>(typst-info)`,
`<Plug>(typst-toc-toggle)`, `<Plug>(typst-clean)`, and `<Plug>(typst-log)`.
The default `mappings.commands.watch = "<localleader>ll"` starts watch mode;
`mappings.commands.compile = "<localleader>lL"` is the one-shot compile.
`select_textobject(kind, part, opts)` supports `heading`, `section`,
`equation`, `delimiter`, `content`, `block`, `structural_block`,
`code_block`, `raw_block`, `call`, `argument`, `list_item`, `label`, and
`import`. Parser-backed text objects are preferred; when no matching parser
range is available and Tinymist supports `textDocument/selectionRange`,
selection falls back to the LSP selection range. Pass
`{ lsp_fallback = false }` to require parser-only ranges. Counted outer argument
text objects select consecutive arguments, such as `y2aa`. Empty inner text objects
and incomplete syntax return no range.
`promote_heading(opts)` and `demote_heading(opts)` prefer matching Tinymist
code actions when attached and otherwise rewrite the local Typst heading marker.
The structural edit plugs `<Plug>(typst-unwrap-function)`,
`<Plug>(typst-change-delimiter-content)`,
`<Plug>(typst-change-delimiter-block)`, `<Plug>(typst-change-delimiter-group)`,
`<Plug>(typst-change-delimiter-equation)`,
`<Plug>(typst-split-arguments)`, `<Plug>(typst-join-arguments)`,
`<Plug>(typst-toggle-arguments)`,
`<Plug>(typst-name-arguments)`,
`<Plug>(typst-toggle-trailing-comma)`, `<Plug>(typst-add-trailing-comma)`,
`<Plug>(typst-remove-trailing-comma)`,
`<Plug>(typst-toggle-label)`, `<Plug>(typst-toggle-reference)`,
`<Plug>(typst-toggle-label-reference)`,
`<Plug>(typst-surround-content)`, `<Plug>(typst-surround-equation)`,
`<Plug>(typst-surround-figure)`, `<Plug>(typst-surround-block)`,
`<Plug>(typst-surround-strong)`, `<Plug>(typst-surround-emph)`,
`<Plug>(typst-toggle-strong)`, `<Plug>(typst-toggle-emph)`,
`<Plug>(typst-toggle-figure)`, `<Plug>(typst-toggle-list)`,
`<Plug>(typst-toggle-bullet-list)`, `<Plug>(typst-toggle-numbered-list)`,
`<Plug>(typst-toggle-equation-numbering)`, and `<Plug>(typst-convert-raw)` are
registered without default keys; users may map them and still get repeatable
edits through the same repeat bridge. When `repeat#set()` is available,
typst.nvim registers the structural edit there as well.

Textobject plugs include `<Plug>(typst-inner-delimiter)`,
`<Plug>(typst-outer-delimiter)`, `<Plug>(typst-inner-block)`,
`<Plug>(typst-outer-block)`, `<Plug>(typst-inner-structural-block)`,
`<Plug>(typst-outer-structural-block)`, `<Plug>(typst-inner-raw-block)`,
`<Plug>(typst-outer-raw-block)`, `<Plug>(typst-inner-list-item)`,
`<Plug>(typst-outer-list-item)`, `<Plug>(typst-inner-label)`,
`<Plug>(typst-outer-label)`, `<Plug>(typst-inner-import)`, and
`<Plug>(typst-outer-import)` in addition to the original heading, section,
equation, content, code block, call, and argument plugs.

## Not Public

Modules below `lua/typst/` other than `lua/typst/init.lua` are implementation
details unless explicitly documented here. Users should not depend on internal
project table shape beyond values returned by `status()` and documented event
payloads.

## Compatibility Policy

Before a 1.0 release, incompatible changes should be rare but may happen when
they simplify the public model. Such changes should be documented in
`MIGRATION.md`. Ecosystem acknowledgements belong in `CREDITS.md`.

After a 1.0 release, breaking changes to commands, documented Lua functions,
event names, and `<Plug>` mappings should require a major version bump.
