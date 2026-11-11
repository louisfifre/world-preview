<p align="center">
  <img src="docs/media/board-hero.png" alt="World preview. See the world a seed and its terrain settings give, before anyone plays in it. The game's own generator: a first sketch in about 11 seconds, the map in about 23." width="100%">
</p>

The world preview shows what a Minecraft seed and a set of terrain values would give, without playing and without generating the world. It asks the game's own generator, through a throwaway server running your Fabric modpack, how high the ground is and which biome sits at the surface, then draws the answer in a small window.

It was written while tuning a modpack's terrain, where every try used to mean starting the game and flying around.

> **Personal project.** Windows only, driven by PowerShell scripts.

<img src="docs/media/board-window.png" alt="The preview window: seed, width of the scanned area and ten terrain sliders on the left, the map in the middle, the figures and the list of biomes on the right." width="100%">

- **The real generator, without the world.** A throwaway dedicated server starts with the pack, and a small mod asks the generator two questions on a grid, one point every 16 blocks: how high is the ground, which biome is at the surface. No chunk is generated. Trees, structures and caves are therefore not on the map.
- **A seed and ten sliders.** The sliders are [Tectonic](https://modrinth.com/mod/tectonic)'s values for the size and climate of biomes, the relief, and the continents. They start at the pack's values; a changed one keeps the pack's value beside it. Sets of values can be kept under a name.
- **A sketch first, then the map.** A coarse sketch, one point every 64 blocks, takes the map's place while the full map is computed (see the timings below).
- **Nothing is written to the pack.** A preview changes the config of its own throwaway server only.

<img src="docs/media/board-views.png" alt="The same area in four views: biomes, flat land, relief, temperature." width="100%">

<img src="docs/media/board-measure.png" alt="The figures after a second run, with what changed since the run before." width="100%">

- **Figures for the question asked.** Three figures lead: the share of flat land, the width of a typical flat zone, the width of a typical biome. Flat means level ground among level ground: 2 blocks at most to the neighbour points, for at least 5 of the 9 points around. A river does not cut a flat zone.
- **What moved since the run before.** After a second run over the same area, a column shows the change of each figure.

<img src="docs/media/board-biomes.png" alt="Three biomes shown alone on the map, the others stepped back to grey, beside the list of biomes with their typical width and their share." width="100%">

- **A few biomes alone.** A click on a biome, in the list or on the map, shows it alone; more clicks add others. The choice is kept from one run to the next, to follow a biome across tries.

<img src="docs/media/board-relief.png" alt="The biome map draped over the real heights, seen from low above the sea." width="100%">

- **Draped over the real heights.** Any view can be shown in 3D, at true scale: one unit is one block, heights included.

## Requirements

- Windows and [PowerShell 7](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows).
- Java 25 or newer, found through `JAVA_HOME` or the `PATH` (Minecraft 26.x needs it).
- [packwiz](https://packwiz.infra.link/) on the `PATH` (or in `%USERPROFILE%\go\bin`), to install the pack's server side.
- Brave or Microsoft Edge: the page opens as a bare window of one of them, and the pictures are taken with one.
- A [packwiz](https://packwiz.infra.link/) pack for Fabric that includes Tectonic and its `config/tectonic.json`, since the sliders are Tectonic's values. The mod is built for Minecraft 26.3 (`mod/gradle.properties`).
- Internet the first time: the Fabric server, the pack's mods, Gradle and the game are downloaded once, and the 3D view loads three.js from jsDelivr.

## Running it

```powershell
scripts/serve.ps1 -Pack D:\path\to\my-pack
```

`-Pack` is the folder that holds `pack.toml`; it can also come from the environment variable `WORLD_PREVIEW_PACK`. `serve.ps1` opens the page on `http://localhost:25590` as a bare browser window and stops by itself about 90 seconds after the window closes. While it runs, an icon sits in the notification area: amber while a map is computed, a notification when it is ready or has failed, and a menu to reopen the window or to quit.

The throwaway server works in `run\preview` inside this repository unless `-Dir` names another folder. A preview from a shell, without the page:

```powershell
scripts/preview.ps1 -Pack D:\path\to\my-pack -Seed cap-1 -Tectonic @{ vertical_scale = 1.2 }
```

The results land in `<Dir>\out`. `-Samples` goes from 256 to 2048 grid points per side (4096 to 32768 blocks).

### The Minecraft EULA

The preview runs a Minecraft server, so its work folder needs the [Minecraft EULA](https://aka.ms/MinecraftEULA) accepted. That is the decision of whoever owns the folder: read the EULA, then write the line `eula=true` in `<Dir>\eula.txt` yourself. No script writes it. Until then a run stops at once with a sentence saying where the file goes.

## Timings

Measured on the machine it was written on (2026-11-11), on a seed whose small world folder already existed:

| Area | Sketch on screen | Full map |
| --- | --- | --- |
| 4096 blocks | 11 s | 15 s |
| 8192 blocks (default) | 11 s | 23 s |
| 16384 blocks | 12 s | 58 s |
| 32768 blocks | 16 s | 3 min 20 s |

Most of the sketch's wait is the server start. A seed run for the first time took about 10 seconds more, once (22 s to the sketch, 32 s to the map, at 8192 blocks). The first run of all also builds the mod and installs the pack, a few minutes.

## Limits

- No trees, structures or caves: the map answers "how big, how high, how much", not "is this biome pleasant to walk in".
- The sketch skips the aquifers and reads one point in four along each side: close to the full map, not proven exact.
- Windows only: the scripts lean on PowerShell, the Windows registry to find the browser, and Windows Forms for the tray icon.
- One run at a time on a machine: a second one waits for the first.

## What is where

| Folder | What it holds |
| --- | --- |
| `mod/` | The Fabric mod that samples the generator, one Gradle build. |
| `page/` | The page, one HTML file. |
| `scripts/` | `serve.ps1` (the page's server), `preview.ps1` (one run), `capture.ps1` and `boards.ps1` (pictures of the page). |
| `docs/` | [How it works](docs/setup.md), and `media/` for the illustrations. |

The illustrations above are real pictures of the page, composed by `scripts/boards.ps1` from `docs/media/boards.html`. None is retouched.

## Licence

The code, the page and the scripts of this repository are under the [GNU General Public License v3.0](LICENSE). The mods of the pack you preview are not part of it: each keeps its own licence. Minecraft is a trademark of Mojang; this project is not affiliated with Mojang or Microsoft.
