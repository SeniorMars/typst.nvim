local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local index = require("typst.index")
local typst = require("typst")
local util = require("typst.core.util")
local old_package_cache_path = vim.env.TYPST_PACKAGE_CACHE_PATH
local package_cache_dir = typst_test_cache_path("context-menu-packages")
local function write_package_version(name, version)
    local dir = ("%s/preview/%s/%s"):format(package_cache_dir, name, version)
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile({
        "[package]",
        ('name = "%s"'):format(name),
        ('version = "%s"'):format(version),
        'entrypoint = "lib.typ"',
        'description = "A semver sorting fixture."',
    }, dir .. "/typst.toml")
    vim.fn.writefile({ "#let sorted-fixture = true" }, dir .. "/lib.typ")
end
local function write_template_package(name, version, template)
    local dir = ("%s/preview/%s/%s"):format(package_cache_dir, name, version)
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile({
        "[package]",
        ('name = "%s"'):format(name),
        ('version = "%s"'):format(version),
        'entrypoint = "lib.typ"',
        'description = "A template containment fixture."',
        "",
        "[template]",
        ('path = "%s"'):format(template.path),
        ('entrypoint = "%s"'):format(template.entrypoint or "main.typ"),
    }, dir .. "/typst.toml")
    vim.fn.writefile(
        { "#let fixture-template(body) = body" },
        dir .. "/lib.typ"
    )
    vim.fn.mkdir(dir .. "/template", "p")
    vim.fn.writefile(
        { '#import "../lib.typ": fixture-template', "#show: fixture-template" },
        dir .. "/template/main.typ"
    )
end
write_package_version("cetz", "0.10.0-rc.1")
write_package_version("cetz", "0.10.0")
write_template_package(
    "escape-template-path",
    "1.0.0",
    { path = "../outside", entrypoint = "main.typ" }
)
write_template_package(
    "escape-template-entrypoint",
    "1.0.0",
    { path = "template", entrypoint = "../lib.typ" }
)
vim.env.TYPST_PACKAGE_CACHE_PATH = package_cache_dir
    .. (util.is_windows() and ";" or ":")
    .. root
    .. "/tests/fixtures/packages"
typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("context-menu-output"),
    completion = {
        font_families = { "Unit Test Serif", "Replacement Serif" },
        font_scan_timeout_ms = 0,
    },
})

local main = root .. "/tests/fixtures/basic/index-main.typ"
vim.cmd.edit(main)
typst.project.set_main(main)

local function action_by_id(actions, id)
    for _, action in ipairs(actions) do
        if action.id == id then
            return action
        end
    end
end

local function place_on(needle)
    local bufnr = vim.api.nvim_get_current_buf()
    for row, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
        local start_col = line:find(needle, 1, true)
        if start_col then
            vim.api.nvim_win_set_cursor(0, { row, start_col - 1 })
            return
        end
    end
    error("fixture missing text: " .. needle)
end

place_on("diagram.svg")
local path_actions, _, path_target = typst.context.open({ open = false })
assert(
    path_target and path_target.kind == "path",
    "context menu should resolve image path target"
)
assert(
    action_by_id(path_actions, "follow"),
    "path context should include follow action"
)
assert(
    action_by_id(path_actions, "copy_target"),
    "path context should include copy action"
)
local path_reveal = assert(
    action_by_id(path_actions, "path_reveal"),
    "path context should include reveal action"
)
local reveal_info =
    require("typst.context").execute(path_reveal, { open = false })
assert(
    reveal_info and reveal_info.path == path_target.path,
    "path reveal should return resolved path metadata"
)
assert(
    reveal_info.directory == vim.fs.dirname(path_target.path),
    "path reveal should include parent directory"
)
assert(
    action_by_id(path_actions, "image_open"),
    "image path context should include image open action"
)
local image_preview = assert(
    action_by_id(path_actions, "image_preview"),
    "image path context should include preview action"
)
local image_info =
    require("typst.context").execute(image_preview, { open = false })
assert(
    image_info and image_info.kind == "image",
    "image preview should return image metadata"
)
assert(
    image_info.path == path_target.path,
    "image preview metadata should include the target path"
)

local selected_titles = {}
local old_select = vim.ui.select
vim.ui.select = function(items, opts, on_choice)
    for _, item in ipairs(items) do
        selected_titles[#selected_titles + 1] = opts.format_item(item)
        if item.id == "copy_target" then
            on_choice(item)
            return
        end
    end
    on_choice(items[1])
end
vim.cmd("TypstContextMenu")
vim.ui.select = old_select

assert(
    vim.tbl_contains(selected_titles, "Open file"),
    "TypstContextMenu should offer path follow action"
)
assert(
    vim.tbl_contains(selected_titles, "Reveal file"),
    "TypstContextMenu should offer path reveal action"
)
assert(
    vim.fn.getreg('"') == path_target.path,
    "copy context action should copy the resolved target"
)

local csl_dir = typst_test_cache_path("context-csl")
vim.fn.mkdir(csl_dir, "p")
local csl_main = csl_dir .. "/main.typ"
local csl_bib = csl_dir .. "/refs.bib"
local csl_file = csl_dir .. "/custom-style.csl"
vim.fn.writefile({
    "@article{csl-key,",
    "  title = {CSL Fixture},",
    "}",
}, csl_bib)
vim.fn.writefile({
    '<style xmlns="http://purl.org/net/xbiblio/csl" version="1.0"></style>',
}, csl_file)
vim.fn.writefile({
    '#bibliography("refs.bib", style: "custom-style.csl")',
    '#bibliography("refs.bib", style: "ieee")',
}, csl_main)
vim.cmd.edit(csl_main)
vim.bo.filetype = "typst"
typst.project.set_main(csl_main)

place_on("custom-style.csl")
local csl_actions, _, csl_target = typst.context.open({ open = false })
assert(
    csl_target and csl_target.kind == "path",
    "local CSL style context should resolve a path target"
)
assert(
    csl_target.path == csl_file,
    "local CSL style context should point at the CSL file"
)
assert(
    csl_target.path_kind == "csl_style",
    "local CSL style context should expose path_kind"
)
assert(
    action_by_id(csl_actions, "follow"),
    "local CSL style context should include follow action"
)
assert(
    action_by_id(csl_actions, "path_reveal"),
    "local CSL style context should include reveal action"
)

place_on("ieee")
local _, _, builtin_style_target = typst.context.open({ open = false })
assert(
    not builtin_style_target,
    "built-in CSL style context should not resolve a fake path target"
)

vim.cmd.edit(main)
vim.bo.filetype = "typst"
typst.project.set_main(main)

place_on("@preview/cetz:0.3.4")
local package_actions, package_ctx, package_target =
    typst.context.open({ open = false })
assert(
    package_ctx and package_ctx.kind == "package",
    "package context should resolve package resource context"
)
assert(
    package_target and package_target.kind == "package",
    "package context should resolve package follow target"
)
assert(
    action_by_id(package_actions, "package_info"),
    "package context should include package info action"
)
assert(
    action_by_id(package_actions, "package_source"),
    "package context should include package source action"
)
assert(
    action_by_id(package_actions, "package_open"),
    "package context should include package open action"
)
local package_update = assert(
    action_by_id(package_actions, "package_update_version"),
    "package context should include cached update-version action"
)

local context = require("typst.context")
local package_versions = context.execute(package_update, { open = false })
assert(
    vim.deep_equal(package_versions, { "0.4.0", "0.10.0-rc.1", "0.10.0" }),
    "package update action should list newer cached versions in semver order"
)
local updated_spec = context.execute(package_update, { version = "0.4.0" })
assert(
    updated_spec == "@preview/cetz:0.4.0",
    "package update action should return the updated spec"
)
assert(
    vim.api.nvim_get_current_line():find("@preview/cetz:0.4.0", 1, true),
    "package update should edit source"
)
vim.api.nvim_set_current_line('#import "@preview/cetz:0.3.4": canvas')
vim.bo.modified = false

place_on("@preview/article-template:1.0.0")
local template_actions = typst.context.open({ open = false })
assert(
    action_by_id(template_actions, "template_info"),
    "template package context should include info action"
)
local template_source = assert(
    action_by_id(template_actions, "template_source"),
    "template package context should include source action"
)
local template_init = assert(
    action_by_id(template_actions, "template_init"),
    "template package context should include init action"
)
local template_entrypoint = context.execute(template_source, { open = false })
assert(
    template_entrypoint:match("article%-template/1%.0%.0/template/main%.typ$"),
    "template source should open entrypoint"
)
local template_info = context.execute(template_init, { open = false })
assert(
    template_info and template_info.spec == "@preview/article-template:1.0.0",
    "template init should expose context"
)
local template_self_destination = context.execute(
    template_init,
    { destination = template_info.source, overwrite = true }
)
assert(
    template_self_destination
        and template_self_destination.reason == "destination_is_template",
    "template init should reject copying a template onto itself"
)
local template_inside_destination = context.execute(
    template_init,
    { destination = template_info.source .. "/nested", overwrite = true }
)
assert(
    template_inside_destination
        and template_inside_destination.reason
            == "destination_inside_template",
    "template init should reject copying a template inside itself"
)
local template_destination = typst_test_cache_path("context-template-init")
local template_result = context.execute(
    template_init,
    { destination = template_destination, overwrite = true }
)
assert(
    template_result and template_result.ok,
    "template init should copy template files"
)
assert(
    vim.fn.filereadable(template_destination .. "/main.typ") == 1,
    "template init should copy entrypoint"
)

local package_provider = require("typst.package.cache")
package_provider.reset()
local unsafe_template_main =
    typst_test_cache_path("context-template-unsafe/main.typ")
vim.fn.mkdir(vim.fs.dirname(unsafe_template_main), "p")
vim.fn.writefile({
    '#import "@preview/escape-template-path:1.0.0": fixture-template',
    '#import "@preview/escape-template-entrypoint:1.0.0": fixture-template',
}, unsafe_template_main)
vim.cmd.edit(unsafe_template_main)
typst.project.set_main(unsafe_template_main)

place_on("@preview/escape-template-path:1.0.0")
local unsafe_path_actions = typst.context.open({ open = false })
local unsafe_path_source = context.execute(
    assert(action_by_id(unsafe_path_actions, "template_source")),
    { open = false }
)
assert(
    unsafe_path_source
        and unsafe_path_source.ok == false
        and unsafe_path_source.reason == "template_path_outside_package",
    "template source should reject template paths outside the cached package"
)
local unsafe_path_init = context.execute(
    assert(action_by_id(unsafe_path_actions, "template_init")),
    {
        destination = typst_test_cache_path(
            "context-template-unsafe-path-dest"
        ),
        overwrite = true,
    }
)
assert(
    unsafe_path_init
        and unsafe_path_init.ok == false
        and unsafe_path_init.reason == "template_path_outside_package",
    "template init should reject template paths outside the cached package"
)

place_on("@preview/escape-template-entrypoint:1.0.0")
local unsafe_entrypoint_actions = typst.context.open({ open = false })
local unsafe_entrypoint_source = context.execute(
    assert(action_by_id(unsafe_entrypoint_actions, "template_source")),
    { open = false }
)
assert(
    unsafe_entrypoint_source
        and unsafe_entrypoint_source.ok == false
        and unsafe_entrypoint_source.reason
            == "template_entrypoint_outside_template",
    "template source should reject entrypoints outside the template directory"
)
local unsafe_entrypoint_init = context.execute(
    assert(action_by_id(unsafe_entrypoint_actions, "template_init")),
    {
        destination = typst_test_cache_path(
            "context-template-unsafe-entrypoint-dest"
        ),
        overwrite = true,
    }
)
assert(
    unsafe_entrypoint_init
        and unsafe_entrypoint_init.ok == false
        and unsafe_entrypoint_init.reason
            == "template_entrypoint_outside_template",
    "template init should reject entrypoints outside the template directory"
)

vim.cmd.edit(main)
typst.project.set_main(main)

place_on("Intro")
local heading_actions = typst.context.open({ open = false })
local demote_heading = assert(
    action_by_id(heading_actions, "heading_demote"),
    "heading context should include demote action"
)
assert(
    action_by_id(heading_actions, "heading_promote"),
    "heading context should include promote action"
)
local demoted = context.execute(demote_heading, { open = false })
assert(
    demoted and demoted.ok and demoted.level == 2,
    "heading demote action should demote the current heading"
)
assert(
    vim.api.nvim_get_current_line():match("^== Intro"),
    "heading demote action should edit the heading marker"
)
place_on("Intro")
local promoted_actions = typst.context.open({ open = false })
local promoted = context.execute(
    assert(action_by_id(promoted_actions, "heading_promote")),
    { open = false }
)
assert(
    promoted and promoted.ok and promoted.level == 1,
    "heading promote action should promote the current heading"
)
assert(
    vim.api.nvim_get_current_line():match("^= Intro"),
    "heading promote action should restore the heading marker"
)
vim.bo.modified = false

place_on("x + y")
local equation_actions = typst.context.open({ open = false })
local equation_convert = assert(
    action_by_id(equation_actions, "equation_convert"),
    "equation context should include style conversion"
)
local equation_styles = context.execute(equation_convert, { open = false })
assert(
    vim.tbl_contains(equation_styles, "block"),
    "equation conversion action should expose block style"
)
local numbered = context.execute(
    assert(
        action_by_id(equation_actions, "equation_numbering"),
        "equation context should include numbering toggle"
    ),
    { style = "on" }
)
assert(
    numbered and numbered.ok and numbered.style == "on",
    "equation numbering action should enable numbering"
)
assert(
    vim.api.nvim_get_current_line():find("#math.equation(numbering:", 1, true),
    "equation numbering action should wrap math syntax"
)
vim.api.nvim_set_current_line("$ x + y $")
vim.bo.modified = false

vim.api.nvim_set_current_line("#math.equation(numbering: none, $ x + y $)")
place_on("numbering")
local equation_call_actions = typst.context.open({ open = false })
assert(
    action_by_id(equation_call_actions, "equation_numbering"),
    "math.equation call context should include numbering toggle"
)
assert(
    not action_by_id(equation_call_actions, "equation_convert"),
    "math.equation call context should not include math-syntax conversion"
)
local call_numbered = context.execute(
    assert(action_by_id(equation_call_actions, "equation_numbering")),
    { style = "on" }
)
assert(
    call_numbered and call_numbered.ok,
    "equation numbering action should edit math.equation calls"
)
assert(
    vim.api.nvim_get_current_line():find('numbering: "(1)"', 1, true),
    "equation call numbering should update the argument"
)
vim.api.nvim_set_current_line("$ x + y $")
vim.bo.modified = false

place_on("fuchsia")
local color_actions = typst.context.open({ open = false })
local color_preview = assert(
    action_by_id(color_actions, "color_preview"),
    "color context should include preview action"
)
local color_replace = assert(
    action_by_id(color_actions, "color_replace"),
    "color context should include replace action"
)
local color_info = context.execute(color_preview, { open = false })
assert(
    color_info and color_info.name == "fuchsia",
    "color preview should return color metadata"
)
local color_words = context.execute(color_replace, { open = false })
assert(
    vim.tbl_contains(color_words, "red"),
    "color replacement should list known Typst colors"
)
context.execute(color_replace, { color = "red" })
assert(
    vim.api.nvim_get_current_line():find("fill: red", 1, true),
    "color replace should edit source"
)
vim.api.nvim_set_current_line("#rect(fill: fuchsia, stroke: color.map.viridis)")
vim.bo.modified = false

place_on("Unit Test Serif")
local font_actions = typst.context.open({ open = false })
local font_info_action = assert(
    action_by_id(font_actions, "font_info"),
    "font context should include info action"
)
local font_replace = assert(
    action_by_id(font_actions, "font_replace"),
    "font context should include replace action"
)
local font_info = context.execute(font_info_action, { open = false })
assert(
    font_info and font_info.name == "Unit Test Serif",
    "font info should return the current font name"
)
assert(font_info.available, "configured font should be reported as available")
local font_words = context.execute(font_replace, { open = false })
assert(
    vim.tbl_contains(font_words, "Replacement Serif"),
    "font replacement should list configured fonts"
)
context.execute(font_replace, { font = "Replacement Serif" })
assert(
    vim.api.nvim_get_current_line():find('"Replacement Serif"', 1, true),
    "font replace should edit source"
)
vim.api.nvim_set_current_line('#set text(font: "Unit Test Serif")')
vim.bo.modified = false

place_on("@doe2020")
local citation_actions, _, citation_target =
    typst.context.open({ open = false })
assert(
    citation_target and citation_target.kind == "citation",
    "citation context should resolve citation target"
)
assert(
    action_by_id(citation_actions, "citation_entry"),
    "citation context should include bibliography entry action"
)
assert(
    action_by_id(citation_actions, "citation_preview"),
    "citation context should include formatted preview action"
)
assert(
    action_by_id(citation_actions, "citation_rename"),
    "citation context should include citation key rename action"
)
assert(
    action_by_id(citation_actions, "copy_citation_key"),
    "citation context should include citation key copy action"
)
assert(
    action_by_id(citation_actions, "citation_url"),
    "citation context should include URL action"
)
assert(
    action_by_id(citation_actions, "citation_doi"),
    "citation context should include DOI action"
)
assert(
    action_by_id(citation_actions, "citation_pdf"),
    "citation context should include PDF action"
)

local entry = context.execute(
    assert(action_by_id(citation_actions, "citation_entry")),
    { open = false }
)
assert(
    entry and entry:match("refs%.bib$"),
    "citation entry action should return bibliography path"
)
local citation_preview = context.execute(
    assert(action_by_id(citation_actions, "citation_preview")),
    { open = false }
)
assert(
    citation_preview
        and citation_preview.ok
        and citation_preview.text:find("Fixture Reference", 1, true),
    "citation preview action should return formatted bibliography text"
)
local citation_rename_plan = context.execute(
    assert(action_by_id(citation_actions, "citation_rename")),
    { open = false }
)
assert(
    citation_rename_plan
        and citation_rename_plan.kind == "bibliography_key_rename",
    "citation rename action should return a rename plan when not applying"
)
local url = context.execute(
    assert(action_by_id(citation_actions, "citation_url")),
    { open = false }
)
assert(
    url == "https://example.com/doe2020",
    "citation URL action should return bibliography URL"
)
local doi = context.execute(
    assert(action_by_id(citation_actions, "citation_doi")),
    { open = false }
)
assert(
    doi == "https://doi.org/10.1000/fixture",
    "citation DOI action should normalize DOI URL"
)
local pdf = context.execute(
    assert(action_by_id(citation_actions, "citation_pdf")),
    { open = false }
)
assert(
    pdf and pdf:match("paper%.pdf$"),
    "citation PDF action should return attached PDF path"
)
assert(
    vim.fn.filereadable(pdf) == 1,
    "citation PDF action should return a readable local attachment"
)
context.execute(assert(action_by_id(citation_actions, "copy_citation_key")))
assert(
    vim.fn.getreg('"') == "doe2020",
    "citation key action should copy citation key"
)

place_on("@yaml2022")
local yaml_actions, _, yaml_target = typst.context.open({ open = false })
assert(
    yaml_target and yaml_target.kind == "citation",
    "Hayagriva citation context should resolve citation target"
)
local yaml_url = context.execute(
    assert(action_by_id(yaml_actions, "citation_url")),
    { open = false }
)
assert(
    yaml_url == "https://example.com/yaml",
    "Hayagriva citation URL action should return bibliography URL"
)
local yaml_doi = context.execute(
    assert(action_by_id(yaml_actions, "citation_doi")),
    { open = false }
)
assert(
    yaml_doi == "https://doi.org/10.2000/yaml",
    "Hayagriva citation DOI action should normalize DOI URL"
)
local yaml_pdf = context.execute(
    assert(action_by_id(yaml_actions, "citation_pdf")),
    { open = false }
)
assert(
    yaml_pdf and yaml_pdf:match("yaml%-paper%.pdf$"),
    "Hayagriva citation PDF action should return attached PDF path"
)
assert(
    vim.fn.filereadable(yaml_pdf) == 1,
    "Hayagriva citation PDF action should return a readable attachment"
)

local doi_dir = typst_test_cache_path("context-doi-normalization")
vim.fn.mkdir(doi_dir, "p")
local doi_main = doi_dir .. "/main.typ"
local doi_bib = doi_dir .. "/refs.bib"
vim.fn.writefile({
    "@article{doi-prefix,",
    "  title = {DOI Prefix},",
    "  doi = {doi:10.3000/prefix},",
    "}",
    "@article{doi-url,",
    "  title = {DOI URL},",
    "  doi = {https://dx.doi.org/10.3000/dx},",
    "}",
    "@article{doi-nondoi-url,",
    "  title = {Non-DOI URL},",
    "  doi = {https://example.com/not-a-doi},",
    "}",
}, doi_bib)
vim.fn.writefile({
    '#bibliography("refs.bib")',
    "See @doi-prefix, @doi-url, and @doi-nondoi-url.",
}, doi_main)
vim.cmd.edit(doi_main)
typst.project.set_main(doi_main)
place_on("@doi-prefix")
local doi_prefix_actions = typst.context.open({ open = false })
local doi_prefix = context.execute(
    assert(action_by_id(doi_prefix_actions, "citation_doi")),
    { open = false }
)
assert(
    doi_prefix == "https://doi.org/10.3000/prefix",
    "citation DOI action should strip doi: prefixes"
)
place_on("@doi-url")
local doi_url_actions = typst.context.open({ open = false })
local canonical_doi_url = context.execute(
    assert(action_by_id(doi_url_actions, "citation_doi")),
    { open = false }
)
assert(
    canonical_doi_url == "https://doi.org/10.3000/dx",
    "citation DOI action should canonicalize dx.doi.org URLs"
)
place_on("@doi-nondoi-url")
local nondoi_url_actions = typst.context.open({ open = false })
local nondoi_url = context.execute(
    assert(action_by_id(nondoi_url_actions, "citation_doi")),
    { open = false }
)
assert(
    nondoi_url == "https://example.com/not-a-doi",
    "citation DOI action should preserve non-DOI URLs"
)

local missing_attachment_dir =
    typst_test_cache_path("context-missing-attachment")
vim.fn.mkdir(missing_attachment_dir, "p")
local missing_attachment_main = missing_attachment_dir .. "/main.typ"
local missing_attachment_bib = missing_attachment_dir .. "/refs.bib"
vim.fn.writefile({
    "@article{missing-pdf,",
    "  title = {Missing Attachment},",
    "  file = {missing.pdf},",
    "}",
}, missing_attachment_bib)
vim.fn.writefile({
    '#bibliography("refs.bib")',
    "See @missing-pdf.",
}, missing_attachment_main)
vim.cmd.edit(missing_attachment_main)
typst.project.set_main(missing_attachment_main)
place_on("@missing-pdf")
local missing_attachment_actions, _, missing_attachment_target =
    typst.context.open({ open = false })
assert(
    missing_attachment_target and missing_attachment_target.kind == "citation",
    "missing attachment fixture should resolve citation target"
)
assert(
    not action_by_id(missing_attachment_actions, "citation_pdf"),
    "citation context should not expose missing local PDF attachments"
)

local ambiguous_dir = typst_test_cache_path("context-ambiguous-cite")
vim.fn.mkdir(ambiguous_dir, "p")
local ambiguous_main = ambiguous_dir .. "/main.typ"
local ambiguous_bib = ambiguous_dir .. "/refs.bib"
vim.fn.writefile({
    "@article{same-key,",
    "  title = {Same Key Citation},",
    "  url = {https://example.com/same-key},",
    "}",
}, ambiguous_bib)
vim.fn.writefile({
    "= Same <same-key>",
    '#bibliography("refs.bib")',
    "Text @same-key.",
    "#cite(<same-key>)",
}, ambiguous_main)
vim.cmd.edit(ambiguous_main)
vim.bo.filetype = "typst"
typst.project.set_main(ambiguous_main)

place_on("@same-key")
local ambiguous_label_actions, _, ambiguous_label_target =
    typst.context.open({ open = false })
assert(
    ambiguous_label_target and ambiguous_label_target.kind == "label",
    "ambiguous shorthand reference context should preserve label fallback"
)
assert(
    action_by_id(ambiguous_label_actions, "label_references"),
    "ambiguous label context should include label actions"
)

place_on("cite(<same-key>)")
local explicit_cite_actions, _, explicit_cite_target =
    typst.context.open({ open = false })
assert(
    explicit_cite_target and explicit_cite_target.kind == "citation",
    "explicit cite context should resolve citation target"
)
assert(
    action_by_id(explicit_cite_actions, "citation_entry"),
    "explicit cite context should include citation actions"
)
assert(
    action_by_id(explicit_cite_actions, "citation_url"),
    "explicit cite context should include citation URL action"
)

vim.cmd.edit(main)
vim.bo.filetype = "typst"
typst.project.set_main(main)

place_on("sec:intro")
local label_actions, _, label_target = typst.context.open({ open = false })
assert(
    label_target and label_target.kind == "label",
    "label context should resolve label target"
)
assert(
    action_by_id(label_actions, "copy_label"),
    "label context should include label copy action"
)
assert(
    action_by_id(label_actions, "label_references"),
    "label context should include reference listing action"
)
context.execute(assert(action_by_id(label_actions, "copy_label")))
assert(
    vim.fn.getreg('"') == "sec:intro",
    "label copy action should copy label name"
)
local label_refs = context.execute(
    assert(action_by_id(label_actions, "label_references")),
    { open = false }
)
assert(#label_refs > 0, "label reference action should return quickfix items")
assert(
    label_refs[1].text:match("@sec:intro"),
    "label reference quickfix text should mention the reference"
)
assert(
    action_by_id(label_actions, "label_rename"),
    "label context should include rename action"
)

local old_index_collect = index.collect
index.collect = function()
    return {
        labels = {
            {
                name = "sec:intro",
                source = {
                    path = "C:/Users/Charlie/Project/main.typ",
                    lnum = 1,
                    col = 1,
                },
            },
            {
                name = "sec:intro",
                source = {
                    path = "c:\\users\\charlie\\project\\main.typ",
                    lnum = 1,
                    col = 1,
                },
            },
        },
        references = {},
    }
end
local windows_rename_plan = context.execute(
    assert(action_by_id(label_actions, "label_rename")),
    { open = false }
)
index.collect = old_index_collect
assert(
    windows_rename_plan.edits and #windows_rename_plan.edits == 1,
    "label rename planning should dedupe Windows-equivalent label source paths"
)

local rename_dir = typst_test_cache_path("context-label-rename")
vim.fn.mkdir(rename_dir, "p")
local rename_main = rename_dir .. "/main.typ"
vim.fn.writefile({
    "= Scratch <old:label>",
    "See @old:label.",
    "Also #ref(<old:label>) and @old:label.",
}, rename_main)
vim.cmd.edit(rename_main)
typst.project.set_main(rename_main)
place_on("old:label")
local rename_actions = typst.context.open({ open = false })
local original_loaded_buffer_for_path = util.loaded_buffer_for_path
local loaded_buffer_lookup_path = nil
util.loaded_buffer_for_path = function(path)
    loaded_buffer_lookup_path = path
    return original_loaded_buffer_for_path(path)
end
local rename_ok, rename_result = pcall(
    context.execute,
    assert(action_by_id(rename_actions, "label_rename")),
    {
        open = false,
        new_name = "new:label",
    }
)
util.loaded_buffer_for_path = original_loaded_buffer_for_path
assert(rename_ok, rename_result)
assert(
    loaded_buffer_lookup_path == rename_main,
    "fallback label rename should prepare edits through the path-identity buffer helper"
)
assert(
    rename_result and rename_result.ok,
    "label rename action should report success"
)
assert(
    rename_result.provider == "syntax",
    "fallback label rename should report the syntax provider"
)
assert(
    rename_result.semantic == false,
    "fallback label rename should not report semantic rename"
)
assert(
    rename_result.edits and #rename_result.edits == 4,
    "label rename action should update definition, shorthand references, and explicit references"
)
local renamed_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
assert(
    renamed_lines[1]:find("<new:label>", 1, true),
    "label rename should update label definition"
)
assert(
    renamed_lines[2]:find("@new:label", 1, true),
    "label rename should update label reference"
)
assert(
    renamed_lines[3]:find("#ref(<new:label>)", 1, true),
    "label rename should update explicit ref calls"
)
assert(
    renamed_lines[3]:find("@new:label", 1, true),
    "label rename should update repeated shorthand refs"
)

local stale_main = rename_dir .. "/stale.typ"
vim.fn.writefile({
    "= Scratch <stale:label>",
    "See @stale:label.",
}, stale_main)
vim.cmd.edit(stale_main)
typst.project.set_main(stale_main)
place_on("stale:label")
local stale_actions = typst.context.open({ open = false })
vim.api.nvim_buf_set_lines(0, 0, -1, false, {
    "= Scratch <other:label>",
    "See @other:label.",
})
local stale_result =
    context.execute(assert(action_by_id(stale_actions, "label_rename")), {
        open = false,
        new_name = "wrong:label",
    })
assert(stale_result and not stale_result.ok, "stale label rename should fail")
assert(
    stale_result.provider == "syntax",
    "failed fallback label rename should report the syntax provider"
)
assert(
    stale_result.semantic == false,
    "failed fallback label rename should not report semantic rename"
)
assert(
    stale_result.reason == "stale_source",
    "stale label rename should report stale source"
)
local stale_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
assert(
    stale_lines[1]:find("<other:label>", 1, true),
    "stale label rename should not edit the definition"
)
assert(
    stale_lines[2]:find("@other:label", 1, true),
    "stale label rename should not edit the reference"
)

local function label_source(path, line, token)
    local col = assert(
        line:find(token, 1, true),
        "missing token in label rename fixture: " .. token
    )
    return {
        path = path,
        lnum = 1,
        col = col,
    }
end

local nonmodifiable_main = rename_dir .. "/nonmodifiable.typ"
local nonmodifiable_ref = rename_dir .. "/nonmodifiable-ref.typ"
local nonmodifiable_main_line = "= Scratch <atomic:label>"
local nonmodifiable_ref_line = "See @atomic:label."
vim.fn.writefile({ nonmodifiable_main_line }, nonmodifiable_main)
vim.fn.writefile({ nonmodifiable_ref_line }, nonmodifiable_ref)
vim.cmd.edit(nonmodifiable_main)
vim.bo.filetype = "typst"
typst.project.set_main(nonmodifiable_main)
place_on("atomic:label")
local nonmodifiable_actions = typst.context.open({ open = false })
old_index_collect = index.collect
index.collect = function()
    return {
        labels = {
            {
                name = "atomic:label",
                source = label_source(
                    nonmodifiable_main,
                    nonmodifiable_main_line,
                    "<atomic:label>"
                ),
            },
        },
        references = {
            {
                name = "atomic:label",
                source = label_source(
                    nonmodifiable_ref,
                    nonmodifiable_ref_line,
                    "@atomic:label"
                ),
            },
        },
    }
end
vim.bo.modifiable = false
local nonmodifiable_result = context.execute(
    assert(action_by_id(nonmodifiable_actions, "label_rename")),
    {
        open = false,
        new_name = "renamed:label",
    }
)
vim.bo.modifiable = true
index.collect = old_index_collect
assert(
    nonmodifiable_result and not nonmodifiable_result.ok,
    "nonmodifiable label rename should fail"
)
assert(
    nonmodifiable_result.reason == "buffer_not_modifiable",
    "nonmodifiable label rename should validate buffer modifiability"
)
assert(
    vim.api.nvim_buf_get_lines(0, 0, -1, false)[1] == nonmodifiable_main_line,
    "nonmodifiable label rename should not edit the loaded buffer"
)
assert(
    vim.fn.readfile(nonmodifiable_ref)[1] == nonmodifiable_ref_line,
    "nonmodifiable label rename should not write earlier disk files"
)

local rollback_main = rename_dir .. "/rollback.typ"
local rollback_ref = rename_dir .. "/rollback-ref.typ"
local rollback_main_line = "= Scratch <rollback:label>"
local rollback_ref_line = "See @rollback:label."
vim.fn.writefile({ rollback_main_line }, rollback_main)
vim.fn.writefile({ rollback_ref_line }, rollback_ref)
vim.cmd.edit(rollback_main)
vim.bo.filetype = "typst"
typst.project.set_main(rollback_main)
place_on("rollback:label")
local rollback_bufnr = vim.api.nvim_get_current_buf()
local rollback_actions = typst.context.open({ open = false })
old_index_collect = index.collect
index.collect = function()
    return {
        labels = {
            {
                name = "rollback:label",
                source = label_source(
                    rollback_main,
                    rollback_main_line,
                    "<rollback:label>"
                ),
            },
        },
        references = {
            {
                name = "rollback:label",
                source = label_source(
                    rollback_ref,
                    rollback_ref_line,
                    "@rollback:label"
                ),
            },
        },
    }
end
local original_set_lines = vim.api.nvim_buf_set_lines
vim.api.nvim_buf_set_lines = function(bufnr, ...)
    if bufnr == rollback_bufnr then
        error("forced buffer apply failure")
    end
    return original_set_lines(bufnr, ...)
end
local rollback_result =
    context.execute(assert(action_by_id(rollback_actions, "label_rename")), {
        open = false,
        new_name = "restored:label",
    })
vim.api.nvim_buf_set_lines = original_set_lines
index.collect = old_index_collect
assert(
    rollback_result and not rollback_result.ok,
    "failed buffer apply should fail the rename transaction"
)
assert(
    rollback_result.reason == "buffer_apply_failed",
    "failed buffer apply should report the protected error reason"
)
assert(
    vim.api.nvim_buf_get_lines(rollback_bufnr, 0, -1, false)[1]
        == rollback_main_line,
    "failed buffer apply should leave the loaded buffer unchanged"
)
assert(
    vim.fn.readfile(rollback_ref)[1] == rollback_ref_line,
    "failed buffer apply should roll back disk files already written"
)

local semantic_only_main = rename_dir .. "/semantic-only.typ"
vim.fn.writefile({
    "= Scratch <semantic:label>",
    "See @semantic:label.",
}, semantic_only_main)
vim.cmd.edit(semantic_only_main)
vim.bo.filetype = "typst"
typst.project.set_main(semantic_only_main)
place_on("semantic:label")
local semantic_only_actions = typst.context.open({ open = false })
local old_get_clients = vim.lsp.get_clients
vim.lsp.get_clients = function()
    return {}
end
local semantic_only_result = context.execute(
    assert(action_by_id(semantic_only_actions, "label_rename")),
    {
        open = false,
        new_name = "renamed:label",
        semantic = true,
    }
)
vim.lsp.get_clients = old_get_clients
assert(
    semantic_only_result and not semantic_only_result.ok,
    "semantic-only label rename should fail without Tinymist"
)
assert(
    semantic_only_result.provider == "tinymist",
    "semantic-only label rename should report the Tinymist provider"
)
assert(
    semantic_only_result.semantic == true,
    "semantic-only label rename should preserve semantic intent"
)
assert(
    semantic_only_result.reason == "async_required",
    "semantic-only label rename should require async Tinymist"
)
local semantic_only_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
assert(
    semantic_only_lines[1]:find("<semantic:label>", 1, true),
    "semantic-only label rename should not edit the definition syntactically"
)
assert(
    semantic_only_lines[2]:find("@semantic:label", 1, true),
    "semantic-only label rename should not edit the reference syntactically"
)

local signature_main = rename_dir .. "/signature.typ"
vim.fn.writefile({
    "#let sig-card(body, fill: red) = body",
    "#sig-card(body, fill: red)",
}, signature_main)
vim.cmd.edit(signature_main)
typst.project.set_main(signature_main)
vim.api.nvim_win_set_cursor(0, { 2, #"#sig-card(body, fill" })
local signature_actions = typst.context.open({ open = false })
local signature_action = assert(
    action_by_id(signature_actions, "function_signature"),
    "function context should include signature action"
)
local signature_info = context.execute(signature_action, { open = false })
assert(
    signature_info and signature_info.label == "sig-card(body, fill: red)",
    "function signature action should return project-index signature metadata"
)

vim.cmd.edit(main)
typst.project.set_main(main)

place_on("local-card[Body]")
local definition_actions, _, definition_target =
    typst.context.open({ open = false })
assert(
    definition_target and definition_target.kind == "definition",
    "definition context should resolve local definition target"
)
assert(
    action_by_id(definition_actions, "definition_references"),
    "definition context should include occurrence listing action"
)
local definition_refs = context.execute(
    assert(action_by_id(definition_actions, "definition_references")),
    { open = false }
)
assert(
    #definition_refs >= 2,
    "definition reference action should return declaration and use occurrences"
)

local occurrence_main = rename_dir .. "/definition-occurrences.typ"
vim.fn.writefile({
    "#let target-func() = none",
    "#target-func()",
    "Don't hide #target-func() after a contraction",
    "// target-func in comment",
    '#let text = "target-func in string"',
    "Inline raw: `target-func in raw`",
    "/*",
    "target-func in block comment",
    "*/",
    "```typ",
    "target-func in fenced raw",
    "```",
}, occurrence_main)
vim.cmd.edit(occurrence_main)
typst.project.set_main(occurrence_main)
place_on("target-func")
local occurrence_actions = typst.context.open({ open = false })
local occurrence_refs = context.execute(
    assert(action_by_id(occurrence_actions, "definition_references")),
    { open = false }
)
assert(
    #occurrence_refs == 3,
    "definition references should include code occurrences after contractions"
)
for _, item in ipairs(occurrence_refs) do
    assert(
        not item.text:find("comment", 1, true),
        "definition references should ignore comments"
    )
    assert(
        not item.text:find("string", 1, true),
        "definition references should ignore strings"
    )
    assert(
        not item.text:find("raw", 1, true),
        "definition references should ignore raw text"
    )
end

vim.cmd.edit(root .. "/tests/fixtures/basic/conceal.typ")
place_on("arrow.r")
local symbol_actions = typst.context.open({ open = false })
local symbol_info_action = assert(
    action_by_id(symbol_actions, "symbol_info"),
    "symbol context should include info action"
)
local symbol_result = context.execute(symbol_info_action, { open = false })
assert(
    symbol_result and symbol_result.kind == "symbol",
    "symbol context action should resolve symbol metadata"
)
local symbol_action = assert(
    action_by_id(symbol_actions, "symbol_insert_variant"),
    "symbol context should include variant action"
)
local variants = context.execute(symbol_action, { open = false })
assert(
    vim.tbl_contains(variants, "arrow.r.long"),
    "symbol variant action should expose generated variants"
)
context.execute(symbol_action, { variant = "arrow.r.long" })
local symbol_line = vim.api.nvim_get_current_line()
assert(
    symbol_line:match("arrow%.r%.long"),
    "symbol variant action should replace the symbol under cursor"
)
vim.bo.modified = false

vim.env.TYPST_PACKAGE_CACHE_PATH = old_package_cache_path
vim.cmd("qa!")
