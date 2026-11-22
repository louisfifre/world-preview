//! Child processes: java for a run or for the pack sync, and the downloads.

use crate::win::KillOnCloseJob;
use crate::{CREATE_NO_WINDOW, Error, Result, STOPPED};
use std::fs::File;
use std::io;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;
use std::os::windows::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

const BELOW_NORMAL_PRIORITY_CLASS: u32 = 0x0000_4000;

/// Runs java in a folder: its output goes to `log` and its errors to a second file beside it, and the
/// exit code comes back. In a file, because a pipe nobody reads would stall a chatty server.
/// The process is tied to this program: if the program dies, so does java.
/// `background` runs it below the normal priority: a long computation steps aside, or Windows would
/// serve it before the window the person is looking at.
/// `stop`, once set, ends java and makes this an error: a caller that holds the driver as a library has no
/// process of the driver's to kill, only this flag.
pub fn run_java(java: &Path, work_dir: &Path, log: &Path, args: &[String], background: bool, stop: Option<&AtomicBool>) -> Result<i32> {
    let mut command = Command::new(java);
    command.args(args);
    run_logged(command, work_dir, log, background, stop)
}

/// Runs any program the way `run_java` runs java: same log files, same job object, same stop flag.
/// The Gradle build of the mod goes through it too, so that a stop reaches it and what it started
/// (the job ends every process it holds, not only the first).
pub fn run_logged(mut command: Command, work_dir: &Path, log: &Path, background: bool, stop: Option<&AtomicBool>) -> Result<i32> {
    let errors = log.with_extension("errors.log");
    let open = |path: &Path| File::create(path).map_err(|e| Error::new(format!("Could not write {}: {e}", path.display())));
    let program = PathBuf::from(command.get_program());
    command
        .current_dir(work_dir)
        .stdin(Stdio::null())
        .stdout(open(log)?)
        .stderr(open(&errors)?)
        .creation_flags(CREATE_NO_WINDOW | if background { BELOW_NORMAL_PRIORITY_CLASS } else { 0 });
    let job = KillOnCloseJob::new()?;
    let mut child = command.spawn().map_err(|e| Error::new(format!("Could not start {}: {e}", program.display())))?;
    job.add(&child)?;
    let lost = |e: io::Error| Error::new(format!("Lost the {} process: {e}", program.display()));
    loop {
        if let Some(status) = child.try_wait().map_err(lost)? {
            return Ok(status.code().unwrap_or(-1));
        }
        if stop.is_some_and(|s| s.load(Ordering::Relaxed)) {
            let _ = child.kill();
            let _ = child.wait();
            return Err(Error::new(STOPPED));
        }
        std::thread::sleep(Duration::from_millis(100));
    }
}
/// A file from the web, written beside its place and moved there in one go, so a run cut short never
/// leaves half a jar that the next run would take for a whole one.
pub fn download(url: &str, dest: &Path) -> Result<()> {
    let fail = |e: &dyn std::fmt::Display| Error::new(format!("Could not download {url}: {e}"));
    let mut response = ureq::get(url).call().map_err(|e| fail(&e))?;
    let part = dest.with_extension("part");
    {
        let mut file = File::create(&part).map_err(|e| fail(&e))?;
        io::copy(&mut response.body_mut().as_reader(), &mut file).map_err(|e| fail(&e))?;
    }
    std::fs::rename(&part, dest).map_err(|e| fail(&e))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;
    use std::time::Instant;

    #[test]
    fn a_stop_ends_the_process_and_says_so() {
        let dir = std::env::temp_dir().join(format!("world-preview-test-{}-stop", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let stop = Arc::new(AtomicBool::new(false));
        let flag = stop.clone();
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(300));
            flag.store(true, Ordering::Relaxed);
        });
        let started = Instant::now();
        // Any long program stands for java: ping waits about 30 s.
        let args: Vec<String> = ["/c", "ping", "-n", "30", "127.0.0.1"].map(String::from).into();
        let result = run_java(Path::new("cmd.exe"), &dir, &dir.join("stop.log"), &args, false, Some(&stop));
        assert_eq!(result.unwrap_err().to_string(), STOPPED);
        assert!(started.elapsed() < Duration::from_secs(5), "the stop took {:?}", started.elapsed());
    }

    #[test]
    fn a_program_that_is_not_java_keeps_its_code_and_obeys_a_stop() {
        let dir = std::env::temp_dir().join(format!("world-preview-test-{}-logged", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let mut command = Command::new("cmd.exe");
        command.args(["/c", "echo built&& exit 3"]);
        let code = run_logged(command, &dir, &dir.join("build.log"), false, None).unwrap();
        assert_eq!(code, 3);
        assert!(std::fs::read_to_string(dir.join("build.log")).unwrap().contains("built"));
        // A stop already set ends the program at the first look.
        let stop = AtomicBool::new(true);
        let mut command = Command::new("cmd.exe");
        command.args(["/c", "ping", "-n", "30", "127.0.0.1"]);
        let started = Instant::now();
        let result = run_logged(command, &dir, &dir.join("build.log"), false, Some(&stop));
        assert_eq!(result.unwrap_err().to_string(), STOPPED);
        assert!(started.elapsed() < Duration::from_secs(5));
    }
}

pub fn get_text(url: &str) -> Result<String> {
    let mut response = ureq::get(url)
        .call()
        .map_err(|e| Error::new(format!("Could not reach {url}: {e}")))?;
    response
        .body_mut()
        .read_to_string()
        .map_err(|e| Error::new(format!("Could not read {url}: {e}")))
}
