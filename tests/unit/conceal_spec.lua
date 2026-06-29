local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")
local conceal = require("typst.conceal")
local metadata = require("typst.metadata")

typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("conceal-output"),
})

local fixture = root .. "/tests/fixtures/basic/conceal.typ"
vim.cmd.edit(fixture)
vim.bo.filetype = "typst"
typst.project.attach(0)

local catalog = metadata.catalog()
assert(
    catalog.symbols["arrow.r"].glyph == "→",
    "metadata should expose arrow.r"
)

local matches = conceal.matches(0)

local function count_category(items, category)
    local count = 0
    for _, match in ipairs(items) do
        if match.category == category then
            count = count + 1
        end
    end
    return count
end

local function find_match(items, predicate)
    for _, match in ipairs(items) do
        if predicate(match) then
            return match
        end
    end
end

local function source_map(items)
    local by_text = {}
    for _, match in ipairs(items) do
        by_text[match.source_text] = match
    end
    return by_text
end

local by_source = {}
for _, match in ipairs(matches) do
    by_source[match.source_text] = match
end

assert(by_source.alpha, "alpha should be a conceal match")
assert(
    by_source.alpha.replacement == "α",
    "alpha replacement should come from metadata"
)
assert(by_source["arrow.r"], "arrow.r should be a conceal match")
assert(
    by_source["arrow.r"].replacement == "→",
    "arrow.r replacement should come from metadata"
)
assert(
    by_source["arrow.r"].resolved_name == "sym.arrow.r",
    "arrow.r should resolve to a symbol id"
)
assert(
    by_source["sym.arrow.l"],
    "explicit sym.arrow.l should be a conceal match"
)
assert(
    by_source["sym.arrow.l"].replacement == "←",
    "explicit sym.arrow.l should conceal to left arrow"
)
assert(
    by_source.RR and by_source.RR.replacement == "ℝ",
    "RR should be concealed as real numbers"
)

local reordered_symbol_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(reordered_symbol_buf)
vim.api.nvim_buf_set_lines(reordered_symbol_buf, 0, -1, false, {
    "$ arrow.double.r $",
})
vim.bo[reordered_symbol_buf].filetype = "typst"
local reordered_by_source = source_map(conceal.matches(reordered_symbol_buf))
assert(
    reordered_by_source["arrow.double.r"]
        and reordered_by_source["arrow.double.r"].resolved_name
            == "sym.arrow.r.double",
    "conceal should normalize modifier-order-insensitive symbols to their canonical name"
)
vim.cmd.edit(fixture)
vim.bo.filetype = "typst"

assert(
    not by_source["x_1"],
    "attached scripts should not be treated as symbol names"
)
assert(
    by_source["_1"] and by_source["_1"].replacement == "₁",
    "single digit subscript should conceal"
)
assert(
    by_source["^2"] and by_source["^2"].replacement == "²",
    "single digit superscript should conceal"
)
assert(not by_source["_(n+1)"], "grouped subscript should remain source text")
assert(not by_source["#emoji.face.halo"], "emoji conceal should be opt-in")
assert(not by_source["emoji.face.halo"], "math emoji conceal should be opt-in")

assert(
    count_category(matches, "math_delimiters") == 4,
    "math delimiters should conceal by default"
)
assert(
    find_match(matches, function(match)
        return match.category == "math_delimiters" and match.replacement == ""
    end),
    "math delimiter conceal should hide punctuation"
)
assert(
    count_category(matches, "markup_delimiters") == 4,
    "markup delimiters should conceal by default"
)
assert(
    find_match(matches, function(match)
        return match.category == "markup_delimiters"
            and match.source_text == "*"
    end),
    "strong delimiter should be captured"
)
assert(
    find_match(matches, function(match)
        return match.category == "markup_delimiters"
            and match.source_text == "_"
    end),
    "emphasis delimiter should be captured"
)
assert(
    count_category(matches, "headings") == 0,
    "heading marker conceal should be opt-in"
)
assert(
    count_category(matches, "lists") == 0,
    "list marker conceal should be opt-in"
)
assert(
    count_category(matches, "raw_blocks") == 0,
    "raw delimiter conceal should be opt-in"
)
assert(
    count_category(matches, "labels") == 0,
    "label delimiter conceal should be opt-in"
)
assert(
    count_category(matches, "reference_markers") == 0,
    "reference marker conceal should be opt-in"
)
assert(
    count_category(matches, "function_wrappers") == 4,
    "style function wrappers should conceal by default"
)
assert(
    find_match(matches, function(match)
        return match.category == "function_wrappers"
            and match.wrapper == "strong"
            and match.source_text == "#strong["
    end),
    "strong function wrapper prefix should be concealed"
)
assert(
    find_match(matches, function(match)
        return match.category == "function_wrappers"
            and match.wrapper == "emph"
            and match.source_text == "]"
    end),
    "emph function wrapper suffix should be concealed"
)

local multiline_wrapper_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(multiline_wrapper_buf)
vim.api.nvim_buf_set_lines(multiline_wrapper_buf, 0, -1, false, {
    "#strong[",
    "important",
    "]",
})
vim.bo[multiline_wrapper_buf].filetype = "typst"
local multiline_wrapper_matches = conceal.matches(multiline_wrapper_buf)
assert(
    find_match(multiline_wrapper_matches, function(match)
        return match.category == "function_wrappers"
            and match.wrapper == "strong"
            and match.part == "prefix"
            and match.source_text == "#strong["
    end),
    "multiline function wrapper prefix should be concealed"
)
assert(
    find_match(multiline_wrapper_matches, function(match)
        return match.category == "function_wrappers"
            and match.wrapper == "strong"
            and match.part == "suffix"
            and match.source_text == "]"
            and match.source.start_row == 2
    end),
    "multiline function wrapper suffix should conceal the final bracket"
)
vim.cmd.edit(fixture)
vim.bo.filetype = "typst"

local error_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(error_buf)
vim.api.nvim_buf_set_lines(error_buf, 0, -1, false, {
    "#let =",
    "$ alpha + arrow.r $",
})
vim.bo[error_buf].filetype = "typst"
local error_by_source = source_map(conceal.matches(error_buf))
assert(
    not error_by_source["#let"],
    "conceal should skip captures that overlap parser errors"
)
assert(
    error_by_source.alpha,
    "parser errors should not suppress conceal matches in valid syntax"
)
assert(
    error_by_source["arrow.r"],
    "parser errors should not suppress later valid symbol conceal"
)
vim.cmd.edit(fixture)
vim.bo.filetype = "typst"

local original_echo = vim.api.nvim_echo
vim.api.nvim_echo = function() end
local inspected = conceal.inspect({ match = by_source["arrow.r"] })
vim.api.nvim_echo = original_echo
assert(
    inspected and inspected.symbol_id == "sym.arrow.r",
    "inspect should return the active match"
)

typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("conceal-output"),
    conceal = {
        custom = {
            math = {
                customop = "★",
                ["arrow.r"] = "⇒",
            },
        },
    },
})

local custom_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(custom_buf)
vim.api.nvim_buf_set_lines(custom_buf, 0, -1, false, {
    "$ customop + arrow.r + wideop + comboseq $",
})
vim.bo[custom_buf].filetype = "typst"
local custom_matches = conceal.matches(custom_buf)
local custom_by_source = {}
for _, match in ipairs(custom_matches) do
    custom_by_source[match.source_text] = match
end

assert(
    custom_by_source.customop,
    "configured custom math symbol should be concealed"
)
assert(
    custom_by_source.customop.replacement == "★",
    "custom math replacement should come from config"
)
assert(
    custom_by_source.customop.provider == "User conceal config",
    "configured custom symbols should report provider"
)
assert(
    custom_by_source.customop.rule == "custom_math_symbols",
    "custom symbols should report their rule"
)
assert(
    custom_by_source["arrow.r"].replacement == "⇒",
    "custom math symbols should override generated metadata"
)

local custom_shadow_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(custom_shadow_buf)
vim.api.nvim_buf_set_lines(custom_shadow_buf, 0, -1, false, {
    "#let customop = 1",
    "$ customop + sym.customop $",
})
vim.bo[custom_shadow_buf].filetype = "typst"
custom_matches = conceal.matches(custom_shadow_buf)
custom_by_source = {}
for _, match in ipairs(custom_matches) do
    custom_by_source[match.source_text] = match
end

assert(
    not custom_by_source.customop,
    "local bindings should suppress implicit custom math conceal"
)
assert(
    custom_by_source["sym.customop"],
    "explicit sym.* custom math symbols should still conceal"
)
assert(
    custom_by_source["sym.customop"].replacement == "★",
    "explicit custom symbol should use configured replacement"
)

assert(
    typst.conceal.register("math", "runtimeop", "◆") == "◆",
    "runtime custom conceal registration should return replacement"
)
assert(
    typst.conceal.custom("math").runtimeop == "◆",
    "runtime custom conceal registry should be inspectable"
)
local runtime_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(runtime_buf)
vim.api.nvim_buf_set_lines(runtime_buf, 0, -1, false, {
    "$ runtimeop $",
})
vim.bo[runtime_buf].filetype = "typst"
custom_matches = conceal.matches(runtime_buf)
custom_by_source = {}
for _, match in ipairs(custom_matches) do
    custom_by_source[match.source_text] = match
end

assert(
    custom_by_source.runtimeop,
    "runtime registered custom math symbol should be concealed"
)
assert(
    custom_by_source.runtimeop.provider == "User conceal registry",
    "runtime custom symbols should report provider"
)
assert(
    typst.conceal.unregister("math", "runtimeop") == "◆",
    "runtime custom conceal unregister should return replacement"
)
assert(
    not typst.conceal.custom("math").runtimeop,
    "runtime custom conceal unregister should remove the mapping"
)

local invalid_register_ok, invalid_register_err = pcall(function()
    typst.conceal.register("math", "badop", "xx")
end)
assert(
    not invalid_register_ok,
    "runtime custom conceal registration should reject multi-character replacements"
)
assert(
    invalid_register_err:match("exactly one character"),
    "runtime custom conceal registration should explain the native conceal character limit"
)

local invalid_combining_ok, invalid_combining_err = pcall(function()
    typst.conceal.register("math", "combiningop", "e\204\129")
end)
assert(
    not invalid_combining_ok,
    "runtime custom conceal registration should reject multi-scalar combining replacements"
)
assert(
    invalid_combining_err:match("exactly one character"),
    "runtime custom conceal registration should explain the native conceal scalar limit"
)

vim.cmd.edit(fixture)
vim.bo.filetype = "typst"

assert(typst.conceal.is_enabled(0), "conceal should default to enabled")
typst.conceal.disable(0)
assert(
    not typst.conceal.is_enabled(0),
    "conceal.disable should set a buffer-local override"
)
typst.conceal.enable(0)
assert(
    not typst.conceal.toggle(0),
    "toggle should report disabled after disabling an enabled buffer"
)
assert(
    typst.conceal.toggle(0),
    "toggle should report enabled after enabling a disabled buffer"
)

typst.conceal.disable(0)
vim.wo.conceallevel = 1
typst.conceal.enable(0)
assert(
    vim.wo.conceallevel == 2,
    "conceal.enable should apply the configured window conceallevel"
)
vim.wo.conceallevel = 3
typst.conceal.disable(0)
assert(
    vim.wo.conceallevel == 3,
    "conceal.disable should not overwrite user conceallevel changes"
)
vim.wo.conceallevel = 1
typst.conceal.enable(0)
typst.conceal.disable(0)
assert(
    vim.wo.conceallevel == 1,
    "conceal.disable should restore unchanged plugin-installed conceallevel"
)

vim.cmd.edit(fixture)
vim.bo.filetype = "typst"
local win_a = vim.api.nvim_get_current_win()
vim.wo[win_a].conceallevel = 0
vim.cmd("vsplit")
local win_b = vim.api.nvim_get_current_win()
vim.wo[win_b].conceallevel = 1
typst.conceal.enable(0)
conceal.apply(0, win_a)
conceal.apply(0, win_b)
assert(
    vim.wo[win_a].conceallevel == 2,
    "conceal.apply should set conceallevel in the first window"
)
assert(
    vim.wo[win_b].conceallevel == 2,
    "conceal.apply should set conceallevel in the second window"
)
typst.conceal.disable(0)
assert(
    vim.wo[win_a].conceallevel == 0,
    "conceal.disable should restore first-window conceallevel"
)
assert(
    vim.wo[win_b].conceallevel == 1,
    "conceal.disable should restore second-window conceallevel"
)
vim.api.nvim_set_current_win(win_b)
vim.cmd("close")
typst.conceal.enable(0)
vim.cmd("vsplit")
local closed_win = vim.api.nvim_get_current_win()
vim.wo[closed_win].conceallevel = 1
conceal.apply(0, closed_win)
assert(
    vim.wo[closed_win].conceallevel == 2,
    "conceal.apply should set conceallevel before window close"
)
vim.cmd("close")
assert(
    not conceal._forget_window(closed_win),
    "WinClosed should clear saved conceallevel state"
)

local reveal_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(reveal_buf)
vim.api.nvim_buf_set_lines(reveal_buf, 0, -1, false, {
    "$ alpha + beta $",
})
vim.bo[reveal_buf].filetype = "typst"
local reveal_win_a = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_cursor(reveal_win_a, { 1, 3 })
vim.cmd("vsplit")
local reveal_win_b = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_cursor(reveal_win_b, { 1, 11 })
typst.conceal.enable(reveal_buf)
conceal.apply(reveal_buf, reveal_win_a)
conceal.apply(reveal_buf, reveal_win_b)

local rendered_a = source_map(
    conceal._window_matches(
        reveal_buf,
        reveal_win_a,
        { start_row = 0, end_row = 1 }
    )
)
local rendered_b = source_map(
    conceal._window_matches(
        reveal_buf,
        reveal_win_b,
        { start_row = 0, end_row = 1 }
    )
)
assert(
    not rendered_a.alpha,
    "first window should reveal only the symbol under its own cursor"
)
assert(
    rendered_a.beta,
    "first window should keep neighboring symbols concealed"
)
assert(
    rendered_b.alpha,
    "second window should keep neighboring symbols concealed"
)
assert(
    not rendered_b.beta,
    "second window should reveal only the symbol under its own cursor"
)

vim.api.nvim_set_current_win(reveal_win_b)
vim.cmd("close")
vim.api.nvim_set_current_win(reveal_win_a)
vim.cmd.edit(fixture)
vim.bo.filetype = "typst"

local before_generation = conceal.generation()
typst.conceal.refresh(0)
assert(
    conceal.generation() > before_generation,
    "refresh should bump the conceal generation"
)

typst.reset()
typst.setup({
    root = root,
    conceal = {
        categories = {
            math_symbols = false,
        },
    },
})
vim.b[0].typst_conceal_enabled = nil
matches = conceal.matches(0)
assert(
    count_category(matches, "math_symbols") == 0,
    "math_symbols=false should suppress symbol conceal"
)
assert(
    count_category(matches, "math_delimiters") == 4,
    "math_symbols=false should not suppress structural conceal"
)

typst.reset()
typst.setup({
    root = root,
    conceal = {
        categories = {
            emoji = true,
        },
        safety = {
            max_display_width = 2,
        },
    },
})
vim.b[0].typst_conceal_enabled = nil
matches = conceal.matches(0)
by_source = {}
for _, match in ipairs(matches) do
    by_source[match.source_text] = match
end
assert(
    count_category(matches, "emoji") == 2,
    "emoji=true should conceal explicit emoji symbols"
)
assert(
    by_source["#emoji.face.halo"].replacement == "😇",
    "markup emoji should conceal to its glyph"
)
assert(
    by_source["#emoji.face.halo"].resolved_name == "emoji.face.halo",
    "markup emoji should resolve to an emoji id"
)
assert(
    by_source["emoji.face.halo"].replacement == "😇",
    "math emoji should conceal to its glyph"
)

typst.reset()
typst.setup({
    root = root,
    conceal = {
        categories = {
            headings = true,
        },
    },
})
vim.b[0].typst_conceal_enabled = nil
matches = conceal.matches(0)
local heading = find_match(matches, function(match)
    return match.category == "headings" and match.source_text == "="
end)
assert(
    heading and heading.replacement == "",
    "headings=true should hide heading markers"
)
assert(
    heading.reveal.start_row == 0 and heading.reveal.end_col == 9,
    "heading reveal should cover the heading"
)

typst.reset()
typst.setup({
    root = root,
    conceal = {
        categories = {
            lists = true,
            raw_blocks = true,
        },
    },
})
vim.b[0].typst_conceal_enabled = nil
matches = conceal.matches(0)
assert(
    count_category(matches, "lists") == 2,
    "lists=true should hide list markers"
)
assert(
    count_category(matches, "raw_blocks") == 4,
    "raw_blocks=true should hide inline and block raw delimiters"
)
assert(
    count_category(matches, "raw_block_languages") == 0,
    "raw block language tags should be separately configurable"
)
assert(
    find_match(matches, function(match)
        return match.category == "lists"
            and match.source_text == "- "
            and match.replacement == ""
    end),
    "bullet list marker should include its following space"
)
assert(
    find_match(matches, function(match)
        return match.category == "lists"
            and match.source_text == "+ "
            and match.replacement == ""
    end),
    "numbered list marker should include its following space"
)
assert(
    find_match(matches, function(match)
        return match.category == "raw_blocks" and match.source_text == "`"
    end),
    "inline raw delimiter should be captured"
)
assert(
    find_match(matches, function(match)
        return match.category == "raw_blocks" and match.source_text == "```"
    end),
    "raw block opening fence should not include its language tag"
)

typst.reset()
typst.setup({
    root = root,
    conceal = {
        categories = {
            raw_block_languages = true,
        },
    },
})
vim.b[0].typst_conceal_enabled = nil
matches = conceal.matches(0)
assert(
    count_category(matches, "raw_block_languages") == 1,
    "raw block language tags should be opt-in"
)
assert(
    find_match(matches, function(match)
        return match.category == "raw_block_languages"
            and match.source_text == "typ"
    end),
    "raw block language tag should be captured separately"
)

typst.reset()
typst.setup({
    root = root,
    conceal = {
        categories = {
            labels = true,
            reference_markers = true,
        },
    },
})
vim.b[0].typst_conceal_enabled = nil
matches = conceal.matches(0)
assert(
    count_category(matches, "labels") == 2,
    "labels=true should hide shorthand label delimiters"
)
assert(
    count_category(matches, "reference_markers") == 2,
    "reference_markers=true should hide shorthand markers"
)
assert(
    find_match(matches, function(match)
        return match.category == "labels"
            and match.source_text == "<"
            and match.replacement == ""
    end),
    "label opening delimiter should be captured"
)
assert(
    find_match(matches, function(match)
        return match.category == "reference_markers"
            and match.source_text == "@"
            and match.replacement == ""
    end),
    "reference marker should be captured"
)

typst.reset()
typst.setup({
    root = root,
    conceal = {
        categories = {
            reference_markers = true,
        },
    },
})
vim.b[0].typst_conceal_enabled = nil
local citation_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(citation_buf)
vim.api.nvim_buf_set_lines(citation_buf, 0, -1, false, {
    "See @doe2020.",
})
vim.bo[citation_buf].filetype = "typst"
matches = conceal.matches(citation_buf)
assert(
    count_category(matches, "reference_markers") == 1,
    "reference_markers=true should hide citation-like markers"
)

typst.reset()
typst.setup({
    root = root,
    conceal = {
        categories = {
            function_wrappers = {
                strong = false,
                emph = true,
                underline = false,
                strike = false,
            },
        },
    },
})
vim.b[0].typst_conceal_enabled = nil
local wrapper_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(wrapper_buf)
vim.api.nvim_buf_set_lines(wrapper_buf, 0, -1, false, {
    "#strong[important] #emph[careful] #underline[marked]",
})
vim.bo[wrapper_buf].filetype = "typst"
matches = conceal.matches(wrapper_buf)
assert(
    count_category(matches, "function_wrappers") == 2,
    "wrapper conceal should honor per-function toggles"
)
assert(not find_match(matches, function(match)
    return match.wrapper == "strong"
end), "disabled function wrappers should remain source text")
assert(
    find_match(matches, function(match)
        return match.wrapper == "emph" and match.source_text == "#emph["
    end),
    "enabled function wrappers should conceal their prefix"
)

typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("conceal-output"),
})
local shadow_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(shadow_buf)
vim.api.nvim_buf_set_lines(shadow_buf, 0, -1, false, {
    "#let alpha = 1",
    "#let arrow = 2",
    '#import "symbols.typ": beta, gamma as delta',
    "",
    "$ alpha + arrow.r + beta + gamma + delta + sym.arrow.l + RR $",
})
vim.bo[shadow_buf].filetype = "typst"
matches = conceal.matches(shadow_buf)
by_source = {}
for _, match in ipairs(matches) do
    by_source[match.source_text] = match
end

assert(
    not by_source.alpha,
    "local let binding should suppress implicit alpha conceal"
)
assert(
    not by_source["arrow.r"],
    "local let binding should suppress dotted symbol conceal from the same root"
)
assert(
    not by_source.beta,
    "explicit import binding should suppress implicit beta conceal"
)
assert(
    by_source.gamma and by_source.gamma.replacement == "γ",
    "aliased import should not suppress the original name"
)
assert(not by_source.delta, "import alias should suppress the local alias name")
assert(by_source["sym.arrow.l"], "explicit sym.* symbols should still conceal")
assert(
    by_source["sym.arrow.l"].shadowed:match("explicit"),
    "explicit symbols should explain shadow handling"
)
assert(
    by_source.RR and by_source.RR.shadowed == "no",
    "unshadowed implicit symbols should report no shadow"
)

local function count_source(items, source)
    local count = 0
    for _, match in ipairs(items) do
        if match.source_text == source then
            count = count + 1
        end
    end
    return count
end

local lexical_shadow_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(lexical_shadow_buf)
vim.api.nvim_buf_set_lines(lexical_shadow_buf, 0, -1, false, {
    "$ alpha + sym.alpha $",
    "#let alpha = 1",
    "$ alpha + sym.alpha $",
})
vim.bo[lexical_shadow_buf].filetype = "typst"
matches = conceal.matches(lexical_shadow_buf)
by_source = {}
for _, match in ipairs(matches) do
    by_source[match.source_text] = match
end
assert(
    count_source(matches, "alpha") == 1,
    "later local bindings should not suppress earlier implicit symbols"
)
assert(
    count_source(matches, "sym.alpha") == 2,
    "explicit sym.* symbols should still conceal across local bindings"
)

local nested_shadow_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(nested_shadow_buf)
vim.api.nvim_buf_set_lines(nested_shadow_buf, 0, -1, false, {
    "#block[",
    "#let beta = 1",
    "$ beta + sym.beta $",
    "]",
    "$ beta $",
})
vim.bo[nested_shadow_buf].filetype = "typst"
matches = conceal.matches(nested_shadow_buf)
assert(
    count_source(matches, "beta") == 1,
    "block-local bindings should not suppress outer implicit symbols"
)
assert(
    count_source(matches, "sym.beta") == 1,
    "explicit sym.* symbols should conceal inside local scopes"
)

local parameter_shadow_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(parameter_shadow_buf)
vim.api.nvim_buf_set_lines(parameter_shadow_buf, 0, -1, false, {
    "#let f(alpha) = [",
    "$ alpha + sym.alpha $",
    "]",
    "$ alpha $",
})
vim.bo[parameter_shadow_buf].filetype = "typst"
matches = conceal.matches(parameter_shadow_buf)
assert(
    count_source(matches, "alpha") == 1,
    "function parameters should only suppress symbols inside the body"
)
assert(
    count_source(matches, "sym.alpha") == 1,
    "explicit sym.* symbols should conceal inside function bodies"
)

local wildcard_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(wildcard_buf)
vim.api.nvim_buf_set_lines(wildcard_buf, 0, -1, false, {
    '#import "symbols.typ": *',
    "$ alpha + sym.arrow.l $",
})
vim.bo[wildcard_buf].filetype = "typst"
matches = conceal.matches(wildcard_buf)
by_source = {}
for _, match in ipairs(matches) do
    by_source[match.source_text] = match
end
assert(
    not by_source.alpha,
    "wildcard imports should suppress uncertain implicit symbol conceal"
)
assert(
    by_source["sym.arrow.l"],
    "wildcard imports should not suppress explicit sym.* symbols"
)

typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("conceal-output"),
})
local cache_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(cache_buf)
vim.api.nvim_buf_set_lines(cache_buf, 0, -1, false, {
    "$ alpha + arrow.r $",
})
vim.bo[cache_buf].filetype = "typst"
local cache_range = { start_row = 0, end_row = 1 }
local cached_matches = conceal.matches(cache_buf, cache_range)

local original_symbol = metadata.symbol
metadata.symbol = function()
    error("metadata lookup should not run for a stable conceal cache entry")
end
local stable_matches = conceal.matches(cache_buf, cache_range)
assert(
    #stable_matches == #cached_matches,
    "stable ranges should filter from cached matches"
)

vim.api.nvim_buf_set_text(cache_buf, 0, 2, 0, 2, { "beta + " })
local ok = pcall(function()
    conceal.matches(cache_buf, cache_range)
end)
assert(not ok, "buffer edits should invalidate cached conceal matches")
metadata.symbol = original_symbol

cached_matches = conceal.matches(cache_buf, cache_range)
metadata.symbol = function()
    error(
        "metadata lookup should run after TypstConcealRefresh invalidates cache"
    )
end
typst.conceal.refresh(cache_buf)
ok = pcall(function()
    conceal.matches(cache_buf, cache_range)
end)
assert(not ok, "TypstConcealRefresh should invalidate cached conceal matches")
metadata.symbol = original_symbol

cached_matches = conceal.matches(cache_buf, cache_range)
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("conceal-output"),
    conceal = {
        categories = {
            math_symbols = false,
        },
    },
})
matches = conceal.matches(cache_buf, cache_range)
assert(
    matches ~= cached_matches,
    "conceal config changes should not reuse stale cached match tables"
)
assert(
    count_category(matches, "math_symbols") == 0,
    "conceal config changes should invalidate symbol matches"
)

typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("conceal-runtime-output"),
})

assert(
    typst.conceal.register("math", "runtimeop", "*") == "*",
    "runtime custom conceal registration should return replacement"
)
assert(
    typst.conceal.custom("math").runtimeop == "*",
    "runtime custom conceal registry should be inspectable"
)
assert(
    typst.conceal.unregister("math", "runtimeop") == "*",
    "runtime custom conceal unregister should return replacement"
)
assert(
    not typst.conceal.custom("math").runtimeop,
    "runtime custom conceal unregister should remove the mapping"
)

local invalid_register_ok, invalid_register_err = pcall(function()
    typst.conceal.register("math", "badop", "xx")
end)
assert(
    not invalid_register_ok,
    "runtime custom conceal registration should reject multi-character replacements"
)
assert(
    tostring(invalid_register_err):match("exactly one character"),
    "runtime custom conceal registration should explain the native conceal character limit"
)

local invalid_combining_ok, invalid_combining_err = pcall(function()
    typst.conceal.register("math", "combiningop", "e\204\129")
end)
assert(
    not invalid_combining_ok,
    "runtime custom conceal registration should reject multi-scalar combining replacements"
)
assert(
    tostring(invalid_combining_err):match("exactly one character"),
    "runtime custom conceal registration should explain the native conceal scalar limit"
)

typst.reset()
local original_set_decoration_provider = vim.api.nvim_set_decoration_provider
local provider_starts = 0
vim.api.nvim_set_decoration_provider = function(...)
    provider_starts = provider_starts + 1
    return original_set_decoration_provider(...)
end

typst.setup({
    root = root,
    output_dir = typst_test_cache_path("conceal-lifecycle-output"),
})
assert(
    provider_starts == 0,
    "setup should not eagerly start the conceal decoration provider"
)

local lifecycle_bufnr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(lifecycle_bufnr)
vim.api.nvim_buf_set_lines(lifecycle_bufnr, 0, -1, false, {
    "= Conceal lifecycle",
})
vim.bo[lifecycle_bufnr].filetype = "typst"

local win_a = vim.api.nvim_get_current_win()
vim.wo[win_a].conceallevel = 0
assert(
    conceal.apply(lifecycle_bufnr, win_a),
    "conceal.apply should enable window-local options"
)
assert(
    provider_starts > 0,
    "conceal.apply should lazily start the decoration provider for Typst buffers"
)
local starts_after_first_apply = provider_starts
assert(
    vim.wo[win_a].conceallevel == 2,
    "conceal.apply should use the configured conceallevel"
)

vim.cmd("vsplit")
local win_b = vim.api.nvim_get_current_win()
vim.wo[win_b].conceallevel = 1
assert(
    conceal.apply(lifecycle_bufnr, win_b),
    "conceal.apply should handle a second window"
)
assert(
    provider_starts == starts_after_first_apply,
    "conceal.apply should not restart an already registered decoration provider"
)
assert(
    vim.wo[win_b].conceallevel == 2,
    "conceal.apply should set the second window conceallevel"
)

vim.cmd("close")
assert(
    not conceal._forget_window(win_b),
    "WinClosed should clear saved conceallevel state"
)

typst.conceal.disable(lifecycle_bufnr)
assert(
    vim.wo[win_a].conceallevel == 0,
    "conceal.disable should restore the surviving window"
)

local starts_before_reset = provider_starts
conceal.reset()
assert(
    provider_starts > starts_before_reset,
    "conceal.reset should clear the registered decoration provider"
)

local starts_after_reset = provider_starts
conceal.enable(lifecycle_bufnr)
assert(
    provider_starts > starts_after_reset,
    "conceal.enable should re-register the provider after reset"
)

typst.conceal.disable(lifecycle_bufnr)
vim.api.nvim_set_decoration_provider = original_set_decoration_provider

vim.cmd("qa!")
