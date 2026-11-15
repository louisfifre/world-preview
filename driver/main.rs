//! world-preview command line: one run of the engine.

use std::process::ExitCode;
use world_preview::args::{self, Parsed};

fn main() -> ExitCode {
    match drive() {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("{error}");
            ExitCode::from(1)
        }
    }
}

fn drive() -> world_preview::Result<()> {
    let (mut options, repo) = match args::parse(std::env::args().skip(1))? {
        Parsed::Help => {
            println!("{}", args::USAGE);
            return Ok(());
        }
        Parsed::Run { options, repo } => (options, repo),
    };
    // The executable sits inside the repository (driver/target/release), so the repository is found from it.
    let exe_dir = std::env::current_exe().ok().and_then(|exe| exe.parent().map(|p| p.to_path_buf()));
    options.repo = match repo.or_else(|| exe_dir.and_then(|dir| world_preview::find_repo_root(&dir))) {
        Some(repo) => repo,
        None => return Err(world_preview::Error::new("The engine's repository was not found from this program. Pass --repo <folder holding mod/build.gradle>.")),
    };
    world_preview::run(&options, &mut |line| println!("{line}"))?;
    Ok(())
}
