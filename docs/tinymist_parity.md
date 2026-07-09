# Tinymist Parity Matrix

This file is the source of truth for typst.nvim's Tinymist integration plan.
The goal is not to wrap every LSP method for its own sake. Native Neovim LSP
should remain the default path when it already gives users the right behavior.
typst.nvim adds a wrapper when it needs project state, async guards, fallback
behavior, reports, pickers, command UI, or Tinymist-specific commands.

Status legend:

- `NATIVE_PASS_THROUGH`: use `vim.lsp.buf.*` or core Neovim UI directly.
- `WRAPPED`: typst.nvim adds guards, reports, normalization, command UI, or
  project-index integration.
- `PLUGIN_OWNED`: typst.nvim feature independent of Tinymist.
- `PARTIAL`: present but missing tests, API, docs, or complete wrapper coverage.
- `POST_1_0`: intentionally deferred.
- `NOT_APPLICABLE`: no meaningful Typst/Tinymist equivalent.

## Tinymist Wrapper Boundary

typst.nvim owns Tinymist startup policy through
`integrations.tinymist.lsp = "auto" | "detect" | "off" | "start"`. The default
`"auto"` mode starts or reuses Tinymist through Neovim's built-in LSP client,
unless coc.nvim appears active. That keeps Coc users on
`coc-tinymist` while still letting native Neovim LSP users get a managed Tinymist
client without requiring lspconfig.

Ordinary LSP behavior should stay native by default. Do not add a typst.nvim
wrapper just to mirror a `vim.lsp.buf.*` call or Neovim core LSP feature. These
features should remain native unless a row below states a concrete reason to
wrap them:

- semantic highlighting;
- goto definition;
- references;
- hover;
- rename;
- signature help;
- document highlight;
- folding range;
- inlay hints;
- code actions;
- formatting;
- document links;
- document symbols;
- workspace symbols;
- code lens;
- color provider.

Add or keep a typst.nvim wrapper only when at least one of these constraints
applies:

- async stale-result guards are needed;
- Tinymist data must be merged into the project index;
- typst.nvim needs a report or scratch-buffer UI;
- the result feeds quickfix, picker, TOC, context-menu, or status surfaces;
- typst.nvim needs fallback behavior when Tinymist is absent;
- the feature depends on Tinymist custom commands;
- formatting or workspace edits need safer apply guards;
- startup/client selection must preserve Coc coexistence policy.

Tinymist-specific wrappers should be callback-first and stale-safe. Interactive
paths must not block waiting for Tinymist; they should return fallback/project
data immediately and merge currently valid Tinymist cache when available.

## How To Use This Matrix

This document is normative for Tinymist-facing work. When a feature changes,
update the matrix and the named tests in the same patch. A status change should
mean one of these things changed: ownership, user-visible behavior, fallback
behavior, or the testing contract.

- `NATIVE_PASS_THROUGH` rows should stay thin. Do not add typst.nvim commands
  unless the feature needs guards, reports, fallback behavior, or project-index
  integration.
- `WRAPPED` rows must name the wrapper surface and at least one focused test.
  The wrapper may still delegate to `vim.lsp.*`; the point is that typst.nvim
  owns some behavior around the request or result.
- `PLUGIN_OWNED` rows may use Tinymist as a provider or command backend, but the
  lifecycle, reports, state, and user-facing contract belong to typst.nvim.
- `PARTIAL` rows are tracked debt. Keep them scarce and precise; each one should
  say what is missing.
- `POST_1_0` rows are intentionally deferred and should not be implied by help
  text or public commands.

Focused tests named in the matrix rows own the behavior. This document is a
product-boundary map, not a generated API surface.

## Implementation Map

- Startup and Coc policy: `lua/typst/integrations/tinymist/clients.lua`.
  This is the only layer that decides whether typst.nvim starts, reuses,
  ignores, or passively detects a native Neovim Tinymist client.
- Guarded request transport: `lua/typst/integrations/tinymist/async.lua`.
  Request wrappers should use this for changedtick, cursor, timeout, generation,
  and callback protection.
- No-UI feature facade: `lua/typst/integrations/tinymist/features.lua`.
  This module builds LSP params and normalizes results for document highlights,
  links, folds, signatures, colors, code lenses, selection ranges, and
  `experimental/onEnter`. It must not open windows, apply edits, or choose
  pickers.
- Execute-command bridge: `lua/typst/integrations/tinymist/commands.lua`.
  This handles LSP `Command` objects and custom Tinymist commands. It prefers
  `client.exec_cmd` when available, then falls back to
  `workspace/executeCommand`.
- Symbol and workspace-symbol cache: `lua/typst/integrations/tinymist/symbols.lua`
  plus `lua/typst/project/semantic.lua`. These are the only Tinymist paths that
  merge semantic symbols/references into the project index.
- Hover, definition, references, rename, and formatting requests:
  `lua/typst/integrations/tinymist/requests.lua`. Callers decide whether the
  result becomes a native LSP action, a typst.nvim report, or a fallback merge.
- Structural code actions:
  `lua/typst/integrations/tinymist/code_actions.lua`. This is the bridge between
  Tinymist code actions and stable editing commands such as heading promotion and
  equation conversion.
- Completion adapters: `lua/typst/completion/*`. Tinymist completion payloads
  must preserve edits, snippets, commands, and frontend-specific degradation.
- Health/status surface: `lua/typst/health.lua`, `lua/typst/statusline.lua`, and
  `lua/typst/info.lua`. These should describe the selected mode and detected
  capability state without starting extra clients.

## Startup And Health Contract

- `integrations.tinymist.lsp = "auto"` starts or reuses a native Neovim LSP
  Tinymist client when possible, but skips native Tinymist when coc.nvim appears
  active.
- Project-local availability is root-aware. A named native client with a
  different `root_dir` does not satisfy a typst.nvim project; rootless clients
  are considered compatible because some Neovim LSP clients are single-file or
  externally managed.
- `coc-tinymist` owns its own Coc language client and server settings such as
  `tinymist.serverPath` and `tinymist.serverArgs`; typst.nvim does not read Coc
  settings or send Tinymist wrapper requests through Coc.
- `"detect"` never starts Tinymist. It only uses an already-attached native
  Neovim client.
- `"off"` disables typst.nvim's native Tinymist integration. Coc or another LSP
  owner may still run outside typst.nvim.
- `"start"` forces typst.nvim to start/reuse native Tinymist even when Coc is
  present.
- `path`, `cmd`, `settings`, `init_options`, `capabilities`, and `on_attach`
  are passed through to `vim.lsp.start()` for `"auto"` and `"start"` modes.
- `:checkhealth typst` must report the normalized mode, attached native
  Tinymist clients, advertised capabilities, Coc detection, and the reason
  native Tinymist was skipped or ignored.
- `:TypstStatus`, `:TypstInfo`, and statusline data should report project-local
  Tinymist visibility and diagnostics policy, not just global client existence.

## Custom Command Inventory

Tinymist custom commands are executed through `tinymist.execute_command()`.
typst.nvim should not hard-code argument schemas for commands it does not own;
it should pass through LSP `Command` objects from code actions and code lenses.

- `tinymist.showTemplateGallery`: pass-through command. typst.nvim's package and
  template gallery remains plugin-owned.
- `tinymist.initTemplate`: pass-through command. typst.nvim's template init
  remains plugin-owned because it controls filesystem containment and rollback.
- `tinymist.initTemplateInPlace`: pass-through command with the same ownership
  boundary as `tinymist.initTemplate`.
- `tinymist.profileCurrentFile`: pass-through command available through the
  execute-command helper when users want Tinymist-owned profiling.
- Commands returned by `textDocument/codeAction`, `codeAction/resolve`,
  `textDocument/codeLens`, and `codeLens/resolve` must flow through the same
  execute-command bridge. This includes export/profile style commands returned
  by Tinymist.

## Wrapper Quality Gates

- Interactive wrappers must be callback-first. Do not introduce synchronous
  `client.request_sync()` calls in completion, TOC, context menu, follow,
  statusline, redraw, or insert-mode paths.
- Requests that can stale must carry the right guard: changedtick for buffer
  contents, cursor position for cursor-local actions, and project generation for
  index merges.
- Workspace edits must be previewable when the command advertises preview
  behavior, and stale edits must not be applied after the buffer changed.
- Fallback behavior must be explicit. If Tinymist is missing, typst.nvim either
  uses project/parser metadata or returns a structured unavailable result.
- Coc coexistence is part of the public contract. Native Neovim LSP support must
  not make Coc users run two Tinymist clients by default.

## Language Service Features

| Feature | Tinymist method/command | Native Nvim path | typst.nvim wrapper | Status | Tests | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| Managed Tinymist startup | `tinymist` executable over stdio | `vim.lsp.start()` | `typst.integrations.tinymist.clients.ensure()` | WRAPPED | `tests/unit/tinymist_lsp_policy_spec.lua`, `tests/integration/health_spec.lua`, `tests/unit/status_tinymist_spec.lua` | Keep rustaceanvim-style ownership: no lspconfig dependency, reuse existing clients, avoid native Tinymist when Coc is active unless `lsp = "start"`. |
| Client discovery and capability checks | Client capabilities | `vim.lsp.get_clients()` | `tinymist.clients()`, `supports_method()`, `available_for_project()` | WRAPPED | `tests/unit/tinymist_lsp_policy_spec.lua`, `tests/unit/status_tinymist_spec.lua` | Used by diagnostics suppression, status, health, semantic wrappers, and project attach. |
| Semantic highlighting | `textDocument/semanticTokens/full`, `textDocument/semanticTokens/range` | Neovim semantic-token engine | No command wrapper; startup/status may report Tinymist attachment | NATIVE_PASS_THROUGH | `tests/unit/tinymist_lsp_policy_spec.lua`, `tests/unit/tinymist_command_workflows_spec.lua`, `tests/unit/syntax_packages_spec.lua` | Let Neovim own semantic tokens. typst.nvim should only document the Tinymist startup config and verify attachment/capability visibility, not Neovim's renderer output. |
| Completion | `textDocument/completion` | Native completion, omnifunc, cmp/blink adapters | `typst.completion`, `typst.completion.lsp` | WRAPPED | `tests/unit/completion/sources_spec.lua`, `tests/integration/completion_frontends/completion_frontend_integration_spec.lua`, `tests/integration/completion_frontends/completion_frontend_popup_spec.lua`, `tests/unit/completion/generation_spec.lua` | Tinymist completion is preferred in semantic Typst contexts, then project/metadata fallback fills gaps. |
| Code actions | `textDocument/codeAction`, `codeAction/resolve`, `workspace/executeCommand` | `vim.lsp.buf.code_action()` | `typst.integrations.tinymist.code_actions`, `typst.edit.structural_action()`, `:TypstCodeAction` | WRAPPED | `tests/unit/tinymist_actions_spec.lua`, `tests/unit/tinymist_command_workflows_spec.lua`, `tests/unit/tinymist_interactive_async_spec.lua`, `tests/unit/context_menu_spec.lua` | Structural actions are stable commands; generic actions can be listed with `:TypstCodeAction` and applied by index when a scriptable wrapper is useful. Native `vim.lsp.buf.code_action()` remains valid for ordinary UI. |
| Heading promote/demote actions | `textDocument/codeAction` matching configured patterns | `vim.lsp.buf.code_action()` | `TypstPromoteHeading`, `TypstDemoteHeading`, `typst.edit.promote_heading()` | WRAPPED | `tests/unit/tinymist_actions_spec.lua`, `tests/unit/transform_spec.lua`, `tests/unit/context_menu_spec.lua` | Tinymist is preferred when a semantic quick fix exists; parser fallback preserves offline behavior. |
| Equation style actions | `textDocument/codeAction` matching equation patterns | `vim.lsp.buf.code_action()` | `TypstConvertEquation`, `typst.edit.convert_equation()` | WRAPPED | `tests/unit/tinymist_actions_spec.lua`, `tests/unit/transform_spec.lua` | Covers inline/block/toggle fallback today. Multiple-line block support should be tracked if Tinymist exposes a distinct action. |
| Formatting | `textDocument/formatting` | `vim.lsp.buf.format()` | `typst.integrations.tinymist.requests.format()`, `typst.formatting`, `:TypstFormat` | WRAPPED | `tests/unit/tinymist_format_async_spec.lua`, `tests/unit/format_async_spec.lua`, `tests/unit/format_lint_spec.lua` | typst.nvim owns safe application: Tinymist first when configured/available, then typstyle/typstfmt/command providers, all behind changedtick and stale-result guards. |
| Document highlight | `textDocument/documentHighlight` | `vim.lsp.buf.document_highlight()` | `tinymist.document_highlight()` facade only | NATIVE_PASS_THROUGH | `tests/unit/tinymist_features_spec.lua` | Native pass-through is enough for normal occurrence highlights. Keep the facade for guarded API/status use; add a command only if typst.nvim needs reports, toggles, or custom highlight groups. |
| Document links | `textDocument/documentLink`, `documentLink/resolve` | Native document-link support when available | `tinymist.document_links()`, `typst.semantic.document_links()`, `:TypstLinks` | WRAPPED | `tests/unit/tinymist_features_spec.lua`, `tests/unit/phase3_spec.lua` | Wrapper feeds report UI and path/link normalization. Dedicated resolve/open edge-case tests are still useful, but request transport belongs in the feature facade. |
| Document symbols | `textDocument/documentSymbol` | `vim.lsp.buf.document_symbol()` | `tinymist.document_symbols()`, TOC/index semantic overlay | WRAPPED | `tests/unit/toc_tinymist_spec.lua`, `tests/unit/index_tinymist_spec.lua`, `tests/unit/status_tinymist_spec.lua` | Normalizes LSP positions to byte columns and merges valid cache into project index/TOC. |
| Folding ranges | `textDocument/foldingRange` | LSP folding or `foldexpr` depending on user config | Tree-sitter folds plus `tinymist.folding_ranges()` facade for tests/status | NATIVE_PASS_THROUGH | `tests/unit/tinymist_features_spec.lua`, `tests/unit/folds_spec.lua`, `tests/unit/queries_spec.lua` | Do not build a custom folding UI. Document Neovim's LSP folding path and keep parser-backed folds as the offline plugin-owned path. |
| Goto definition | `textDocument/definition` | `vim.lsp.buf.definition()` | `tinymist.definition()`, follow fallback | WRAPPED | `tests/unit/follow_spec.lua`, `tests/unit/coordinate_unicode_matrix_spec.lua` | Wrapper is used where follow needs async guards and project-aware fallback. Native LSP remains fine for direct user mappings. |
| References | `textDocument/references` | `vim.lsp.buf.references()` | `tinymist.references()`, `typst.semantic.references()`, project semantic overlay | WRAPPED | `tests/unit/context_tinymist_references_spec.lua`, `tests/unit/index_tinymist_spec.lua`, `tests/unit/coordinate_unicode_matrix_spec.lua` | Results are normalized for reports, context menus, and semantic index merge. |
| Hover tips | `textDocument/hover` | `vim.lsp.buf.hover()` | `<Plug>(typst-hover)`, `typst.navigation.hover()` | NATIVE_PASS_THROUGH | `tests/unit/hover_spec.lua` | typst.nvim delegates hover to native LSP when available; no custom hover renderer should be added unless needed. |
| Inlay hints | `textDocument/inlayHint`, `inlayHint/resolve` | `vim.lsp.inlay_hint.enable()` | `typst.semantic.inlay_hints_toggle()`, `:TypstInlayHintsToggle` | NATIVE_PASS_THROUGH | `tests/unit/api_symbols_spec.lua`, `tests/policy/parity_doc_spec.lua` | Native Neovim renders and stores inlay hints. typst.nvim's toggle is only a convenience command. |
| Color provider | `textDocument/documentColor`, `textDocument/colorPresentation` | Native color support when available | `tinymist.document_color()`, `tinymist.color_presentation()`, `typst.semantic.color_info()`, `:TypstColorInfo`, `:TypstColorPresentation` | WRAPPED | `tests/unit/tinymist_features_spec.lua`, `tests/unit/tinymist_command_workflows_spec.lua`, `tests/unit/phase3_spec.lua` | typst.nvim wraps color reports/swatch display and can apply a selected Tinymist color presentation by index. |
| Code lens | `textDocument/codeLens`, `codeLens/resolve`, code-lens commands | `vim.lsp.codelens.refresh()`, `vim.lsp.codelens.run()` | `tinymist.code_lens()`, `typst.semantic.code_lens()`, `:TypstCodeLens`, `tinymist.execute_command()` | WRAPPED | `tests/unit/tinymist_features_spec.lua`, `tests/unit/tinymist_execute_command_spec.lua`, `tests/unit/phase3_spec.lua` | Wrapper lists and executes selected lenses while native code-lens refresh remains available. Returned commands go through the shared execute-command helper without becoming typst.nvim-owned workflows. |
| Rename symbols and embedded paths | `textDocument/rename` | `vim.lsp.buf.rename()` | `tinymist.rename()`, `typst.semantic.rename_preview()`, label/citation fallback rename | WRAPPED | `tests/unit/context_tinymist_rename_spec.lua`, `tests/unit/label_rename_transaction_spec.lua`, `tests/unit/bibliography/workflow_spec.lua` | Preview mode requests edits without applying. Parser fallbacks keep labels/citations usable without Tinymist. |
| Signature help | `textDocument/signatureHelp` | `vim.lsp.buf.signature_help()` | `tinymist.signature_help()` facade; project/metadata fallback signatures in completion | NATIVE_PASS_THROUGH | `tests/unit/tinymist_features_spec.lua`, `tests/unit/completion/sources_spec.lua`, `tests/unit/metadata_spec.lua` | Native pass-through is the user-facing path. Keep the facade for API consistency and guarded callers, not for a custom signature UI. |
| Workspace symbols | `workspace/symbol` | `vim.lsp.buf.workspace_symbol()` | `tinymist.workspace_symbols()`, `typst.semantic.workspace_symbols()`, semantic index overlay | WRAPPED | `tests/unit/status_tinymist_spec.lua`, `tests/unit/index_tinymist_spec.lua` | Workspace cache is generation/query guarded before merge. |
| Selection range | `textDocument/selectionRange` | Native clients/plugins may expose selection range | `typst.semantic.selection_expand()`, text-object fallback | WRAPPED | `tests/unit/textobjects_spec.lua`, `tests/unit/tinymist_interactive_async_spec.lua` | Used as a fallback for semantic selection when parser text objects do not cover the structure. |
| Experimental on-enter | `experimental/onEnter` | No standard native command | `tinymist.on_enter()`, `typst.semantic.on_enter()`, `:TypstOnEnter` | WRAPPED | `tests/unit/tinymist_features_spec.lua`, `tests/unit/tinymist_command_workflows_spec.lua` | Explicit opt-in helper applies returned edits behind the guarded Tinymist request path. It is intentionally not mapped to `<CR>` by default. |
| Diagnostics from Tinymist | `textDocument/publishDiagnostics` | Native LSP diagnostics | Diagnostics policy suppresses fallback compiler diagnostics when native Tinymist is attached or coc.nvim appears to own the Typst LSP session | WRAPPED | `tests/integration/diagnostics/publishing_spec.lua`, `tests/unit/status_tinymist_spec.lua` | Tinymist owns semantic diagnostics; typst.nvim keeps source/project fallback namespaces for non-Tinymist providers. |

## Tinymist CLI And Suite Features

| Feature | Tinymist method/command | Native Nvim path | typst.nvim wrapper | Status | Tests | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| Compile to PDF on save/watch | `tinymist` may compile internally; Typst CLI `compile/watch` | None | `typst.compiler.compile()`, `typst.compiler.watch()`, `:TypstCompile`, `:TypstWatch` | PLUGIN_OWNED | `tests/integration/compiler/lifecycle_spec.lua`, `tests/integration/watch/lifecycle_spec.lua`, `tests/unit/lifecycle_matrix_spec.lua` | typst.nvim owns compile/watch lifecycle rather than relying on LSP. |
| As-you-type or alternate compile triggers | Typst/Tinymist external behavior | Autocmds/timers | Compile/watch config and operations | PLUGIN_OWNED | `tests/integration/compiler/lifecycle_spec.lua`, `tests/integration/watch/process_spec.lua` | Keep debounce/restart behavior in compiler services, not Tinymist wrapper. |
| Export to PDF/SVG/PNG/HTML/Markdown/Text | Tinymist code lens/commands may export; Typst CLI export providers | None | `typst.artifact.export()`, `:TypstExport`, profiles, `tinymist.execute_command()` for returned LSP commands | PLUGIN_OWNED | `tests/unit/export_spec.lua`, `tests/unit/phase3_spec.lua`, `tests/integration/cleanup/clean_spec.lua`, `tests/unit/tinymist_execute_command_spec.lua` | Artifact ownership, path leases, profiles, and cleanup are plugin-owned. Tinymist export code lenses execute through the shared command helper when present. |
| Artifact registry/open/clean | Plugin-owned artifact registry | None | `typst.artifact.list/open/clean()` | PLUGIN_OWNED | `tests/unit/export_spec.lua`, `tests/integration/cleanup/clean_spec.lua`, `tests/integration/cleanup/clean_active_spec.lua` | Safety model is ownership/fingerprint/path-lease based. |
| Built-in linting | Tinymist diagnostics or CLI/provider lint | Native diagnostics | `typst.tools.lint()`, diagnostics namespaces | PLUGIN_OWNED | `tests/unit/format_lint_spec.lua`, `tests/unit/diagnostics/namespace_spec.lua`, `tests/unit/lint_grammar_generation_spec.lua` | Lint workflow and project/source namespaces are plugin-owned. Tinymist diagnostics remain native LSP diagnostics when attached. |
| Status bar data | LSP client state may be visible through LSP | User statusline | `typst.ui.statusline()`, `:TypstStatus`, `:TypstInfo` | PLUGIN_OWNED | `tests/integration/commands/status_spec.lua`, `tests/unit/status_tinymist_spec.lua`, `tests/integration/commands/info_spec.lua` | Includes compiler, diagnostics, word count, Tinymist attachment, and diagnostics policy. |
| Template gallery | `tinymist.showTemplateGallery` | None | `typst.template.list()`, `:TypstTemplates`, `tinymist.execute_command()` | PLUGIN_OWNED | `tests/unit/phase3_spec.lua`, `tests/unit/package_spec.lua`, `tests/unit/tinymist_execute_command_spec.lua` | Plugin gallery/resource data is canonical. Tinymist's gallery command is available through the shared command helper for users or future UI. |
| Initialize template | `tinymist.initTemplate`, `tinymist.initTemplateInPlace` | None | `typst.template.init()`, `:TypstInit`, `tinymist.execute_command()` | PLUGIN_OWNED | `tests/unit/phase3_spec.lua`, `tests/unit/template_rollback_spec.lua`, `tests/unit/tinymist_execute_command_spec.lua` | Filesystem safety, rollback, and containment are plugin-owned. Tinymist init commands can be executed explicitly through the helper. |
| Package resources and docs | Tinymist hover/resource support, package commands where available | Hover/native LSP | `typst.package.*`, `typst.symbol.*` | PLUGIN_OWNED | `tests/unit/package_spec.lua`, `tests/unit/symbol_spec.lua` | typst.nvim intentionally avoids a fake `texdoc`; package resources and Tinymist hover are the Typst-native model. |

## Remaining Wrapper Work

1. Keep Coc users first-class: `lsp = "auto"` must continue to avoid native
   Tinymist startup or reuse when Coc owns LSP. Use `"detect"` for passive
   native-client discovery and `"start"` to force native Tinymist.
