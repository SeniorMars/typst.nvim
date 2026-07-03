local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")
local project_services = require("typst.project.services")
local util = require("typst.core.util")

typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("index-output"),
})

local main = root .. "/tests/fixtures/basic/index-main.typ"
vim.cmd.edit(main)
local project = assert(typst.project.attach(0), "index fixture should attach")
local live_project = assert(require("typst.project.store").get(project.key))

local function has_item_named(items, name)
    for _, item in ipairs(items or {}) do
        if item.name == name then
            return true
        end
    end
    return false
end

local labels = typst.navigation.labels({ open = false })
assert(
    has_item_named(labels, "sec:intro"),
    "TypstLabels should list project labels"
)
local labels_qf = vim.fn.getqflist({ title = 1, items = 1 })
assert(
    labels_qf.title:match("typst.nvim labels"),
    "labels quickfix title was not set"
)
local labels_qf_has_intro = false
for _, item in ipairs(labels_qf.items or {}) do
    labels_qf_has_intro = labels_qf_has_intro
        or item.text:find("sec:intro", 1, true) ~= nil
end
assert(labels_qf_has_intro, "labels quickfix items should include the label")

local citations = typst.navigation.citations({ open = false })
local citation_by_name = {}
for _, item in ipairs(citations) do
    citation_by_name[item.name] = item
end
assert(citation_by_name.doe2020, "TypstCitations should list bibliography keys")
assert(
    citation_by_name.smith2021,
    "TypstCitations should parse later bibliography entries"
)
assert(
    citation_by_name.commentedFields2025,
    "TypstCitations should parse entries with commented fields"
)
assert(
    citation_by_name.multiline2026,
    "TypstCitations should parse multiline bibliography calls"
)
assert(
    citation_by_name.yaml2022,
    "TypstCitations should parse Hayagriva bibliography entries"
)
assert(
    citation_by_name.yaml2024,
    "TypstCitations should parse Hayagriva entries with structured people"
)
assert(
    not citation_by_name.commented2024,
    "BibTeX parser should ignore commented-out entries"
)
assert(
    citation_by_name.doe2020.fields.title == "Fixture Reference",
    "BibTeX parser should normalize multiline braced fields"
)
assert(
    citation_by_name.doe2020.fields.url == "https://example.com/doe2020",
    "BibTeX parser should concatenate URL fields"
)
assert(
    citation_by_name.doe2020.fields.doi == "10.1000/fixture",
    "BibTeX parser should concatenate DOI fields"
)
assert(
    citation_by_name.smith2021.fields.title == "Second Fixture",
    "BibTeX parser should preserve spaces across concatenated fields"
)
assert(
    citation_by_name.smith2021.fields.month == "January",
    "BibTeX parser should expand built-in month macros"
)
assert(
    citation_by_name.smith2021.fields.booktitle
        == "Proceedings of FixtureConf 2021",
    "BibTeX parser should expand chained string macros"
)
assert(
    citation_by_name.smith2021.fields.publisher == "Fixture Press imprint",
    "BibTeX parser should expand string macros defined after citation entries"
)
assert(
    citation_by_name.commentedFields2025.fields.author == "Comment, Casey",
    "BibTeX parser should continue parsing after in-entry comments"
)
assert(
    citation_by_name.commentedFields2025.fields.year == "2025",
    "BibTeX parser should keep fields after in-entry comments"
)
assert(
    citation_by_name.yaml2022.fields.title == "YAML Fixture",
    "Hayagriva parser should fold multiline fields"
)
assert(
    citation_by_name.yaml2022.fields.author == "Doe, Jane; Roe, Richard",
    "Hayagriva parser should aggregate scalar sequence fields"
)
assert(
    citation_by_name.yaml2022.fields.doi == "10.2000/yaml",
    "Hayagriva parser should expose nested DOI fields"
)
assert(
    citation_by_name.yaml2022.fields["serial-number.doi"] == "10.2000/yaml",
    "Hayagriva parser should preserve nested field paths"
)
assert(
    citation_by_name.yaml2022.fields.url == "https://example.com/yaml",
    "Hayagriva parser should expose URL fields"
)
assert(
    citation_by_name.yaml2024.fields.author == "Ada Lovelace; Alan Turing",
    "Hayagriva parser should aggregate structured person sequences"
)
assert(
    citation_by_name.yaml2024.fields["author.given-name"] == "Ada; Alan",
    "Hayagriva parser should preserve nested person given-name fields"
)
assert(
    citation_by_name.yaml2024.fields["author.family-name"] == "Lovelace; Turing",
    "Hayagriva parser should preserve nested person family-name fields"
)
assert(
    citation_by_name.yaml2025.fields.author == "Grace Hopper; ACM Team",
    "Hayagriva parser should aggregate inline structured person sequences"
)
assert(
    citation_by_name.yaml2025.fields["author.given-name"] == "Grace",
    "Hayagriva parser should expose inline structured person given-name fields"
)
assert(
    citation_by_name.yaml2025.fields["author.family-name"] == "Hopper",
    "Hayagriva parser should expose inline structured person family-name fields"
)
assert(
    citation_by_name.yaml2025.fields.doi == "10.2000/inline",
    "Hayagriva parser should expose inline map DOI fields"
)
assert(
    citation_by_name.yaml2025.fields["serial-number.doi"] == "10.2000/inline",
    "Hayagriva parser should preserve inline nested field paths"
)
assert(
    citation_by_name.yaml2026.fields.author == "Inline, Alice; Inline, Bob",
    "Hayagriva parser should aggregate inline scalar sequences"
)
assert(
    citation_by_name.yaml2027.fields.title == "Don't Hide YAML Comments",
    "Hayagriva parser should not treat contractions as quoted scalars"
)
assert(
    citation_by_name.yaml2027.fields.author == "Alice's Research Group",
    "Hayagriva parser should preserve possessives in unquoted scalars"
)
local citations_qf = vim.fn.getqflist({ title = 1, items = 1 })
assert(
    citations_qf.title:match("typst.nvim citations"),
    "citations quickfix title was not set"
)
local citations_qf_has_doe = false
for _, item in ipairs(citations_qf.items or {}) do
    citations_qf_has_doe = citations_qf_has_doe
        or item.text:find("doe2020", 1, true) ~= nil
end
assert(citations_qf_has_doe, "citations quickfix items should include the key")

local symbols = typst.navigation.symbols({ open = false })
local symbol_names = vim.tbl_map(function(item)
    return item.name
end, symbols)
assert(
    vim.tbl_contains(symbol_names, "local-card"),
    "TypstSymbols should list local definitions"
)
assert(
    vim.tbl_contains(symbol_names, "helper-func"),
    "TypstSymbols should list imported-file definitions"
)
local symbols_qf = vim.fn.getqflist({ title = 1, items = 1 })
assert(
    symbols_qf.title:match("typst.nvim symbols"),
    "symbols quickfix title was not set"
)

local collected = typst.index.collect({ project = project })
local imported_by_name = {}
for _, item in ipairs(collected.imported_bindings or {}) do
    imported_by_name[item.name] = item
end
local function find_imported(name, predicate)
    for _, item in ipairs(collected.imported_bindings or {}) do
        if item.name == name and (not predicate or predicate(item)) then
            return item
        end
    end
end
assert(
    imported_by_name["exported-value"]
        and imported_by_name["exported-value"].wildcard == true,
    "project index should expand wildcard file imports into imported bindings"
)
assert(
    imported_by_name["helper-alias"]
        and imported_by_name["helper-alias"].imported_name == "helper-func"
        and imported_by_name["helper-alias"].definition.path:match(
            "index%-lib%.typ$"
        ),
    "project index should preserve source names for aliased direct imports"
)
assert(
    imported_by_name["helper-multiline"]
        and imported_by_name["helper-multiline"].imported_name == "helper-func"
        and imported_by_name["helper-multiline"].definition.path:match(
            "index%-lib%.typ$"
        ),
    "project index should preserve source names for multiline aliased imports"
)
assert(
    imported_by_name["exported-multiline"]
        and imported_by_name["exported-multiline"].imported_name == "exported-value"
        and imported_by_name["exported-multiline"].definition.path:match(
            "index%-lib%.typ$"
        ),
    "project index should index later multiline import selectors"
)
assert(
    imported_by_name["hidden.hidden-value"]
        and imported_by_name["hidden.hidden-value"].module == "hidden",
    "project index should expose module-only definitions as qualified imported bindings"
)
local direct_reexport = find_imported("reexported-helper", function(item)
    return item.reexported == true
end)
local aliased_reexport = find_imported("reexported-alias", function(item)
    return item.reexported == true
end)
assert(
    direct_reexport
        and direct_reexport.definition.path:match("index%-leaf%.typ$"),
    "project index should resolve direct file re-exports to their leaf definition"
)
assert(
    aliased_reexport
        and aliased_reexport.imported_name == "aliased-helper"
        and aliased_reexport.definition.path:match("index%-leaf%.typ$"),
    "project index should preserve aliased re-export source names"
)
assert(
    imported_by_name["reexported.reexported-helper"]
        and imported_by_name["reexported.reexported-helper"].reexported == true
        and imported_by_name["reexported.reexported-helper"].definition.path:match(
            "index%-leaf%.typ$"
        ),
    "project index should resolve module-alias re-exports to their leaf definition"
)
assert(
    imported_by_name["reexported.reexported-alias"]
        and imported_by_name["reexported.reexported-alias"].imported_name == "aliased-helper"
        and imported_by_name["reexported.reexported-alias"].definition.path:match(
            "index%-leaf%.typ$"
        ),
    "project index should resolve module-alias aliased re-exports to their leaf definition"
)

local api_labels = typst.index.labels(project)
assert(
    has_item_named(api_labels, "sec:intro"),
    "index.labels should return labels"
)
local sec_intro_labels = 0
for _, item in ipairs(api_labels) do
    if item.name == "sec:intro" then
        sec_intro_labels = sec_intro_labels + 1
    end
end
assert(
    sec_intro_labels == 1,
    "explicit #ref(<label>) should not be indexed as a label definition"
)

local collected_references =
    typst.index.collect({ project = project }).references
local sec_intro_reference_styles = {}
local multiline_reference_styles = {}
local reference_targets = {}
local reference_target_names = {}
for _, item in ipairs(collected_references or {}) do
    if item.name == "sec:intro" then
        sec_intro_reference_styles[item.reference_style or "shorthand"] = true
    end
    if item.name == "multiline2026" then
        multiline_reference_styles[item.reference_style or "shorthand"] = true
    end
    reference_targets[item.name] = reference_targets[item.name] or {}
    reference_targets[item.name][item.reference_target or "unknown"] = true
    if item.reference_target_name then
        reference_target_names[item.reference_target_name] = reference_target_names[item.reference_target_name]
            or {}
        reference_target_names[item.reference_target_name][item.reference_target or "unknown"] =
            true
    end
end
assert(
    sec_intro_reference_styles.shorthand,
    "index.references should include shorthand label references"
)
assert(
    sec_intro_reference_styles["function"],
    "index.references should include explicit #ref(<label>) references"
)
assert(
    reference_targets["sec:intro"].label,
    "label references should be classified as label-targeted"
)
assert(
    reference_targets["apostrophe:label"].label,
    "contractions should not hide later shorthand references"
)
assert(
    reference_targets.doe2020.citation,
    "bibliography-only shorthand references should be classified as citations"
)
assert(
    reference_target_names.yaml2022.citation,
    "Hayagriva shorthand references should be classified as citations"
)
assert(
    multiline_reference_styles.cite,
    "index.references should include explicit #cite(<key>) references"
)
assert(
    reference_targets.multiline2026.citation,
    "explicit #cite(<key>) references should be classified as citations"
)

local api_headings = typst.index.headings(project)
assert(
    api_headings[1] and api_headings[1].title == "Intro",
    "index.headings should return cached headings"
)
assert(
    #typst.index.imports(project) >= 2,
    "index.imports should return local and package imports"
)
assert(
    typst.index.todos(project)[1].tag == "TODO",
    "index.todos should return TODO comments"
)
assert(
    #typst.index.definitions(project) >= 2,
    "index.definitions should return project definitions"
)
local glossary_names = vim.tbl_map(function(item)
    return item.name
end, typst.index.glossary_entries(project))
assert(
    vim.tbl_contains(glossary_names, "api"),
    "index.glossary_entries should include dictionary-style keys"
)
assert(
    vim.tbl_contains(glossary_names, "tls"),
    "index.glossary_entries should include key fields"
)

local function find_definition(name)
    for _, item in ipairs(typst.index.definitions(project) or {}) do
        if item.name == name then
            return item
        end
    end
end

local multiline_definition = assert(
    find_definition("multiline-card"),
    "project index should include multiline local function declarations"
)
assert(
    find_definition("apostrophe-helper"),
    "possessives should not hide later definitions"
)
assert(
    multiline_definition.kind == "function",
    "multiline local #let declarations should be indexed as functions"
)
local multiline_parameters = {}
for _, parameter in ipairs(multiline_definition.parameters or {}) do
    multiline_parameters[parameter.name] = parameter
end
assert(
    multiline_parameters.body,
    "multiline local function parameters should include positional names"
)
assert(
    multiline_parameters.fill and multiline_parameters.fill.default == "aqua",
    "multiline local function parameters should preserve defaults"
)
assert(
    multiline_parameters.stroke
        and multiline_parameters.stroke.default == "black",
    "multiline local function parameters should include later parameters"
)

local function has_label(items, name)
    for _, item in ipairs(items or {}) do
        if item.name == name then
            return true
        end
    end
    return false
end

local function find_path(items, word, path_kind)
    for _, item in ipairs(items or {}) do
        if item.word == word and item.path_kind == path_kind then
            return item
        end
    end
end

assert(
    has_label(api_labels, "apostrophe:label"),
    "contractions should not hide later labels"
)
assert(
    has_label(typst.index.labels(project), "sec:zinclude"),
    "project index should traverse local #include files before compiler dependencies are available"
)
assert(
    has_label(typst.index.definitions(project), "z-included-helper"),
    "project index should include definitions from local #include files"
)
local included_heading = false
for _, item in ipairs(typst.index.headings(project)) do
    if item.title == "Included Section" then
        included_heading = true
        break
    end
end
assert(
    included_heading,
    "project index should include headings from local #include files"
)

local api_paths = typst.index.paths(project)
assert(
    find_path(api_paths, "refs.bib", "bibliography"),
    "public index API should expose bibliography path references"
)
assert(
    find_path(api_paths, "refs-multiline.bib", "bibliography"),
    "public index API should expose multiline bibliography path references"
)
local csl_path = assert(
    find_path(api_paths, "custom-style.csl", "csl_style"),
    "project index should expose local CSL style file references"
)
assert(
    csl_path.path:match("custom%-style%.csl$"),
    "CSL style index entry should resolve the local file"
)
assert(
    find_path(api_paths, "custom-multiline-style.csl", "csl_style"),
    "project index should expose multiline local CSL style file references"
)
assert(
    not find_path(api_paths, "ieee", "csl_style"),
    "project index should not treat built-in CSL style IDs as file references"
)
assert(
    find_path(api_paths, "data.json", "read"),
    "project index should expose read() path references"
)
assert(
    find_path(api_paths, "data-extra.json", "read"),
    "project index should expose multiline read() path references"
)
assert(
    find_path(api_paths, "diagram-multiline.svg", "image"),
    "project index should expose multiline image paths"
)
assert(
    not has_label(collected.labels, "fake:comment"),
    "comment labels should not be indexed"
)
assert(
    not has_label(collected.labels, "fake:string"),
    "string labels should not be indexed"
)
assert(
    not has_label(collected.labels, "fake:inline"),
    "inline raw labels should not be indexed"
)
assert(
    not has_label(collected.labels, "fake:block-heading"),
    "block comment heading labels should not be indexed"
)
assert(
    not has_label(collected.labels, "fake:block"),
    "block comment labels should not be indexed"
)
assert(
    not has_label(collected.labels, "fake:raw-heading"),
    "raw block heading labels should not be indexed"
)
assert(
    not has_label(collected.labels, "fake:raw"),
    "raw block labels should not be indexed"
)
assert(
    not has_label(collected.references, "fake-comment"),
    "comment shorthand references should not be indexed"
)
assert(
    not has_label(collected.references, "fake:ref"),
    "comment explicit references should not be indexed"
)
assert(
    not has_label(collected.references, "fake-string"),
    "string shorthand references should not be indexed"
)
assert(
    not has_label(collected.references, "fake-inline"),
    "inline raw shorthand references should not be indexed"
)
assert(
    not has_label(collected.references, "fake:inline-ref"),
    "inline raw explicit references should not be indexed"
)
assert(
    not has_label(collected.references, "fake-block"),
    "block comment shorthand references should not be indexed"
)
assert(
    not has_label(collected.references, "fake:block-ref"),
    "block comment explicit references should not be indexed"
)
assert(
    not has_label(collected.references, "fake-raw"),
    "raw block shorthand references should not be indexed"
)
assert(
    not has_label(collected.references, "fake:raw-ref"),
    "raw block explicit references should not be indexed"
)
assert(
    not has_label(collected.definitions, "fake-comment"),
    "comment definitions should not be indexed"
)
assert(
    not has_label(collected.definitions, "fake-inline-func"),
    "inline raw definitions should not be indexed"
)
assert(
    not has_label(collected.definitions, "fake-block-func"),
    "block comment definitions should not be indexed"
)
assert(
    not has_label(collected.definitions, "fake-raw-func"),
    "raw block definitions should not be indexed"
)
assert(
    not find_path(api_paths, "fake.typ", "include"),
    "comment includes should not be indexed"
)
assert(
    not find_path(api_paths, "fake.svg", "image"),
    "comment image paths should not be indexed"
)
assert(
    not find_path(api_paths, "fake.bib", "bibliography"),
    "comment bibliography paths should not be indexed"
)
assert(
    not find_path(api_paths, "fake-inline.typ", "include"),
    "inline raw includes should not be indexed"
)
assert(
    not find_path(api_paths, "fake-inline.svg", "image"),
    "inline raw image paths should not be indexed"
)
assert(
    not find_path(api_paths, "fake-inline.bib", "bibliography"),
    "inline raw bibliography paths should not be indexed"
)
assert(
    not find_path(api_paths, "fake-block.typ", "include"),
    "block comment includes should not be indexed"
)
assert(
    not find_path(api_paths, "fake-block.svg", "image"),
    "block comment image paths should not be indexed"
)
assert(
    not find_path(api_paths, "fake-block.bib", "bibliography"),
    "block comment bibliography paths should not be indexed"
)
assert(
    not find_path(api_paths, "fake-raw.typ", "include"),
    "raw block includes should not be indexed"
)
assert(
    not find_path(api_paths, "fake-raw.svg", "image"),
    "raw block image paths should not be indexed"
)
assert(
    not find_path(api_paths, "fake-raw.bib", "bibliography"),
    "raw block bibliography paths should not be indexed"
)
assert(#collected.figures == 1, "non-code figure tokens should not be indexed")
assert(#collected.tables == 1, "non-code table tokens should not be indexed")
assert(
    #collected.equations == 1,
    "non-code equation tokens should not be indexed"
)
for _, item in ipairs(collected.imports or {}) do
    assert(item.spec ~= "fake.typ", "comment imports should not be indexed")
    assert(
        item.spec ~= "fake-inline.typ",
        "inline raw imports should not be indexed"
    )
    assert(
        item.spec ~= "fake-block.typ",
        "block comment imports should not be indexed"
    )
    assert(
        item.spec ~= "fake-raw.typ",
        "raw block imports should not be indexed"
    )
end
for _, item in ipairs(collected.headings or {}) do
    assert(
        item.title ~= "Fake Block Heading",
        "block comment headings should not be indexed"
    )
    assert(
        item.title ~= "Fake Raw Heading",
        "raw block headings should not be indexed"
    )
end
for _, item in ipairs(collected.todos or {}) do
    assert(
        not item.text:find("fake block", 1, true),
        "block comment TODOs should not be indexed"
    )
    assert(
        not item.text:find("fake raw", 1, true),
        "raw block TODOs should not be indexed"
    )
end

local project_index = project_services.index(live_project)
local stats = project_index and project_index.stats
assert(
    stats and stats.file_misses > 0,
    "project index should record initial file scan misses"
)
assert(
    stats.bibliography_misses > 0,
    "project index should cache bibliography scans"
)
assert(
    stats.collect_misses > 0,
    "project index should record aggregate collection misses"
)

local main_record = assert(
    project_index.files[util.path_key(main)],
    "project index should expose a persistent per-file entry for the main file"
)
assert(
    main_record.version and main_record.version ~= "",
    "per-file index entries should expose their version"
)
assert(
    main_record.graph and #main_record.graph > 0,
    "per-file index entries should expose import/include graph edges"
)
assert(
    has_label(main_record.labels, "sec:intro"),
    "per-file index entries should expose labels directly"
)
assert(
    has_label(main_record.definitions, "local-card"),
    "per-file index entries should expose definitions directly"
)
assert(
    vim.tbl_contains(
        vim.tbl_map(function(item)
            return item.title
        end, main_record.headings),
        "Intro"
    ),
    "per-file index entries should expose headings directly"
)
assert(
    main_record.imports[1] and main_record.imports[1].spec == "index-lib.typ",
    "per-file entries should expose imports"
)
assert(
    main_record.paths[1],
    "per-file index entries should expose path references"
)
assert(
    main_record.todos[1] and main_record.todos[1].tag == "TODO",
    "per-file index entries should expose TODOs"
)

local refs_bib = util.normalize(root .. "/tests/fixtures/basic/refs.bib")
local refs_record = assert(
    project_index.bibliographies[util.path_key(refs_bib)],
    "project index should expose persistent bibliography entries"
)
assert(
    refs_record.version and refs_record.version ~= "",
    "bibliography index entries should expose their version"
)
assert(
    has_label(refs_record.citations, "doe2020"),
    "bibliography index entries should expose citations directly"
)

local file_hits = stats.file_hits
local file_misses = stats.file_misses
local bibliography_hits = stats.bibliography_hits
local bibliography_misses = stats.bibliography_misses
local collect_hits = stats.collect_hits
local collect_misses = stats.collect_misses
local unchanged = typst.index.collect({ project = project })
assert(
    stats.collect_hits > collect_hits,
    "unchanged project index collection should reuse aggregate results"
)
assert(
    stats.collect_misses == collect_misses,
    "unchanged project index collection should not rebuild aggregate results"
)
assert(
    stats.file_hits > file_hits,
    "unchanged project index collection should reuse file scans"
)
assert(
    stats.file_misses == file_misses,
    "unchanged project index collection should not rescan files"
)
local semantic_collect_hits = stats.collect_hits
local semantic_collect_misses = stats.collect_misses
local semantic_file_misses = stats.file_misses
local semantic_project = require("typst.project.semantic")
local original_merge_workspace_symbols =
    semantic_project.merge_workspace_symbols
local saw_semantic_traversal = false
semantic_project.merge_workspace_symbols = function(
    merge_project,
    out,
    seen,
    opts,
    traversal,
    helpers
)
    if opts and opts.include_tinymist == true then
        assert(
            type(traversal) == "table"
                and type(traversal.visited) == "table"
                and type(traversal.initial_paths) == "table",
            "Tinymist semantic overlay should receive traversal context"
        )
        saw_semantic_traversal = true
    end
    return original_merge_workspace_symbols(
        merge_project,
        out,
        seen,
        opts,
        traversal,
        helpers
    )
end
local semantic = typst.index.collect({
    project = project,
    include_tinymist = true,
})
semantic_project.merge_workspace_symbols = original_merge_workspace_symbols
assert(
    semantic and semantic ~= unchanged,
    "Tinymist-inclusive project index collection should return a mutable overlay"
)
assert(
    saw_semantic_traversal,
    "Tinymist-inclusive project index collection should pass traversal to semantic overlay"
)
assert(
    stats.collect_hits > semantic_collect_hits,
    "Tinymist-inclusive collection should reuse the syntactic aggregate cache"
)
assert(
    stats.collect_misses == semantic_collect_misses,
    "Tinymist-inclusive collection should not rebuild syntactic aggregate data"
)
assert(
    stats.file_misses == semantic_file_misses,
    "Tinymist-inclusive collection should not rescan syntactic files"
)
local original_loaded_buffers_by_path = util.loaded_buffers_by_path
local loaded_buffer_map_calls = 0
util.loaded_buffers_by_path = function(...)
    loaded_buffer_map_calls = loaded_buffer_map_calls + 1
    return original_loaded_buffers_by_path(...)
end
typst.index.collect({ project = project })
util.loaded_buffers_by_path = original_loaded_buffers_by_path
assert(
    loaded_buffer_map_calls == 1,
    "cached project index collection should build one loaded-buffer map"
)
local shared_unchanged =
    typst.index.collect({ project = project, shared = true })
local shared_unchanged_again =
    typst.index.collect({ project = project, shared = true })
assert(
    shared_unchanged_again == shared_unchanged,
    "aggregate cache callers should be able to request the shared cached snapshot"
)
local unchanged_again = typst.index.collect({ project = project })
assert(
    unchanged_again == unchanged,
    "aggregate cache hits should return the shared cached snapshot by default"
)
local category_collect_hits = stats.collect_hits
local category_collect_misses = stats.collect_misses
local category_file_misses = stats.file_misses
local category_bibliography_misses = stats.bibliography_misses
for _, name in ipairs({
    "headings",
    "labels",
    "citations",
    "imports",
    "todos",
    "definitions",
    "glossary_entries",
    "paths",
}) do
    local items = typst.index[name](project)
    assert(
        type(items) == "table",
        "index category accessor should return a table"
    )
end
assert(
    stats.collect_hits >= category_collect_hits + 8,
    "generation-matched category accessors should use aggregate cache hits"
)
assert(
    stats.collect_misses == category_collect_misses,
    "generation-matched category accessors should not rebuild the aggregate"
)
assert(
    stats.file_misses == category_file_misses,
    "generation-matched category accessors should not rescan files"
)
assert(
    stats.bibliography_misses == category_bibliography_misses,
    "generation-matched category accessors should not reparse bibliographies"
)
local mutable_unchanged =
    typst.index.collect({ project = project, mutable = true })
assert(
    mutable_unchanged ~= unchanged and mutable_unchanged.project == live_project,
    "aggregate cache callers should be able to request an owned mutable copy"
)
assert(
    stats.bibliography_hits > bibliography_hits,
    "unchanged project index collection should reuse bibliography scans"
)
assert(
    stats.bibliography_misses == bibliography_misses,
    "unchanged project index collection should not rescan bibliographies"
)

local raw_path_project = {
    root = root,
    main = root .. "/tests/fixtures/basic/../basic/index-main.typ",
    bufs = {},
}
project_services.ensure(raw_path_project)
typst.index.collect({ project = raw_path_project })
local raw_path_index = project_services.index(raw_path_project)
assert(
    raw_path_index.files[util.path_key(raw_path_project.main)],
    "project index file entries should be stored by canonical path key"
)
assert(
    raw_path_index.files[raw_path_project.main] == nil,
    "project index should not retain raw compatibility path keys"
)

mutable_unchanged.labels[1].name = "mutated-cache-result"
local isolated = typst.index.collect({ project = project, mutable = true })
assert(
    has_label(isolated.labels, "sec:intro"),
    "mutable aggregate results should be isolated from the cached snapshot"
)

vim.api.nvim_buf_set_lines(0, -1, -1, false, { "", "= Cached", "<sec:cached>" })
local edit_misses = stats.file_misses
local edit_hits = stats.file_hits
local edit_collect_misses = stats.collect_misses
local updated = typst.index.collect({ project = project })
assert(
    has_label(updated.labels, "sec:cached"),
    "changed loaded buffer should refresh its cached index entry"
)
assert(
    vim.tbl_contains(
        vim.tbl_map(function(item)
            return item.title
        end, updated.headings),
        "Cached"
    ),
    "changed loaded buffer should refresh cached headings"
)
assert(
    stats.file_misses > edit_misses,
    "changed loaded buffer should be rescanned"
)
assert(
    stats.file_hits > edit_hits,
    "unchanged imported files should still be reused after one buffer changes"
)
assert(
    stats.collect_misses > edit_collect_misses,
    "changed loaded buffer should rebuild aggregate results"
)

vim.cmd("TypstLabels")
local command_qf = vim.fn.getqflist({ title = 1, items = 1 })
assert(
    command_qf.title:match("typst.nvim labels"),
    "TypstLabels command should populate quickfix"
)

local uv = vim.uv or vim.loop
local symlink_dir = typst_test_cache_path("index-loaded-symlink-")
    .. tostring(uv.hrtime())
vim.fn.mkdir(symlink_dir, "p")
local symlink_main = symlink_dir .. "/main.typ"
local canonical_lib = symlink_dir .. "/lib.typ"
local linked_lib = symlink_dir .. "/lib-link.typ"
vim.fn.writefile({ '#include "lib.typ"' }, symlink_main)
vim.fn.writefile({ "= Disk <sec:disk>" }, canonical_lib)
if uv.fs_symlink(canonical_lib, linked_lib) then
    vim.cmd.edit(vim.fn.fnameescape(symlink_main))
    vim.bo.filetype = "typst"
    local symlink_project =
        assert(typst.project.attach(0), "symlink index fixture should attach")
    local linked_bufnr = vim.api.nvim_create_buf(false, false)
    vim.api.nvim_buf_set_name(linked_bufnr, linked_lib)
    vim.bo[linked_bufnr].filetype = "typst"
    vim.api.nvim_buf_set_lines(
        linked_bufnr,
        0,
        -1,
        false,
        { "= Live <sec:live>" }
    )

    local symlink_collected = typst.index.collect({ project = symlink_project })
    assert(
        has_label(symlink_collected.labels, "sec:live"),
        "project index should scan loaded equivalent-path buffers for imported files"
    )
    assert(
        not has_label(symlink_collected.labels, "sec:disk"),
        "loaded equivalent-path buffers should take precedence over stale imported file contents"
    )
end

local main_sort_dir = typst_test_cache_path("index-main-sort-symlink-")
    .. tostring(uv.hrtime())
vim.fn.mkdir(main_sort_dir, "p")
local canonical_main = main_sort_dir .. "/main.typ"
local linked_main = main_sort_dir .. "/main-link.typ"
local earlier_import = main_sort_dir .. "/aaa.typ"
vim.fn.writefile(
    { '#include "aaa.typ"', "= Main <sec:main-sort>" },
    canonical_main
)
vim.fn.writefile({ "= Included <sec:included-sort>" }, earlier_import)
if uv.fs_symlink(canonical_main, linked_main) then
    local sort_project = {
        root = main_sort_dir,
        main = linked_main,
        bufs = {},
        files = {},
        dependencies = {},
    }
    local sort_headings =
        typst.index.collect({ project = sort_project }).headings
    assert(
        sort_headings[1] and sort_headings[1].title == "Main",
        "project index should prioritize headings from an equivalent main path"
    )
end

typst.providers.register("index", "phase2-index-spec", {
    collect = function(target_project)
        return {
            items = {
                {
                    kind = "label",
                    name = "provider:label",
                    source = {
                        path = target_project.main,
                        lnum = 1,
                        col = 1,
                    },
                },
                {
                    category = "definitions",
                    kind = "function",
                    name = "provider-card",
                    signature = "provider-card(body)",
                    parameters = {
                        {
                            name = "body",
                        },
                    },
                    source = {
                        path = target_project.main,
                        lnum = 1,
                        col = 1,
                    },
                },
            },
        }
    end,
})
typst.index.mark_dirty(project, "index provider registered")
local provider_collected = typst.index.collect({ project = project })
assert(
    has_label(provider_collected.labels, "provider:label"),
    "index providers should contribute labels"
)
assert(
    has_label(provider_collected.definitions, "provider-card"),
    "index providers should contribute definitions"
)
typst.providers.unregister("index", "phase2-index-spec")
typst.index.mark_dirty(project, "index provider unregistered")

typst.providers.register("index", "provider-merge-a", {
    collect = function(target_project)
        return {
            labels = {
                {
                    name = "provider:merge-a",
                    source = {
                        path = target_project.main,
                        lnum = 1,
                        col = 1,
                    },
                },
            },
        }
    end,
})
typst.providers.register("index", "provider-merge-b", {
    collect = function(target_project)
        return {
            labels = {
                {
                    name = "provider:merge-b",
                    source = {
                        path = target_project.main,
                        lnum = 2,
                        col = 1,
                    },
                },
            },
            definitions = {
                {
                    kind = "function",
                    name = "provider-merge-fn",
                    source = {
                        path = target_project.main,
                        lnum = 2,
                        col = 1,
                    },
                },
            },
        }
    end,
})
typst.index.mark_dirty(project, "index provider merge registered")
local provider_merge_collected = typst.index.collect({ project = project })
assert(
    has_label(provider_merge_collected.labels, "provider:merge-a"),
    "first provider category labels should survive later providers"
)
assert(
    has_label(provider_merge_collected.labels, "provider:merge-b"),
    "second provider category labels should be merged"
)
assert(
    has_label(provider_merge_collected.definitions, "provider-merge-fn"),
    "provider category definitions should be merged"
)
typst.providers.unregister("index", "provider-merge-a")
typst.providers.unregister("index", "provider-merge-b")
typst.index.mark_dirty(project, "index provider merge unregistered")

local disk_signature_dir = typst_test_cache_path("index-disk-signature-")
    .. tostring(uv.hrtime())
vim.fn.mkdir(disk_signature_dir, "p")
local disk_main = disk_signature_dir .. "/main.typ"
local disk_lib = disk_signature_dir .. "/lib.typ"
vim.fn.writefile({ '#include "lib.typ"' }, disk_main)
vim.fn.writefile({ "= Old <sec:disk-old>" }, disk_lib)
vim.cmd.edit(vim.fn.fnameescape(disk_main))
vim.bo.filetype = "typst"
local disk_project = assert(
    typst.project.set_main(disk_main),
    "disk-signature fixture should attach"
)
local live_disk_project =
    assert(require("typst.project.store").get(disk_project.key))
local disk_collected = typst.index.collect({ project = disk_project })
assert(
    has_label(disk_collected.labels, "sec:disk-old"),
    "disk-signature fixture should index imported labels"
)
assert(
    vim.fn.bufloaded(disk_lib) == 0,
    "disk-signature imported file should remain unloaded"
)

local disk_index = project_services.index(live_disk_project)
local disk_collect_misses = disk_index.stats.collect_misses
vim.fn.writefile({ "= New changed content <sec:disk-new>" }, disk_lib)
local disk_updated = typst.index.collect({ project = disk_project })
assert(
    has_label(disk_updated.labels, "sec:disk-new"),
    "external edits to unloaded imported files should invalidate the aggregate index"
)
assert(
    disk_index.stats.collect_misses > disk_collect_misses,
    "external edits to unloaded imported files should rebuild the aggregate cache"
)

local function has_heading(items, title)
    for _, item in ipairs(items or {}) do
        if item.title == title then
            return true
        end
    end
    return false
end

local large_dir = typst_test_cache_path("index-large-file-policy")
vim.fn.delete(large_dir, "rf")
vim.fn.mkdir(large_dir, "p")
local large_main = large_dir .. "/main.typ"
local large_file = large_dir .. "/large.typ"
local large_nested = large_dir .. "/nested.typ"
vim.fn.writefile({ '#include "large.typ"', "= Large Main" }, large_main)
vim.fn.writefile({ "= Nested Large Import" }, large_nested)
vim.fn.writefile({
    "= Large Included",
    "<large-label>",
    '#include "nested.typ"',
    string.rep("x", 1024),
}, large_file)

typst.reset()
typst.setup({
    root = large_dir,
    output_dir = typst_test_cache_path("index-large-file-skip-output"),
    project = {
        index = {
            max_file_bytes = 128,
            large_file_policy = "skip",
        },
    },
})
vim.cmd.edit(large_main)
local large_project = typst.project.set_main(large_main)
local large_skipped = typst.index.collect({ project = large_project })
assert(
    not has_heading(large_skipped.headings, "Large Included"),
    "skip large-file policy should omit headings from oversized unloaded files"
)
typst.setup({
    root = large_dir,
    output_dir = typst_test_cache_path("index-large-file-reconfigure-output"),
    project = {
        index = {
            max_file_bytes = 128,
            large_file_policy = "headings-only",
        },
    },
})
local large_reconfigured = typst.index.collect({ project = large_project })
assert(
    has_heading(large_reconfigured.headings, "Large Included"),
    "changing large-file policy should invalidate cached skipped records"
)
assert(
    not has_label(large_reconfigured.labels, "large-label"),
    "reconfigured headings-only policy should not reuse a full scan or stale label record"
)

typst.reset()
typst.setup({
    root = large_dir,
    output_dir = typst_test_cache_path("index-large-file-headings-output"),
    project = {
        index = {
            max_file_bytes = 128,
            large_file_policy = "headings-only",
        },
    },
})
vim.cmd.edit(large_main)
large_project = typst.project.set_main(large_main)
local large_headings = typst.index.collect({ project = large_project })
assert(
    has_heading(large_headings.headings, "Large Included"),
    "headings-only large-file policy should keep oversized file headings"
)
assert(
    has_heading(large_headings.headings, "Nested Large Import"),
    "headings-only large-file policy should still follow local includes"
)
assert(
    not has_label(large_headings.labels, "large-label"),
    "headings-only large-file policy should skip non-heading label scans"
)

typst.reset()
typst.setup({
    root = large_dir,
    output_dir = typst_test_cache_path("index-large-file-scan-output"),
    project = {
        index = {
            max_file_bytes = 128,
            large_file_policy = "scan",
        },
    },
})
vim.cmd.edit(large_main)
large_project = typst.project.set_main(large_main)
local large_scanned = typst.index.collect({ project = large_project })
assert(
    has_heading(large_scanned.headings, "Large Included"),
    "scan large-file policy should keep oversized file headings"
)
assert(
    has_label(large_scanned.labels, "large-label"),
    "scan large-file policy should keep full label scans for oversized files"
)

typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("index-watch-cap-output"),
    project = {
        index = {
            fs_watchers = 4,
        },
    },
})

local index_cache = require("typst.project.index_cache")
local cap_dir = typst_test_cache_path("index-watch-cap")
vim.fn.mkdir(cap_dir, "p")

local cap_paths = {}
for index = 1, 8 do
    local path = ("%s/file-%02d.typ"):format(cap_dir, index)
    vim.fn.writefile({ ("= File %d"):format(index) }, path)
    cap_paths[path] = path
end

local cap_project = {
    root = cap_dir,
    main = cap_dir .. "/file-01.typ",
    bufs = {},
    files = {},
    dependencies = {},
}
local cap_state = index_cache.ensure(cap_project)
index_cache.sync_file_watchers(cap_state, cap_paths)

assert(
    cap_state.fs_watch_mode == "polling",
    "index fs watchers should fall back to polling when cap is exceeded"
)
assert(
    cap_state.fs_watch_disabled_reason == "cap_exceeded",
    "index fs watcher fallback should record the cap reason"
)
assert(
    cap_state.fs_watch_wanted_count == 8,
    "wanted watcher count should be kept"
)
assert(cap_state.fs_watch_active_count == 0, "no watchers should remain active")
assert(cap_state.fs_watch_cap == 4, "configured watcher cap should be reported")
assert(
    next(cap_state.fs_watchers or {}) == nil,
    "watcher cap fallback should close/avoid watcher records"
)

local cap_logged = false
for _, entry in ipairs(typst.ui.log()) do
    if entry.message == "index fs watchers disabled; using disk polling" then
        cap_logged = true
        break
    end
end
assert(cap_logged, "watcher cap fallback should be logged")

vim.cmd("qa!")
