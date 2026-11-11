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

The mod makes several passes, from coarse to full. The sketches first: one point in 16, then 4, then 2 of the full grid along each side, each kept when it leaves at least 128 points a side, without the aquifers, so close but not proven exact. Each replaces `coarse.json` and writes its points as `coarse-<step>-heights.bin` and `coarse-<step>-biomes.bin`; the page asks for `coarse.json` every second and draws a sketch when it is finer than the one on screen. Then the full grid (`preview.json`, `heights.bin`, `biomes.bin`): the ground height from `ChunkGenerator.getBaseHeight` (heightmap `OCEAN_FLOOR_WG`, so a sea bed shows its depth) and the surface biome from the biome source. No chunk is generated.

The computation leaves room for the rest of the machine: the mod samples on half of the available processors (`-Dworldpreview.threads=<n>` on the server's command line says otherwise), and `preview.ps1` puts the server below the normal priority. With every thread at the normal priority, a full pass made the machine stall for seconds at a time.

A changed Tectonic value applies on the next start, on the same world folder. Two runs never go together on one machine: they would share a port and, often, a folder. The second waits on a named mutex.

## The page and its server

A page cannot start a program or read a file, so `serve.ps1` is the small local server behind it, on `localhost` only:

| Route | What it does |
| --- | --- |
| `GET /` | The page. Its state can be asked in the address: `/?view=height,relief3d&biome=minecraft:desert`. |
| `GET /api/preview/config` | The pack's Tectonic values, where the sliders start. |
| `POST /api/preview` | Starts a run in the background and answers when it ends. Only from the page itself: the `Origin` header must be the server's own. |
| `GET /api/preview/run` | The run under way, if any: its seed, area, values and age in seconds. A window opened during a run reads it to join that run; once the run is over, it says what went wrong, if anything. |
| `GET /preview/data/<file>` | The files of the last run, the sketch included. |
| `GET /api/ping` | The page pings every 10 seconds; the server stops about 90 seconds after the pings stop, never during a run. |

The run goes on a background thread, so the server answers the page's other requests meanwhile, the sketch among them. Quitting from the icon stops a run under way, its Java included. If the port is already taken, the script only opens a window on the server that holds it.

## Looking at the page without opening it

`scripts/capture.ps1` takes pictures of the page into `run\captures`, for an agent or for a before/after. It starts a second server on port 25591 whose previews land in `<Dir>\out-capture`, and drives a headless Brave or Edge over the DevTools protocol. A server already running and the preview on its screen are not touched.

- `scripts/capture.ps1 -Pack <pack>` takes the usual set (every view, both themes, a small window).
- `scripts/capture.ps1 -Pack <pack> -Seed cap-2 -Tectonic @{ flat_terrain_skew = 0.35 }` computes that world first.
- A shot can run JavaScript in the page (`Eval`), stay on the page of the shot before (`Stay`), wait for a condition (`Until`), be twice as fine (`Scale = 2`), hold one element only (`Clip`, a CSS selector) and open any address (`Url`). See the script's help.
- The page tells the script it is drawn by setting `data-ready="1"` on its root element.

`scripts/boards.ps1 -Pack <pack>` makes the illustrations of the README again: it computes seed `cap-1` with the pack's values, then a flatter run through the page itself, takes the pieces, and saves each board of `docs/media/boards.html` as `docs/media/board-<name>.png`.
