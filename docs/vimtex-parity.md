# VimTeX Parity Matrix

This file tracks capability parity against VimTeX help sections, using the
VimTeX `doc/vimtex.txt` contents list as the source of section names. It is a
roadmap document, not a claim that every `Partial` row is release-ready.

Primary references:

- VimTeX README: https://raw.githubusercontent.com/lervag/vimtex/master/README.md
- VimTeX help: https://raw.githubusercontent.com/lervag/vimtex/master/doc/vimtex.txt
- Typst CLI args: https://raw.githubusercontent.com/typst/typst/main/crates/typst-cli/src/args.rs
- Tinymist README: https://raw.githubusercontent.com/Myriad-Dreamin/tinymist/main/README.md

Classification legend:

- `DIRECT`: Same feature and behavior category can exist in typst.nvim.
- `REINTERPRETED`: Same user goal, but implemented with Typst-native concepts.
- `DELEGATED`: typst.nvim owns the user-facing surface but delegates the engine
  to Neovim, Tinymist, typst-preview.nvim, a picker, or an external tool.
- `NOT APPLICABLE`: LaTeX-only concept with a stated Typst replacement.

Status legend:

- `Implemented`: Current code and tests cover the feature class.
- `Partial`: Current code covers a useful subset, but more roadmap work remains.
- `Planned`: The parity target is accepted, but implementation is still missing.
- `Delegated`: typst.nvim intentionally integrates with another tool.
- `N/A`: No Typst equivalent should be implemented.

## Current Position

typst.nvim now covers most top-level VimTeX workflow categories. The remaining
work is concentrated in lifecycle correctness, richer semantic polish, a real
previous Typst metadata artifact, and Typst-native workflows that should go
beyond a direct port. The Phase 1 tactile editing baseline is complete, and the
Phase 2 ecosystem API baseline is implemented.

| Area | Current position |
| --- | --- |
| Multi-file projects and main-file resolution | At or above basic VimTeX parity. |
| Compilation, watch mode, diagnostics, profiles | Broad parity, but release-grade process lifecycle still needs hardening. |
| Preview and viewers | Correct Typst-native reinterpretation through output viewers and browser preview source maps. |
| TOC and project navigation | At or above VimTeX's basic feature set. |
| Completion | Broad fallback coverage with async Tinymist cache and native/cmp/blink/omnifunc adapter surfaces. |
| Motions and text objects | Strong. |
| Structural transformations | Strong baseline with generic delete/change surrounding operations and Typst-native tactile toggles. |
| Syntax, injections, conceal | Strong core, with package extension API and built-in CeTZ profile; performance work remains. |
| Folding and indentation | Configurable baseline with fold refresh, fold text, and conservative Typst prose `formatexpr`. |
| Context menu and bibliography actions | Strong, with bibliography diagnostics, insertion-ready picker entries, and conservative BibTeX/Hayagriva fold/indent helpers. |
| Package resources and symbol information | Typst-native replacement for texdoc-style workflows. |
| Extensibility, events, providers, health | Strong. |

## Parity Entries

| VimTeX tag | VimTeX section | Classification | typst.nvim equivalent | Status |
| --- | --- | --- | --- | --- |
| `|vimtex-introduction|` | Introduction | DIRECT | Project overview in README, help, and API docs. | Implemented |
| `|vimtex-comment-internal|` | Comment on internal tex plugin | NOT APPLICABLE | Typst filetype setup; no built-in TeX plugin conflict. | N/A |
| `|vimtex-features|` | Feature overview | DIRECT | README status and feature list. | Partial |
| `|vimtex-requirements|` | Requirements | REINTERPRETED | Neovim 0.11+, Typst CLI, optional Tinymist/preview/parser integrations. | Implemented |
| `|vimtex-multi-file|` | Support for multi-file projects | REINTERPRETED | Project registry keyed by `(root, main)`, dependency graph, buffer membership. | Implemented |
| `|vimtex-tex-directives|` | Support for TeX specifiers | REINTERPRETED | Typst main-file configuration, buffer override, root/main decision reporting. | Partial |
| `|vimtex-package-detection|` | Package detection | REINTERPRETED | Typst imports, package specs, cached package resources, project index. | Partial |
| `|vimtex-and-friends|` | Integration with other plugins | DELEGATED | Tinymist, typst-preview.nvim, Telescope/fzf-lua/fzf.vim/Snacks pickers, formatters, linters, snippet engines. | Partial |
| `|vimtex-usage|` | Usage | DIRECT | README command examples and `doc/typst.txt`. | Implemented |
| `|vimtex-default-mappings|` | Default mappings | DIRECT | Buffer-local Typst mappings for motions, text objects, follow, repeat, match. | Implemented |
| `|vimtex-options|` | Options | DIRECT | Validated `setup()` configuration in `lua/typst/config/`. | Implemented |
| `|vimtex-commands|` | Commands | DIRECT | Public `:Typst*` command surface covered by API contract tests, including all-project status and clean/full-clean semantics. | Implemented |
| `|vimtex-mappings|` | Map definitions | DIRECT | Stable `<Plug>(typst-...)` mappings, configurable defaults, generic surround delete/change targets, smart close/function creation plugs, and line-break/delimiter-size toggles. | Implemented |
| `|vimtex-imaps|` | Insert mode mappings | REINTERPRETED | Opt-in context-aware imap registry with built-ins, `:TypstImapsList`, and runtime register/unregister APIs; snippets remain delegated. | Implemented |
| `|vimtex-events|` | Events | DIRECT | `TypstEvent*` lifecycle user events plus compatibility aliases. | Implemented |
| `|vimtex-text-objects|` | Text objects | REINTERPRETED | Typst heading, section, equation, delimiter, block, raw, call, argument, label, import objects with optional Tinymist Neovim LSP selection-range fallback. | Implemented |
| `|vimtex-completion|` | Completion | REINTERPRETED | Project-index fallback plus local/imported named parameters, filesystem paths, metadata-backed symbols/emojis, CSL styles, packages/templates, raw language tags, color names, font families, and optional Tinymist Neovim LSP completion when already attached. | Partial |
| `|vimtex-complete-cites|` | Complete citations | REINTERPRETED | Bibliography key completion from project index plus dedicated bibliography picker entries and diagnostics. | Implemented |
| `|vimtex-complete-labels|` | Complete labels | REINTERPRETED | Typst label/reference completion from project index. | Partial |
| `|vimtex-complete-commands|` | Complete commands | REINTERPRETED | Typst symbols/emojis, local functions, imported names, and package/template specs. | Partial |
| `|vimtex-complete-environments|` | Complete environments | NOT APPLICABLE | Typst content blocks, function calls, figures, tables, equations. | N/A |
| `|vimtex-complete-filenames|` | Complete file names | REINTERPRETED | Import, image, bibliography, data, and raw-block path completion from project references and current-directory filesystem scans. | Partial |
| `|vimtex-complete-glossary|` | Complete glossary entries | REINTERPRETED | Project-index glossary entries complete from conservative `#let` glossary/acronym/term data; package-specific schema extraction remains future work. | Partial |
| `|vimtex-complete-packages|` | Complete packages | REINTERPRETED | Cached Typst package namespace/name/version completion plus optional local Universe index data. | Partial |
| `|vimtex-complete-classes|` | Complete documentclasses | NOT APPLICABLE | Cached Typst template package completion and project entry points replace document classes. | Partial |
| `|vimtex-complete-bibstyle|` | Complete bibliographystyles | REINTERPRETED | CSL style IDs, configured styles, and project-local `.csl` files. | Partial |
| `|vimtex-complete-auto|` | Autocomplete | DELEGATED | Native LSP-style items, omnifunc, nvim-cmp and blink.cmp adapter/source APIs. | Implemented |
| `|vimtex-complete-coc.nvim|` | coc.nvim | DELEGATED | Completion UI integration remains user-selected. | Delegated |
| `|vimtex-complete-deoplete|` | deoplete | DELEGATED | Completion UI integration remains user-selected. | Delegated |
| `|vimtex-complete-neocomplete|` | Neocomplete | DELEGATED | Completion UI integration remains user-selected. | Delegated |
| `|vimtex-complete-ncm2|` | ncm2 | DELEGATED | Completion UI integration remains user-selected. | Delegated |
| `|vimtex-complete-ncm|` | nvim-completion-manager | DELEGATED | Completion UI integration remains user-selected. | Delegated |
| `|vimtex-complete-youcompleteme|` | YouCompleteMe | DELEGATED | Completion UI integration remains user-selected. | Delegated |
| `|vimtex-complete-vcm|` | VimCompletesMe | DELEGATED | Completion UI integration remains user-selected. | Delegated |
| `|vimtex-complete-nvim-cmp|` | nvim-cmp | DELEGATED | `require("typst").completion.cmp()` and `cmp_source()` expose nvim-cmp-shaped completion data. | Implemented |
| `|vimtex-complete-nvim-compe|` | nvim-compe | DELEGATED | Completion UI integration remains user-selected. | Delegated |
| `|vimtex-complete-mucomplete|` | MUcomplete | DELEGATED | Completion UI integration remains user-selected. | Delegated |
| `|vimtex-folding|` | Folding | REINTERPRETED | Tree-sitter heading/content/function/raw-block folds, heading fallback, fold kind config, fold text callback, manual mode, and `:TypstRefreshFolds`. | Implemented |
| `|vimtex-indent|` | Indentation | REINTERPRETED | Tree-sitter indentation query extension, cached raw-fence ranges, delimiter/math/list rules, and conservative Typst prose/comment `formatexpr`. | Implemented |
| `|vimtex-syntax|` | Syntax highlighting | REINTERPRETED | Typst Tree-sitter query ownership for highlighting, conceal, folds, injections. | Partial |
| `|vimtex-syntax-core|` | Syntax core specification | REINTERPRETED | Core Typst highlight/conceal/text-object/fold/indent/injection queries, Markdown Typst-fence injection, spell/nospell regions, TODO/error captures, and parser-backed fixtures. | Partial |
| `|vimtex-syntax-packages|` | Syntax package specification | REINTERPRETED | Package-aware syntax extension layer for configured Typst package specs, with built-in CeTZ highlighting and custom package member rules. | Implemented |
| `|vimtex-syntax-conceal|` | Syntax conceal | REINTERPRETED | Metadata-backed and custom math symbols, opt-in emoji conceal, plus syntax-backed structural, function-wrapper, raw/list, label, reference, and citation punctuation conceal. | Partial |
| `|vimtex-syntax-reference|` | Syntax group reference | REINTERPRETED | Help documents shipped Typst highlight groups and Tree-sitter captures for conceal, text objects, folds, indents, and injections. | Implemented |
| `|vimtex-navigation|` | Navigation | REINTERPRETED | Typst motions, follow target, TOC, labels, citations, symbols. | Partial |
| `|vimtex-includeexpr|` | Include expression (gf command) | REINTERPRETED | Enhanced `gf` for imports, files, package specs, URLs, labels, refs. | Implemented |
| `|vimtex-toc|` | Table of contents | REINTERPRETED | Dedicated layered Typst TOC backed by Tree-sitter/project index/Tinymist symbols with picker reuse. | Partial |
| `|vimtex-toc-custom-maps|` | Custom mappings | DIRECT | TOC buffers support configurable jump, preview, close, refresh, toggle, layer-toggle, filter, and clear-filter mappings. | Implemented |
| `|vimtex-denite|` | Denite source | DELEGATED | `pick_items()` exposes normalized project and TOC-model items for custom picker consumers. | Partial |
| `|vimtex-unite|` | Unite source | DELEGATED | `pick_items()` exposes normalized project and TOC-model items for custom picker consumers. | Partial |
| `|vimtex-fzf|` | fzf.vim integration | DELEGATED | `:TypstPick` includes a `fzf_vim` backend over public index items. | Implemented |
| `|vimtex-fzf-lua|` | fzf-lua integration | DELEGATED | `:TypstPick` includes an fzf-lua backend over public index items. | Implemented |
| `|vimtex-snacks|` | Snacks integration | DELEGATED | `:TypstPick` includes a Snacks backend over public index items. | Implemented |
| `|vimtex-compiler|` | Compilation | REINTERPRETED | Typst one-shot compile, watch, provider interface, all-project status, stop, logs, and clean/full-clean semantics; lifecycle hardening remains parity work. | Partial |
| `|vimtex-compiler-latexmk|` | Latexmk | NOT APPLICABLE | Typst CLI watch/compile and provider interface replace latexmk. | N/A |
| `|vimtex-compiler-latexrun|` | Latexrun | NOT APPLICABLE | Typst CLI diagnostics and provider interface replace latexrun. | N/A |
| `|vimtex-compiler-tectonic|` | Tectonic | NOT APPLICABLE | Typst CLI/provider interface replaces TeX engines. | N/A |
| `|vimtex-compiler-arara|` | Arara | NOT APPLICABLE | Project-specific task/generic compiler providers replace TeX automation directives and are covered by provider lifecycle tests. | Implemented |
| `|vimtex-compiler-generic|` | Generic | DIRECT | Custom compile/watch provider support. | Implemented |
| `|vimtex-lint|` | Syntax Checking (Linting) | REINTERPRETED | Typst/Tinymist/command lint providers, font diagnostics, and quickfix integration. | Implemented |
| `|vimtex-grammar|` | Grammar Checking | DELEGATED | `:TypstGrammar` runs external prose/grammar providers, normalizes provider output, and publishes diagnostics/quickfix. | Implemented |
| `|vimtex-grammar-textidote|` | textidote | DELEGATED | `grammar.provider = "textidote"` command preset with textidote line/column output parsing. | Implemented |
| `|vimtex-grammar-vlty|` | vlty | DELEGATED | `grammar.provider = "vlty"` command preset with Vale/vlty-style JSON output parsing through the grammar provider API. | Implemented |
| `|vimtex-view|` | View | REINTERPRETED | Generic output opener plus native browser/viewer preview. | Partial |
| `|vimtex-view-configuration|` | Viewer configuration | DIRECT | `viewer.open`, `viewer.args`, `viewer.forward`, and placeholders. | Implemented |
| `|vimtex-view-evince|` | Evince | DELEGATED | Named PDF viewer preset opens/reuses Typst output; source sync remains capability-gated. | Partial |
| `|vimtex-view-galley|` | Galley | REINTERPRETED | Native browser preview serves typst.nvim compiler output from a local loopback shell; source-map callbacks and explicit typst-preview.nvim compatibility remain capability-gated. | Implemented |
| `|vimtex-view-mupdf|` | MuPDF | DELEGATED | Named PDF viewer preset opens/reuses Typst output; source sync remains capability-gated. | Partial |
| `|vimtex-view-okular|` | Okular | DELEGATED | Named PDF viewer preset opens/reuses Typst output; source sync remains capability-gated. | Partial |
| `|vimtex-view-qpdfview|` | qpdfview | DELEGATED | Named PDF viewer preset opens/reuses Typst output; source sync remains capability-gated. | Partial |
| `|vimtex-view-sioyek|` | Sioyek | DELEGATED | Named PDF viewer preset opens/reuses Typst output; source sync remains capability-gated. | Partial |
| `|vimtex-view-skim|` | Skim | DELEGATED | Named PDF viewer preset opens/reuses Typst output; source sync remains capability-gated. | Partial |
| `|vimtex-view-sumatrapdf|` | SumatraPDF | DELEGATED | Named PDF viewer preset opens/reuses Typst output; source sync remains capability-gated. | Partial |
| `|vimtex-view-texshop|` | TeXShop | NOT APPLICABLE | Typst output viewers replace TeXShop-specific workflows. | N/A |
| `|vimtex-view-zathura|` | Zathura | DELEGATED | Named PDF viewer preset opens/reuses Typst output; source sync remains capability-gated. | Partial |
| `|vimtex-view-zathura-simple|` | Zathura (simple) | DELEGATED | Zathura preset covers simple output opening; source sync remains capability-gated. | Partial |
| `|vimtex-synctex|` | Synctex | NOT APPLICABLE | Typst preview source maps replace SyncTeX where available. | N/A |
| `|vimtex-synctex-forward-search|` | Forward search | REINTERPRETED | `:TypstViewForward` with configured viewer or preview backend. | Implemented |
| `|vimtex-synctex-inverse-search|` | Inverse search | REINTERPRETED | `:TypstViewInverse` and `:TypstPreviewInverse` handle source locations from declared viewer/preview source-map capabilities. | Implemented |
| `|vimtex-latexdoc|` | LaTeX Documentation | REINTERPRETED | Tinymist owns semantic docs; typst.nvim provides generated built-in stdlib/symbol metadata and cached package resource navigation, not a texdoc-style package manual. | Partial |
| `|vimtex-context-menu|` | Context menu | REINTERPRETED | Typst context menu for function signatures, generated symbol variants, packages/templates, cached package updates, citations, label copy/reference/rename actions, definition occurrences, open/reveal/copy path actions, images, colors, fonts, headings, and equations. | Partial |
| `|vimtex-context-citation|` | Citation context | REINTERPRETED | Bibliography entry/DOI/URL/PDF actions for Typst citations. | Implemented |
| `|vimtex-code|` | Code structure | DIRECT | Lua module boundaries, provider interfaces, public provider registration, and API docs. | Partial |
| `|vimtex-code-api|` | API | DIRECT | `API.md`, provider registry docs, contract tests, documented commands/functions/events/plugs. | Implemented |
| `|vimtex-credits|` | Credits | DIRECT | `CREDITS.md` acknowledges VimTeX, Typst, Tinymist, typst-preview.nvim, tree-sitter-typst, math-conceal.nvim, Neovim, and the preserved prototype. | Implemented |

## Remaining Direct VimTeX Parity

The remaining gap is not a missing skeleton. typst.nvim already has projects,
compile/watch, diagnostics, preview/view, TOC, completion, motions, text
objects, syntax, conceal, context actions, providers, events, and health. The
remaining VimTeX-shaped work is about predictable background operations,
completion and bibliography polish, and ecosystem integrations.

### Surrounding Editing Language

typst.nvim has `TypstUnwrapFunction`, `TypstChangeFunction`,
`TypstChangeDelimiter`, surround commands, generic delete/change surrounding
commands, equation conversion, argument transforms, figure/list/raw transforms,
and markup toggles:

```text
<Plug>(typst-surround-delete-call)
<Plug>(typst-surround-delete-delimiter)
<Plug>(typst-surround-delete-block)
<Plug>(typst-surround-delete-equation)

<Plug>(typst-surround-change-call)
<Plug>(typst-surround-change-delimiter)
<Plug>(typst-surround-change-block)
<Plug>(typst-surround-change-equation)
```

The Phase 1 baseline operations resolve the nearest supported surrounding
construct and are covered by contract and transform tests. Deeper operator
coverage, where useful, is post-Phase-1 polish rather than a blocker for this
phase.

Typst-native transforms now include simple local toggles for:

- `a / b` to and from `frac(a, b)` on simple same-line forms.
- Ordinary same-line delimiters to and from auto-sized `lr(...)`.
- Markup line-break insertion/removal.

Post-Phase-1 transforms to deepen:

- Content block to and from code block where semantics permit.
- Positional to and from named arguments.
- Shorthand to and from explicit function form.
- Plain content to and from figure, equation, or table wrappers.

LaTeX-only star/environment toggles should be explicitly marked not applicable
unless there is a real Typst workflow behind them.

### Insert-Mode Mapping Engine

Current paired insert helpers are complemented by an opt-in context-aware
insert mapping registry:

```text
:TypstImapsList
require("typst").imaps.register(...)
require("typst").imaps.unregister(...)
require("typst").imaps.active(bufnr)
```

An entry should support:

```lua
{
  lhs = ";a",
  rhs = "alpha",
  modes = { "math" },
  condition = function(ctx) end,
  priority = 100,
  description = "Typst alpha symbol",
}
```

Current built-ins cover common Greek/math names, `frac`, `sqrt`, and an inline
equation pair. Post-Phase-1 built-ins to consider:

- Common structural pairs.
- Continue `///`, `//!`, and `//` comments on Enter.
- Equation-aware Enter behavior.
- Smart list continuation.
- Smart closing of the nearest content block, call, equation, raw span, or
  delimiter.
- Convert the preceding identifier or selection into a function call.

This must not become a snippet engine. Full snippets and templates remain
delegated to snippet plugins.

### Matching-Pair Highlighting

`%` navigation exists, and typst.nvim now has a matching-pair decoration
provider for delimiter, equation, raw-fence, content-block, call, and trailing
content pairs. Post-Phase-1 highlight coverage:

- Opening and closing constructs represented by different syntax nodes.

Navigation and highlighting should stay separate so users can keep `%` while
disabling the more expensive highlight provider. Later extensions can cover
middle constructs such as table/grid boundaries or conditional branches.

### Compiler Command Parity

Two command semantics now have baseline coverage:

- All-project status is available through `:TypstStatusAll`.
- `:TypstClean` removes temporary artifacts, while `:TypstClean!` also removes
  the resolved generated output. A richer artifact registry is still future
  work.

The status UI should make multiple projects comparable:

```text
main.typ     watching   last build success  0 errors
slides.typ   idle       last build failed   3 errors
manual.typ   compiling  pid 12345
```

Compiler reliability remains more important than new compiler commands.
Phase 0 already covered the baseline process ownership fixes; release hardening
continues with:

- Wait until an old process exits before starting its replacement.
- Bind callbacks and stream chunks to their originating process.
- Bind each active run to the provider instance that created it.
- Terminate process trees reliably on exit.
- Make stop/restart and watcher-cycle tests deterministic.
- Treat Typst's human-readable watch output as best-effort compatibility only;
  prefer stable structured JSON-line watch events whenever a Typst executable
  or wrapper provides them.
- Check real return codes for temporary-file cleanup and generated-output
  deletion.

### Folding And Indentation

Tree-sitter folding has configurable fold classes, fold text, manual mode, and
heading fallback:

```lua
folds = {
  headings = true,
  imports = true,
  comments = false,
  content_blocks = true,
  code_blocks = true,
  calls = false,
  equations = true,
  raw_blocks = true,
  arrays = false,
  dictionaries = false,
  bibliography = true,

  text = function(ctx)
    return ...
  end,

  mode = "expr", -- or "manual"
}
```

`:TypstRefreshFolds` refreshes fold settings and recomputes folds.

Post-Phase-1 indentation polish:

- Cached raw/string/comment regions instead of rescanning preceding lines.
- Configurable delimiter indentation.
- Table/grid cell alignment.
- Array and dictionary indentation.
- Show/set rule bodies.
- Hanging argument indentation.
- Dedicated `.bib` and Hayagriva behavior.
- More complete `formatexpr` coverage beyond conservative prose/comment
  paragraphs.

### Package Extension Ecosystem

typst.nvim exposes a package-aware syntax extension contract through
`syntax.packages`, `syntax.package_extensions()`, `package_matches()`,
`refresh()`, and `clear()`. The built-in CeTZ profile is the representative
package integration, and custom package member rules can be configured without
rewriting core Tree-sitter queries. A future companion package repository can
build on the same contract:

```lua
{
  package = "@preview/example",

  highlights = {},
  conceal = {},
  injections = {},
  folds = {},
  textobjects = {},
  toc = {},
  completion = {},
  context_actions = {},
}
```

High-value future extension categories include diagramming, presentations, theorem
systems, glossaries, algorithms, code listings, and citation helpers. Ship only
a small set of high-quality built-ins, or maintain a companion package
extension repository.

### Completion Frontends

Completion frontends consume one completion service:

```text
native LSP completion
nvim-cmp
blink.cmp
omnifunc
```

Implemented Phase 2 work:

- Insert-mode completion uses asynchronous Tinymist requests and cached
  responses instead of synchronous one-second waits.
- Stdlib, symbols, and emoji completion use prefix-range lookup and requested
  limits.
- `require("typst").completion.native()`, `.cmp()`, `.blink()`, `.cmp_source()`,
  and `.blink_source()` expose adapter surfaces while keeping UI ownership in
  the user's completion frontend.
- CI smoke tests install real `nvim-cmp` and `blink.cmp` modules and verify the
  source refresh contract against Tinymist responses.
- Frontend CI also drives real headless popup sessions for `nvim-cmp` and
  `blink.cmp`, verifies the `nvim-cmp` refresh hook path, and separately checks
  that cached adapter output preserves Tinymist text edits, snippets, additional
  edits, and commands. Full visual popup insertion and frontend-specific
  refresh rendering remain frontend-owned behavior rather than a typst.nvim CI
  guarantee.
- The syntactic project index is the documented fallback.

Post-Phase-2 completion polish:

- Semantic re-export, wildcard import, and alias resolution when Tinymist can
  provide richer data.

### Bibliography Workflow

Citation actions and BibTeX/Hayagriva parsing are already beyond a minimal
port. Phase 2 adds:

- Explicit undefined citation diagnostics.
- Duplicate bibliography-key diagnostics.
- Unused bibliography-entry diagnostics.
- Label/citation collision diagnostics.
- Dedicated `:TypstPick bibliography` source with insertion-ready `@key`,
  `#cite(<key>)`, or `<key>` values.
- Conservative BibTeX and Hayagriva fold/indent helper APIs.
- Citation-key rename.
- Formatted citation previews.
- Broader `crossref`, `xdata`, and BibTeX expansion semantics.
- Attachment discovery with configurable PDF fields and path patterns.
- Project bibliography status summaries.

Post-Phase-2 bibliography polish:

- Search by author, title, year, key, and keyword.
- Richer health/info rendering for bibliography summaries.

## Stable-Release Proof Gates

The feature baseline is intentionally broader than the stable-release proof.
Before declaring stable, these remaining proof gaps should be closed or kept
explicitly out of scope:

- Watch parsing should use stable structured watch events when Typst provides
  them. The human-readable parser remains fixture-gated best-effort
  compatibility.
- Package extensions should graduate from a working provider API and selected
  built-ins to a documented ecosystem contract with high-quality package
  integrations.

## Typst-Native Features Beyond VimTeX

Reaching VimTeX parity is not the final goal. Typst has workflows that do not
map cleanly to LaTeX and should become first-class.

### Exports And Artifacts

Typst can emit PDF, PNG, SVG, HTML, and bundle outputs with page selection,
PDF conformance, PPI, pretty output, dependency output, and timings. typst.nvim
now exposes a baseline artifact registry and export command set:

```text
:TypstExport [profile|format]
:TypstArtifacts
:TypstArtifactOpen
:TypstArtifactClean
```

Profiles support multiple artifacts through `exports.profiles`:

```lua
require("typst").setup({
  exports = {
    profiles = {
      release = {
        { format = "pdf", pdf_standard = { "a-2b" } },
        { format = "html", pretty = true },
        { format = "png", pages = { "1" }, ppi = 192 },
      },
    },
  },
})
```

Project state tracks `project.services.artifacts.items`, not only one compiler output.
Further work can make `TypstView` choose a viewer by artifact type
automatically.

### Evaluation And Introspection

The baseline uses `typst eval`; no new features are built around the deprecated
query interface.

```text
:TypstEval {expression}
:TypstEvalSelection
:TypstInspect
```

Implemented use cases:

- Evaluate an explicit expression.
- Evaluate selected source.
- Inspect the expression or word under the cursor.
- Show serialized JSON in a scratch buffer.

Future polish can add richer element-field, counter, show/set-rule, and module
export inspection UIs.

### CLI-Backed Template Initialization

Typst's own `typst init` is the primary path for local and published templates:

```text
:TypstInit [template] [directory]
:TypstTemplates
```

The baseline lists cached templates, supports exact template versions through
the CLI argument, opens the new main file when found, and keeps manual cache
copying as an explicit offline fallback with containment checks and staged
renames. The template gallery now combines cached template packages with
configured Universe-index template metadata and can drive no-argument
initialization.

### Profiling, Tests, Benchmarks, Coverage

The development namespace exists:

```text
:TypstProfile
:TypstTest
:TypstBench
:TypstCoverage
```

`TypstProfile` generates Typst `--timings` JSON and opens a scratch report.
`TypstTest` runs `tinymist test`, `TypstCoverage` runs
`tinymist test --coverage`, and `TypstBench` runs `crityp` when available.
Register providers with the `profile`, `test`, `bench`, and `coverage` provider
kinds to override the default commands.

### Semantic Editor Integrations

Tinymist remains the semantic engine; typst.nvim now owns stable command/API
wrappers for:

- Parameter-name inlay hint toggles.
- Color information with source and report swatches.
- Document links.
- Code-lens listing and refresh.
- Workspace symbols.
- Semantic selection expansion.
- References under the cursor.
- Rename previews before applying workspace edits.

Further work can add color picker actions, deeper code-lens execution polish,
document-link navigation commands, on-enter behavior, and reference highlighting
under the cursor.

### Rendered Editor Previews

The first version is explicit, not automatic inline rendering on every edit:

- `:TypstPreviewFragment` renders selected source.
- `:TypstPreviewEquation` renders an equation expression or selection.
- `:TypstPreviewImage` resolves an image path under the cursor.
- `:TypstPreviewPage` renders one page from the project main.
- `:TypstRenderCacheClear` clears cached rendered artifacts.

The baseline render cache is keyed by source, project context, format, page, and
executable. Terminal graphics support is provider-backed through the `render`
provider's `display(result, opts)` method, so Kitty, WezTerm, iTerm, or another
terminal image backend can be integrated without changing the core commands.
Future work can add true floating image buffers, color and gradient previews,
and richer cache keys for font state and exact Typst version.

## Features Not To Copy Literally

- `texdoc`: Typst has no equivalent package-manual resolver. Keep cached
  READMEs, source entrypoints, repository/homepage links, Universe pages,
  package resources, and Tinymist hover.
- SyncTeX for ordinary PDFs: browser preview source maps are the primary Typst
  equivalent; PDF sync remains capability-gated.
- Built-in snippet engine: delegate snippets and templates to snippet plugins.
  Examples or companion snippet sources are fine.
- LaTeX build engines and star toggles: `latexmk`, document classes, TeX
  engines, auxiliary-program orchestration, starred environments, and
  `\left`/`\right` behavior should only be copied when a real Typst workflow
  exists.

## Roadmap

### Phase 0: Reliability Gate

Do not add public features until these are fixed:

- Compiler stop/restart ordering.
- Watcher callback ownership.
- Process-tree shutdown.
- Shared Typst lexical masker.
- Lua 5.1 compatibility.
- Semantic-version handling.
- Filetype option and mapping restoration.
- Transactional rename/file writes.
- Template path containment.
- Asynchronous completion.
- Incremental conceal and indentation.

### Phase 1: Tactile VimTeX Parity

Status: complete.

Deliver:

- Generic delete/change surroundings. DONE.
- Smart close. DONE.
- Function creation. DONE.
- Rich configurable insert maps and `:TypstImapsList`. DONE.
- Fraction and delimiter-size toggles. DONE.
- Line-break toggle. DONE.
- Matching-pair highlighting. DONE.
- All-project status. DONE.
- Real clean versus clean-full. DONE.
- Configurable folding and fold text. DONE.
- Typst-aware `formatexpr`. DONE.

### Phase 2: Ecosystem Parity

Status: implemented baseline with current and previous Typst metadata snapshots.

Deliver:

- Completion adapters. DONE.
- Package extension API. DONE.
- Representative package integrations. DONE.
- Bibliography picker and diagnostics. DONE.
- Bibliography/Hayagriva folding and indentation. DONE.
- Stable custom TOC/index providers. DONE.
- Current and previous Typst metadata snapshots. DONE.

### Phase 3: Complete Typst Suite

Status: implemented with real Tinymist/crityp development commands, richer
template gallery data, and semantic color/code-lens UI polish.

Deliver:

- Multi-artifact export. DONE.
- `typst eval` integration. DONE.
- Template gallery and `typst init`. DONE.
- Profiling. DONE.
- Testing, benchmarking, and coverage. DONE.
- Semantic inlay/color/code-lens UX. DONE.
- HTML live-server workflow. EXPORT HELPER DONE.
- Presentation workflow. EXPORT HELPER DONE.

### Phase 4: Rendered Editor UX

Status: implemented with built-in terminal image display and richer in-buffer
image/color reports.

Deliver:

- Fragment and equation preview. DONE.
- Image preview. DONE.
- Page preview. DONE.
- Render caching. DONE.
- Optional terminal-image integration. DONE.

## Definition Of Complete

The suite is complete when:

1. Every VimTeX help section has a deliberate classification.
2. Project/build/navigation/edit/conceal work without Tinymist.
3. Tinymist enriches semantics without being mandatory.
4. Every background operation is asynchronous and cancellable.
5. No operation can silently corrupt or partially edit project files.
6. Multi-main projects, unnamed buffers, Unicode paths, and Windows process
   trees are tested.
7. Editing operations honor counts, operators, visual mode, registers,
   dot-repeat, and one-step undo.
8. The package extension API is stable.
9. Export, eval, init, profiling, and testing workflows are first-class.
10. The public command, Lua, event, and provider APIs are versioned and
    documented.
