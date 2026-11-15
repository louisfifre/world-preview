<#
.SYNOPSIS
Previews the world a seed and a Tectonic config would give, without playing and without generating chunks.

.DESCRIPTION
Starts a throwaway dedicated server with the pack and the world-preview mod. The mod asks the
generator for the ground height and the surface biome on a grid, writes the answer and stops the
server. The result lands in <Dir>\out: preview.json, heights.bin, biomes.bin, and first sketches of
them, each finer than the one before: coarse.json, coarse-<step>-heights.bin, coarse-<step>-biomes.bin.

The throwaway server has its own folder, so a real server and its world are never touched.
It refuses to start until eula.txt in that folder says eula=true: accepting the Minecraft EULA is
the decision of whoever owns that folder, and no script writes it.

Errors are thrown, never `exit`, so the page server can call this script and survive.

This script only relays: the run itself is the Rust driver in driver\, built here when it is missing or older than its sources, so that the server dies with the driver if the caller quits.

.PARAMETER Pack
The folder holding the pack's pack.toml (a packwiz pack for Fabric, with Tectonic). Read from the
environment variable WORLD_PREVIEW_PACK when omitted.

.PARAMETER Dir
The work folder of the throwaway server: its mods, its config, one small world per seed, the
results. run\preview inside this repository when omitted.

.PARAMETER Seed
World seed, as typed in the game. Each seed gets its own small world folder.

.PARAMETER Tectonic
Values that replace those of the pack's config/tectonic.json for this run, by key name:
-Tectonic @{ temperature_scale = 0.1; vertical_scale = 1.2 }

.PARAMETER Samples
Grid points per side. With Step 16, 512 covers 8192 blocks; the page asks for 256 to 4096, past 2048
at a coarser Detail only.

.PARAMETER Step
Blocks between two grid points.

.PARAMETER Detail
Blocks between two points of the map: Step for the full map, or 2 or 4 times Step to stop after that
sketch, which is then the map. A map stopped there has no cuts and no structures, which cost the same
whatever the detail, and its heights leave out the aquifers, like every sketch. Step when omitted.

.PARAMETER Out
Where the result lands, <Dir>\out when omitted. A second caller passes its own folder, so it never
replaces the preview someone is looking at. The server folder stays shared: one run at a time, the
next one waits.

.PARAMETER Mods
Jars added to the server for this run, on top of the pack's mods: a mod being worked on, which the
pack does not hold yet. Read from the environment variable WORLD_PREVIEW_MODS when omitted, its
paths separated by semicolons.
#>
param(
    [string]$Pack,
    [string]$Dir,
    [string]$Seed = 'cap-1',
    [hashtable]$Tectonic = @{},
    [int]$Samples = 512,
    [int]$Step = 16,
    [int]$Detail,
    [string]$Out,
    [string[]]$Mods
)

$repo = Split-Path $PSScriptRoot -Parent
$driverDir = Join-Path $repo 'driver'
$exe = Join-Path $driverDir 'target\release\world-preview.exe'

# Runs a program, shows its output as it comes and throws, never exits, when it fails: its error stream
# is read as text, because Windows PowerShell turns it into error records once it is redirected.
function Invoke-Program([string]$File, [string[]]$Arguments, [string]$Failure) {
    $errors = New-Object System.Collections.Generic.List[string]
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $File @Arguments 2>&1 | ForEach-Object {
            if ($_ -is [Management.Automation.ErrorRecord]) { $errors.Add($_.Exception.Message) } else { Write-Host $_ }
        }
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previous }
    if ($code -ne 0) {
        if ($errors.Count) { throw ($errors -join "`n") }
        throw "$Failure (code $code)."
    }
}

$stale = -not (Test-Path $exe)
if (-not $stale) {
    $built = (Get-Item $exe).LastWriteTime
    $targetDir = Join-Path $driverDir 'target'
    $stale = [bool](Get-ChildItem $driverDir -Recurse -File | Where-Object {
        -not $_.FullName.StartsWith($targetDir, [StringComparison]::OrdinalIgnoreCase) -and $_.LastWriteTime -gt $built
    } | Select-Object -First 1)
}
if ($stale) {
    if (-not (Get-Command cargo -CommandType Application -ErrorAction SilentlyContinue)) {
        throw 'The driver has to be built and cargo was not found. Install Rust from https://rustup.rs'
    }
    Write-Host 'Building the world-preview driver'
    Invoke-Program 'cargo' @('build', '--release', '-q', '--manifest-path', (Join-Path $driverDir 'Cargo.toml')) 'The world-preview driver did not build'
}

# The driver resolves paths from its own folder, not from this shell's: they are made absolute here.
function Resolve-Argument([string]$Path) { $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path) }
$arguments = @('--repo', $repo, '--seed', $Seed, '--samples', "$Samples", '--step', "$Step")
if ($Pack) { $arguments += '--pack', (Resolve-Argument $Pack) }
if ($Dir) { $arguments += '--dir', (Resolve-Argument $Dir) }
if ($Out) { $arguments += '--out', (Resolve-Argument $Out) }
if ($Detail) { $arguments += '--detail', "$Detail" }
foreach ($mod in $Mods) { if ($mod) { $arguments += '--mod', (Resolve-Argument $mod) } }
foreach ($key in $Tectonic.Keys) {
    $value = $Tectonic[$key]
    $text = if ($value -is [bool]) { "$value".ToLower() } else { ([double]$value).ToString([Globalization.CultureInfo]::InvariantCulture) }
    $arguments += '--tectonic', "$key=$text"
}
Invoke-Program $exe $arguments 'The world-preview driver failed'
