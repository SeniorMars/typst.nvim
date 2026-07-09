# Credits

typst.nvim is built around Typst-native behavior while borrowing proven workflow
ideas from the broader Vim and Typst ecosystem.

- [VimTeX](https://github.com/lervag/vimtex) established the project-aware
  editing model this plugin adapts for Typst: main-file state, compiler
  workflows, viewers, TOC, completion, documentation, context actions, motions,
  text objects, and public events.
- [Typst](https://github.com/typst/typst) provides the language, CLI, package
  model, and Rust crates used by the release-time metadata generator.
- [Tinymist](https://github.com/Myriad-Dreamin/tinymist) provides the optional
  semantic language-service layer for hover, definitions, formatting, code
  actions, preview/export integration, and richer Typst analysis.
  provides an optional low-latency browser preview and source-jump backend.
- [tree-sitter-typst](https://github.com/SeniorMars/tree-sitter-typst)
  provides the parser foundation for Neovim queries, motions, folds,
  indentation, injections, text objects, and conceal.
- [math-conceal.nvim](https://github.com/pxwg/math-conceal.nvim) informed the
  viewport-scoped, Tree-sitter-assisted conceal architecture.
- Neovim's Lua, Tree-sitter, diagnostics, job, quickfix, extmark, decoration
  provider, and LSP APIs provide the runtime platform.

The old `nvim-oxi` prototype remains in `experiments/nvim-oxi/` as historical
context, but the maintained runtime is Lua-first and does not require native
Neovim modules.
