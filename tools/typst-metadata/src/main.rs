use serde_json::{Map as JsonMap, Number as JsonNumber, Value as JsonValue};
use std::cmp::Ordering;
use std::collections::{BTreeMap, BTreeSet};
use std::env;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use typst::foundations::{
    Binding, CastInfo, Func, ParamInfo, Repr, Scope, Symbol, Value as TypstValue,
};
use typst::{Library, LibraryExt};
use typst_syntax::ast;

const MANIFEST_SCHEMA: u64 = 2;
const SYMBOL_SCHEMA: u64 = 1;
const SHORTHAND_SCHEMA: u64 = 1;
const STDLIB_INDEX_SCHEMA: u64 = 1;
const SIGNATURE_SCHEMA: u64 = 2;
const SIGNATURE_DOCS_SCHEMA: u64 = 1;
const GENERATOR_VERSION: u64 = 4;
const MAX_SCOPE_DEPTH: usize = 4;

const KIND_ELEMENT: u64 = 1;
const KIND_FUNCTION: u64 = 2;
const KIND_TYPE: u64 = 3;
const KIND_MODULE: u64 = 4;
const KIND_CONSTANT: u64 = 5;
const KIND_SYMBOL: u64 = 6;

const CONTEXT_GLOBAL: u64 = 1;
const CONTEXT_MATH: u64 = 2;

const FLAG_CONTEXTUAL: u64 = 1;
const FLAG_DEPRECATED: u64 = 2;
const FLAG_HAS_CONSTRUCTOR: u64 = 4;

const PARAM_POSITIONAL: u64 = 1;
const PARAM_NAMED: u64 = 2;
const PARAM_REQUIRED: u64 = 4;
const PARAM_VARIADIC: u64 = 8;
const PARAM_SETTABLE: u64 = 16;

#[derive(Debug, Clone)]
struct SymbolEntry {
    name: String,
    glyph: String,
    deprecated: Option<String>,
}

#[derive(Debug, Clone)]
struct Deprecation {
    message: String,
    until: Option<String>,
}

#[derive(Debug, Clone)]
struct ItemIr {
    path: String,
    name: String,
    kind: u64,
    category: Option<String>,
    contexts: u64,
    flags: u64,
    signature_id: Option<u64>,
    constructor_signature_id: Option<u64>,
    type_name: Option<String>,
    repr: Option<String>,
    title: Option<String>,
    deprecated: Option<Deprecation>,
    keywords: Vec<String>,
    param_docs: Vec<(String, String)>,
}

#[derive(Debug, Clone)]
struct ParamIr {
    name: Option<String>,
    flags: u64,
    input_id: Option<u64>,
    default_id: Option<u64>,
}

#[derive(Debug, Clone)]
struct SignatureIr {
    returns_id: Option<u64>,
    params: Vec<ParamIr>,
}

#[derive(Debug, Default)]
struct StringPool {
    ids: BTreeMap<String, u64>,
    values: Vec<String>,
}

impl StringPool {
    fn intern(&mut self, value: &str) -> u64 {
        if value.is_empty() {
            return 0;
        }

        if let Some(id) = self.ids.get(value) {
            return *id;
        }

        let id = self.values.len() as u64 + 1;
        self.values.push(value.to_string());
        self.ids.insert(value.to_string(), id);
        id
    }

    fn intern_opt(&mut self, value: Option<&str>) -> u64 {
        value.map_or(0, |value| self.intern(value))
    }

    fn values_json(&self) -> JsonValue {
        JsonValue::Array(self.values.iter().map(|value| json_string(value)).collect())
    }
}

#[derive(Debug, Default)]
struct JsonInterner {
    ids: BTreeMap<String, u64>,
    values: Vec<JsonValue>,
}

impl JsonInterner {
    fn intern(&mut self, value: JsonValue) -> u64 {
        let key = serde_json::to_string(&value).expect("compact metadata value should serialize");
        if let Some(id) = self.ids.get(&key) {
            return *id;
        }

        let id = self.values.len() as u64 + 1;
        self.values.push(value);
        self.ids.insert(key, id);
        id
    }

    fn values_json(&self) -> JsonValue {
        JsonValue::Array(self.values.clone())
    }
}

#[derive(Debug, Default)]
struct SignatureStore {
    strings: StringPool,
    inputs: JsonInterner,
    defaults: JsonInterner,
    signatures: Vec<SignatureIr>,
    signature_ids: BTreeMap<String, u64>,
}

impl SignatureStore {
    fn intern_signature(&mut self, func: &Func) -> u64 {
        let func_params = func_params(func);
        let params = func_params
            .iter()
            .map(|param| self.param_ir(param))
            .collect();
        let returns_id = func.returns().map(|returns| self.intern_cast(returns));
        self.intern_signature_ir(SignatureIr { returns_id, params })
    }

    fn intern_signature_ir(&mut self, signature: SignatureIr) -> u64 {
        let value = self.signature_json(&signature);
        let key = serde_json::to_string(&value).expect("signature should serialize");
        if let Some(id) = self.signature_ids.get(&key) {
            return *id;
        }

        let id = self.signatures.len() as u64 + 1;
        self.signatures.push(signature);
        self.signature_ids.insert(key, id);
        id
    }

    fn param_ir(&mut self, param: &ParamInfo) -> ParamIr {
        let mut flags = 0;
        if param_positional(param) {
            flags |= PARAM_POSITIONAL;
        }
        if param_named(param) {
            flags |= PARAM_NAMED;
        }
        if param_required(param) {
            flags |= PARAM_REQUIRED;
        }
        if param_variadic(param) {
            flags |= PARAM_VARIADIC;
        }
        if param_settable(param) {
            flags |= PARAM_SETTABLE;
        }

        let default_id = param_default(param).map(|default| self.intern_default(&default));
        let input_id = param_input(param).map(|input| self.intern_cast(input));

        ParamIr {
            name: param_name(param).map(ToString::to_string),
            flags,
            input_id,
            default_id,
        }
    }

    fn intern_default(&mut self, value: &TypstValue) -> u64 {
        let repr_id = self.strings.intern(&value.repr());
        let type_id = self.strings.intern(value.ty().short_name());
        self.defaults
            .intern(json_array([json_number(repr_id), json_number(type_id)]))
    }

    fn intern_cast(&mut self, info: &CastInfo) -> u64 {
        let value = match info {
            CastInfo::Any => json_array([json_number(1)]),
            CastInfo::Value(value, docs) => {
                let repr_id = self.strings.intern(&value.repr());
                let type_id = self.strings.intern(value.ty().short_name());
                let docs_string_id = self.strings.intern(docs);
                json_array([
                    json_number(2),
                    json_number(repr_id),
                    json_number(type_id),
                    json_number(docs_string_id),
                ])
            }
            CastInfo::Type(ty) => json_array([
                json_number(3),
                json_number(self.strings.intern(ty.short_name())),
                json_number(self.strings.intern(ty.long_name())),
                json_number(self.strings.intern(ty.title())),
            ]),
            CastInfo::Union(values) => {
                let child_ids = values
                    .iter()
                    .map(|value| json_number(self.intern_cast(value)))
                    .collect::<Vec<_>>();
                json_array([json_number(4), JsonValue::Array(child_ids)])
            }
        };

        self.inputs.intern(value)
    }

    fn signature_json(&mut self, signature: &SignatureIr) -> JsonValue {
        json_array([
            json_number(signature.returns_id.unwrap_or(0)),
            JsonValue::Array(
                signature
                    .params
                    .iter()
                    .map(|param| {
                        json_array([
                            json_number(self.strings.intern_opt(param.name.as_deref())),
                            json_number(param.flags),
                            json_number(param.input_id.unwrap_or(0)),
                            json_number(param.default_id.unwrap_or(0)),
                        ])
                    })
                    .collect(),
            ),
        ])
    }

    fn payload(&mut self, typst_version: &str) -> JsonValue {
        let signatures = self
            .signatures
            .clone()
            .iter()
            .map(|signature| self.signature_json(signature))
            .collect::<Vec<_>>();

        json_array([
            json_number(SIGNATURE_SCHEMA),
            json_string(typst_version),
            self.strings.values_json(),
            self.inputs.values_json(),
            self.defaults.values_json(),
            JsonValue::Array(signatures),
        ])
    }
}

#[derive(Debug, Default)]
struct StdlibCollector {
    items: BTreeMap<String, ItemIr>,
    signatures: SignatureStore,
}

impl StdlibCollector {
    fn collect(lib: &Library) -> Self {
        let mut collector = Self::default();
        collector.collect_context(lib.global.scope(), CONTEXT_GLOBAL);
        collector.collect_context(lib.math.scope(), CONTEXT_MATH);
        collector
    }

    fn collect_context(&mut self, scope: &Scope, context: u64) {
        for (name, binding) in scope.iter() {
            let path = name.to_string();
            self.visit_binding(name, &path, binding, context, 0);
        }
    }

    fn visit_binding(
        &mut self,
        name: &str,
        path: &str,
        binding: &Binding,
        context: u64,
        depth: usize,
    ) {
        let value = binding.read();
        let item = self.item_ir(name, path, binding, value, context);
        self.merge_item(item);

        if depth >= MAX_SCOPE_DEPTH {
            return;
        }

        if let Some(scope) = value.scope() {
            for (member_name, member_binding) in scope.iter() {
                let member_path = format!("{path}.{member_name}");
                self.visit_binding(
                    member_name,
                    &member_path,
                    member_binding,
                    context,
                    depth + 1,
                );
            }
        }
    }

    fn item_ir(
        &mut self,
        name: &str,
        path: &str,
        binding: &Binding,
        value: &TypstValue,
        context: u64,
    ) -> ItemIr {
        let kind = value_kind(value);
        let mut flags = 0;
        let mut signature_id = None;
        let mut constructor_signature_id = None;
        let mut type_name = None;
        let mut repr = None;
        let mut title = None;
        let mut keywords = Vec::new();
        let mut param_docs = Vec::new();

        match value {
            TypstValue::Func(func) => {
                signature_id = Some(self.signatures.intern_signature(func));
                let func_params = func_params(func);
                param_docs = func_params
                    .iter()
                    .filter_map(param_doc)
                    .map(|(name, docs)| (name.to_string(), docs.to_string()))
                    .filter(|(_, docs)| !docs.is_empty())
                    .collect();
                if func.contextual() == Some(true) {
                    flags |= FLAG_CONTEXTUAL;
                }
                title = func.title().map(ToString::to_string);
                keywords = func.keywords().iter().map(ToString::to_string).collect();
            }
            TypstValue::Type(ty) => {
                type_name = Some(ty.short_name().to_string());
                title = Some(ty.title().to_string());
                keywords = ty.keywords().iter().map(ToString::to_string).collect();
                if let Ok(constructor) = ty.constructor() {
                    flags |= FLAG_HAS_CONSTRUCTOR;
                    constructor_signature_id = Some(self.signatures.intern_signature(&constructor));
                }
            }
            TypstValue::Symbol(symbol) => {
                repr = Some(symbol.get().to_string());
                type_name = Some(value.ty().short_name().to_string());
            }
            _ => {
                repr = Some(value.repr().to_string());
                type_name = Some(value.ty().short_name().to_string());
            }
        }

        let deprecated = binding.deprecation().map(|deprecation| Deprecation {
            message: deprecation.message().to_string(),
            until: deprecation.until().map(ToString::to_string),
        });
        if deprecated.is_some() {
            flags |= FLAG_DEPRECATED;
        }

        ItemIr {
            path: path.to_string(),
            name: name.to_string(),
            kind,
            category: binding
                .category()
                .map(|category| category.name().to_string()),
            contexts: context,
            flags,
            signature_id,
            constructor_signature_id,
            type_name,
            repr,
            title,
            deprecated,
            keywords,
            param_docs,
        }
    }

    fn merge_item(&mut self, item: ItemIr) {
        let Some(existing) = self.items.get_mut(&item.path) else {
            self.items.insert(item.path.clone(), item);
            return;
        };

        existing.contexts |= item.contexts;
        existing.flags |= item.flags;
        if existing.category.is_none() {
            existing.category = item.category;
        }
        if existing.signature_id.is_none() {
            existing.signature_id = item.signature_id;
        }
        if existing.constructor_signature_id.is_none() {
            existing.constructor_signature_id = item.constructor_signature_id;
        }
        if existing.type_name.is_none() {
            existing.type_name = item.type_name;
        }
        if existing.repr.is_none() {
            existing.repr = item.repr;
        }
        if existing.title.is_none() {
            existing.title = item.title;
        }
        if existing.deprecated.is_none() {
            existing.deprecated = item.deprecated;
        }

        let mut keywords = existing.keywords.iter().cloned().collect::<BTreeSet<_>>();
        keywords.extend(item.keywords);
        existing.keywords = keywords.into_iter().collect();
        if existing.param_docs.is_empty() {
            existing.param_docs = item.param_docs;
        }
    }

    fn stdlib_payload(&self, typst_version: &str) -> JsonValue {
        let mut strings = StringPool::default();
        let items = self
            .items
            .values()
            .map(|item| item_json(item, &mut strings))
            .collect::<Vec<_>>();

        json_array([
            json_number(STDLIB_INDEX_SCHEMA),
            json_string(typst_version),
            strings.values_json(),
            JsonValue::Array(items),
        ])
    }

    fn signature_docs_payload(&self, typst_version: &str) -> JsonValue {
        let mut strings = StringPool::default();
        let rows = self
            .items
            .values()
            .filter(|item| !item.param_docs.is_empty())
            .map(|item| {
                json_array([
                    json_number(strings.intern(&item.path)),
                    JsonValue::Array(
                        item.param_docs
                            .iter()
                            .map(|(name, docs)| {
                                json_array([
                                    json_number(strings.intern(name)),
                                    json_number(strings.intern(docs)),
                                ])
                            })
                            .collect(),
                    ),
                ])
            })
            .collect::<Vec<_>>();

        json_array([
            json_number(SIGNATURE_DOCS_SCHEMA),
            json_string(typst_version),
            strings.values_json(),
            JsonValue::Array(rows),
        ])
    }
}

fn main() -> io::Result<()> {
    let repo_root = repo_root()?;
    let typst_version = typst_dependency_version(&repo_root)?;
    let out_dir = repo_root
        .join("data")
        .join("typst")
        .join("metadata")
        .join(&typst_version);
    let versions_path = repo_root
        .join("data")
        .join("typst")
        .join("metadata")
        .join("versions.json");

    let lib = Library::default();
    let symbols = collect_symbols(&lib);
    let emojis = collect_emojis(&lib);
    let shorthands = collect_shorthands();
    let mut stdlib = StdlibCollector::collect(&lib);

    fs::create_dir_all(&out_dir)?;

    let artifacts = vec![
        write_artifact(
            &out_dir,
            "symbols",
            "symbols.mpack",
            SYMBOL_SCHEMA,
            symbols.len(),
            symbol_payload(&symbols, &typst_version),
        )?,
        write_artifact(
            &out_dir,
            "emojis",
            "emojis.mpack",
            SYMBOL_SCHEMA,
            emojis.len(),
            symbol_payload(&emojis, &typst_version),
        )?,
        write_artifact(
            &out_dir,
            "shorthands",
            "shorthands.mpack",
            SHORTHAND_SCHEMA,
            shorthand_count(&shorthands),
            shorthand_payload(&shorthands, &typst_version),
        )?,
        write_artifact(
            &out_dir,
            "stdlib_index",
            "stdlib-index.mpack",
            STDLIB_INDEX_SCHEMA,
            stdlib.items.len(),
            stdlib.stdlib_payload(&typst_version),
        )?,
        write_artifact(
            &out_dir,
            "signatures",
            "signatures.mpack",
            SIGNATURE_SCHEMA,
            stdlib.signatures.signatures.len(),
            stdlib.signatures.payload(&typst_version),
        )?,
        write_artifact(
            &out_dir,
            "signature_docs",
            "signature-docs.mpack",
            SIGNATURE_DOCS_SCHEMA,
            stdlib
                .items
                .values()
                .filter(|item| !item.param_docs.is_empty())
                .count(),
            stdlib.signature_docs_payload(&typst_version),
        )?,
    ];

    write_manifest(&out_dir.join("manifest.json"), &artifacts, &typst_version)?;
    write_versions(&versions_path, &typst_version)?;
    remove_legacy_lua_artifacts(&repo_root, &typst_version)?;
    print_size_report(&artifacts);

    Ok(())
}

fn typst_dependency_version(repo_root: &Path) -> io::Result<String> {
    if let Ok(version) = env::var("TYPST_METADATA_VERSION") {
        let version = version.trim();
        if !version.is_empty() {
            return Ok(version.to_string());
        }
    }

    let lock_path = repo_root
        .join("tools")
        .join("typst-metadata")
        .join("Cargo.lock");
    let lock = fs::read_to_string(lock_path)?;
    let mut in_typst_package = false;

    for line in lock.lines() {
        let trimmed = line.trim();
        if trimmed == "[[package]]" {
            in_typst_package = false;
        } else if trimmed == "name = \"typst\"" {
            in_typst_package = true;
        } else if in_typst_package
            && let Some(version) = trimmed
                .strip_prefix("version = \"")
                .and_then(|value| value.strip_suffix('"'))
        {
            return Ok(version.to_string());
        }
    }

    Err(io::Error::new(
        io::ErrorKind::InvalidData,
        "could not determine typst dependency version from Cargo.lock",
    ))
}

fn repo_root() -> io::Result<PathBuf> {
    let mut dir = env::current_dir()?;
    loop {
        if dir.join(".git").exists() || dir.join("lua").join("typst").exists() {
            return Ok(dir);
        }

        if !dir.pop() {
            return env::current_dir();
        }
    }
}

fn collect_symbols(lib: &Library) -> Vec<SymbolEntry> {
    let mut symbols = BTreeMap::new();
    extract_named_module(lib.global.scope(), "sym", &mut symbols);
    extract_named_module(lib.global.scope(), "math", &mut symbols);
    symbols.into_values().collect()
}

fn collect_emojis(lib: &Library) -> Vec<SymbolEntry> {
    let mut emojis = BTreeMap::new();
    extract_named_module(lib.global.scope(), "emoji", &mut emojis);
    emojis.into_values().collect()
}

#[cfg(feature = "typst_0_14")]
fn func_params(func: &Func) -> Vec<ParamInfo> {
    func.params()
        .map(|params| params.to_vec())
        .unwrap_or_default()
}

#[cfg(not(feature = "typst_0_14"))]
fn func_params(func: &Func) -> Vec<ParamInfo> {
    func.params().collect()
}

#[cfg(feature = "typst_0_14")]
fn func_is_element(func: &Func) -> bool {
    func.element().is_some()
}

#[cfg(not(feature = "typst_0_14"))]
fn func_is_element(func: &Func) -> bool {
    func.to_element().is_some()
}

#[cfg(feature = "typst_0_14")]
fn param_name(param: &ParamInfo) -> Option<&str> {
    Some(param.name)
}

#[cfg(not(feature = "typst_0_14"))]
fn param_name(param: &ParamInfo) -> Option<&str> {
    param.name()
}

#[cfg(feature = "typst_0_14")]
fn param_input(param: &ParamInfo) -> Option<&CastInfo> {
    Some(&param.input)
}

#[cfg(not(feature = "typst_0_14"))]
fn param_input(param: &ParamInfo) -> Option<&CastInfo> {
    param.to_native().map(|native| &native.input)
}

#[cfg(feature = "typst_0_14")]
fn param_default(param: &ParamInfo) -> Option<TypstValue> {
    param.default.map(|default| default())
}

#[cfg(not(feature = "typst_0_14"))]
fn param_default(param: &ParamInfo) -> Option<TypstValue> {
    param.default()
}

#[cfg(feature = "typst_0_14")]
fn param_positional(param: &ParamInfo) -> bool {
    param.positional
}

#[cfg(not(feature = "typst_0_14"))]
fn param_positional(param: &ParamInfo) -> bool {
    param.positional()
}

#[cfg(feature = "typst_0_14")]
fn param_named(param: &ParamInfo) -> bool {
    param.named
}

#[cfg(not(feature = "typst_0_14"))]
fn param_named(param: &ParamInfo) -> bool {
    param.named()
}

#[cfg(feature = "typst_0_14")]
fn param_required(param: &ParamInfo) -> bool {
    param.required
}

#[cfg(not(feature = "typst_0_14"))]
fn param_required(param: &ParamInfo) -> bool {
    param.required()
}

#[cfg(feature = "typst_0_14")]
fn param_variadic(param: &ParamInfo) -> bool {
    param.variadic
}

#[cfg(not(feature = "typst_0_14"))]
fn param_variadic(param: &ParamInfo) -> bool {
    param.variadic()
}

#[cfg(feature = "typst_0_14")]
fn param_settable(param: &ParamInfo) -> bool {
    param.settable
}

#[cfg(not(feature = "typst_0_14"))]
fn param_settable(param: &ParamInfo) -> bool {
    param.settable()
}

#[cfg(feature = "typst_0_14")]
fn param_doc(param: &ParamInfo) -> Option<(&str, &str)> {
    Some((param.name, param.docs))
}

#[cfg(not(feature = "typst_0_14"))]
fn param_doc(param: &ParamInfo) -> Option<(&str, &str)> {
    param.to_native().map(|native| (native.name, native.docs))
}

fn extract_named_module(
    scope: &Scope,
    module_name: &str,
    symbols: &mut BTreeMap<String, SymbolEntry>,
) {
    for (name, binding) in scope.iter() {
        if name != module_name {
            continue;
        }

        if let TypstValue::Module(module) = binding.read() {
            extract_symbols_from_scope(module.scope(), symbols);
        }
        return;
    }
}

fn extract_symbols_from_scope(scope: &Scope, symbols: &mut BTreeMap<String, SymbolEntry>) {
    for (name, binding) in scope.iter() {
        if let TypstValue::Symbol(symbol) = binding.read() {
            insert_symbol(name, symbol, symbols);
        }
    }
}

fn insert_symbol(root_name: &str, symbol: &Symbol, symbols: &mut BTreeMap<String, SymbolEntry>) {
    insert_symbol_entry(
        symbols,
        root_name.to_string(),
        symbol.get().to_string(),
        None,
    );

    for (modifiers, glyph, deprecated) in symbol.variants() {
        let modifiers = modifiers
            .into_iter()
            .map(ToString::to_string)
            .collect::<Vec<_>>();
        let canonical = if modifiers.is_empty() {
            root_name.to_string()
        } else {
            format!("{}.{}", root_name, modifiers.join("."))
        };
        insert_symbol_entry(
            symbols,
            canonical,
            glyph.to_string(),
            deprecated.map(ToString::to_string),
        );
    }
}

fn insert_symbol_entry(
    symbols: &mut BTreeMap<String, SymbolEntry>,
    name: String,
    glyph: String,
    deprecated: Option<String>,
) {
    symbols
        .entry(name.clone())
        .and_modify(|entry| {
            if entry.deprecated.is_none() {
                entry.deprecated = deprecated.clone();
            }
        })
        .or_insert(SymbolEntry {
            name,
            glyph,
            deprecated,
        });
}

fn collect_shorthands() -> Vec<(&'static str, Vec<(&'static str, char)>)> {
    vec![
        ("markup", ast::Shorthand::LIST.to_vec()),
        ("math", ast::MathShorthand::LIST.to_vec()),
    ]
}

fn value_kind(value: &TypstValue) -> u64 {
    match value {
        TypstValue::Func(func) if func_is_element(func) => KIND_ELEMENT,
        TypstValue::Func(_) => KIND_FUNCTION,
        TypstValue::Type(_) => KIND_TYPE,
        TypstValue::Module(_) => KIND_MODULE,
        TypstValue::Symbol(_) => KIND_SYMBOL,
        _ => KIND_CONSTANT,
    }
}

fn item_json(item: &ItemIr, strings: &mut StringPool) -> JsonValue {
    let keyword_ids = item
        .keywords
        .iter()
        .map(|keyword| json_number(strings.intern(keyword)))
        .collect::<Vec<_>>();
    let deprecated_message_id = item
        .deprecated
        .as_ref()
        .map_or(0, |deprecated| strings.intern(&deprecated.message));
    let deprecated_until_id = item
        .deprecated
        .as_ref()
        .and_then(|deprecated| deprecated.until.as_deref())
        .map_or(0, |until| strings.intern(until));

    json_array([
        json_number(strings.intern(&item.path)),
        json_number(strings.intern(&item.name)),
        json_number(item.kind),
        json_number(strings.intern_opt(item.category.as_deref())),
        json_number(item.contexts),
        json_number(item.flags),
        json_number(item.signature_id.unwrap_or(0)),
        json_number(item.constructor_signature_id.unwrap_or(0)),
        json_number(strings.intern_opt(item.type_name.as_deref())),
        json_number(strings.intern_opt(item.repr.as_deref())),
        json_number(strings.intern_opt(item.title.as_deref())),
        json_number(deprecated_message_id),
        json_number(deprecated_until_id),
        JsonValue::Array(keyword_ids),
    ])
}

fn symbol_payload(entries: &[SymbolEntry], typst_version: &str) -> JsonValue {
    let names = entries
        .iter()
        .map(|entry| json_string(&entry.name))
        .collect::<Vec<_>>();
    let glyphs = entries
        .iter()
        .map(|entry| json_string(&entry.glyph))
        .collect::<Vec<_>>();
    let mut deprecated_names = Vec::new();
    let mut deprecated_messages = Vec::new();
    for entry in entries {
        if let Some(deprecated) = &entry.deprecated {
            deprecated_names.push(json_string(&entry.name));
            deprecated_messages.push(json_string(deprecated));
        }
    }

    json_array([
        json_number(SYMBOL_SCHEMA),
        json_string(typst_version),
        JsonValue::Array(names),
        JsonValue::Array(glyphs),
        JsonValue::Array(deprecated_names),
        JsonValue::Array(deprecated_messages),
    ])
}

fn shorthand_payload(
    shorthands: &[(&'static str, Vec<(&'static str, char)>)],
    typst_version: &str,
) -> JsonValue {
    let entries = shorthands
        .iter()
        .map(|(context, list)| {
            let list = list
                .iter()
                .map(|(source, glyph)| {
                    json_array([json_string(source), json_string(&glyph.to_string())])
                })
                .collect::<Vec<_>>();
            json_array([json_string(context), JsonValue::Array(list)])
        })
        .collect::<Vec<_>>();

    json_array([
        json_number(SHORTHAND_SCHEMA),
        json_string(typst_version),
        JsonValue::Array(entries),
    ])
}

fn shorthand_count(shorthands: &[(&'static str, Vec<(&'static str, char)>)]) -> usize {
    shorthands.iter().map(|(_, entries)| entries.len()).sum()
}

#[derive(Debug, Clone)]
struct ArtifactInfo {
    name: String,
    file: String,
    schema: u64,
    count: usize,
    bytes: u64,
}

fn write_artifact(
    out_dir: &Path,
    name: &str,
    file: &str,
    schema: u64,
    count: usize,
    value: JsonValue,
) -> io::Result<ArtifactInfo> {
    let mut encoded = Vec::new();
    encode_mpack(&value, &mut encoded)?;
    let path = out_dir.join(file);
    fs::write(&path, &encoded)?;
    Ok(ArtifactInfo {
        name: name.to_string(),
        file: file.to_string(),
        schema,
        count,
        bytes: encoded.len() as u64,
    })
}

fn write_manifest(path: &Path, artifacts: &[ArtifactInfo], typst_version: &str) -> io::Result<()> {
    let mut artifact_map = JsonMap::new();
    for artifact in artifacts {
        let mut item = JsonMap::new();
        item.insert("file".into(), json_string(&artifact.file));
        item.insert("schema".into(), json_number(artifact.schema));
        item.insert("count".into(), json_number(artifact.count as u64));
        item.insert("bytes".into(), json_number(artifact.bytes));
        artifact_map.insert(artifact.name.clone(), JsonValue::Object(item));
    }

    let mut enums = JsonMap::new();
    enums.insert(
        "kind".into(),
        json_object([
            ("element", json_number(KIND_ELEMENT)),
            ("function", json_number(KIND_FUNCTION)),
            ("type", json_number(KIND_TYPE)),
            ("module", json_number(KIND_MODULE)),
            ("constant", json_number(KIND_CONSTANT)),
            ("symbol", json_number(KIND_SYMBOL)),
        ]),
    );
    enums.insert(
        "context".into(),
        json_object([
            ("global", json_number(CONTEXT_GLOBAL)),
            ("math", json_number(CONTEXT_MATH)),
        ]),
    );
    enums.insert(
        "item_flags".into(),
        json_object([
            ("contextual", json_number(FLAG_CONTEXTUAL)),
            ("deprecated", json_number(FLAG_DEPRECATED)),
            ("has_constructor", json_number(FLAG_HAS_CONSTRUCTOR)),
        ]),
    );
    enums.insert(
        "param_flags".into(),
        json_object([
            ("positional", json_number(PARAM_POSITIONAL)),
            ("named", json_number(PARAM_NAMED)),
            ("required", json_number(PARAM_REQUIRED)),
            ("variadic", json_number(PARAM_VARIADIC)),
            ("settable", json_number(PARAM_SETTABLE)),
        ]),
    );

    let mut root = JsonMap::new();
    root.insert("schema".into(), json_number(MANIFEST_SCHEMA));
    root.insert("typst_version".into(), json_string(typst_version));
    root.insert("generator_version".into(), json_number(GENERATOR_VERSION));
    root.insert("artifacts".into(), JsonValue::Object(artifact_map));
    root.insert("enums".into(), JsonValue::Object(enums));

    write_pretty_json(path, &JsonValue::Object(root))
}

fn write_versions(path: &Path, typst_version: &str) -> io::Result<()> {
    let mut versions = BTreeSet::new();
    if let Ok(contents) = fs::read_to_string(path)
        && let Ok(JsonValue::Object(existing)) = serde_json::from_str::<JsonValue>(&contents)
        && let Some(JsonValue::Array(raw_versions)) = existing.get("versions")
    {
        for version in raw_versions {
            if let JsonValue::String(version) = version {
                versions.insert(version.clone());
            }
        }
    }
    versions.insert(typst_version.to_string());

    let mut versions = versions.into_iter().collect::<Vec<_>>();
    versions.sort_by(|left, right| compare_versions(left, right));
    let latest = versions
        .last()
        .cloned()
        .unwrap_or_else(|| typst_version.to_string());

    let mut root = JsonMap::new();
    root.insert("schema".into(), json_number(1));
    root.insert("latest".into(), json_string(&latest));
    root.insert(
        "versions".into(),
        JsonValue::Array(
            versions
                .iter()
                .map(|version| json_string(version))
                .collect(),
        ),
    );
    write_pretty_json(path, &JsonValue::Object(root))
}

fn compare_versions(left: &str, right: &str) -> Ordering {
    let left_parts = version_parts(left);
    let right_parts = version_parts(right);
    for index in 0..left_parts.len().max(right_parts.len()) {
        let left_part = left_parts.get(index).copied().unwrap_or(0);
        let right_part = right_parts.get(index).copied().unwrap_or(0);
        match left_part.cmp(&right_part) {
            Ordering::Equal => {}
            ordering => return ordering,
        }
    }

    let left_prerelease = left.contains('-');
    let right_prerelease = right.contains('-');
    match (left_prerelease, right_prerelease) {
        (true, false) => Ordering::Less,
        (false, true) => Ordering::Greater,
        _ => left.cmp(right),
    }
}

fn version_parts(version: &str) -> Vec<u64> {
    version
        .split(['.', '-', '+'])
        .take_while(|part| part.chars().all(|ch| ch.is_ascii_digit()))
        .filter_map(|part| part.parse::<u64>().ok())
        .collect()
}

fn write_pretty_json(path: &Path, value: &JsonValue) -> io::Result<()> {
    let json = serde_json::to_string_pretty(value).expect("manifest should serialize");
    fs::write(path, format!("{json}\n"))
}

fn remove_legacy_lua_artifacts(repo_root: &Path, typst_version: &str) -> io::Result<()> {
    let legacy_dir = repo_root
        .join("lua")
        .join("typst")
        .join("metadata")
        .join("generated")
        .join(typst_version);
    for file in ["symbols.lua", "emojis.lua", "shorthands.lua", "stdlib.lua"] {
        let path = legacy_dir.join(file);
        match fs::remove_file(&path) {
            Ok(()) => {}
            Err(err) if err.kind() == io::ErrorKind::NotFound => {}
            Err(err) => return Err(err),
        }
    }

    match fs::remove_dir(&legacy_dir) {
        Ok(()) => {}
        Err(err)
            if err.kind() == io::ErrorKind::NotFound
                || err.kind() == io::ErrorKind::DirectoryNotEmpty => {}
        Err(err) => return Err(err),
    }

    Ok(())
}

fn print_size_report(artifacts: &[ArtifactInfo]) {
    let mut total = 0;
    for artifact in artifacts {
        total += artifact.bytes;
        eprintln!(
            "{:<20} {:>8} bytes ({:>5} entries)",
            artifact.file, artifact.bytes, artifact.count
        );
    }
    eprintln!("{:<20} {:>8} bytes", "core total", total);
}

fn encode_mpack(value: &JsonValue, out: &mut Vec<u8>) -> io::Result<()> {
    match value {
        JsonValue::Null => out.push(0xc0),
        JsonValue::Bool(false) => out.push(0xc2),
        JsonValue::Bool(true) => out.push(0xc3),
        JsonValue::Number(number) => encode_number(number, out)?,
        JsonValue::String(value) => encode_str(value, out),
        JsonValue::Array(values) => {
            encode_array_len(values.len(), out)?;
            for value in values {
                encode_mpack(value, out)?;
            }
        }
        JsonValue::Object(values) => {
            encode_map_len(values.len(), out)?;
            for (key, value) in values {
                encode_str(key, out);
                encode_mpack(value, out)?;
            }
        }
    }

    Ok(())
}

fn encode_number(number: &JsonNumber, out: &mut Vec<u8>) -> io::Result<()> {
    if let Some(value) = number.as_u64() {
        encode_u64(value, out);
    } else if let Some(value) = number.as_i64() {
        encode_i64(value, out);
    } else {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "floating point values are not supported in generated metadata",
        ));
    }
    Ok(())
}

fn encode_u64(value: u64, out: &mut Vec<u8>) {
    if value <= 0x7f {
        out.push(value as u8);
    } else if u8::try_from(value).is_ok() {
        out.push(0xcc);
        out.push(value as u8);
    } else if u16::try_from(value).is_ok() {
        out.push(0xcd);
        out.extend_from_slice(&(value as u16).to_be_bytes());
    } else if u32::try_from(value).is_ok() {
        out.push(0xce);
        out.extend_from_slice(&(value as u32).to_be_bytes());
    } else {
        out.push(0xcf);
        out.extend_from_slice(&value.to_be_bytes());
    }
}

fn encode_i64(value: i64, out: &mut Vec<u8>) {
    if value >= 0 {
        encode_u64(value as u64, out);
    } else if value >= -32 {
        out.push(value as i8 as u8);
    } else if value >= i8::MIN as i64 {
        out.push(0xd0);
        out.push(value as i8 as u8);
    } else if value >= i16::MIN as i64 {
        out.push(0xd1);
        out.extend_from_slice(&(value as i16).to_be_bytes());
    } else if value >= i32::MIN as i64 {
        out.push(0xd2);
        out.extend_from_slice(&(value as i32).to_be_bytes());
    } else {
        out.push(0xd3);
        out.extend_from_slice(&value.to_be_bytes());
    }
}

fn encode_str(value: &str, out: &mut Vec<u8>) {
    let bytes = value.as_bytes();
    let len = bytes.len();
    if len <= 31 {
        out.push(0xa0 | len as u8);
    } else if u8::try_from(len).is_ok() {
        out.push(0xd9);
        out.push(len as u8);
    } else if u16::try_from(len).is_ok() {
        out.push(0xda);
        out.extend_from_slice(&(len as u16).to_be_bytes());
    } else {
        out.push(0xdb);
        out.extend_from_slice(&(len as u32).to_be_bytes());
    }
    out.extend_from_slice(bytes);
}

fn encode_array_len(len: usize, out: &mut Vec<u8>) -> io::Result<()> {
    if len <= 15 {
        out.push(0x90 | len as u8);
    } else if u16::try_from(len).is_ok() {
        out.push(0xdc);
        out.extend_from_slice(&(len as u16).to_be_bytes());
    } else if u32::try_from(len).is_ok() {
        out.push(0xdd);
        out.extend_from_slice(&(len as u32).to_be_bytes());
    } else {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "array is too large for MessagePack",
        ));
    }
    Ok(())
}

fn encode_map_len(len: usize, out: &mut Vec<u8>) -> io::Result<()> {
    if len <= 15 {
        out.push(0x80 | len as u8);
    } else if u16::try_from(len).is_ok() {
        out.push(0xde);
        out.extend_from_slice(&(len as u16).to_be_bytes());
    } else if u32::try_from(len).is_ok() {
        out.push(0xdf);
        out.extend_from_slice(&(len as u32).to_be_bytes());
    } else {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "map is too large for MessagePack",
        ));
    }
    Ok(())
}

fn json_array(values: impl IntoIterator<Item = JsonValue>) -> JsonValue {
    JsonValue::Array(values.into_iter().collect())
}

fn json_object<const N: usize>(values: [(&str, JsonValue); N]) -> JsonValue {
    let mut object = JsonMap::new();
    for (key, value) in values {
        object.insert(key.into(), value);
    }
    JsonValue::Object(object)
}

fn json_string(value: &str) -> JsonValue {
    JsonValue::String(value.to_string())
}

fn json_number(value: u64) -> JsonValue {
    JsonValue::Number(JsonNumber::from(value))
}
