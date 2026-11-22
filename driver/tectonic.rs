//! The values a run replaces in the pack's Tectonic config, and the record kept of them.

use crate::{Error, Result};
use regex::{Captures, Regex};
use serde_json::{Map, Value};

/// A Tectonic value as it is written into the config: a switch or a number.
fn render(key: &str, value: &Value) -> Result<String> {
    match value {
        Value::Bool(b) => Ok(b.to_string()),
        // Rust writes a float in the shortest form that reads back the same, never with a comma.
        Value::Number(n) => Ok(n.as_f64().unwrap_or_default().to_string()),
        _ => Err(Error::new(format!("The Tectonic value of {key} must be true, false or a number."))),
    }
}

/// The pack's config with the asked values replaced, key by key, everywhere the key appears.
pub fn rewrite(config: &str, values: &[(String, Value)]) -> Result<String> {
    let mut config = config.to_string();
    for (key, value) in values {
        let text = render(key, value)?;
        let pattern = Regex::new(&format!(r#"("{}":\s*)(-?[0-9.eE+-]+|true|false)"#, regex::escape(key))).unwrap();
        if !pattern.is_match(&config) {
            return Err(Error::new(format!("Unknown Tectonic key: {key}")));
        }
        config = pattern.replace_all(&config, |m: &Captures| format!("{}{}", &m[1], text)).into_owned();
    }
    Ok(config)
}

/// What this preview was made with, so a caller can show the same seed and values next to the map.
/// A switch is kept as 1 or 0, the form a caller's controls take.
pub fn run_record(seed: &str, values: &[(String, Value)]) -> String {
    let mut tectonic = Map::new();
    for (key, value) in values {
        let kept = match value {
            Value::Bool(b) => Value::from(*b as i32),
            other => other.clone(),
        };
        tectonic.insert(key.clone(), kept);
    }
    let mut record = Map::new();
    record.insert("seed".into(), Value::from(seed));
    record.insert("tectonic".into(), Value::Object(tectonic));
    serde_json::to_string_pretty(&Value::Object(record)).unwrap()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const CONFIG: &str = "{\n  \"vertical_scale\": 1.0,\n  \"ocean_offset\": -0.8,\n  \"cave\": true,\n  \"sea_level\": 63\n}";

    fn one(key: &str, value: Value) -> Vec<(String, Value)> {
        vec![(key.to_string(), value)]
    }

    #[test]
    fn replaces_a_decimal_and_keeps_the_rest() {
        let out = rewrite(CONFIG, &one("vertical_scale", json!(1.2))).unwrap();
        assert!(out.contains("\"vertical_scale\": 1.2,"));
        assert!(out.contains("\"ocean_offset\": -0.8"));
    }

    #[test]
    fn a_switch_is_written_as_a_word() {
        let out = rewrite(CONFIG, &one("cave", json!(false))).unwrap();
        assert!(out.contains("\"cave\": false"));
    }

    #[test]
    fn an_integer_stays_without_a_dot_and_a_number_may_replace_a_switch() {
        let out = rewrite(CONFIG, &one("sea_level", json!(70))).unwrap();
        assert!(out.contains("\"sea_level\": 70\n"));
        let out = rewrite(CONFIG, &one("cave", json!(0))).unwrap();
        assert!(out.contains("\"cave\": 0,"));
    }

    #[test]
    fn replaces_every_match() {
        let twice = "{\"a\": 1, \"b\": {\"a\": 2}}";
        assert_eq!(rewrite(twice, &one("a", json!(5))).unwrap(), "{\"a\": 5, \"b\": {\"a\": 5}}");
    }

    #[test]
    fn an_unknown_key_is_an_error() {
        let err = rewrite(CONFIG, &one("nope", json!(1))).unwrap_err();
        assert_eq!(err.to_string(), "Unknown Tectonic key: nope");
    }

    #[test]
    fn the_record_keeps_switches_as_numbers() {
        let values = vec![("cave".to_string(), json!(true)), ("sea_level".to_string(), json!(70)), ("v".to_string(), json!(1.2))];
        let record: Value = serde_json::from_str(&run_record("cap-1", &values)).unwrap();
        assert_eq!(record, json!({"seed": "cap-1", "tectonic": {"cave": 1, "sea_level": 70, "v": 1.2}}));
    }
}
