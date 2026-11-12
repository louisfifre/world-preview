<#
.SYNOPSIS
Makes the illustrations of the README again, from real pictures of the page.

.DESCRIPTION
Three steps, all through capture.ps1:
1. computes the reference world (seed cap-1, the pack's values), then a second one with more flat
   land through the page itself, so that the figures show what moved between two runs;
2. takes the "pieces": the page and parts of it, twice as fine as a screen, into
   run\captures\pieces (not versioned);
3. opens docs/media/boards.html once per board and saves each as docs/media/board-<name>.png.

A board changes in boards.html; a piece changes here. The page is pictured as it is: no picture is
retouched.

.PARAMETER Pack
The folder holding the pack's pack.toml, as in preview.ps1. Read from WORLD_PREVIEW_PACK when omitted.

.PARAMETER Dir
The work folder of the throwaway server, as in preview.ps1. run\preview when omitted.
#>
param(
    [string]$Pack,
    [string]$Dir
)

. "$PSScriptRoot\common.ps1"

$pieces = Join-Path $RepoRoot 'run\captures\pieces'
$media = Join-Path $RepoRoot 'docs\media'
$done = "document.getElementById('status').textContent.startsWith('Preview ready') || document.getElementById('status').className === 'trouble'"
$flatter = "for (const [k, v] of [['flat_terrain_skew', 0.35], ['erosion_scale', 0.15]]) { const i = document.getElementById(k); i.value = v; i.dispatchEvent(new Event('input')); } document.getElementById('generate').click();"
$chosen = 'biome=minecraft:desert,minecraft:badlands,minecraft:plains'

& "$PSScriptRoot\capture.ps1" -Pack $Pack -Dir $Dir -Seed cap-1 -OutDir $pieces -Shots @(
    @{ Name = 'run-started';     Eval = $flatter; Wait = 1000 }
    @{ Name = 'run-done';        Stay = $true; Until = $done }
    @{ Name = 'page';            Scale = 2 }
    @{ Name = 'figures';         Path = '/?view=flat'; Scale = 2; Clip = '#figures'; Pad = 4 }
    @{ Name = 'map-biomes';      Scale = 2; Clip = '#map' }
    @{ Name = 'map-flat';        Path = '/?view=flat'; Scale = 2; Clip = '#map' }
    @{ Name = 'map-relief';      Path = '/?view=height'; Scale = 2; Clip = '#map' }
    @{ Name = 'map-temperature'; Path = '/?view=temperature'; Scale = 2; Clip = '#map' }
    @{ Name = 'map-chosen';      Path = "/?$chosen"; Scale = 2; Clip = '#map' }
    @{ Name = 'biome-list';      Path = "/?$chosen"; Scale = 2; Clip = 'section:nth-of-type(3) > div:last-child'; Pad = 8 }
    @{ Name = '3d-relief';       Path = '/?view=height,relief3d&camera=0.05,0.28,0.62'; Size = '1500,1300'; Scale = 2; Clip = '#relief'; Wait = 1500 }
    @{ Name = '3d-biomes';       Path = '/?view=biomes,relief3d&camera=-0.35,0.2,0.45'; Size = '1500,1300'; Scale = 2; Clip = '#relief'; Wait = 1500 }
)

# The boards are local files: no server and no pack needed for them.
$page = 'file:///' + ((Join-Path $media 'boards.html') -replace '\\', '/')
& "$PSScriptRoot\capture.ps1" -OutDir $media -Shots @(
    foreach ($board in 'hero', 'window', 'views', 'measure', 'biomes', 'relief') {
        @{ Name = "board-$board"; Url = "$page`?board=$board"; Size = '1280,640'; Scale = 2 }
    }
)
