//! The command line of the driver: hand-parsed, because it is a dozen flags.

use crate::{Error, Options, Result};
use serde_json::Value;
use std::path::PathBuf;

pub const USAGE: &str = "\
Usage: world-preview [options]

  --pack <folder>         a packwiz pack or a game folder (WORLD_PREVIEW_PACK when omitted)
  --dir <folder>          work folder of the throwaway server (<repo>/run/preview when omitted)
  --out <folder>          where the result lands (<dir>/out when omitted)
  --seed <text>           world seed as typed in the game (default cap-1)
  --samples <n>           grid points per side (default 512)
  --step <n>              blocks between two grid points (default 16)
  --detail <n>            blocks between two points of the map: step, 2 x step or 4 x step
  --tectonic <key=value>  replaces a Tectonic config value for this run; true, false or a number; repeatable
  --mod <jar>             a jar added to the server for this run; repeatable (WORLD_PREVIEW_MODS when omitted)
  --repo <folder>         the engine's repository, when it is not found from the executable
  --help                  this text";

/// What the command line asked for. `repo` stays empty when no flag named it.
pub enum Parsed {
    Help,
    Run { options: Options, repo: Option<PathBuf> },
}

/// A Tectonic value: a switch, or a number that stays an integer when typed without a dot.
pub fn tectonic_value(text: &str) -> Result<Value> {
    match text {
        "true" => return Ok(Value::Bool(true)),
        "false" => return Ok(Value::Bool(false)),
        _ => {}
    }
    if let Ok(n) = text.parse::<i64>() {
        return Ok(Value::from(n));
    }
    match text.parse::<f64>() {
        Ok(n) if n.is_finite() => Ok(Value::from(n)),
        _ => Err(Error::new(format!("A Tectonic value is true, false or a number, not '{text}'."))),
    }
}

pub fn parse(args: impl IntoIterator<Item = String>) -> Result<Parsed> {
    let mut options = Options::new(PathBuf::new());
    let mut repo = None;
    let mut args = args.into_iter();
    while let Some(flag) = args.next() {
        if flag == "--help" || flag == "-h" {
            return Ok(Parsed::Help);
        }
        let mut value = || args.next().ok_or_else(|| Error::new(format!("{flag} needs a value.")));
        let number = |text: String| {
            text.parse::<u32>()
                .map_err(|_| Error::new(format!("{flag} needs a whole number, not '{text}'.")))
        };
        match flag.as_str() {
            "--pack" => options.pack = Some(value()?.into()),
            "--dir" => options.dir = Some(value()?.into()),
            "--out" => options.out = Some(value()?.into()),
            "--repo" => repo = Some(value()?.into()),
            "--seed" => options.seed = value()?,
            "--samples" => options.samples = number(value()?)?,
            "--step" => options.step = number(value()?)?,
            "--detail" => options.detail = Some(number(value()?)?),
            "--mod" => options.mods.push(value()?.into()),
            "--tectonic" => {
                let pair = value()?;
                let Some((key, text)) = pair.split_once('=') else {
                    return Err(Error::new(format!("--tectonic needs key=value, not '{pair}'.")));
                };
                options.tectonic.push((key.to_string(), tectonic_value(text)?));
            }
            other => return Err(Error::new(format!("Unknown option: {other}. See --help."))),
        }
    }
    Ok(Parsed::Run { options, repo })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn parse_strs(args: &[&str]) -> Result<Parsed> {
        parse(args.iter().map(|s| s.to_string()))
    }

    #[test]
    fn defaults_are_the_scripts() {
        let Ok(Parsed::Run { options, repo }) = parse_strs(&[]) else { panic!() };
        assert_eq!((options.seed.as_str(), options.samples, options.step), ("cap-1", 512, 16));
        assert!(options.pack.is_none() && options.detail.is_none() && repo.is_none());
    }

    #[test]
    fn every_flag_is_read() {
        let Ok(Parsed::Run { options, repo }) = parse_strs(&[
            "--pack", "p", "--dir", "d", "--out", "o", "--seed", "abc", "--samples", "256", "--step", "8", "--detail", "16",
            "--tectonic", "vertical_scale=1.2", "--tectonic", "cave=false", "--tectonic", "sea=70", "--mod", "a.jar",
            "--mod", "b.jar", "--repo", "r",
        ]) else { panic!() };
        assert_eq!(options.pack, Some("p".into()));
        assert_eq!((options.samples, options.step, options.detail), (256, 8, Some(16)));
        assert_eq!(options.mods.len(), 2);
        assert_eq!(repo, Some("r".into()));
        assert_eq!(
            options.tectonic,
            vec![("vertical_scale".to_string(), json!(1.2)), ("cave".to_string(), json!(false)), ("sea".to_string(), json!(70))]
        );
    }

    #[test]
    fn bad_input_is_an_error() {
        assert!(parse_strs(&["--bogus"]).is_err());
        assert!(parse_strs(&["--seed"]).is_err());
        assert!(parse_strs(&["--samples", "many"]).is_err());
        assert!(parse_strs(&["--tectonic", "novalue"]).is_err());
        assert!(parse_strs(&["--tectonic", "k=maybe"]).is_err());
    }

    #[test]
    fn a_number_without_a_dot_is_an_integer() {
        assert!(tectonic_value("2").unwrap().is_i64());
        assert!(tectonic_value("2.0").unwrap().is_f64());
        assert_eq!(tectonic_value("true").unwrap(), json!(true));
    }

    #[test]
    fn help_is_recognised() {
        assert!(matches!(parse_strs(&["--help"]), Ok(Parsed::Help)));
    }
}
