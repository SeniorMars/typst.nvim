local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")
local edit_repeat = require("typst.edit.repeat")
typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("transform-output"),
})

local function edit(lines)
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.bo[bufnr].filetype = "typst"
    local undolevels = vim.bo[bufnr].undolevels
    vim.bo[bufnr].undolevels = -1
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].undolevels = undolevels
    return bufnr
end

local function line(n)
    return vim.api.nvim_buf_get_lines(0, n - 1, n, false)[1]
end

edit({
    "#strong[inside]",
    '#figure([Hi], caption: [Cap], kind: "x")',
    "*hello*",
    "_there_",
    "plain text",
    "#table.cell[item]",
})

vim.api.nvim_win_set_cursor(0, { 1, 9 })
local result = typst.edit.change_function("emph", { notify = false })
assert(result.ok, result.message or "Typst change_function failed")
assert(
    line(1) == "#emph[inside]",
    "TypstChangeFunction should replace only the function name"
)

vim.api.nvim_win_set_cursor(0, { 1, 7 })
result = typst.edit.unwrap_function({ notify = false })
assert(result.ok, result.message or "Typst unwrap_function failed")
assert(
    line(1) == "inside",
    "TypstUnwrapFunction should replace the whole function call with content"
)

vim.api.nvim_win_set_cursor(0, { 2, 18 })
result = typst.edit.change_function("table", { notify = false })
assert(
    result.ok,
    result.message or "Typst change_function failed for grouped call"
)
assert(
    line(2) == '#table([Hi], caption: [Cap], kind: "x")',
    "TypstChangeFunction should preserve grouped arguments"
)

vim.api.nvim_win_set_cursor(0, { 3, 2 })
result = typst.edit.toggle_strong({ notify = false })
assert(result.ok, result.message or "Typst toggle_strong failed for markup")
assert(
    line(3) == "#strong[hello]",
    "TypstToggleStrong should convert markup to function form"
)

vim.api.nvim_win_set_cursor(0, { 3, 9 })
result = typst.edit.toggle_strong({ notify = false })
assert(
    result.ok,
    result.message or "Typst toggle_strong failed for function form"
)
assert(
    line(3) == "*hello*",
    "TypstToggleStrong should convert function form back to markup"
)

vim.api.nvim_win_set_cursor(0, { 4, 2 })
result = typst.edit.toggle_emph({ notify = false })
assert(result.ok, result.message or "Typst toggle_emph failed for markup")
assert(
    line(4) == "#emph[there]",
    "TypstToggleEmph should convert markup to function form"
)

vim.api.nvim_win_set_cursor(0, { 4, 7 })
result = typst.edit.toggle_emph({ notify = false })
assert(
    result.ok,
    result.message or "Typst toggle_emph failed for function form"
)
assert(
    line(4) == "_there_",
    "TypstToggleEmph should convert function form back to markup"
)

vim.api.nvim_win_set_cursor(0, { 5, 1 })
result = typst.edit.unwrap_function({ notify = false })
assert(
    not result.ok and result.reason == "no_call",
    "TypstUnwrapFunction should report no surrounding call"
)

vim.api.nvim_buf_set_lines(0, 4, 5, false, { "#emph[last]" })
vim.api.nvim_win_set_cursor(0, { 5, 6 })
local original_notify = vim.notify
vim.notify = function() end
vim.cmd("TypstChangeFunction strong")
vim.notify = original_notify
assert(
    line(5) == "#strong[last]",
    "TypstChangeFunction command should edit the surrounding call"
)

vim.api.nvim_win_set_cursor(0, { 6, 0 })
result = typst.edit.change_function("strong", { notify = false })
assert(
    result.ok,
    result.message or "Typst change_function failed for dotted call"
)
assert(
    line(6) == "#strong[item]",
    "TypstChangeFunction should handle # cursor and replace a dotted callee"
)

edit({
    "#box[first]",
    "#emph[second]",
})

typst.project.attach(0)
vim.api.nvim_win_set_cursor(0, { 1, 5 })
result = typst.edit.change_function("strong", { notify = false })
assert(
    result.ok,
    result.message or "Typst change_function failed before dot-repeat"
)
assert(
    line(1) == "#strong[first]",
    "TypstChangeFunction should prepare a repeatable edit"
)
local repeat_state = edit_repeat.state(0)
assert(
    repeat_state and repeat_state.command == "TypstChangeFunction strong",
    "TypstChangeFunction should register a repeat command"
)
vim.api.nvim_win_set_cursor(0, { 2, 6 })
original_notify = vim.notify
vim.notify = function() end
vim.cmd("normal .")
vim.notify = original_notify
assert(
    line(2) == "#strong[second]",
    "dot-repeat should replay the last Typst structural edit"
)

edit({
    "= Top",
    "== Child",
    "=== Counted",
    "====== Deep",
    "plain text",
})

vim.api.nvim_win_set_cursor(0, { 2, 1 })
result = typst.edit.promote_heading({ notify = false })
assert(result.ok, result.message or "Typst promote_heading failed")
assert(
    line(2) == "= Child",
    "TypstPromoteHeading should reduce the heading marker level"
)

vim.api.nvim_win_set_cursor(0, { 3, 1 })
result = typst.edit.demote_heading({ count = 2, notify = false })
assert(
    result.ok and result.count == 2,
    result.message or "Typst counted demote_heading failed"
)
assert(
    line(3) == "===== Counted",
    "TypstDemoteHeading should honor explicit transform counts"
)
vim.cmd("silent undo")
assert(
    line(3) == "=== Counted",
    "Counted TypstDemoteHeading should undo both changes in one step"
)
vim.api.nvim_win_set_cursor(0, { 3, 1 })
result = typst.edit.demote_heading({ count = 2, notify = false })
assert(
    result.ok,
    result.message or "Typst counted demote_heading failed after undo"
)
assert(
    line(3) == "===== Counted",
    "TypstDemoteHeading should reapply counted edits after undo"
)

vim.api.nvim_win_set_cursor(0, { 1, 1 })
local heading_notify = vim.notify
vim.notify = function() end
vim.cmd("TypstDemoteHeading")
vim.notify = heading_notify
assert(
    line(1) == "== Top",
    "TypstDemoteHeading command should increase the heading marker level"
)

vim.api.nvim_buf_set_lines(0, 1, 2, false, { "= Child" })
vim.api.nvim_win_set_cursor(0, { 2, 1 })
result = typst.edit.promote_heading({ notify = false })
assert(
    not result.ok and result.reason == "min_heading_level",
    "TypstPromoteHeading should reject level-1 headings"
)

vim.api.nvim_win_set_cursor(0, { 4, 1 })
result = typst.edit.demote_heading({ notify = false })
assert(
    not result.ok and result.reason == "max_heading_level",
    "TypstDemoteHeading should reject level-6 headings"
)

vim.api.nvim_win_set_cursor(0, { 5, 1 })
result = typst.edit.demote_heading({ notify = false })
assert(
    not result.ok and result.reason == "no_heading",
    "TypstDemoteHeading should require a heading"
)

edit({
    "#box[body]",
    "#let x = (1, 2)",
    "#let y = { a + b }",
    "$ x + y $",
    "plain text",
})

vim.api.nvim_win_set_cursor(0, { 1, 6 })
result = typst.edit.change_delimiter("block", { notify = false })
assert(result.ok, result.message or "Typst change_delimiter block failed")
assert(
    line(1) == "#box{body}",
    "TypstChangeDelimiter should change content brackets to braces"
)
vim.cmd("silent undo")
assert(
    line(1) == "#box[body]",
    ("TypstChangeDelimiter should undo both delimiter edits in one step, got %q"):format(
        line(1)
    )
)
result = typst.edit.change_delimiter("block", { notify = false })
assert(
    result.ok,
    result.message or "Typst change_delimiter block failed after undo"
)
assert(
    line(1) == "#box{body}",
    "TypstChangeDelimiter should reapply after undo"
)

vim.api.nvim_win_set_cursor(0, { 2, 12 })
result = typst.edit.change_delimiter("content", { notify = false })
assert(result.ok, result.message or "Typst change_delimiter content failed")
assert(
    line(2) == "#let x = [1, 2]",
    "TypstChangeDelimiter should change parentheses to content brackets"
)

vim.api.nvim_win_set_cursor(0, { 3, 12 })
result = typst.edit.change_delimiter("group", { notify = false })
assert(result.ok, result.message or "Typst change_delimiter group failed")
assert(
    line(3) == "#let y = ( a + b )",
    "TypstChangeDelimiter should change braces to parentheses"
)

vim.api.nvim_win_set_cursor(0, { 4, 3 })
result = typst.edit.change_delimiter("block", { notify = false })
assert(result.ok, result.message or "Typst change_delimiter math failed")
assert(
    line(4) == "{ x + y }",
    "TypstChangeDelimiter should change equation delimiters to braces"
)

vim.api.nvim_win_set_cursor(0, { 5, 1 })
result = typst.edit.change_delimiter("content", { notify = false })
assert(
    not result.ok and result.reason == "no_delimiter",
    "TypstChangeDelimiter should require a surrounding pair"
)

edit({
    "[body]",
})

vim.fn.setreg("a", "keep-register")
vim.api.nvim_win_set_cursor(0, { 1, 2 })
result = typst.edit.surround_delete_delimiter(nil, { notify = false })
assert(result.ok, result.message or "Typst surround_delete_delimiter failed")
assert(
    line(1) == "body",
    "TypstSurroundDeleteDelimiter should delete the nearest delimiter pair"
)
assert(
    vim.fn.getreg("a") == "keep-register",
    "Typst transforms should preserve explicit registers"
)
vim.cmd("silent undo")
assert(
    line(1) == "[body]",
    "TypstSurroundDeleteDelimiter should undo both delimiter deletions in one step"
)

edit({
    "#let z = { q }",
})

vim.api.nvim_win_set_cursor(0, { 1, 12 })
original_notify = vim.notify
vim.notify = function() end
vim.cmd("TypstChangeDelimiter equation")
vim.notify = original_notify
assert(
    line(1) == "#let z = $ q $",
    "TypstChangeDelimiter command should change delimiters by target"
)

edit({
    "first",
    "second",
    "third",
})

vim.fn.setreg("a", "visual-register")
result = typst.edit.surround_content({
    line1 = 1,
    line2 = 2,
    range = 2,
    notify = false,
})
assert(result.ok, result.message or "TypstSurroundContent range failed")
assert(
    line(1) == "[",
    "TypstSurroundContent should honor command and visual ranges"
)
assert(
    line(2) == "first",
    "TypstSurroundContent should keep the first selected line"
)
assert(
    line(3) == "second",
    "TypstSurroundContent should keep the second selected line"
)
assert(
    line(4) == "]",
    "TypstSurroundContent should close after the selected range"
)
assert(
    line(5) == "third",
    "TypstSurroundContent should not include the line after the selected range"
)
assert(
    vim.fn.getreg("a") == "visual-register",
    "Typst range transforms should preserve explicit registers"
)
vim.cmd("silent undo")
assert(line(1) == "first", "TypstSurroundContent range should undo in one step")
assert(
    line(2) == "second",
    "TypstSurroundContent range undo should restore selected content"
)
assert(
    line(3) == "third",
    "TypstSurroundContent range undo should preserve following content"
)

edit({
    "#rect(width: 1pt, height: 2pt, [body])",
})

vim.api.nvim_win_set_cursor(0, { 1, 10 })
result = typst.edit.split_arguments({ notify = false })
assert(result.ok, result.message or "Typst split_arguments failed")
assert(
    line(1) == "#rect(",
    "TypstSplitArguments should keep the function call prefix"
)
assert(
    line(2) == "  width: 1pt,",
    "TypstSplitArguments should split the first argument"
)
assert(
    line(3) == "  height: 2pt,",
    "TypstSplitArguments should split the second argument"
)
assert(
    line(4) == "  [body],",
    "TypstSplitArguments should split content arguments"
)
assert(line(5) == ")", "TypstSplitArguments should close the grouped call")

vim.api.nvim_win_set_cursor(0, { 2, 4 })
result = typst.edit.join_arguments({ notify = false })
assert(result.ok, result.message or "Typst join_arguments failed")
assert(
    line(1) == "#rect(width: 1pt, height: 2pt, [body])",
    "TypstJoinArguments should restore inline arguments"
)

edit({
    "#pad(x: 1pt, y: 2pt)",
})

vim.api.nvim_win_set_cursor(0, { 1, 8 })
original_notify = vim.notify
vim.notify = function() end
vim.cmd("TypstToggleArguments")
vim.notify = original_notify
assert(
    line(1) == "#pad(",
    "TypstToggleArguments command should split inline argument lists"
)
assert(
    line(2) == "  x: 1pt,",
    "TypstToggleArguments command should preserve named arguments"
)
assert(
    line(3) == "  y: 2pt,",
    "TypstToggleArguments command should preserve the second named argument"
)
assert(
    line(4) == ")",
    "TypstToggleArguments command should close split argument lists"
)

edit({
    "#pad(",
    "  x: 1pt,",
    "  y: 2pt,",
    ")",
})

vim.api.nvim_win_set_cursor(0, { 2, 4 })
result = typst.edit.toggle_arguments({ notify = false })
assert(result.ok, result.message or "Typst toggle_arguments join failed")
assert(
    line(1) == "#pad(x: 1pt, y: 2pt)",
    "TypstToggleArguments should join multiline argument lists"
)

edit({
    "#strong[body]",
})

vim.api.nvim_win_set_cursor(0, { 1, 9 })
result = typst.edit.split_arguments({ notify = false })
assert(
    not result.ok and result.reason == "no_argument_group",
    "TypstSplitArguments should require a parenthesized argument group"
)

edit({
    "#wrap(",
    "  [",
    "    body",
    "  ],",
    ")",
})

vim.api.nvim_win_set_cursor(0, { 2, 3 })
result = typst.edit.join_arguments({ notify = false })
assert(
    not result.ok and result.reason == "multiline_argument",
    "TypstJoinArguments should reject multiline argument bodies"
)
assert(
    line(1) == "#wrap(",
    "TypstJoinArguments should leave multiline argument lists unchanged on rejection"
)

edit({
    "#pad(",
    "  x: 1pt,",
    "  y: 2pt",
    ")",
})

vim.api.nvim_win_set_cursor(0, { 2, 4 })
result = typst.edit.add_trailing_comma({ notify = false })
assert(result.ok, result.message or "Typst add_trailing_comma failed")
assert(
    line(3) == "  y: 2pt,",
    "TypstAddTrailingComma should add a comma after the last top-level argument"
)

result = typst.edit.add_trailing_comma({ notify = false })
assert(
    not result.ok and result.reason == "already_trailing_comma",
    "TypstAddTrailingComma should report an existing trailing comma"
)

result = typst.edit.remove_trailing_comma({ notify = false })
assert(result.ok, result.message or "Typst remove_trailing_comma failed")
assert(
    line(3) == "  y: 2pt",
    "TypstRemoveTrailingComma should remove the final top-level comma"
)

result = typst.edit.toggle_trailing_comma("toggle", { notify = false })
assert(result.ok, result.message or "Typst toggle_trailing_comma failed")
assert(
    line(3) == "  y: 2pt,",
    "TypstToggleTrailingComma should add a missing trailing comma"
)

original_notify = vim.notify
vim.notify = function() end
vim.cmd("TypstToggleTrailingComma remove")
vim.notify = original_notify
assert(
    line(3) == "  y: 2pt",
    "TypstToggleTrailingComma command should accept remove mode"
)

edit({
    "#wrap(",
    "  [",
    "    body",
    "  ]",
    ")",
})

vim.api.nvim_win_set_cursor(0, { 2, 3 })
result = typst.edit.toggle_trailing_comma("add", { notify = false })
assert(
    result.ok,
    result.message or "Typst trailing comma add failed for multiline argument"
)
assert(
    line(4) == "  ],",
    "Typst trailing comma add should preserve multiline argument bodies"
)

result = typst.edit.toggle_trailing_comma("remove", { notify = false })
assert(
    result.ok,
    result.message
        or "Typst trailing comma remove failed for multiline argument"
)
assert(
    line(4) == "  ]",
    "Typst trailing comma remove should preserve multiline argument bodies"
)

edit({
    "#pad(x: 1pt, y: 2pt)",
})

vim.api.nvim_win_set_cursor(0, { 1, 8 })
result = typst.edit.toggle_trailing_comma("add", { notify = false })
assert(
    not result.ok and result.reason == "not_multiline",
    "TypstToggleTrailingComma should only edit multiline argument lists"
)

edit({
    "#let alert(body, fill: red, stroke: none) = body",
    "#alert([Hi], blue, stroke: black)",
})

vim.api.nvim_win_set_cursor(0, { 2, 8 })
result = typst.edit.name_arguments({ notify = false })
assert(result.ok, result.message or "Typst name_arguments failed")
assert(
    line(2) == "#alert(body: [Hi], fill: blue, stroke: black)",
    "TypstNameArguments should use local function parameter names"
)
vim.cmd("silent undo")
assert(
    line(2) == "#alert([Hi], blue, stroke: black)",
    ("TypstNameArguments should undo all argument edits in one step, got %q"):format(
        line(2)
    )
)
result = typst.edit.name_arguments({ notify = false })
assert(result.ok, result.message or "Typst name_arguments failed after undo")
assert(
    line(2) == "#alert(body: [Hi], fill: blue, stroke: black)",
    "TypstNameArguments should reapply after undo"
)

result = typst.edit.name_arguments({ notify = false })
assert(
    not result.ok and result.reason == "no_positional_arguments",
    "TypstNameArguments should report calls with no remaining positional arguments"
)

edit({
    "#let glyph(first, second) = first",
    '#glyph("α", [β])',
})

vim.api.nvim_win_set_cursor(0, { 2, 9 })
result = typst.edit.name_arguments({ notify = false })
assert(
    result.ok,
    result.message or "Typst name_arguments failed for Unicode arguments"
)
assert(
    line(2) == '#glyph(first: "α", second: [β])',
    "TypstNameArguments should use byte ranges when naming Unicode arguments"
)

edit({
    "#let note(body, fill: red) = body",
    "#note(",
    "  [Hi],",
    "  blue,",
    ")",
})

vim.api.nvim_win_set_cursor(0, { 3, 3 })
original_notify = vim.notify
vim.notify = function() end
vim.cmd("TypstNameArguments")
vim.notify = original_notify
assert(
    line(3) == "  body: [Hi],",
    "TypstNameArguments command should name multiline content arguments"
)
assert(
    line(4) == "  fill: blue,",
    "TypstNameArguments command should name multiline positional arguments"
)

edit({
    '#figure(image("diagram.svg"))',
})

vim.api.nvim_win_set_cursor(0, { 1, 10 })
result = typst.edit.name_arguments({ notify = false })
assert(
    not result.ok and result.reason == "positional_only_parameters",
    "TypstNameArguments should use stdlib metadata to reject positional-only built-in arguments"
)

edit({
    "#unknown-helper(1)",
})

vim.api.nvim_win_set_cursor(0, { 1, 10 })
result = typst.edit.name_arguments({ notify = false })
assert(
    not result.ok and result.reason == "no_parameter_metadata",
    "TypstNameArguments should report missing metadata for unknown calls"
)

edit({
    "#let collect(first, ..rest) = first",
    "#collect(1, 2)",
})

vim.api.nvim_win_set_cursor(0, { 2, 10 })
result = typst.edit.name_arguments({ notify = false })
assert(
    not result.ok and result.reason == "variadic_parameters",
    "TypstNameArguments should reject variadic local declarations"
)

edit({
    "= Intro <sec:intro>",
    "See @sec:intro.",
    "#ref(<sec:intro>)",
    "#label(<sec:intro>)",
    '#label("sec:plain")',
    "#cite(<doe2020>)",
    "plain text",
})

vim.api.nvim_win_set_cursor(0, { 1, 10 })
result = typst.edit.toggle_label({ notify = false })
assert(
    result.ok,
    result.message or "Typst toggle_label failed for shorthand form"
)
assert(
    line(1) == "= Intro #label(<sec:intro>)",
    "TypstToggleLabel should convert shorthand labels to calls"
)

vim.api.nvim_win_set_cursor(0, { 1, 14 })
result = typst.edit.toggle_label({ notify = false })
assert(
    result.ok,
    result.message or "Typst toggle_label failed for explicit form"
)
assert(
    line(1) == "= Intro <sec:intro>",
    "TypstToggleLabel should convert label calls to shorthand labels"
)

vim.api.nvim_win_set_cursor(0, { 2, 6 })
result = typst.edit.toggle_reference({ notify = false })
assert(
    result.ok,
    result.message or "Typst toggle_reference failed for shorthand form"
)
assert(
    line(2) == "See #ref(<sec:intro>).",
    "TypstToggleReference should convert shorthand references to calls"
)

vim.api.nvim_win_set_cursor(0, { 2, 7 })
result = typst.edit.toggle_reference({ notify = false })
assert(
    result.ok,
    result.message or "Typst toggle_reference failed for explicit form"
)
assert(
    line(2) == "See @sec:intro.",
    "TypstToggleReference should convert ref calls to shorthand references"
)

vim.api.nvim_win_set_cursor(0, { 3, 7 })
result = typst.edit.toggle_label_reference({ notify = false })
assert(
    result.ok,
    result.message
        or "Typst toggle_label_reference failed for explicit reference"
)
assert(
    line(3) == "@sec:intro",
    "TypstToggleLabelReference should dispatch to reference toggles"
)

vim.api.nvim_win_set_cursor(0, { 4, 9 })
result = typst.edit.toggle_label({ notify = false })
assert(
    result.ok,
    result.message or "Typst toggle_label failed for explicit label"
)
assert(
    line(4) == "<sec:intro>",
    "TypstToggleLabel should unwrap explicit label calls"
)

vim.api.nvim_win_set_cursor(0, { 5, 9 })
result = typst.edit.toggle_label({ notify = false })
assert(
    result.ok,
    result.message or "Typst toggle_label failed for string label"
)
assert(
    line(5) == "<sec:plain>",
    "TypstToggleLabel should convert plain string label calls"
)

vim.api.nvim_win_set_cursor(0, { 6, 9 })
result = typst.edit.toggle_label({ notify = false })
assert(
    not result.ok and result.reason == "label_argument",
    "TypstToggleLabel should not rewrite label arguments inside other calls"
)

vim.api.nvim_win_set_cursor(0, { 7, 1 })
result = typst.edit.toggle_label_reference({ notify = false })
assert(
    not result.ok and result.reason == "no_label_or_reference",
    "TypstToggleLabelReference should require a surrounding label or reference"
)

edit({
    "$x + y$",
    "",
    "$",
    "  a = b",
    "$",
    "Text $z$ tail.",
})

vim.api.nvim_win_set_cursor(0, { 1, 2 })
result = typst.edit.convert_equation("block", { notify = false })
assert(result.ok, result.message or "Typst convert_equation block failed")
assert(line(1) == "$", "TypstConvertEquation block should open display math")
assert(
    line(2) == "  x + y",
    "TypstConvertEquation block should preserve formula text"
)
assert(line(3) == "$", "TypstConvertEquation block should close display math")

vim.api.nvim_win_set_cursor(0, { 2, 4 })
result = typst.edit.convert_equation("inline", { notify = false })
assert(result.ok, result.message or "Typst convert_equation inline failed")
assert(
    line(1) == "$x + y$",
    "TypstConvertEquation inline should collapse display math"
)

vim.api.nvim_win_set_cursor(0, { 4, 4 })
result = typst.edit.convert_equation("toggle", { notify = false })
assert(result.ok, result.message or "Typst convert_equation toggle failed")
assert(
    line(3) == "$a = b$",
    "TypstConvertEquation toggle should convert block math to inline"
)

vim.api.nvim_win_set_cursor(0, { 4, 7 })
result = typst.edit.convert_equation("block", { notify = false })
assert(result.ok, result.message or "Typst convert_equation prose split failed")
assert(
    line(4) == "Text",
    "TypstConvertEquation block should keep prose before inline math"
)
assert(
    line(5) == "$",
    "TypstConvertEquation block should split display math onto its own lines"
)
assert(
    line(6) == "  z",
    "TypstConvertEquation block should keep inline formula"
)
assert(
    line(7) == "$",
    "TypstConvertEquation block should close split display math"
)
assert(
    line(8) == "tail.",
    "TypstConvertEquation block should keep prose after inline math"
)

edit({
    "$ x + y $",
})

vim.api.nvim_win_set_cursor(0, { 1, 3 })
result = typst.edit.toggle_equation_numbering("toggle", { notify = false })
assert(result.ok, result.message or "Typst toggle_equation_numbering failed")
assert(
    line(1) == '#math.equation(numbering: "(1)", $ x + y $)',
    "TypstToggleEquationNumbering should wrap math syntax in an explicit numbered equation"
)

vim.api.nvim_win_set_cursor(0, { 1, 20 })
result = typst.edit.toggle_equation_numbering("toggle", { notify = false })
assert(
    result.ok,
    result.message or "Typst toggle_equation_numbering disable failed"
)
assert(
    line(1) == "#math.equation(numbering: none, $ x + y $)",
    "TypstToggleEquationNumbering should disable explicit equation numbering"
)

result = typst.edit.toggle_equation_numbering("on", { notify = false })
assert(result.ok, result.message or "Typst toggle_equation_numbering on failed")
assert(
    line(1) == '#math.equation(numbering: "(1)", $ x + y $)',
    "TypstToggleEquationNumbering on should restore default numbering"
)

edit({
    "#math.equation($ z $)",
})

vim.api.nvim_win_set_cursor(0, { 1, 18 })
result = typst.edit.toggle_equation_numbering("off", { notify = false })
assert(
    result.ok,
    result.message or "Typst toggle_equation_numbering off failed"
)
assert(
    line(1) == "#math.equation(numbering: none, $ z $)",
    "TypstToggleEquationNumbering off should insert a missing numbering argument"
)

edit({
    "$ q = r $",
})

vim.api.nvim_win_set_cursor(0, { 1, 3 })
original_notify = vim.notify
vim.notify = function() end
vim.cmd("TypstToggleEquationNumbering off")
vim.notify = original_notify
assert(
    line(1) == "#math.equation(numbering: none, $ q = r $)",
    "TypstToggleEquationNumbering command should support forced off mode"
)

edit({
    "`raw`",
})

vim.api.nvim_win_set_cursor(0, { 1, 2 })
result = typst.edit.convert_raw("block", { notify = false })
assert(result.ok, result.message or "Typst convert_raw block failed")
assert(line(1) == "```", "TypstConvertRaw block should open a raw block")
assert(line(2) == "raw", "TypstConvertRaw block should preserve raw text")
assert(line(3) == "```", "TypstConvertRaw block should close a raw block")

vim.api.nvim_win_set_cursor(0, { 2, 1 })
result = typst.edit.convert_raw("inline", { notify = false })
assert(result.ok, result.message or "Typst convert_raw inline failed")
assert(
    line(1) == "`raw`",
    "TypstConvertRaw inline should collapse single-line raw blocks"
)

edit({
    "```typst",
    "let x = 1",
    "```",
})

vim.api.nvim_win_set_cursor(0, { 2, 1 })
result = typst.edit.convert_raw("inline", { notify = false })
assert(
    result.ok,
    result.message or "Typst convert_raw inline failed for language raw block"
)
assert(
    result.language == "typst",
    "TypstConvertRaw should report the dropped raw block language"
)
assert(
    line(1) == "`let x = 1`",
    "TypstConvertRaw inline should preserve single-line raw block content"
)

edit({
    "Text `x` tail.",
})

vim.api.nvim_win_set_cursor(0, { 1, 6 })
result = typst.edit.convert_raw("block", { notify = false })
assert(result.ok, result.message or "Typst convert_raw prose split failed")
assert(
    line(1) == "Text",
    "TypstConvertRaw block should keep prose before inline raw text"
)
assert(
    line(2) == "```",
    "TypstConvertRaw block should split raw text onto its own lines"
)
assert(line(3) == "x", "TypstConvertRaw block should keep inline raw text")
assert(line(4) == "```", "TypstConvertRaw block should close split raw text")
assert(
    line(5) == "tail.",
    "TypstConvertRaw block should keep prose after inline raw text"
)

edit({
    "```",
    "a",
    "b",
    "```",
})

vim.api.nvim_win_set_cursor(0, { 2, 0 })
result = typst.edit.convert_raw("inline", { notify = false })
assert(
    not result.ok and result.reason == "multiline_raw",
    "TypstConvertRaw should reject lossy multi-line raw collapse"
)
assert(
    line(1) == "```",
    "TypstConvertRaw should leave multi-line raw blocks unchanged"
)

edit({
    "`cmd`",
})

vim.api.nvim_win_set_cursor(0, { 1, 2 })
original_notify = vim.notify
vim.notify = function() end
vim.cmd("TypstConvertRaw block")
vim.notify = original_notify
assert(
    line(1) == "```",
    "TypstConvertRaw command should convert inline raw text"
)
assert(
    line(2) == "cmd",
    "TypstConvertRaw command should preserve inline raw text"
)
assert(line(3) == "```", "TypstConvertRaw command should close raw blocks")

edit({
    'image("diagram.svg")',
})

vim.api.nvim_win_set_cursor(0, { 1, 1 })
result = typst.edit.toggle_figure({ notify = false })
assert(result.ok, result.message or "Typst toggle_figure wrap failed")
assert(line(1) == "#figure[", "TypstToggleFigure should open a figure wrapper")
assert(
    line(2) == 'image("diagram.svg")',
    "TypstToggleFigure should preserve wrapped content"
)
assert(line(3) == "]", "TypstToggleFigure should close a figure wrapper")

vim.api.nvim_win_set_cursor(0, { 2, 1 })
result = typst.edit.toggle_figure({ notify = false })
assert(result.ok, result.message or "Typst toggle_figure unwrap failed")
assert(
    line(1) == 'image("diagram.svg")',
    "TypstToggleFigure should unwrap figure content"
)

edit({
    "  first line",
    "  second line",
})

result =
    typst.edit.toggle_figure({ start_row = 0, end_row = 1, notify = false })
assert(result.ok, result.message or "Typst toggle_figure range wrap failed")
assert(
    line(1) == "  #figure[",
    "TypstToggleFigure should align the wrapper with selected content"
)
assert(
    line(2) == "  first line",
    "TypstToggleFigure should preserve first selected line"
)
assert(
    line(3) == "  second line",
    "TypstToggleFigure should preserve second selected line"
)
assert(
    line(4) == "  ]",
    "TypstToggleFigure should close ranged wrappers at selected indentation"
)

edit({
    "#figure([Hi], caption: [Cap])",
})

vim.api.nvim_win_set_cursor(0, { 1, 11 })
result = typst.edit.toggle_figure({ notify = false })
assert(result.ok, result.message or "Typst toggle_figure grouped unwrap failed")
assert(
    line(1) == "Hi",
    "TypstToggleFigure should unwrap grouped figure body content"
)

edit({
    "Alpha",
    "Beta",
})

vim.api.nvim_win_set_cursor(0, { 1, 1 })
original_notify = vim.notify
vim.notify = function() end
vim.cmd("1,2TypstToggleFigure")
vim.notify = original_notify
assert(
    line(1) == "#figure[",
    "TypstToggleFigure command should wrap command ranges"
)
assert(
    line(2) == "Alpha",
    "TypstToggleFigure command should preserve first ranged line"
)
assert(
    line(3) == "Beta",
    "TypstToggleFigure command should preserve second ranged line"
)
assert(
    line(4) == "]",
    "TypstToggleFigure command should close command range wrappers"
)

edit({
    "Alpha",
    "Beta",
})

result =
    typst.edit.surround_content({ start_row = 0, end_row = 1, notify = false })
assert(result.ok, result.message or "Typst surround_content failed")
assert(line(1) == "[", "TypstSurroundContent should open content brackets")
assert(
    line(2) == "Alpha",
    "TypstSurroundContent should preserve first selected line"
)
assert(
    line(3) == "Beta",
    "TypstSurroundContent should preserve second selected line"
)
assert(line(4) == "]", "TypstSurroundContent should close content brackets")

edit({
    "  x + y",
})

result = typst.edit.surround_equation({ notify = false })
assert(result.ok, result.message or "Typst surround_equation failed")
assert(
    line(1) == "  $",
    "TypstSurroundEquation should open an equation at selected indentation"
)
assert(
    line(2) == "  x + y",
    "TypstSurroundEquation should preserve equation content"
)
assert(
    line(3) == "  $",
    "TypstSurroundEquation should close an equation at selected indentation"
)

edit({
    "body",
})

result = typst.edit.surround_function("quote", { notify = false })
assert(result.ok, result.message or "Typst surround_function failed")
assert(
    line(1) == "#quote[",
    "TypstSurroundFunction should open a function content call"
)
assert(
    line(2) == "body",
    "TypstSurroundFunction should preserve wrapped content"
)
assert(
    line(3) == "]",
    "TypstSurroundFunction should close the function content call"
)

edit({
    "  name",
})

result = typst.edit.surround_strong({ notify = false })
assert(result.ok, result.message or "Typst surround_strong failed")
assert(
    line(1) == "  *name*",
    "TypstSurroundStrong should wrap a single line after indentation"
)

edit({
    "  name",
})

result = typst.edit.surround_emph({ notify = false })
assert(result.ok, result.message or "Typst surround_emph failed")
assert(
    line(1) == "  _name_",
    "TypstSurroundEmph should wrap a single line after indentation"
)

edit({
    "value",
})

original_notify = vim.notify
vim.notify = function() end
vim.cmd("1TypstSurround block")
vim.notify = original_notify
assert(line(1) == "{", "TypstSurround command should open a code block")
assert(
    line(2) == "value",
    "TypstSurround command should preserve block content"
)
assert(line(3) == "}", "TypstSurround command should close a code block")

edit({
    "first",
    "second",
})

original_notify = vim.notify
vim.notify = function() end
vim.cmd("1,2TypstSurround function emph")
vim.notify = original_notify
assert(
    line(1) == "#emph[",
    "TypstSurround function command should open a named call"
)
assert(
    line(2) == "first",
    "TypstSurround function command should preserve first ranged line"
)
assert(
    line(3) == "second",
    "TypstSurround function command should preserve second ranged line"
)
assert(
    line(4) == "]",
    "TypstSurround function command should close the named call"
)

edit({
    "image",
})

result = typst.edit.surround_figure({ notify = false })
assert(result.ok, result.message or "Typst surround_figure failed")
assert(
    line(1) == "#figure[",
    "TypstSurroundFigure should open a figure wrapper"
)
assert(
    line(2) == "image",
    "TypstSurroundFigure should preserve wrapped content"
)
assert(line(3) == "]", "TypstSurroundFigure should close a figure wrapper")

edit({
    "plain",
    "  nested",
    "- bullet",
    "+ numbered",
    "",
    "  - nested bullet",
})

vim.api.nvim_win_set_cursor(0, { 1, 1 })
result = typst.edit.toggle_bullet_list({ notify = false })
assert(result.ok, result.message or "Typst toggle_bullet_list failed")
assert(line(1) == "- plain", "TypstToggleBulletList should add a bullet marker")

result = typst.edit.toggle_bullet_list({ notify = false })
assert(result.ok, result.message or "Typst toggle_bullet_list remove failed")
assert(
    line(1) == "plain",
    "TypstToggleBulletList should remove existing bullet markers"
)

result = typst.edit.toggle_numbered_list({
    start_row = 1,
    end_row = 3,
    notify = false,
})
assert(result.ok, result.message or "Typst toggle_numbered_list range failed")
assert(
    line(2) == "  + nested",
    "TypstToggleNumberedList should preserve indentation"
)
assert(
    line(3) == "+ bullet",
    "TypstToggleNumberedList should convert bullet markers"
)
assert(
    line(4) == "+ numbered",
    "TypstToggleNumberedList should preserve numbered markers"
)

result = typst.edit.toggle_list(
    "toggle",
    { start_row = 1, end_row = 3, notify = false }
)
assert(result.ok, result.message or "Typst toggle_list failed")
assert(
    line(2) == "  - nested",
    "TypstToggleList should flip numbered ranges to bullets"
)
assert(
    line(3) == "- bullet",
    "TypstToggleList should flip converted numbered item"
)
assert(
    line(4) == "- numbered",
    "TypstToggleList should flip existing numbered item"
)
assert(line(5) == "", "TypstToggleList should leave blank lines unchanged")

original_notify = vim.notify
vim.notify = function() end
vim.cmd("5,6TypstToggleList numbered")
vim.notify = original_notify
assert(
    line(5) == "",
    "TypstToggleList command range should preserve blank lines"
)
assert(
    line(6) == "  + nested bullet",
    "TypstToggleList command range should convert nested list items"
)

edit({
    "[body]",
})
vim.api.nvim_win_set_cursor(0, { 1, 2 })
result = typst.edit.surround_delete_delimiter(nil, { notify = false })
assert(result.ok, result.message or "TypstSurroundDeleteDelimiter failed")
assert(
    line(1) == "body",
    "TypstSurroundDeleteDelimiter should remove the nearest delimiter pair"
)

edit({
    "{body}",
})
vim.api.nvim_win_set_cursor(0, { 1, 2 })
result = typst.edit.surround_delete_block({ notify = false })
assert(result.ok, result.message or "TypstSurroundDeleteBlock failed")
assert(
    line(1) == "body",
    "TypstSurroundDeleteBlock should remove block delimiters"
)

edit({
    "$x + y$",
})
vim.api.nvim_win_set_cursor(0, { 1, 2 })
result = typst.edit.surround_delete_equation({ notify = false })
assert(result.ok, result.message or "TypstSurroundDeleteEquation failed")
assert(
    line(1) == "x + y",
    "TypstSurroundDeleteEquation should remove equation delimiters"
)

edit({
    "#strong[body]",
})
vim.api.nvim_win_set_cursor(0, { 1, 8 })
result = typst.edit.surround_change_call("emph", { notify = false })
assert(result.ok, result.message or "TypstSurroundChangeCall failed")
assert(
    line(1) == "#emph[body]",
    "TypstSurroundChangeCall should change the surrounding function"
)

edit({
    "a / b",
})
result = typst.edit.toggle_fraction({ notify = false })
assert(result.ok, result.message or "TypstToggleFraction slash failed")
assert(
    line(1) == "frac(a, b)",
    "TypstToggleFraction should convert slash fractions"
)
result = typst.edit.toggle_fraction({ notify = false })
assert(result.ok, result.message or "TypstToggleFraction frac failed")
assert(line(1) == "a / b", "TypstToggleFraction should convert frac calls back")

edit({
    "(x + y)",
})
result = typst.edit.toggle_delimiter_size({ notify = false })
assert(result.ok, result.message or "TypstToggleDelimiterSize plain failed")
assert(line(1) == "lr(x + y)", "TypstToggleDelimiterSize should add lr")
result = typst.edit.toggle_delimiter_size({ notify = false })
assert(result.ok, result.message or "TypstToggleDelimiterSize lr failed")
assert(line(1) == "(x + y)", "TypstToggleDelimiterSize should remove lr")

edit({
    "line",
})
result = typst.edit.toggle_line_break({ notify = false })
assert(
    result.ok and line(1) == "line \\",
    "TypstToggleLineBreak should add a markup line break"
)
result = typst.edit.toggle_line_break({ notify = false })
assert(
    result.ok and line(1) == "line",
    "TypstToggleLineBreak should remove a markup line break"
)

edit({
    "alpha",
})
vim.api.nvim_win_set_cursor(0, { 1, 1 })
result = typst.edit.create_function("box", { notify = false })
assert(result.ok, result.message or "TypstCreateFunction failed")
assert(
    line(1) == "#box(alpha)",
    "TypstCreateFunction should wrap the current word"
)

local convert_buf = edit({
    "Before $x + y$ after",
})
local convert = typst.edit.convert_equation("block", {
    bufnr = convert_buf,
    notify = false,
    pos = { 0, 9 },
})
assert(
    convert.ok,
    convert.message or "fallback inline equation conversion failed"
)
assert(
    line(1) == "Before",
    "fallback conversion should preserve prose before inline math"
)
assert(line(2) == "$", "fallback conversion should open display math")
assert(
    line(3) == "  x + y",
    "fallback conversion should preserve inline formula"
)
assert(line(4) == "$", "fallback conversion should close display math")
assert(
    line(5) == "after",
    "fallback conversion should preserve prose after inline math"
)

local numbering_buf = edit({
    "$z$",
})
local numbering = typst.edit.toggle_equation_numbering("on", {
    bufnr = numbering_buf,
    notify = false,
    pos = { 0, 1 },
})
assert(numbering.ok, numbering.message or "fallback equation numbering failed")
assert(
    line(1) == '#math.equation(numbering: "(1)", $z$)',
    "fallback numbering should wrap inline math syntax in an explicit equation call"
)

edit({
    "[",
})
vim.api.nvim_win_set_cursor(0, { 1, 1 })
result = typst.edit.smart_close({ notify = false })
assert(result.ok, result.message or "TypstSmartClose failed")
assert(
    line(1) == "[]",
    "TypstSmartClose should insert the nearest closing delimiter"
)

original_notify = vim.notify
vim.notify = function() end
vim.cmd("TypstToggleLineBreak")
vim.cmd("TypstCreateFunction emph")
vim.notify = original_notify

vim.cmd("qa!")
