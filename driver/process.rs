//! Child processes: java for a run or for the pack sync, and the downloads.

use crate::win::KillOnCloseJob;
use crate::{CREATE_NO_WINDOW, Error, Result};
use std::fs::File;
use std::io;
use std::os::windows::process::CommandExt;
use std::path::Path;
use std::process::{Command, Stdio};

const BELOW_NORMAL_PRIORITY_CLASS: u32 = 0x0000_4000;

/// Runs java in a folder: its output goes to `log` and its errors to a second file beside it, and the
/// exit code comes back. In a file, because a pipe nobody reads would stall a chatty server.
/// The process is tied to this program: if the program dies, so does java.
/// `background` runs it below the normal priority: a long computation steps aside, or Windows would
/// serve it before the window the person is looking at.
pub fn run_java(java: &Path, work_dir: &Path, log: &Path, args: &[String], background: bool) -> Result<i32> {
    let errors = log.with_extension("errors.log");
    let open = |path: &Path| File::create(path).map_err(|e| Error::new(format!("Could not write {}: {e}", path.display())));
    let mut command = Command::new(java);
    command
        .args(args)
        .current_dir(work_dir)
        .stdin(Stdio::null())
        .stdout(open(log)?)
        .stderr(open(&errors)?)
        .creation_flags(CREATE_NO_WINDOW | if background { BELOW_NORMAL_PRIORITY_CLASS } else { 0 });
    let job = KillOnCloseJob::new()?;
    let mut child = command.spawn().map_err(|e| Error::new(format!("Could not start {}: {e}", java.display())))?;
    job.add(&child)?;
    let status = child.wait().map_err(|e| Error::new(format!("Lost the Java process: {e}")))?;
    Ok(status.code().unwrap_or(-1))
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

pub fn get_text(url: &str) -> Result<String> {
    let mut response = ureq::get(url)
        .call()
        .map_err(|e| Error::new(format!("Could not reach {url}: {e}")))?;
    response
        .body_mut()
        .read_to_string()
        .map_err(|e| Error::new(format!("Could not read {url}: {e}")))
}
