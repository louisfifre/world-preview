# How it works

What happens behind the page, and how to look at the page without opening it. The README covers installing and running.

## A run

`preview.ps1` prepares a throwaway dedicated server in its work folder (`-Dir`, `run\preview` by default) and starts it:

1. It checks `eula.txt` in the work folder first, before downloading anything there. Accepting the Minecraft EULA is the folder owner's decision; no script writes it.
2. It takes the mod's jar. Next to its sources, it builds it when they are newer (`mod\gradlew.bat build`, a JDK 25; the first build downloads Gradle and the game, a few minutes). In the ready-to-use folder there are no sources and the jar is taken as it is.
3. It downloads the Fabric server launcher, then fills the work folder with the mods, again only when they changed. From a packwiz pack, packwiz-installer reads `pack.toml` straight from the disk and installs the pack's server side, at the versions the pack names. From a game folder, the jars of `mods` and the `config` folder are copied, and the versions are those the mod is built for (`mod\gradle.properties`). Distant Horizons, when it is there, is taken out of the work folder only: it plays no part in the generator's answers and costs seconds at every start.
4. It writes the pack's `config/tectonic.json` into the work folder, with the values the run asked for, and a `server.properties` for a server nobody joins (local only, port 25599, one small world folder per seed, watchdog off since the sampling runs inside one tick).
5. It starts the server. The mod, dormant unless the server is started with `-Dworldpreview.out`, samples the generator once the server is up, writes the files and stops the server.

The server's output lands in `last-run.log` in the work folder, what Java wrote as errors in `last-run.errors.log`, and the same two for packwiz-installer under `last-sync`. Java runs through `Start-Process` and these files: Windows PowerShell stops a script on the first line a program writes to a redirected error stream.

The mod makes several passes, from coarse to full. The sketches first: one point in 16, then 4, then 2 of the full grid along each side, each kept when it leaves at least 128 points a side, without the aquifers, so close but not proven exact. Each replaces `coarse.json` and writes its points as `coarse-<step>-heights.bin` and `coarse-<step>-biomes.bin`; the page asks for `coarse.json` every second and draws a sketch when it is finer than the one on screen. Then the full grid (`preview.json`, `heights.bin`, `biomes.bin`): the ground height from `ChunkGenerator.getBaseHeight` (heightmap `OCEAN_FLOOR_WG`, so a sea bed shows its depth) and the surface biome from the biome source. No chunk is generated. `preview.json` also lists, as `possible`, every biome the biome source can place, each with whether it is tagged `c:is_underground`: the page counts the biomes of the square against those that are not, and names the missing ones.

The detail (`-Detail` of `preview.ps1`, the Detail choice beside the page's button) stops the run earlier: at 32 or 64 blocks, the sketch of that step is written as the map itself (`preview.json`, `heights.bin`, `biomes.bin`) and the run ends there, without what follows. So a coarser map has no aquifers in its heights, no cuts, no ore rules and no structures, and the page greys the views and figures that need them: Flat, Structures, Section, the flat land and the typical flat zone (level land is told from one point to the next, 16 blocks away). The structures would be exact at any detail, since they ask the generator's placement and not the grid, but they cost the same whatever the detail (about 3.5 s for 8192 blocks on the machine they were measured on, growing with the area), which is what a coarser map is meant to spare.

The page tells each detail's wait from this machine's own runs: the start of the game (the time the first pass landed, less what the mod says that pass took) and a cost per point for each detail, kept by the browser. A detail never run yet borrows the full map's cost per point.

Last come what the Section view shows. Up to four cuts through the ground (`section.json`, `section-<n>.bin`): lines running west to east across the whole square, from its west edge to its east edge (`samples * step` blocks: 8192 for 512 points every 16 blocks, 32768 for 2048), drawn at random from the seed among the rows of the map, kept at least an eighth of the square apart, the ones that cross the most different ground kept (a height, some sea, some level land). Each cell of a cut, one per block from the bottom of the world to its top, is what the generator's density and aquifers give: rock, air, water or lava. Then the ore rules the server ended up with (`ores.json`): every placement of an ore feature with its steps, as a data pack writes them, and for each biome the placements it lists once every mod has added its own. Trouble in this last part is logged and leaves the map as it is.

Then where structures would start (`structures.json`): `structures` lists every structure of every structure set the overworld generator can place, as `{ "id", "set", "step" }` (the step is the generation step the structure declares, `surface_structures` or `underground_structures` for most), and `points` holds one row per start inside the square, `[index into structures, x, z]` in blocks. The mod asks the generator what it asks when a chunk reaches its structure starts, without any chunk: for each set, the chunks its placement picks (one per region of a random spread, or the stronghold rings), its frequency and its exclusion zone, then which structure of the set is tried there (a weighted draw seeded by the chunk, the next one drawn when the first is not valid) and whether that structure finds a valid point, its biome included. `/locate` is not used: it loads chunks. Its limits: a point is where a structure begins, at the generation point it found, not all it covers (a village spreads over several chunks around it); what a later step of a real chunk changes is not known; a point whose structure starts in a chunk of the square but lands just outside it is left out. Trouble here is logged apart from the cuts, so one never loses the other.

The page plays those rules on the cut itself: for each chunk along it, each rule its surface biome lists draws its tries and its veins the way the game does. So the ground of a cut is the generator's, and its ores are a play of the rules, not the blocks a world of that seed would hold. The ores are counted over a slice 16 blocks thick, on 512 plays of a chunk whatever the length of the cut (every chunk of a short cut several times, one chunk in so many of a long one), and drawn over 4 blocks, for the part of the cut on screen only. The page shows a cut twice: a strip of its whole length with the heights stretched, and under it the part chosen on the strip, at true scale. The top layers of the ground, where no ore goes, are taken as 3 blocks; carved ravines are not there. Rules that count a depth from the ground (a `heightmap` step, then `offset` steps down) are shown as rows the page can change, add to or remove; the rows live in the browser and are written nowhere else, except into an export.

Compared once with real chunks (a census of another world of the same pack, low ground): the play gave about a fifth to a half more ore per chunk for the deep ores. Read its figures as one try against another, not as a count.

The computation leaves room for the rest of the machine: the mod samples on half of the available processors (`-Dworldpreview.threads=<n>` on the server's command line says otherwise), and `preview.ps1` puts the server below the normal priority. With every thread at the normal priority, a full pass made the machine stall for seconds at a time.

`-Mods` (or the environment variable `WORLD_PREVIEW_MODS`, paths separated by semicolons) adds jars to the server on top of the pack's, for a mod being worked on; those of the run before leave the folder first.

A changed Tectonic value applies on the next start, on the same world folder. Two runs never go together on one machine: they would share a port and, often, a folder. The second waits on a named mutex.

## The page and its server

A page cannot start a program or read a file, so `serve.ps1` is the small local server behind it, on `localhost` only:

| Route | What it does |
| --- | --- |
| `GET /` | The page. Its state can be asked in the address: `/?view=height,relief3d&biome=minecraft:desert`, or `/?view=structures&structure=surface` (a structure's id, or `surface` or `under` for a whole part). |
| `GET /api/preview/config` | The pack's Tectonic values, where the sliders start. |
| `POST /api/preview` | Starts a run in the background and answers when it ends. Only from the page itself: the `Origin` header must be the server's own. |
| `GET /api/preview/run` | The run under way, if any: its seed, area, values and age in seconds. A window opened during a run reads it to join that run; once the run is over, it says what went wrong, if anything, or that it was stopped. |
| `POST /api/preview/stop` | Stops the run under way, its Java included. The request that started the run then answers `stopped`. |
| `POST /api/preview/export/<name>/<file>` | Writes one file of an export into `<Exports>\<name>`, the exports folder being `-Exports` of `serve.ps1` (`run\exports` by default): a picture of a view (`biomes.png`, `height-3d.png`, `structures.png`…), of the part of the cut on screen (`section.png`), or `export.json`, the settings and what the page measured. |
| `POST /api/preview/export/<name>/open` | Opens that export's folder in the file explorer, which a page cannot do itself. Only a folder of the exports folder, and only one that exists. |
| `GET /preview/data/<file>` | The files of the last run, the sketch, the cuts, the ore rules and the structure starts included. |
| `GET /api/ping` | The page pings every 10 seconds; the server stops about 90 seconds after the pings stop, never during a run. |

The run goes on a background thread, so the server answers the page's other requests meanwhile, the sketch among them. Quitting from the icon stops a run under way, its Java included. If the port is already taken, the script only opens a window on the server that holds it.

## Looking at the page without opening it

`scripts/capture.ps1` takes pictures of the page into `run\captures`, for an agent or for a before/after. It starts a second server on port 25591 whose previews land in `<Dir>\out-capture`, and drives a headless Brave or Edge over the DevTools protocol. A server already running and the preview on its screen are not touched.

- `scripts/capture.ps1 -Pack <pack>` takes the usual set (every view, both themes, a small window).
- `scripts/capture.ps1 -Pack <pack> -Seed cap-2 -Tectonic @{ flat_terrain_skew = 0.35 }` computes that world first.
- A shot can run JavaScript in the page (`Eval`), stay on the page of the shot before (`Stay`), wait for a condition (`Until`), be twice as fine (`Scale = 2`), hold one element only (`Clip`, a CSS selector) and open any address (`Url`). See the script's help.
- The page tells the script it is drawn by setting `data-ready="1"` on its root element.

`scripts/boards.ps1 -Pack <pack>` makes the illustrations of the README again: it computes seed `cap-1` with the pack's values, then a flatter run through the page itself, takes the pieces, and saves each board of `docs/media/boards.html` as `docs/media/board-<name>.png`.
