# world-preview

A Windows tool that shows what a Minecraft seed and a set of Tectonic values would give, without generating the world: a throwaway Fabric server runs a packwiz pack plus our small mod, the mod samples the generator's ground height and surface biome on a grid, and a local page draws the result. Any packwiz pack for Fabric that includes Tectonic can be previewed; the pack is always a parameter.

## Where things live

- `mod/`: the Fabric mod (id `world-preview`, jar `world-preview-<version>.jar`), one single-project Gradle build with its wrapper.
- `page/preview.html`: the page, one file, served at `/`.
- `scripts/common.ps1`: helpers (pack lookup, Java, Fabric server jar, packwiz sync, browser lookup).
- `scripts/preview.ps1`: one run. `scripts/serve.ps1`: the page's local server, port 25590. `scripts/capture.ps1`: pictures of the page from a second server, port 25591. `scripts/boards.ps1`: the README's illustrations.
- `docs/setup.md`: how a run and the server work. `docs/media/`: `boards.html` and the board pictures.
- `run/` (ignored): downloaded tools, the default work folder `run\preview`, captures.

## Rules

- Nothing personal in this repository: no machine paths, no user names, no private pack. The pack and the work folder are always parameters (`-Pack` or `WORLD_PREVIEW_PACK`, `-Dir`).
- Never write `eula.txt` anywhere. Accepting the Minecraft EULA is the decision of whoever owns the work folder; scripts and agents only say where the line goes.
- The page and its sentences are English, like the rest of the repository.
- Simple over fine-grained: when a feature forks between a simple form and a finer one, take the simple one.
- Comments say why, not what.
- The mod reads the generator only, never a live world, and generates no chunk.
- The pictures in `docs/media` are real captures made by `scripts/boards.ps1`; none is retouched. Regenerate them when the page changes in a way they show.
- Small commits with conventional messages (`feat(scripts): ...`, `docs: ...`).
