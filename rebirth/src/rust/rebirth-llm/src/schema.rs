//! D-030's bounded JSON Schema profile and independent output validation.

use crate::error::RebirthError;
use crate::structured::STRUCTURED_MAX_OUTPUT_BYTES as OUTPUT_MAX_BYTES;
use serde::de::{self, DeserializeSeed, MapAccess, SeqAccess, Visitor};
use std::collections::{BTreeMap, BTreeSet};
use std::fmt;

pub const SCHEMA_MAX_BYTES: usize = 64 * 1024;
pub const SCHEMA_MAX_DEPTH: usize = 8;
pub const SCHEMA_MAX_NODES: usize = 128;
pub const GRAMMAR_MAX_BYTES: usize = 512 * 1024;
const MAX_OBJECT_PROPERTIES: usize = 16;
const MAX_TOTAL_PROPERTIES: usize = 64;
const MAX_ENUM_MEMBERS: usize = 32;
const MAX_ENUM_LENGTH: usize = 128;
const MAX_STRING_LENGTH: usize = 2048;
// Schema depth counts schema nodes, not their properties/type/required wrappers.
// These separate raw-JSON limits also bound malformed or unsupported input.
const JSON_MAX_DEPTH: usize = 2 * SCHEMA_MAX_DEPTH + 2;
const JSON_MAX_NODES: usize = 8192;

#[derive(Debug)]
pub struct CompiledSchema {
    root: Node,
    grammar: String,
}

impl CompiledSchema {
    /// Compile the approved closed-object profile, before model decode begins.
    pub fn compile(text: &str) -> Result<Self, RebirthError> {
        if text.len() > SCHEMA_MAX_BYTES {
            return Err(schema_error("", "schema exceeds 64 KiB"));
        }
        let json = parse_json(text.as_bytes()).map_err(|e| schema_error(&e.path, &e.reason))?;
        let root = ProfileBudget::default().node(&json, "", 1, true)?;
        let mut builder = GrammarBuilder::default();
        // Compact generation avoids an otherwise legal whitespace-only loop.
        // Validation still accepts all JSON whitespace; this only chooses the
        // serialization emitted by the grammar, not the values it can express.
        builder.add("ws", r#"[ ]?"#, "")?;
        builder.add("hex", "[0-9a-fA-F]", "")?;
        // A surrogate pair is ONE decoded scalar. Lone surrogate escapes and
        // literal surrogate codepoints are excluded before token selection.
        builder.add(
            "json-char",
            r#"[\x20-\x21\x23-\x5b\x5d-\ud7ff\ue000-\U0010ffff] | "\\" (["\\/bfnrt] | "u" ([0-9a-cA-Ce-fE-F] hex hex hex | [dD] [0-7] hex hex | [dD] [89aAbB] hex hex "\\u" [dD] [c-fC-F] hex hex))"#,
            "",
        )?;
        let rule = builder.node(&root, "")?;
        builder.add("root", &format!("ws {rule} ws"), "")?;
        Ok(Self {
            root,
            grammar: builder.rules,
        })
    }

    /// GBNF accepted by the pinned llama.cpp grammar parser; start rule `root`.
    pub fn grammar(&self) -> &str {
        &self.grammar
    }

    /// Parse and validate independently of the compiled grammar/state machine.
    /// Key order and equivalent JSON escapes are deliberately immaterial here.
    pub fn validate(&self, bytes: &[u8]) -> Result<(), String> {
        if bytes.len() > OUTPUT_MAX_BYTES {
            return Err("output exceeds 64 KiB".to_string());
        }
        let json = parse_json(bytes).map_err(|e| format!("JSON at {:?}: {}", e.path, e.reason))?;
        validate_node(&self.root, &json, "")
    }
}

fn schema_error(path: &str, reason: &str) -> RebirthError {
    RebirthError::Schema {
        reason: reason.to_string(),
        schema_path: path.to_string(),
    }
}

fn pointer(parent: &str, key: &str) -> String {
    format!("{parent}/{}", key.replace('~', "~0").replace('/', "~1"))
}

#[derive(Debug)]
enum Json {
    Null,
    Bool(bool),
    Integer(i64),
    String(String),
    Array(Vec<Json>),
    Object(BTreeMap<String, Json>),
}

struct ParseFailure {
    reason: String,
    path: String,
}

#[derive(Default)]
struct JsonBudget {
    nodes: usize,
    failure_path: String,
}

struct JsonSeed<'a> {
    budget: &'a mut JsonBudget,
    depth: usize,
    path: String,
}

impl<'de> DeserializeSeed<'de> for JsonSeed<'_> {
    type Value = Json;

    fn deserialize<D: de::Deserializer<'de>>(self, deserializer: D) -> Result<Json, D::Error> {
        if self.depth > JSON_MAX_DEPTH || self.budget.nodes >= JSON_MAX_NODES {
            self.budget.failure_path = self.path;
            return Err(de::Error::custom(
                "JSON nesting/node resource limit exceeded",
            ));
        }
        self.budget.nodes += 1;
        deserializer.deserialize_any(self)
    }
}

impl<'de> Visitor<'de> for JsonSeed<'_> {
    type Value = Json;

    fn expecting(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("strict bounded JSON")
    }
    fn visit_unit<E: de::Error>(self) -> Result<Json, E> {
        Ok(Json::Null)
    }
    fn visit_bool<E: de::Error>(self, value: bool) -> Result<Json, E> {
        Ok(Json::Bool(value))
    }
    fn visit_i64<E: de::Error>(self, value: i64) -> Result<Json, E> {
        Ok(Json::Integer(value))
    }
    fn visit_u64<E: de::Error>(self, value: u64) -> Result<Json, E> {
        i64::try_from(value)
            .map(Json::Integer)
            .map_err(|_| E::custom("integer is out of range"))
    }
    fn visit_f64<E: de::Error>(self, value: f64) -> Result<Json, E> {
        // serde_json represents the legal integer lexeme -0 as a float. The
        // lexical precheck has already excluded every decimal/exponent form.
        if value == 0.0 && value.is_sign_negative() {
            Ok(Json::Integer(0))
        } else {
            Err(E::custom("integer is out of range"))
        }
    }
    fn visit_str<E: de::Error>(self, value: &str) -> Result<Json, E> {
        Ok(Json::String(value.to_string()))
    }
    fn visit_string<E: de::Error>(self, value: String) -> Result<Json, E> {
        Ok(Json::String(value))
    }

    fn visit_seq<S: SeqAccess<'de>>(self, mut seq: S) -> Result<Json, S::Error> {
        let mut values = Vec::new();
        while let Some(value) = seq.next_element_seed(JsonSeed {
            budget: self.budget,
            depth: self.depth + 1,
            path: pointer(&self.path, &values.len().to_string()),
        })? {
            values.push(value);
        }
        Ok(Json::Array(values))
    }

    fn visit_map<M: MapAccess<'de>>(self, mut map: M) -> Result<Json, M::Error> {
        let mut values = BTreeMap::new();
        while let Some(key) = map.next_key::<String>()? {
            let path = pointer(&self.path, &key);
            if values.contains_key(&key) {
                self.budget.failure_path = path;
                return Err(de::Error::custom("duplicate decoded object key"));
            }
            let value = map.next_value_seed(JsonSeed {
                budget: self.budget,
                depth: self.depth + 1,
                path,
            })?;
            values.insert(key, value);
        }
        Ok(Json::Object(values))
    }
}

fn parse_json(bytes: &[u8]) -> Result<Json, ParseFailure> {
    // Keep Serde responsible for JSON syntax, UTF-8 and surrogate decoding.
    // Its std-only Number representation discards lexical 1 vs 1.0 vs 1e0;
    // screen only number tokens to preserve the profile's decimal-integer rule.
    let mut quoted = false;
    let mut escaped = false;
    let mut number = false;
    for &byte in bytes {
        if quoted {
            if escaped {
                escaped = false;
            } else if byte == b'\\' {
                escaped = true;
            } else if byte == b'"' {
                quoted = false;
            }
        } else if byte == b'"' {
            quoted = true;
            number = false;
        } else if number && matches!(byte, b'.' | b'e' | b'E') {
            return Err(ParseFailure {
                reason: "decimal fractions and exponent number lexemes are unsupported".to_string(),
                path: String::new(),
            });
        } else {
            number = byte.is_ascii_digit() || byte == b'-';
        }
    }
    let mut budget = JsonBudget::default();
    let mut deserializer = serde_json::Deserializer::from_slice(bytes);
    let result = JsonSeed {
        budget: &mut budget,
        depth: 1,
        path: String::new(),
    }
    .deserialize(&mut deserializer);
    let value = result.map_err(|e| ParseFailure {
        reason: e.to_string(),
        path: budget.failure_path,
    })?;
    deserializer.end().map_err(|e| ParseFailure {
        reason: e.to_string(),
        path: String::new(),
    })?;
    Ok(value)
}

#[derive(Debug)]
struct Node {
    kind: Kind,
    nullable: bool,
}

#[derive(Debug)]
enum Kind {
    Object(BTreeMap<String, Node>),
    String { min: usize, max: usize },
    Enum(Vec<String>),
    Integer { min: i32, max: i32 },
    Boolean,
    Null,
}

#[derive(Default)]
struct ProfileBudget {
    nodes: usize,
    properties: usize,
}

fn field<'a>(
    object: &'a BTreeMap<String, Json>,
    name: &str,
    path: &str,
) -> Result<&'a Json, RebirthError> {
    object
        .get(name)
        .ok_or_else(|| schema_error(&pointer(path, name), "required schema keyword is missing"))
}

fn integer_field(
    object: &BTreeMap<String, Json>,
    name: &str,
    path: &str,
) -> Result<i64, RebirthError> {
    match field(object, name, path)? {
        Json::Integer(value) => Ok(*value),
        _ => Err(schema_error(
            &pointer(path, name),
            "expected a decimal integer",
        )),
    }
}

impl ProfileBudget {
    fn node(
        &mut self,
        json: &Json,
        path: &str,
        depth: usize,
        root: bool,
    ) -> Result<Node, RebirthError> {
        if depth > SCHEMA_MAX_DEPTH || self.nodes >= SCHEMA_MAX_NODES {
            return Err(schema_error(path, "schema nesting/node limit exceeded"));
        }
        self.nodes += 1;
        let Json::Object(object) = json else {
            return Err(schema_error(path, "schema node must be an object"));
        };
        let (name, nullable) = match field(object, "type", path)? {
            Json::String(name) => (name.as_str(), false),
            Json::Array(types) if types.len() == 2 => match (&types[0], &types[1]) {
                (Json::String(a), Json::String(b)) if a == "null" && b != "null" => {
                    (b.as_str(), true)
                }
                (Json::String(a), Json::String(b)) if b == "null" && a != "null" => {
                    (a.as_str(), true)
                }
                _ => {
                    return Err(schema_error(
                        &pointer(path, "type"),
                        "nullable type must contain one supported non-null type and null",
                    ))
                }
            },
            _ => {
                return Err(schema_error(
                    &pointer(path, "type"),
                    "type must name one supported type or a two-member nullable type",
                ))
            }
        };
        if root && (name != "object" || nullable) {
            return Err(schema_error(
                &pointer(path, "type"),
                "root must be a nonnullable object",
            ));
        }
        let allowed: &[&str] = match name {
            "object" => &["properties", "required", "additionalProperties"],
            "string" if object.contains_key("enum") => &["enum"],
            "string" => &["minLength", "maxLength"],
            "integer" => &["minimum", "maximum"],
            "boolean" | "null" => &[],
            _ => {
                return Err(schema_error(
                    &pointer(path, "type"),
                    "unsupported schema type",
                ))
            }
        };
        for key in object.keys() {
            if key != "type" && !(root && key == "$schema") && !allowed.contains(&key.as_str()) {
                return Err(schema_error(
                    &pointer(path, key),
                    "unsupported schema keyword for this type",
                ));
            }
        }
        if let Some(value) = object.get("$schema") {
            if !matches!(value, Json::String(s) if s == "https://json-schema.org/draft/2020-12/schema")
            {
                return Err(schema_error(
                    &pointer(path, "$schema"),
                    "unsupported JSON Schema dialect",
                ));
            }
        }
        let kind = match name {
            "object" => {
                if !matches!(
                    field(object, "additionalProperties", path)?,
                    Json::Bool(false)
                ) {
                    return Err(schema_error(
                        &pointer(path, "additionalProperties"),
                        "additionalProperties must explicitly be false",
                    ));
                }
                let Json::Object(properties) = field(object, "properties", path)? else {
                    return Err(schema_error(
                        &pointer(path, "properties"),
                        "properties must be an object",
                    ));
                };
                if properties.len() > MAX_OBJECT_PROPERTIES
                    || self.properties + properties.len() > MAX_TOTAL_PROPERTIES
                {
                    return Err(schema_error(
                        &pointer(path, "properties"),
                        "property count exceeds 16 per object or 64 total",
                    ));
                }
                self.properties += properties.len();
                let Json::Array(required) = field(object, "required", path)? else {
                    return Err(schema_error(
                        &pointer(path, "required"),
                        "required must be an array of all property names",
                    ));
                };
                let mut names = BTreeSet::new();
                for entry in required {
                    let Json::String(name) = entry else {
                        return Err(schema_error(
                            &pointer(path, "required"),
                            "required must contain only strings",
                        ));
                    };
                    if !properties.contains_key(name) || !names.insert(name) {
                        return Err(schema_error(
                            &pointer(path, "required"),
                            "required must name each property exactly once",
                        ));
                    }
                }
                if names.len() != properties.len() {
                    return Err(schema_error(
                        &pointer(path, "required"),
                        "required must name each property exactly once",
                    ));
                }
                let mut fields = BTreeMap::new();
                for (key, value) in properties {
                    fields.insert(
                        key.clone(),
                        self.node(
                            value,
                            &pointer(&pointer(path, "properties"), key),
                            depth + 1,
                            false,
                        )?,
                    );
                }
                Kind::Object(fields)
            }
            "string" if object.contains_key("enum") => {
                if nullable {
                    return Err(schema_error(
                        &pointer(path, "enum"),
                        "enum is unsupported on nullable types",
                    ));
                }
                let Json::Array(members) = field(object, "enum", path)? else {
                    return Err(schema_error(
                        &pointer(path, "enum"),
                        "enum must be a nonempty array of strings",
                    ));
                };
                if members.is_empty() || members.len() > MAX_ENUM_MEMBERS {
                    return Err(schema_error(
                        &pointer(path, "enum"),
                        "enum must have 1 to 32 members",
                    ));
                }
                let mut unique = BTreeSet::new();
                for member in members {
                    let Json::String(value) = member else {
                        return Err(schema_error(
                            &pointer(path, "enum"),
                            "enum members must be strings",
                        ));
                    };
                    if value.chars().count() > MAX_ENUM_LENGTH || !unique.insert(value.clone()) {
                        return Err(schema_error(
                            &pointer(path, "enum"),
                            "enum members must be unique and at most 128 Unicode scalar values",
                        ));
                    }
                }
                Kind::Enum(unique.into_iter().collect())
            }
            "string" => {
                let max = integer_field(object, "maxLength", path)?;
                let min = if object.contains_key("minLength") {
                    integer_field(object, "minLength", path)?
                } else {
                    0
                };
                if min < 0 || min > max || max > MAX_STRING_LENGTH as i64 {
                    return Err(schema_error(
                        path,
                        "string lengths must satisfy 0 <= minLength <= maxLength <= 2048",
                    ));
                }
                Kind::String {
                    min: min as usize,
                    max: max as usize,
                }
            }
            "integer" => {
                let min = integer_field(object, "minimum", path)?;
                let max = integer_field(object, "maximum", path)?;
                if min < i32::MIN as i64 || max > i32::MAX as i64 || min > max {
                    return Err(schema_error(
                        path,
                        "integer bounds must be ordered within -2147483648..2147483647",
                    ));
                }
                Kind::Integer {
                    min: min as i32,
                    max: max as i32,
                }
            }
            "boolean" => Kind::Boolean,
            "null" => Kind::Null,
            _ => unreachable!("schema type was checked above"),
        };
        Ok(Node { kind, nullable })
    }
}

fn validate_node(schema: &Node, value: &Json, path: &str) -> Result<(), String> {
    if schema.nullable && matches!(value, Json::Null) {
        return Ok(());
    }
    let error = |reason: &str| format!("output at {path:?}: {reason}");
    match (&schema.kind, value) {
        (Kind::Null, Json::Null) | (Kind::Boolean, Json::Bool(_)) => Ok(()),
        (Kind::Integer { min, max }, Json::Integer(n))
            if (*min as i64..=*max as i64).contains(n) =>
        {
            Ok(())
        }
        (Kind::String { min, max }, Json::String(s))
            if (*min..=*max).contains(&s.chars().count()) =>
        {
            Ok(())
        }
        (Kind::Enum(members), Json::String(s)) if members.contains(s) => Ok(()),
        (Kind::Object(properties), Json::Object(values)) => {
            if values.len() != properties.len() || values.keys().ne(properties.keys()) {
                return Err(error(
                    "object must contain every declared property exactly once and no others",
                ));
            }
            for (key, schema) in properties {
                // Key equality was checked above; avoid a panic even if this is
                // later refactored to validate optional fields.
                let value = values
                    .get(key)
                    .ok_or_else(|| error("required property is missing"))?;
                validate_node(schema, value, &pointer(path, key))?;
            }
            Ok(())
        }
        _ => Err(error(
            "value does not satisfy its declared type, bounds or enum",
        )),
    }
}

#[derive(Default)]
struct GrammarBuilder {
    rules: String,
    next_node: usize,
    exact: BTreeSet<usize>,
    upto: BTreeSet<usize>,
    literal_chars: BTreeMap<char, String>,
}

fn append_grammar(buffer: &mut String, text: &str, path: &str) -> Result<(), RebirthError> {
    if buffer
        .len()
        .checked_add(text.len())
        .is_none_or(|n| n > GRAMMAR_MAX_BYTES)
    {
        return Err(schema_error(path, "compiled grammar exceeds 512 KiB"));
    }
    buffer.push_str(text);
    Ok(())
}

impl GrammarBuilder {
    fn add(&mut self, name: &str, expression: &str, path: &str) -> Result<(), RebirthError> {
        for part in [name, " ::= ", expression, "\n"] {
            append_grammar(&mut self.rules, part, path)?;
        }
        Ok(())
    }

    fn node(&mut self, schema: &Node, path: &str) -> Result<String, RebirthError> {
        let name = format!("value-{}", self.next_node);
        self.next_node += 1;
        let mut expression = match &schema.kind {
            Kind::Null => gbnf_literal("null"),
            Kind::Boolean => "\"true\" | \"false\"".to_string(),
            Kind::Integer { min, max } => integer_expression(*min, *max),
            Kind::String { min, max } => {
                let exact = self.repeat_exact(*min, path)?;
                let upto = self.repeat_upto(max - min, path)?;
                format!(r#""\"" {exact} {upto} "\"""#)
            }
            Kind::Enum(members) => {
                let mut expression = String::new();
                for (index, member) in members.iter().enumerate() {
                    if index > 0 {
                        append_grammar(&mut expression, " | ", path)?;
                    }
                    append_grammar(&mut expression, r#""\"" "#, path)?;
                    for ch in member.chars() {
                        let scalar = self.literal_scalar(ch, path)?;
                        append_grammar(&mut expression, &scalar, path)?;
                        append_grammar(&mut expression, " ", path)?;
                    }
                    append_grammar(&mut expression, r#""\"""#, path)?;
                }
                expression
            }
            Kind::Object(properties) => {
                let mut expression = "\"{\" ws".to_string();
                for (index, (key, value)) in properties.iter().enumerate() {
                    if index > 0 {
                        append_grammar(&mut expression, " \",\" ws", path)?;
                    }
                    let child_path = pointer(&pointer(path, "properties"), key);
                    let child = self.node(value, &child_path)?;
                    let key = serde_json::to_string(key)
                        .map_err(|e| schema_error(path, &e.to_string()))?;
                    append_grammar(
                        &mut expression,
                        &format!(" {} ws \":\" ws {child} ws", gbnf_literal(&key)),
                        path,
                    )?;
                }
                append_grammar(&mut expression, " \"}\"", path)?;
                expression
            }
        };
        if schema.nullable {
            append_grammar(&mut expression, " | \"null\"", path)?;
        }
        self.add(&name, &expression, path)?;
        Ok(name)
    }

    // Binary decomposition keeps both grammar size and expansion stacks small.
    // A linear chain of 2048 optional json-char rules is pathologically costly
    // for llama.cpp's nondeterministic grammar sampler.
    fn repeat_exact(&mut self, n: usize, path: &str) -> Result<String, RebirthError> {
        if n == 0 {
            return Ok("\"\"".to_string());
        }
        if n == 1 {
            return Ok("json-char".to_string());
        }
        let name = format!("exact-{n}");
        if self.exact.insert(n) {
            let a = self.repeat_exact(n / 2, path)?;
            let b = self.repeat_exact(n - n / 2, path)?;
            self.add(&name, &format!("{a} {b}"), path)?;
        }
        Ok(name)
    }

    fn repeat_upto(&mut self, n: usize, path: &str) -> Result<String, RebirthError> {
        if n == 0 {
            return Ok("\"\"".to_string());
        }
        let name = format!("upto-{n}");
        if self.upto.insert(n) {
            let pivot = 1usize << (usize::BITS - 1 - n.leading_zeros());
            let small = self.repeat_upto(pivot - 1, path)?;
            let exact = self.repeat_exact(pivot, path)?;
            let rest = self.repeat_upto(n - pivot, path)?;
            self.add(&name, &format!("{small} | {exact} {rest}"), path)?;
        }
        Ok(name)
    }

    fn literal_scalar(&mut self, ch: char, path: &str) -> Result<String, RebirthError> {
        if let Some(name) = self.literal_chars.get(&ch) {
            return Ok(name.clone());
        }
        let name = format!("literal-{}", self.literal_chars.len());
        let mut choices = Vec::new();
        if ch >= ' ' && ch != '"' && ch != '\\' {
            choices.push(gbnf_literal(&ch.to_string()));
        }
        let escape = match ch {
            '"' => Some("\\\""),
            '\\' => Some("\\\\"),
            '/' => Some("\\/"),
            '\u{8}' => Some("\\b"),
            '\u{c}' => Some("\\f"),
            '\n' => Some("\\n"),
            '\r' => Some("\\r"),
            '\t' => Some("\\t"),
            _ => None,
        };
        if let Some(escape) = escape {
            choices.push(gbnf_literal(escape));
        }
        let mut units = [0; 2];
        let encoded = ch
            .encode_utf16(&mut units)
            .iter()
            .map(|unit| {
                let digits = format!("{unit:04x}")
                    .chars()
                    .map(|digit| {
                        if digit.is_ascii_lowercase() {
                            format!("[{digit}{}]", digit.to_ascii_uppercase())
                        } else {
                            gbnf_literal(&digit.to_string())
                        }
                    })
                    .collect::<Vec<_>>()
                    .join(" ");
                format!("{} {digits}", gbnf_literal("\\u"))
            })
            .collect::<Vec<_>>()
            .join(" ");
        choices.push(encoded);
        self.add(&name, &choices.join(" | "), path)?;
        self.literal_chars.insert(ch, name.clone());
        Ok(name)
    }
}

fn gbnf_literal(value: &str) -> String {
    let mut result = String::from("\"");
    for ch in value.chars() {
        match ch {
            '"' => result.push_str("\\\""),
            '\\' => result.push_str("\\\\"),
            '\n' => result.push_str("\\n"),
            '\r' => result.push_str("\\r"),
            '\t' => result.push_str("\\t"),
            ch if ch < ' ' => result.push_str(&format!("\\u{:04x}", ch as u32)),
            ch => result.push(ch),
        }
    }
    result.push('"');
    result
}

fn integer_expression(min: i32, max: i32) -> String {
    let mut branches = Vec::new();
    if min < 0 {
        let lower = i64::from(max.min(-1)).unsigned_abs();
        let upper = i64::from(min).unsigned_abs();
        branches.push(format!("\"-\" ({})", unsigned_interval(lower, upper)));
    }
    if max >= 0 {
        branches.push(unsigned_interval(min.max(0) as u64, max as u64));
    }
    if min <= 0 && max >= 0 {
        branches.push("\"-0\"".to_string());
    }
    branches.join(" | ")
}

fn unsigned_interval(min: u64, max: u64) -> String {
    let mut branches = Vec::new();
    for digits in min.to_string().len()..=max.to_string().len() {
        let floor = if digits == 1 {
            0
        } else {
            10u64.pow(digits as u32 - 1)
        };
        let ceiling = 10u64.pow(digits as u32) - 1;
        branches.push(digit_interval(
            min.max(floor).to_string().as_bytes(),
            max.min(ceiling).to_string().as_bytes(),
        ));
    }
    branches.join(" | ")
}

// Equal-width decimal bounds. The three branches partition by first digit;
// subsequent all-zero/all-nine spans collapse to one digit class per position.
fn digit_interval(lower: &[u8], upper: &[u8]) -> String {
    if lower.is_empty() {
        return "\"\"".to_string();
    }
    if lower == upper {
        return gbnf_literal(
            &lower
                .iter()
                .map(|&digit| char::from(digit))
                .collect::<String>(),
        );
    }
    if lower.iter().all(|&c| c == b'0') && upper.iter().all(|&c| c == b'9') {
        return vec!["[0-9]"; lower.len()].join(" ");
    }
    if lower[0] == upper[0] {
        return format!(
            "{} ({})",
            gbnf_literal(&(lower[0] as char).to_string()),
            digit_interval(&lower[1..], &upper[1..])
        );
    }
    let mut branches = Vec::new();
    branches.push(format!(
        "{} ({})",
        gbnf_literal(&(lower[0] as char).to_string()),
        digit_interval(&lower[1..], &vec![b'9'; lower.len() - 1])
    ));
    if lower[0] + 1 < upper[0] {
        let first = if lower[0] + 2 == upper[0] {
            gbnf_literal(&((lower[0] + 1) as char).to_string())
        } else {
            format!("[{}-{}]", (lower[0] + 1) as char, (upper[0] - 1) as char)
        };
        branches.push(format!(
            "{first} {}",
            vec!["[0-9]"; lower.len() - 1].join(" ")
        ));
    }
    branches.push(format!(
        "{} ({})",
        gbnf_literal(&(upper[0] as char).to_string()),
        digit_interval(&vec![b'0'; upper.len() - 1], &upper[1..])
    ));
    format!("({})", branches.join(" | "))
}

#[cfg(test)]
mod tests {
    use super::*;

    // Model-free: runs in the normal Rust PR test job on macOS and Linux.
    fn record(value_schema: &str) -> String {
        format!(
            r#"{{"type":"object","properties":{{"value":{value_schema}}},"required":["value"],"additionalProperties":false}}"#
        )
    }

    fn compiled(value_schema: &str) -> CompiledSchema {
        CompiledSchema::compile(&record(value_schema)).unwrap()
    }

    fn output(schema: &CompiledSchema, value: &str) -> Result<(), String> {
        schema.validate(format!(r#"{{"value":{value}}}"#).as_bytes())
    }

    #[test]
    fn integer_lexemes_and_endpoints_are_exact() {
        let all = compiled(r#"{"type":"integer","minimum":-2147483648,"maximum":2147483647}"#);
        for value in ["-2147483648", "2147483647", "0", "-0", "-1"] {
            assert!(output(&all, value).is_ok(), "{value}");
        }
        for value in [
            "-2147483649",
            "2147483648",
            "1.0",
            "1e0",
            "-0.0",
            "-0e0",
            "01",
            "+1",
            "18446744073709551616",
            "null",
            "true",
            "\"1\"",
        ] {
            assert!(output(&all, value).is_err(), "{value}");
        }
        let bounded = compiled(r#"{"type":"integer","minimum":-13,"maximum":27}"#);
        for value in -30..=40 {
            assert_eq!(
                output(&bounded, &value.to_string()).is_ok(),
                (-13..=27).contains(&value)
            );
        }
    }

    #[test]
    fn native_integer_grammar_matches_interval_boundaries() {
        use crate::structured::tests::accepts;
        for (min, max) in [
            (i32::MIN, i32::MAX),
            (i32::MIN, i32::MIN),
            (i32::MAX, i32::MAX),
            (-100, -9),
            (-13, 27),
            (0, 0),
            (8, 105),
            (199, 200),
        ] {
            let schema = compiled(&format!(
                r#"{{"type":"integer","minimum":{min},"maximum":{max}}}"#
            ));
            let samples = [
                i64::from(min) - 1,
                i64::from(min),
                i64::from(min) + 1,
                i64::from(max) - 1,
                i64::from(max),
                i64::from(max) + 1,
                -100,
                -99,
                -10,
                -9,
                -1,
                0,
                1,
                9,
                10,
                99,
                100,
            ]
            .into_iter()
            .collect::<BTreeSet<_>>();
            for value in samples {
                let text = format!(r#"{{"value":{value}}}"#);
                let expected = (i64::from(min)..=i64::from(max)).contains(&value);
                assert_eq!(accepts(&schema, &text), expected, "{min}..={max}: {text}");
            }
            assert_eq!(accepts(&schema, r#"{"value":-0}"#), min <= 0 && max >= 0);
            for invalid in ["01", "-01", "+1", "1.0", "1e0", "-0.0", "-0e0"] {
                let text = format!(r#"{{"value":{invalid}}}"#);
                assert!(!accepts(&schema, &text), "{min}..={max}: {text}");
            }
        }
    }

    #[test]
    fn native_enum_grammar_accepts_equivalent_scalar_encodings() {
        use crate::structured::tests::accepts;
        let schema = compiled(
            r#"{"type":"string","enum":["a","é","😀","\"","\\","/","\b","\f","\n","\r","\t","\u0000",""]}"#,
        );
        for value in [
            r#""a""#,
            r#""\u0061""#,
            r#""é""#,
            r#""\u00E9""#,
            r#""😀""#,
            r#""\uD83D\uDe00""#,
            r#""\"""#,
            r#""\u0022""#,
            r#""\\""#,
            r#""\u005C""#,
            r#""/""#,
            r#""\/""#,
            r#""\b""#,
            r#""\f""#,
            r#""\n""#,
            r#""\r""#,
            r#""\t""#,
            r#""\u0000""#,
            r#""""#,
        ] {
            let text = format!(r#"{{"value":{value}}}"#);
            assert!(accepts(&schema, &text), "{text}");
            schema.validate(text.as_bytes()).unwrap();
        }
        for value in [
            r#""b""#,
            r#""e\u0301""#,
            r#""\uD83D""#,
            r#""\uDE00""#,
            r#""\uD83D\u0061""#,
            "null",
        ] {
            assert!(
                !accepts(&schema, &format!(r#"{{"value":{value}}}"#)),
                "{value}"
            );
        }
    }

    #[test]
    fn native_string_repetition_has_exact_scalar_bounds() {
        use crate::structured::tests::accepts;
        for (min, max) in [(0, 0), (1, 1), (2, 3), (2047, 2048)] {
            let schema = compiled(&format!(
                r#"{{"type":"string","minLength":{min},"maxLength":{max}}}"#
            ));
            for length in [0, min, max, max + 1] {
                let text = format!(r#"{{"value":"{}"}}"#, "😀".repeat(length));
                assert_eq!(
                    accepts(&schema, &text),
                    (min..=max).contains(&length),
                    "{min}..={max}: {length}"
                );
            }
        }
        let schema = compiled(r#"{"type":"string","minLength":1,"maxLength":1}"#);
        for value in [r#""\ud83d\ude00""#, r#""\u0000""#, r#""\n""#] {
            assert!(
                accepts(&schema, &format!(r#"{{"value":{value}}}"#)),
                "{value}"
            );
        }
        for value in [
            r#""\ud83d""#,
            r#""\ude00""#,
            r#""\ud83d\u0041""#,
            r#""\udc00\ud800""#,
            r#""\ud83d\ude00a""#,
        ] {
            assert!(
                !accepts(&schema, &format!(r#"{{"value":{value}}}"#)),
                "{value}"
            );
        }
    }

    #[test]
    fn scalar_lengths_count_decoded_unicode() {
        let one = compiled(r#"{"type":"string","minLength":1,"maxLength":1}"#);
        for value in [
            r#""é""#,
            r#""\u00e9""#,
            r#""😀""#,
            r#""\ud83d\ude00""#,
            r#""\u0000""#,
            r#""\n""#,
        ] {
            assert!(output(&one, value).is_ok(), "{value}");
        }
        for value in [
            r#""""#,
            r#""é""#,
            r#""\ud83d""#,
            r#""\ude00""#,
            r#""\ud83d\u0041""#,
            r#""\udc00\ud800""#,
        ] {
            assert!(output(&one, value).is_err(), "{value}");
        }
        assert!(one.validate(b"{\"value\":\"\xff\"}").is_err());
        assert!(one.validate(b"{\"value\":\"\xed\xa0\x80\"}").is_err());
        let empty = compiled(r#"{"type":"string","maxLength":0}"#);
        assert!(output(&empty, r#""""#).is_ok());
        assert!(output(&empty, r#""a""#).is_err());
    }

    #[test]
    fn strict_objects_reject_duplicates_aliases_and_extra_keys() {
        let s = compiled(r#"{"type":"boolean"}"#);
        for bytes in [
            r#"{}"#,
            r#"{"value":true,"other":null}"#,
            r#"{"value":true,"value":false}"#,
            r#"{"value":true,"\u0076alue":false}"#,
            r#"{"value":true} {}"#,
            r#"{"value":true,}"#,
            r#"[true]"#,
        ] {
            assert!(s.validate(bytes.as_bytes()).is_err(), "{bytes}");
        }
        assert!(s.validate(b" \t\r\n{\"\\u0076alue\" : true}\r\n ").is_ok());
        let duplicate_schema = record(r#"{"type":"boolean","\u0074ype":"boolean"}"#);
        assert!(CompiledSchema::compile(&duplicate_schema).is_err());
        let duplicate_properties = r#"{"type":"object","properties":{"a":{"type":"null"},"\u0061":{"type":"null"}},"required":["a"],"additionalProperties":false}"#;
        assert!(CompiledSchema::compile(duplicate_properties).is_err());
    }

    #[test]
    fn nullable_branches_enums_and_null_are_distinct() {
        let s = compiled(r#"{"type":["string","null"],"minLength":1,"maxLength":2}"#);
        assert!(output(&s, "null").is_ok());
        assert!(output(&s, r#""a""#).is_ok());
        assert!(output(&s, r#""""#).is_err());
        let e = compiled(r#"{"type":"string","enum":["a","é","😀",""]}"#);
        for value in [
            r#""a""#,
            r#""\u0061""#,
            r#""\u00E9""#,
            r#""\ud83d\ude00""#,
            r#""""#,
        ] {
            assert!(output(&e, value).is_ok(), "{value}");
        }
        assert!(output(&e, "null").is_err());
        assert!(output(&e, r#""é""#).is_err());
        let n = compiled(r#"{"type":"null"}"#);
        assert!(output(&n, "null").is_ok());
        assert!(output(&n, "false").is_err());
        let b = compiled(r#"{"type":["null","boolean"]}"#);
        for v in ["null", "true", "false"] {
            assert!(output(&b, v).is_ok());
        }
    }

    #[test]
    fn unsupported_or_incomplete_profiles_fail_before_generation() {
        let invalid = [
            r#"{"type":"array","items":{"type":"null"}}"#,
            r#"{"type":"number","minimum":0,"maximum":1}"#,
            r#"{"type":"boolean","description":"annotation"}"#,
            r#"{"type":"boolean","$schema":"https://json-schema.org/draft/2020-12/schema"}"#,
            r#"{"type":"string"}"#,
            r#"{"type":"string","maxLength":2049}"#,
            r#"{"type":"string","minLength":2,"maxLength":1}"#,
            r#"{"type":"string","minLength":-1,"maxLength":1}"#,
            r#"{"type":"string","maxLength":1.0}"#,
            r#"{"type":"string","enum":[]}"#,
            r#"{"type":"string","enum":["a","\u0061"]}"#,
            r#"{"type":"string","enum":[1]}"#,
            r#"{"type":"string","enum":["a"],"maxLength":2}"#,
            r#"{"type":["string","null"],"enum":["a"]}"#,
            r#"{"type":["boolean"]}"#,
            r#"{"type":["null","null"]}"#,
            r#"{"type":["boolean","string"]}"#,
            r#"{"type":["boolean","null","null"]}"#,
            r#"{"type":"integer","minimum":0}"#,
            r#"{"type":"integer","minimum":2,"maximum":1}"#,
            r#"{"type":"integer","minimum":-2147483649,"maximum":0}"#,
            r#"{"type":"integer","minimum":0,"maximum":2147483648}"#,
            r#"{"type":"integer","minimum":0,"maximum":1e0}"#,
            r#"{"type":"object","properties":{},"required":[]}"#,
            r#"{"type":"object","properties":{},"required":[],"additionalProperties":true}"#,
            r#"{"type":"object","properties":{"a":{"type":"null"}},"required":[],"additionalProperties":false}"#,
            r#"{"type":"object","properties":{"a":{"type":"null"}},"required":["a","a"],"additionalProperties":false}"#,
            r#"{"type":"object","properties":{},"required":["missing"],"additionalProperties":false}"#,
        ];
        for value in invalid {
            assert!(CompiledSchema::compile(&record(value)).is_err(), "{value}");
        }
        for root in [
            r#"{"type":"null"}"#,
            r#"{"type":["object","null"],"properties":{},"required":[],"additionalProperties":false}"#,
        ] {
            assert!(CompiledSchema::compile(root).is_err(), "{root}");
        }
    }

    #[test]
    fn schema_paths_are_json_pointers() {
        let text = r#"{"type":"object","properties":{"a/b~c":{"type":"string","pattern":"a"}},"required":["a/b~c"],"additionalProperties":false}"#;
        match CompiledSchema::compile(text).unwrap_err() {
            RebirthError::Schema { schema_path, .. } => {
                assert_eq!(schema_path, "/properties/a~1b~0c/pattern")
            }
            other => panic!("unexpected error: {other:?}"),
        }
    }

    #[test]
    fn resource_limits_are_inclusive() {
        let mut nested = r#"{"type":"null"}"#.to_string();
        for _ in 1..SCHEMA_MAX_DEPTH {
            nested = record(&nested);
        }
        assert!(CompiledSchema::compile(&nested).is_ok());
        assert!(CompiledSchema::compile(&record(&nested)).is_err());
        let padded = format!(
            "{}{}",
            record(r#"{"type":"null"}"#),
            " ".repeat(SCHEMA_MAX_BYTES - record(r#"{"type":"null"}"#).len())
        );
        assert!(CompiledSchema::compile(&padded).is_ok());
        assert!(CompiledSchema::compile(&(padded + " ")).is_err());
        let text = compiled(r#"{"type":"string","maxLength":2048}"#);
        assert!(output(&text, &format!("\"{}\"", "😀".repeat(2048))).is_ok());
        assert!(output(&text, &format!("\"{}\"", "😀".repeat(2049))).is_err());
        assert!(
            text.grammar().len() < 12_000,
            "bounded strings need compact repetition rules"
        );
        let mut raw = b"{\"value\":\"a\"}".to_vec();
        raw.resize(OUTPUT_MAX_BYTES, b' ');
        assert!(text.validate(&raw).is_ok());
        raw.push(b' ');
        assert!(text.validate(&raw).is_err());
    }

    #[test]
    fn property_and_enum_resource_limits_are_checked() {
        fn many_properties(n: usize) -> String {
            let properties = (0..n)
                .map(|i| format!(r#""p{i}":{{"type":"null"}}"#))
                .collect::<Vec<_>>()
                .join(",");
            let required = (0..n)
                .map(|i| format!(r#""p{i}""#))
                .collect::<Vec<_>>()
                .join(",");
            format!(
                r#"{{"type":"object","properties":{{{properties}}},"required":[{required}],"additionalProperties":false}}"#
            )
        }
        assert!(CompiledSchema::compile(&many_properties(16)).is_ok());
        assert!(CompiledSchema::compile(&many_properties(17)).is_err());
        for (groups, per_group, expected) in [(4, 15, true), (5, 12, false)] {
            let properties = (0..groups)
                .map(|i| format!(r#""p{i}":{}"#, many_properties(per_group)))
                .collect::<Vec<_>>()
                .join(",");
            let required = (0..groups)
                .map(|i| format!(r#""p{i}""#))
                .collect::<Vec<_>>()
                .join(",");
            let schema = format!(
                r#"{{"type":"object","properties":{{{properties}}},"required":[{required}],"additionalProperties":false}}"#
            );
            assert_eq!(CompiledSchema::compile(&schema).is_ok(), expected);
        }
        let members = (0..32)
            .map(|i| format!(r#""{i}""#))
            .collect::<Vec<_>>()
            .join(",");
        assert!(CompiledSchema::compile(&record(&format!(
            r#"{{"type":"string","enum":[{members}]}}"#
        )))
        .is_ok());
        assert!(CompiledSchema::compile(&record(&format!(
            r#"{{"type":"string","enum":[{members},"extra"]}}"#
        )))
        .is_err());
        for (n, ok) in [(128, true), (129, false)] {
            let value = format!(r#"{{"type":"string","enum":["{}"]}}"#, "é".repeat(n));
            assert_eq!(CompiledSchema::compile(&record(&value)).is_ok(), ok);
        }
    }

    #[test]
    fn parser_and_grammar_allocation_limits_fail_cleanly() {
        let deep = format!("{}0{}", "[".repeat(10_000), "]".repeat(10_000));
        assert!(CompiledSchema::compile(&deep).is_err());
        let wide = format!("[{}]", vec!["0"; JSON_MAX_NODES].join(","));
        assert!(CompiledSchema::compile(&wide).is_err());

        // Valid profile within 64 KiB, but many distinct literal Unicode scalar
        // rules exceed the separate compiled-grammar budget. No giant buffer is
        // allocated before that check.
        let mut properties = Vec::new();
        let mut scalar = 0x1000;
        for i in 0..4 {
            let mut members = Vec::new();
            for _ in 0..32 {
                let member = (0..128)
                    .map(|_| {
                        let ch = char::from_u32(scalar).unwrap();
                        scalar += 1;
                        ch
                    })
                    .collect::<String>();
                members.push(serde_json::to_string(&member).unwrap());
            }
            properties.push(format!(
                r#""p{i}":{{"type":"string","enum":[{}]}}"#,
                members.join(",")
            ));
        }
        let large = format!(
            r#"{{"type":"object","properties":{{{}}},"required":["p0","p1","p2","p3"],"additionalProperties":false}}"#,
            properties.join(",")
        );
        assert!(large.len() < SCHEMA_MAX_BYTES);
        match CompiledSchema::compile(&large).unwrap_err() {
            RebirthError::Schema { reason, .. } => {
                assert!(reason.contains("grammar exceeds"), "{reason}")
            }
            other => panic!("unexpected error: {other:?}"),
        }
    }

    #[test]
    fn canonical_grammar_is_stable_when_schema_keys_reorder() {
        let first = r#"{"type":"object","properties":{"z":{"type":"boolean"},"a":{"type":"null"}},"required":["z","a"],"additionalProperties":false}"#;
        let second = r#"{"additionalProperties":false,"required":["a","z"],"properties":{"a":{"type":"null"},"z":{"type":"boolean"}},"type":"object"}"#;
        let a = CompiledSchema::compile(first).unwrap();
        let b = CompiledSchema::compile(second).unwrap();
        assert_eq!(a.grammar(), b.grammar());
        assert!(a.validate(br#"{"z":true,"a":null}"#).is_ok());
        assert!(a.validate(br#"{"a":null,"z":false}"#).is_ok());
        assert!(a.grammar().contains("root ::="));
    }

    #[test]
    fn frozen_pilot_labels_validate_against_the_frozen_schema() {
        let schema = CompiledSchema::compile(include_str!(
            "../../../../../tests/structured-output/output.schema.json"
        ))
        .unwrap();
        let cases: serde_json::Value = serde_json::from_str(include_str!(
            "../../../../../tests/structured-output/cases.json"
        ))
        .unwrap();
        let records = cases
            .as_array()
            .unwrap_or_else(|| cases["cases"].as_array().unwrap());
        assert_eq!(records.len(), 32);
        for record in records {
            let label = record
                .get("expected")
                .or_else(|| record.get("label"))
                .unwrap();
            schema
                .validate(&serde_json::to_vec(label).unwrap())
                .unwrap();
        }
    }
}
