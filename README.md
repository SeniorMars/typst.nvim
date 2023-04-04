# typst.nvim
WIP. Goals: Tree-sitter highlighting, snippets, and a smooth integration with neovim.

For the past week, I've been thinking what I want for Neovim and typst.

I now believe that typst will big, and I want to fully support everything the best way I can.

So here is what I want:

- [ ] Treesitter support:
    - [ ] Conceal!
    - [ ] Code blocks
    - [ ] Highlighting
    - [ ] Folding
    - The issue is Typst is a big language, that I needed a break from this project for a bit.
- [ ] Rendering math typst blocks
    - [ ] To get this to work properly, I need to contribute to neovim's anticonceal feature.
    - [ ] Plus get image rendering to work as expected
- [ ] Snippets. Basically, port all the snippets I use from latex to typst.
- [ ] External PDF viewers. This is not so hard, but I need to a PR for this to work.

It's going to be a lot of work, but I'll get it done.

---

Currently working on the tree-sitter parser: https://github.com/SeniorMars/tree-sitter-typst


Language spec(?):
https://github.com/typst/typst/blob/main/tools/support/typst.tmLanguage.json

This plugin will take much inspiration from VimTeX and silicon.nvim :)


Note: since the language I'm most familiar with is rust, this project will probably be written in Rust.