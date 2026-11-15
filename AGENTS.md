# world-preview

The engine that makes a Minecraft world's maps from the game's own worldgen, without generating the world: a throwaway Fabric server runs a set of mods plus our small mod, the mod samples the generator (ground height, surface biome, cuts through the ground, ore rules, structure starts) and writes files into an out folder. The mods come from a game folder or from a packwiz pack, for Fabric and with Tectonic; that folder is always a parameter.

It draws nothing. Its interface is Outpost Tools, a repository of its own, which finds this one beside the pack repository or at `WORLD_PREVIEW_DIR`, runs `scripts/preview.ps1` and reads the out folder. It stays a repository of its own so that others can use the generator alone (decided with the maintainer, 2026-11-15). A new interface goes in Outpost Tools, not here.

## Where things live

- `mod/`: the Fabric mod (id `world-preview`, jar `world-preview-<version>.jar`), one single-project Gradle build with its wrapper. The version lives in `mod/build.gradle`.
- `scripts/preview.ps1`: one run, the engine's entry point. Its parameters and the out folder's files are the contract with every caller: change them only together with Outpost Tools (and rust-native-ui's preview demo, which builds the same command line).
- `scripts/common.ps1`: its helpers (pack lookup, Java, Fabric server jar, filling the work folder from a pack or a game folder).
- `scripts/serve.ps1` and `page/preview.html`: not the engine. The former page and its server, kept only while Outpost Tools' page launcher still starts `serve.ps1` and frames the page. Fix them if they break; add nothing to them; remove both once nothing calls them.
- `docs/setup.md`: how a run works, pass by pass.
- `run/` (ignored): downloaded tools, the default work folder `run\preview`.

## Rules

- Nothing personal in this repository: no machine paths, no user names, no private pack. The pack and the work folder are always parameters (`-Pack` or `WORLD_PREVIEW_PACK`, `-Dir`).
- Never write `eula.txt` anywhere. Accepting the Minecraft EULA is the decision of whoever owns the work folder; scripts and agents only say where the line goes.
- The scripts work under Windows PowerShell 5.1 and ask for nothing to install beyond the game and, to build the mod, a JDK.
- The mod reads the generator only, never a live world, and generates no chunk.
- A file of the out folder is written beside its place and moved there in one go: a reader must never see half of one.
- English everywhere in the repository.
- Simple over fine-grained: when a feature forks between a simple form and a finer one, take the simple one.
- Comments say why, not what.
- Small commits with conventional messages (`feat(mod): ...`, `docs: ...`).
