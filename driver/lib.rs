//! The driver of the world-preview engine.
//!
//! It prepares a throwaway Fabric server folder with a pack's mods and the engine's mod, runs the
//! server, and the mod writes the maps' files into an out folder. It draws nothing.

pub mod args;
mod java;
mod pack;
mod process;
mod tectonic;
mod win;

use serde_json::Value;
use std::fmt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Instant, SystemTime};

use std::os::windows::process::CommandExt;

pub(crate) const CREATE_NO_WINDOW: u32 = 0x0800_0000;

/// A failure with a message a person can read as it is.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Error(String);

impl Error {
    pub fn new(message: impl Into<String>) -> Self {
        Self(message.into())
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for Error {}

pub type Result<T> = std::result::Result<T, Error>;

/// What one run needs. Folders that are left out take the script's defaults.
#[derive(Debug, Clone)]
pub struct Options {
    /// The engine's repository: where `mod/` and `run/` are.
    pub repo: PathBuf,
    /// A packwiz pack or a game folder; WORLD_PREVIEW_PACK when None.
    pub pack: Option<PathBuf>,
    /// Work folder of the throwaway server; `<repo>/run/preview` when None.
    pub dir: Option<PathBuf>,
    /// Where the result lands; `<dir>/out` when None.
    pub out: Option<PathBuf>,
    pub seed: String,
    /// Values replacing those of the pack's Tectonic config: a bool or a number each.
    pub tectonic: Vec<(String, Value)>,
    /// Grid points per side.
    pub samples: u32,
    /// Blocks between two grid points.
    pub step: u32,
    /// Blocks between two points of the map: step, 2 x step or 4 x step. Step when None.
    pub detail: Option<u32>,
    /// Jars added to the server for this run; WORLD_PREVIEW_MODS (semicolon-separated) when empty.
    pub mods: Vec<PathBuf>,
}

impl Options {
    pub fn new(repo: PathBuf) -> Self {
        Self {
            repo,
            pack: None,
            dir: None,
            out: None,
            seed: "cap-1".into(),
            tectonic: Vec::new(),
            samples: 512,
            step: 16,
            detail: None,
            mods: Vec::new(),
        }
    }
}

/// The first folder, from `start` up, that holds `mod/build.gradle`: the engine's repository.
pub fn find_repo_root(start: &Path) -> Option<PathBuf> {
    start.ancestors().find(|dir| dir.join("mod").join("build.gradle").is_file()).map(Path::to_path_buf)
}

pub(crate) fn absolute(path: &Path) -> Result<PathBuf> {
    std::path::absolute(path).map_err(|e| Error::new(format!("Bad path {}: {e}", path.display())))
}

/// Files of a folder whose name starts and ends so, whatever the case, as Windows globs do.
pub(crate) fn matching(dir: &Path, prefix: &str, suffix: &str) -> Vec<PathBuf> {
    let Ok(entries) = std::fs::read_dir(dir) else { return Vec::new() };
    entries
        .flatten()
        .filter(|e| {
            let name = e.file_name().to_string_lossy().to_lowercase();
            e.path().is_file() && name.starts_with(prefix) && name.ends_with(suffix)
        })
        .map(|e| e.path())
        .collect()
}

fn modified(path: &Path) -> Option<SystemTime> {
    std::fs::metadata(path).and_then(|m| m.modified()).ok()
}

fn newest_in(path: &Path, newest: &mut Option<SystemTime>) {
    if path.is_dir() {
        if let Ok(entries) = std::fs::read_dir(path) {
            for entry in entries.flatten() {
                newest_in(&entry.path(), newest);
            }
        }
    } else if let Some(time) = modified(path) {
        if newest.is_none_or(|n| time > n) {
            *newest = Some(time);
        }
    }
}

/// Java is looked for once, and only if a step needs it.
struct LazyJava(Option<PathBuf>);

impl LazyJava {
    fn get(&mut self) -> Result<PathBuf> {
        if self.0.is_none() {
            self.0 = Some(java::find_java()?);
        }
        Ok(self.0.clone().unwrap())
    }
}

fn newest_mod_jar(libs: &Path) -> Option<PathBuf> {
    matching(libs, "world-preview-", ".jar").into_iter().max_by_key(|p| modified(p))
}

/// The mod jar. A copy shipped without the sources, the jar built beforehand, takes it as it is.
/// Next to its sources, it is rebuilt when they are newer.
fn mod_jar(repo: &Path, java: &mut LazyJava, log: &mut dyn FnMut(&str)) -> Result<PathBuf> {
    let mod_root = repo.join("mod");
    let libs = mod_root.join("build").join("libs");
    let jar = newest_mod_jar(&libs);
    let sources = mod_root.join("src");
    if !sources.exists() {
        return jar.ok_or_else(|| {
            Error::new(format!("The world-preview mod is missing: no jar in {} and no sources to build it from.", libs.display()))
        });
    }
    let mut newest = None;
    newest_in(&sources, &mut newest);
    newest_in(&mod_root.join("build.gradle"), &mut newest);
    if let (Some(jar), Some(newest)) = (&jar, newest) {
        if modified(jar).is_some_and(|built| built >= newest) {
            return Ok(jar.clone());
        }
    }
    log("Building the world-preview mod");
    let java_home = java.get()?;
    let java_home = java_home.parent().and_then(Path::parent).map(Path::to_path_buf).unwrap_or_default();
    let output = Command::new(mod_root.join("gradlew.bat"))
        .args(["build", "--console=plain", "-q"])
        .current_dir(&mod_root)
        .env("JAVA_HOME", java_home)
        .stdin(Stdio::null())
        .creation_flags(CREATE_NO_WINDOW)
        .output()
        .map_err(|e| Error::new(format!("Could not start the Gradle build of the mod: {e}")))?;
    for line in String::from_utf8_lossy(&output.stdout).lines().chain(String::from_utf8_lossy(&output.stderr).lines()) {
        log(line);
    }
    if !output.status.success() {
        return Err(Error::new("The world-preview mod did not build."));
    }
    newest_mod_jar(&libs).ok_or_else(|| Error::new(format!("The build left no world-preview jar in {}.", libs.display())))
}

fn io_err(what: &str, path: &Path, e: std::io::Error) -> Error {
    Error::new(format!("Could not {what} {}: {e}", path.display()))
}

/// Lines the way Windows writes them, the form the script wrote.
fn write_lines(path: &Path, lines: &[String]) -> Result<()> {
    let text: String = lines.iter().map(|l| format!("{l}\r\n")).collect();
    std::fs::write(path, text).map_err(|e| io_err("write", path, e))
}

/// A file of the out folder is written beside its place and moved there in one go:
/// a reader must never see half of one.
fn write_whole(path: &Path, text: &str) -> Result<()> {
    let part = path.with_extension("json.part");
    std::fs::write(&part, text).map_err(|e| io_err("write", &part, e))?;
    std::fs::rename(&part, path).map_err(|e| io_err("move", path, e))
}

/// One run: prepares the server folder, runs the server, and returns the out folder.
/// `log` gets the progress lines.
pub fn run(options: &Options, log: &mut dyn FnMut(&str)) -> Result<PathBuf> {
    let repo = &options.repo;
    let pack = pack::resolve_pack(options.pack.as_deref())?;
    let dir = options.dir.clone().unwrap_or_else(|| repo.join("run").join("preview"));
    std::fs::create_dir_all(&dir).map_err(|e| io_err("create", &dir, e))?;
    let dir = absolute(&dir)?;
    // The mod writes where it is told, from the server's own folder: a relative path would land in the wrong place.
    let out = absolute(&options.out.clone().unwrap_or_else(|| dir.join("out")))?;
    let step = options.step;
    let detail = options.detail.filter(|d| *d != 0).unwrap_or(step);
    // The mod's sketches are one point in 2 and in 4 of the full grid: the map can stop at one of them only.
    if ![step, 2 * step, 4 * step].contains(&detail) {
        return Err(Error::new(format!("Detail must be {step}, {} or {} blocks.", 2 * step, 4 * step)));
    }

    // Checked first, before anything is downloaded into the folder: without it the server would not start.
    let eula = dir.join("eula.txt");
    let accepted = std::fs::read_to_string(&eula)
        .map(|text| regex::Regex::new(r"(?m)^eula=true").unwrap().is_match(&text))
        .unwrap_or(false);
    if !accepted {
        return Err(Error::new(format!(
            "EULA: the preview server needs the Minecraft EULA accepted in its own folder. Read https://aka.ms/MinecraftEULA, then write the line eula=true in {}",
            eula.display()
        )));
    }

    let mut java = LazyJava(None);
    // 1. The mod jar.
    let jar = mod_jar(repo, &mut java, log)?;

    // One run at a time on this machine: two runs in one folder would overwrite each other's config, and
    // two servers would ask for the same port. The second one waits.
    let lock = win::RunLock::acquire("world-preview-run")?;

    // 2. The throwaway server: launcher jar, then the pack's mods, synced again only when the pack changed.
    let launcher = pack::fabric_server_jar(&pack, &dir, repo, log)?;
    let stamp_file = dir.join(".pack-stamp");
    let stamp = pack::pack_stamp(&pack)?;
    if std::fs::read_to_string(&stamp_file).map(|s| s.trim() != stamp).unwrap_or(true) {
        pack::sync_pack(&pack, &dir, repo, &java.get()?, log)?;
        std::fs::write(&stamp_file, &stamp).map_err(|e| io_err("write", &stamp_file, e))?;
    }
    let mods_dir = dir.join("mods");
    for old in matching(&mods_dir, "world-preview-", ".jar") {
        let _ = std::fs::remove_file(old);
    }
    std::fs::copy(&jar, mods_dir.join(jar.file_name().unwrap())).map_err(|e| io_err("copy", &jar, e))?;
    // Distant Horizons does not take part in the generator's answers (the files come out byte for byte the
    // same without it), but it costs seconds at every start. It leaves this folder only: the pack keeps it,
    // and the next sync brings it back before this line takes it out again.
    for dh in matching(&mods_dir, "distanthorizons-", ".jar") {
        let _ = std::fs::remove_file(dh);
    }
    // The jars asked on top of the pack. Those of the run before leave first, by the names kept from it:
    // a mod that is no longer asked for must not stay in the server.
    let mods: Vec<PathBuf> = if options.mods.is_empty() {
        std::env::var("WORLD_PREVIEW_MODS")
            .unwrap_or_default()
            .split(';')
            .filter(|m| !m.is_empty())
            .map(PathBuf::from)
            .collect()
    } else {
        options.mods.clone()
    };
    let added_file = dir.join(".added-mods");
    if let Ok(previous) = std::fs::read_to_string(&added_file) {
        for name in previous.lines().filter(|n| !n.is_empty()) {
            let _ = std::fs::remove_file(mods_dir.join(name));
        }
    }
    let mut names = Vec::new();
    for extra in &mods {
        if !extra.exists() {
            return Err(Error::new(format!("The mod to add was not found: {}", extra.display())));
        }
        let name = extra.file_name().unwrap();
        std::fs::copy(extra, mods_dir.join(name)).map_err(|e| io_err("copy", extra, e))?;
        names.push(name.to_string_lossy().into_owned());
    }
    write_lines(&added_file, &names)?;

    // 3. The Tectonic config for this run: the pack's file, with the asked values replaced.
    let source = pack.join("config").join("tectonic.json");
    let config = std::fs::read_to_string(&source).map_err(|e| io_err("read", &source, e))?;
    let config = tectonic::rewrite(config.trim_start_matches('\u{feff}'), &options.tectonic)?;
    let config_dir = dir.join("config");
    std::fs::create_dir_all(&config_dir).map_err(|e| io_err("create", &config_dir, e))?;
    let target = config_dir.join("tectonic.json");
    std::fs::write(&target, config).map_err(|e| io_err("write", &target, e))?;

    // 4. A server nobody joins: local only, its own port, one small world folder per seed.
    let world: String = std::iter::once("seed-".to_string())
        .chain(options.seed.chars().map(|c| if c.is_ascii_alphanumeric() || c == '_' || c == '-' { c } else { '_' }).map(String::from))
        .collect();
    // Written as UTF-8 without a mark at its head, whatever the shell: the server reads it so.
    write_lines(
        &dir.join("server.properties"),
        &[
            "motd=World preview".into(),
            format!("level-seed={}", options.seed),
            format!("level-name={world}"),
            "server-ip=127.0.0.1".into(),
            "server-port=25599".into(),
            "enable-rcon=false".into(),
            "view-distance=2".into(),
            "simulation-distance=2".into(),
            // The sampling runs inside one tick. A wide grid takes more than the minute after which the
            // watchdog calls a server crashed and kills it, so the watchdog is off here.
            "max-tick-time=-1".into(),
        ],
    )?;

    // 5. Run. The mod stops the server itself once the files are written.
    for name in ["preview.json", "coarse.json", "section.json", "ores.json", "structures.json", "timing.json", "progress.json", "partial.json"] {
        let _ = std::fs::remove_file(out.join(name));
    }
    for (prefix, suffix) in [("coarse-", ".bin"), ("section-", ".bin"), ("partial-", ".bin")] {
        for old in matching(&out, prefix, suffix) {
            let _ = std::fs::remove_file(old);
        }
    }
    let started = Instant::now();
    let log_file = dir.join("last-run.log");
    let args: Vec<String> = vec![
        "-Xmx4G".into(),
        "-XX:+UseZGC".into(),
        format!("-Dworldpreview.out={}", out.display()),
        format!("-Dworldpreview.samples={}", options.samples),
        format!("-Dworldpreview.step={step}"),
        format!("-Dworldpreview.detail={detail}"),
        "-jar".into(),
        launcher.to_string_lossy().into_owned(),
        "nogui".into(),
    ];
    process::run_java(&java.get()?, &dir, &log_file, &args, true)?;
    if !out.join("preview.json").exists() {
        return Err(Error::new(format!("The preview server ended without a result. See {}", log_file.display())));
    }
    drop(lock);

    std::fs::create_dir_all(&out).map_err(|e| io_err("create", &out, e))?;
    write_whole(&out.join("run.json"), &tectonic::run_record(&options.seed, &options.tectonic))?;
    log(&format!("Preview ready in {} ({} s)", out.display(), started.elapsed().as_secs()));
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_repository_is_the_first_folder_holding_the_mod() {
        let root = std::env::temp_dir().join(format!("world-preview-test-{}-repo", std::process::id()));
        let deep = root.join("driver").join("target").join("release");
        std::fs::create_dir_all(&deep).unwrap();
        std::fs::create_dir_all(root.join("mod")).unwrap();
        std::fs::write(root.join("mod").join("build.gradle"), "").unwrap();
        assert_eq!(find_repo_root(&deep), Some(root.clone()));
        assert_eq!(find_repo_root(&root.join("mod").join("none")), Some(root));
    }

    #[test]
    fn the_detail_must_be_one_of_the_sketches() {
        let base = std::env::temp_dir().join(format!("world-preview-test-{}-detail", std::process::id()));
        let pack = base.join("pack");
        std::fs::create_dir_all(pack.join("mods")).unwrap();
        std::fs::create_dir_all(pack.join("config")).unwrap();
        std::fs::write(pack.join("config").join("tectonic.json"), "{}").unwrap();
        let mut options = Options::new(base.clone());
        options.pack = Some(pack);
        options.dir = Some(base.join("work"));
        options.detail = Some(24);
        let err = run(&options, &mut |_| {}).unwrap_err();
        assert_eq!(err.to_string(), "Detail must be 16, 32 or 64 blocks.");
        // A valid detail goes on to the next check, the EULA, which is not accepted in a fresh folder.
        options.detail = Some(32);
        assert!(run(&options, &mut |_| {}).unwrap_err().to_string().starts_with("EULA:"));
    }
}