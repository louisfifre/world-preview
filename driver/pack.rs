//! The pack: where its mods are, what version of the game it wants, and putting it in the server's folder.

use crate::process::{download, get_text, run_java};
use crate::{Error, Result, absolute, matching};
use regex::Regex;
use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};
use std::time::SystemTime;

const BOOTSTRAP_URL: &str =
    "https://github.com/packwiz/packwiz-installer-bootstrap/releases/download/v0.0.3/packwiz-installer-bootstrap.jar";

pub fn is_packwiz(pack: &Path) -> bool {
    pack.join("pack.toml").exists()
}

/// The pack is the one input with no sensible default: the argument first, then WORLD_PREVIEW_PACK.
/// It is either a packwiz pack (pack.toml) or a plain game folder (mods and config), the one a launcher plays from.
pub fn resolve_pack(pack: Option<&Path>) -> Result<PathBuf> {
    let from_env = std::env::var_os("WORLD_PREVIEW_PACK").filter(|v| !v.is_empty()).map(PathBuf::from);
    let Some(pack) = pack.map(Path::to_path_buf).filter(|p| !p.as_os_str().is_empty()).or(from_env) else {
        return Err(Error::new("No pack given. Pass -Pack <a game folder or a packwiz pack>, or set WORLD_PREVIEW_PACK."));
    };
    if !pack.is_dir() {
        return Err(Error::new(format!("No such folder: {}", pack.display())));
    }
    let pack = absolute(&pack)?;
    // A launcher's instance keeps its game folder one level down, and the instance is the folder people find first.
    let found = [pack.clone(), pack.join("minecraft"), pack.join(".minecraft")]
        .into_iter()
        .find(|f| f.join("pack.toml").exists() || f.join("mods").exists());
    let Some(found) = found else {
        return Err(Error::new(format!(
            "No mods folder and no pack.toml in {}. Choose the game folder, the one that holds mods and config.",
            pack.display()
        )));
    };
    if !found.join("config").join("tectonic.json").exists() {
        return Err(Error::new(format!(
            "No config\\tectonic.json in {}. A run's values are Tectonic's: the mods must include Tectonic, and the game must have started once with it so that its config exists.",
            found.display()
        )));
    }
    Ok(found)
}

/// Minecraft and Fabric loader versions in a text, as pack.toml or gradle.properties write them.
pub fn read_versions(text: &str) -> Option<(String, String)> {
    let find = |pattern: &str| {
        Regex::new(pattern).unwrap().captures(text).map(|c| c[1].to_string()).filter(|v| !v.is_empty())
    };
    let mc = find(r#"(?m)^\s*minecraft(?:_version)?\s*=\s*"?([^"\s]+)"#)?;
    let loader = find(r#"(?m)^\s*(?:fabric|loader_version)\s*=\s*"?([^"\s]+)"#)?;
    Some((mc, loader))
}

/// The Fabric server launcher, downloaded once per folder. A packwiz pack names its versions; a game
/// folder does not, so it gets those the mod is built for, the only game version the mod runs on anyway.
pub fn fabric_server_jar(pack: &Path, dir: &Path, repo: &Path, log: &mut dyn FnMut(&str)) -> Result<PathBuf> {
    let file = if is_packwiz(pack) { pack.join("pack.toml") } else { repo.join("mod").join("gradle.properties") };
    let text = std::fs::read_to_string(&file).map_err(|e| Error::new(format!("Could not read {}: {e}", file.display())))?;
    let Some((mc, loader)) = read_versions(&text) else {
        return Err(Error::new(format!(
            "No Minecraft and Fabric loader versions in {} : the preview mod is a Fabric mod.",
            file.display()
        )));
    };
    let jar = dir.join(format!("fabric-server-{mc}-{loader}.jar"));
    if !jar.exists() {
        let installers: serde_json::Value = serde_json::from_str(&get_text("https://meta.fabricmc.net/v2/versions/installer")?)
            .map_err(|e| Error::new(format!("Fabric's installer list is not readable: {e}")))?;
        let installer = installers
            .as_array()
            .into_iter()
            .flatten()
            .find(|v| v["stable"].as_bool() == Some(true))
            .and_then(|v| v["version"].as_str())
            .ok_or_else(|| Error::new("Fabric lists no stable installer."))?;
        let url = format!("https://meta.fabricmc.net/v2/versions/loader/{mc}/{loader}/{installer}/server/jar");
        log(&format!("Downloading Fabric server launcher from {url}"));
        download(&url, &jar)?;
    }
    Ok(jar)
}

fn bootstrap(repo: &Path, log: &mut dyn FnMut(&str)) -> Result<PathBuf> {
    let tools = repo.join("run").join("tools");
    let jar = tools.join("packwiz-installer-bootstrap.jar");
    if !jar.exists() {
        std::fs::create_dir_all(&tools).map_err(|e| Error::new(format!("Could not create {}: {e}", tools.display())))?;
        log(&format!("Downloading packwiz-installer-bootstrap from {BOOTSTRAP_URL}"));
        download(BOOTSTRAP_URL, &jar)?;
    }
    Ok(jar)
}

fn sha256_hex(path: &Path) -> Result<String> {
    let bytes = std::fs::read(path).map_err(|e| Error::new(format!("Could not read {}: {e}", path.display())))?;
    Ok(Sha256::digest(bytes).iter().map(|b| format!("{b:02X}")).collect())
}

/// Changes when the pack's mods do, so the work folder is filled again only then.
pub fn pack_stamp(pack: &Path) -> Result<String> {
    if is_packwiz(pack) {
        return Ok(sha256_hex(&pack.join("pack.toml"))? + &sha256_hex(&pack.join("index.toml"))?);
    }
    let mut jars = matching(&pack.join("mods"), "", ".jar");
    jars.sort_by_key(|p| p.file_name().unwrap().to_string_lossy().to_lowercase());
    let parts: Vec<String> = jars
        .iter()
        .map(|jar| {
            let meta = std::fs::metadata(jar).map_err(|e| Error::new(format!("Could not read {}: {e}", jar.display())))?;
            let ticks = meta
                .modified()
                .ok()
                .and_then(|t| t.duration_since(SystemTime::UNIX_EPOCH).ok())
                // Ticks of 100 ns since year 1, the unit the script's stamp was written in.
                .map(|d| d.as_nanos() / 100 + 621_355_968_000_000_000)
                .unwrap_or(0);
            Ok(format!("{}:{}:{}", jar.file_name().unwrap().to_string_lossy(), meta.len(), ticks))
        })
        .collect::<Result<_>>()?;
    Ok(format!("{}|{}", pack.display(), parts.join("|")))
}

/// `file:///D:/a%20b/pack.toml`, the form packwiz-installer takes.
fn file_uri(path: &Path) -> String {
    let mut uri = String::from("file:///");
    for byte in path.to_string_lossy().replace('\\', "/").bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' | b'/' | b':' => uri.push(byte as char),
            _ => uri.push_str(&format!("%{byte:02X}")),
        }
    }
    uri
}

fn copy_dir(from: &Path, to: &Path) -> Result<()> {
    let fail = |e: std::io::Error| Error::new(format!("Could not copy {}: {e}", from.display()));
    std::fs::create_dir_all(to).map_err(fail)?;
    for entry in std::fs::read_dir(from).map_err(fail)? {
        let entry = entry.map_err(fail)?;
        let target = to.join(entry.file_name());
        if entry.path().is_dir() {
            copy_dir(&entry.path(), &target)?;
        } else {
            std::fs::copy(entry.path(), &target).map_err(fail)?;
        }
    }
    Ok(())
}

/// Puts the pack's mods and config into the throwaway server's folder.
pub fn sync_pack(pack: &Path, target: &Path, repo: &Path, java: &Path, log: &mut dyn FnMut(&str)) -> Result<()> {
    let mods = target.join("mods");
    std::fs::create_dir_all(&mods).map_err(|e| Error::new(format!("Could not create {}: {e}", mods.display())))?;
    if is_packwiz(pack) {
        // The server side of the pack only: the throwaway server is a dedicated server. packwiz-installer
        // reads the pack straight from the disk, so the packwiz tool itself is not needed.
        let sync_log = target.join("last-sync.log");
        let args: Vec<String> = [
            "-jar".to_string(),
            bootstrap(repo, log)?.to_string_lossy().into_owned(),
            "-g".into(),
            "-s".into(),
            "server".into(),
            file_uri(&pack.join("pack.toml")),
        ]
        .into();
        let code = run_java(java, target, &sync_log, &args, false, None)?;
        if code != 0 {
            return Err(Error::new(format!(
                "The pack's mods could not be installed (packwiz-installer, code {code}). See {}. A pack edited by hand needs 'packwiz refresh' first, so that its index matches its files.",
                sync_log.display()
            )));
        }
        return Ok(());
    }
    // A game folder: the same jars and the same config as the game. Fabric leaves a mod made for the
    // client alone on a server, as long as the mod says so.
    let fail = |e: std::io::Error| Error::new(format!("Could not copy the game folder's mods: {e}"));
    for old in matching(&mods, "", ".jar") {
        std::fs::remove_file(old).map_err(fail)?;
    }
    for jar in matching(&pack.join("mods"), "", ".jar") {
        std::fs::copy(&jar, mods.join(jar.file_name().unwrap())).map_err(fail)?;
    }
    copy_dir(&pack.join("config"), &target.join("config"))
}

#[cfg(test)]
mod tests {
    use super::*;

    pub fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("world-preview-test-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn touch(path: &Path) {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, "x").unwrap();
    }

    #[test]
    fn versions_come_from_pack_toml_and_gradle_properties() {
        let toml = "name = \"P\"\n[versions]\nfabric = \"0.20.1\"\nminecraft = \"26.3\"\n";
        assert_eq!(read_versions(toml), Some(("26.3".into(), "0.20.1".into())));
        let props = "minecraft_version=26.3\nloader_version=0.20.1\nloom_version=1.19-SNAPSHOT\n";
        assert_eq!(read_versions(props), Some(("26.3".into(), "0.20.1".into())));
        assert_eq!(read_versions("nothing"), None);
    }

    #[test]
    fn a_game_folder_is_found_directly_or_one_level_down() {
        let root = scratch("pack");
        touch(&root.join(".minecraft").join("mods").join("a.jar"));
        let err = resolve_pack(Some(&root)).unwrap_err().to_string();
        assert!(err.starts_with("No config\\tectonic.json in "), "{err}");
        touch(&root.join(".minecraft").join("config").join("tectonic.json"));
        assert_eq!(resolve_pack(Some(&root)).unwrap(), root.join(".minecraft"));
    }

    #[test]
    fn a_folder_without_mods_or_pack_toml_is_refused() {
        let root = scratch("empty");
        let err = resolve_pack(Some(&root)).unwrap_err().to_string();
        assert!(err.starts_with("No mods folder and no pack.toml in "), "{err}");
        let err = resolve_pack(Some(&root.join("missing"))).unwrap_err().to_string();
        assert!(err.starts_with("No such folder: "), "{err}");
    }

    #[test]
    fn a_packwiz_pack_is_taken_as_it_is() {
        let root = scratch("packwiz");
        touch(&root.join("pack.toml"));
        touch(&root.join("config").join("tectonic.json"));
        assert_eq!(resolve_pack(Some(&root)).unwrap(), root);
        assert!(is_packwiz(&root));
    }

    #[test]
    fn the_uri_escapes_what_a_url_cannot_hold() {
        assert_eq!(file_uri(Path::new(r"D:\a b\pack.toml")), "file:///D:/a%20b/pack.toml");
    }

    #[test]
    fn the_stamp_of_a_game_folder_follows_its_jars() {
        let root = scratch("stamp");
        touch(&root.join("mods").join("b.jar"));
        let first = pack_stamp(&root).unwrap();
        touch(&root.join("mods").join("a.jar"));
        assert_ne!(first, pack_stamp(&root).unwrap());
    }
}
