//! Finding a Java the game can run on.

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::os::windows::process::CommandExt;

use crate::{CREATE_NO_WINDOW, Error, Result};

/// True when the version line `java -version` prints says 25 or newer.
pub fn version_is_enough(text: &str) -> bool {
    regex::Regex::new(r#"version "(\d+)"#)
        .unwrap()
        .captures(text)
        .and_then(|c| c[1].parse::<u32>().ok())
        .is_some_and(|major| major >= 25)
}

fn test_java(exe: &Path) -> bool {
    if !exe.is_file() {
        return false;
    }
    // java prints its version on the error stream.
    let Ok(output) = Command::new(exe)
        .arg("-version")
        .stdin(Stdio::null())
        .creation_flags(CREATE_NO_WINDOW)
        .output()
    else {
        return false;
    };
    let text = format!("{}{}", String::from_utf8_lossy(&output.stdout), String::from_utf8_lossy(&output.stderr));
    version_is_enough(&text)
}

/// The user-level JAVA_HOME covers a shell opened before Java was installed.
fn user_java_home() -> Option<String> {
    let output = Command::new("reg")
        .args(["query", r"HKCU\Environment", "/v", "JAVA_HOME"])
        .creation_flags(CREATE_NO_WINDOW)
        .output()
        .ok()?;
    let text = String::from_utf8_lossy(&output.stdout);
    let line = text.lines().find(|l| l.trim_start().starts_with("JAVA_HOME"))?;
    // The line reads: JAVA_HOME    REG_SZ    <value>
    for tag in ["REG_EXPAND_SZ", "REG_SZ"] {
        if let Some(at) = line.find(tag) {
            let value = line[at + tag.len()..].trim();
            return (!value.is_empty()).then(|| value.to_string());
        }
    }
    None
}

fn find_in(root: &Path, found: &mut Option<PathBuf>) {
    let Ok(entries) = std::fs::read_dir(root) else { return };
    for entry in entries.flatten() {
        if found.is_some() {
            return;
        }
        let path = entry.path();
        if path.is_dir() {
            find_in(&path, found);
        } else if entry.file_name().to_string_lossy().eq_ignore_ascii_case("java.exe") && test_java(&path) {
            *found = Some(path);
        }
    }
}

pub fn find_java() -> Result<PathBuf> {
    // JAVA_HOME first, then PATH.
    let mut candidates: Vec<PathBuf> = Vec::new();
    for home in [std::env::var("JAVA_HOME").ok(), user_java_home()].into_iter().flatten() {
        if !home.is_empty() {
            candidates.push(Path::new(&home).join("bin").join("java.exe"));
        }
    }
    if let Some(path) = std::env::var_os("PATH") {
        candidates.extend(std::env::split_paths(&path).map(|dir| dir.join("java.exe")));
    }
    if let Some(java) = candidates.into_iter().find(|c| test_java(c)) {
        return Ok(java);
    }
    // Whoever has played Minecraft 26 already has the right Java: each launcher downloads its own and
    // keeps it in a folder of its own, off the PATH.
    let var = |name: &str| std::env::var(name).unwrap_or_default();
    let roots = [
        format!(r"{}\Packages\Microsoft.4297127D64EC6_8wekyb3d8bbwe\LocalCache\Local\runtime", var("LOCALAPPDATA")),
        format!(r"{}\.minecraft\runtime", var("APPDATA")),
        format!(r"{}\Minecraft Launcher\runtime", var("ProgramFiles(x86)")),
        format!(r"{}\PrismLauncher\java", var("APPDATA")),
        format!(r"{}\ModrinthApp\meta\java_versions", var("APPDATA")),
        format!(r"{}\curseforge\minecraft\Install\runtime", var("USERPROFILE")),
    ];
    for root in roots {
        let mut found = None;
        find_in(Path::new(&root), &mut found);
        if let Some(java) = found {
            return Ok(java);
        }
    }
    Err(Error::new(
        "Java 25 or newer was not found. Start Minecraft 26 once from its launcher, which downloads its own Java, or install Java 25 from https://adoptium.net",
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn version_line_is_read() {
        assert!(version_is_enough("openjdk version \"25.0.1\" 2025-10-21"));
        assert!(version_is_enough("java version \"26\" 2026-03-17"));
        assert!(!version_is_enough("openjdk version \"21.0.4\" 2024-07-16"));
        assert!(!version_is_enough("java version \"1.8.0_401\""));
        assert!(!version_is_enough("nothing useful"));
    }
}
