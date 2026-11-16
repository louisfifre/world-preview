# world-preview

The engine that makes a Minecraft world's maps from the game's own worldgen, without generating the world: a throwaway Fabric server runs a set of mods plus our small mod, the mod samples the generator (ground height, surface biome, cuts through the ground, ore rules, structure starts) and writes files into an out folder. The mods come from a game folder or from a packwiz pack, for Fabric and with Tectonic; that folder is always a parameter.

It draws nothing. Its interface is Outpost Tools, a repository of its own, which finds this one beside the pack repository or at `WORLD_PREVIEW_DIR`, calls the driver as a library (`world_preview::run`) and reads the out folder. It stays a repository of its own so that others can use the generator alone (decided with the maintainer, 2026-11-15). A new interface goes in Outpost Tools, not here.

## Where things live

- `mod/`: the Fabric mod (id `world-preview`, jar `world-preview-<version>.jar`), one single-project Gradle build with its wrapper. Its sources sit flat in `mod/src` (the build's `sourceSets` point there). The version lives in `mod/build.gradle` and again in `driver/Cargo.toml`: bump both.
- `driver/`: the driver, in Rust, flat (`lib.rs`, `main.rs` and their modules beside `Cargo.toml`). It does the whole run: pack lookup, Java, the Fabric server jar, filling the work folder, the Tectonic config, the server, inside a job object that ends the server with the driver. A library (`world_preview::run`, with `Options::stop` for a caller that holds it in its own process) and a program (`world-preview.exe`). The library's `Options`, the program's flags and the out folder's files are the contract with every caller: change them only together with Outpost Tools' native launcher and mere-ui's preview demo, which call the library by a path dependency on `driver/`. Nothing in the engine is PowerShell but the legacy `scripts/serve.ps1`.
- `scripts/serve.ps1` and `page/preview.html`: not the engine. The former page and its server, kept only while Outpost Tools' page launcher still starts `serve.ps1` and frames the page; `serve.ps1` builds `world-preview.exe` when it is stale and runs it. Fix them if they break; add nothing to them; remove both once nothing calls them.
- `docs/setup.md`: how a run works, pass by pass.
- `run/` (ignored): downloaded tools, the default work folder `run\preview`.

## Rules

- Nothing personal in this repository: no machine paths, no user names, no private pack. The pack and the work folder are always parameters (`--pack` or `WORLD_PREVIEW_PACK`, `--dir`).
- Never write `eula.txt` anywhere. Accepting the Minecraft EULA is the decision of whoever owns the work folder; scripts and agents only say where the line goes.
- `serve.ps1` works under Windows PowerShell 5.1. Nothing to install beyond the game, Rust to build the driver and a JDK to build the mod.
- The mod reads the generator only, never a live world, and generates no chunk.
- A file of the out folder is written beside its place and moved there in one go: a reader must never see half of one.
- English everywhere in the repository.
- Simple over fine-grained: when a feature forks between a simple form and a finer one, take the simple one.
- Comments say why, not what.
- Small commits with conventional messages (`feat(mod): ...`, `docs: ...`).
