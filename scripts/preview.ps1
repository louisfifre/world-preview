<#
.SYNOPSIS
Previews the world a seed and a Tectonic config would give, without playing and without generating chunks.

.DESCRIPTION
Starts a throwaway dedicated server with the pack and the world-preview mod. The mod asks the
generator for the ground height and the surface biome on a grid, writes the answer and stops the
server. The result lands in <Dir>\out: preview.json, heights.bin, biomes.bin, and first a sketch of
them, coarse.json, coarse-heights.bin, coarse-biomes.bin.

The throwaway server has its own folder, so a real server and its world are never touched.
It refuses to start until eula.txt in that folder says eula=true: accepting the Minecraft EULA is
the decision of whoever owns that folder, and no script writes it.

Errors are thrown, never `exit`, so the page server can call this script and survive.

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
Grid points per side. With Step 16, 512 covers 8192 blocks; the page asks for 256 to 2048.

.PARAMETER Step
Blocks between two grid points.

.PARAMETER Out
Where the result lands, <Dir>\out when omitted. A second caller (the capture script) passes its
own folder, so it never replaces the preview someone is looking at. The server folder stays shared:
one run at a time, the next one waits.
#>
param(
    [string]$Pack,
    [string]$Dir,
    [string]$Seed = 'cap-1',
    [hashtable]$Tectonic = @{},
    [int]$Samples = 512,
    [int]$Step = 16,
    [string]$Out
)

. "$PSScriptRoot\common.ps1"
$Pack = Resolve-Pack $Pack
if (-not $Dir) { $Dir = $DefaultDir }
New-Item -ItemType Directory -Force $Dir | Out-Null
$Dir = (Resolve-Path $Dir).Path
if (-not $Out) { $Out = Join-Path $Dir 'out' }
# The mod writes where it is told, from the server's own folder: a relative path would land in the wrong place.
$Out = [IO.Path]::GetFullPath($Out)

# Checked first, before anything is downloaded into the folder: without it the server would not start.
$eula = Join-Path $Dir 'eula.txt'
if (-not ((Test-Path $eula) -and ((Get-Content $eula -Raw) -match '(?m)^eula=true'))) {
    throw "EULA: the preview server needs the Minecraft EULA accepted in its own folder. Read https://aka.ms/MinecraftEULA, then write the line eula=true in $eula"
}

# 1. The mod jar. The ready-to-use folder (scripts/package.ps1) ships it built and without its sources:
# it is taken as it is. Next to its sources, it is rebuilt when they are newer.
$modRoot = Join-Path $RepoRoot 'mod'
$libs = Join-Path $modRoot 'build\libs'
$jar = Get-ChildItem $libs -Filter 'world-preview-*.jar' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime | Select-Object -Last 1
$sources = Join-Path $modRoot 'src'
if (-not (Test-Path $sources)) {
    if (-not $jar) { throw "The world-preview mod is missing: no jar in $libs and no sources to build it from." }
}
elseif (-not $jar -or $jar.LastWriteTime -lt (Get-ChildItem $sources, (Join-Path $modRoot 'build.gradle') -Recurse -File |
        Sort-Object LastWriteTime | Select-Object -Last 1).LastWriteTime) {
    Write-Host 'Building the world-preview mod'
    $env:JAVA_HOME = Split-Path (Split-Path (Find-Java))
    Push-Location $modRoot
    try {
        & .\gradlew.bat build --console=plain -q
        if ($LASTEXITCODE -ne 0) { throw 'The world-preview mod did not build.' }
    } finally { Pop-Location }
    $jar = Get-ChildItem $libs -Filter 'world-preview-*.jar' | Sort-Object LastWriteTime | Select-Object -Last 1
}

# One run at a time on this machine: two runs in one folder would overwrite each other's config, and
# two servers would ask for the same port. The second one waits.
$lock = [Threading.Mutex]::new($false, 'world-preview-run')
try { $null = $lock.WaitOne() } catch [Threading.AbandonedMutexException] { }
try {

# 2. The throwaway server: launcher jar, then the pack's mods, synced again only when the pack changed.
$launcher = Get-FabricServerJar $Pack $Dir
$stampFile = Join-Path $Dir '.pack-stamp'
$stamp = Get-PackStamp $Pack
if (-not (Test-Path $stampFile) -or [IO.File]::ReadAllText($stampFile).Trim() -ne $stamp) {
    Sync-Pack $Pack $Dir
    [IO.File]::WriteAllText($stampFile, $stamp)
}
Get-ChildItem (Join-Path $Dir 'mods') -Filter 'world-preview-*.jar' | Remove-Item
Copy-Item $jar.FullName (Join-Path $Dir 'mods')
# Distant Horizons does not take part in the generator's answers (the files come out byte for byte the
# same without it), but it costs seconds at every start. It leaves this folder only: the pack keeps it,
# and the next sync brings it back before this line takes it out again.
Get-ChildItem (Join-Path $Dir 'mods') -Filter 'DistantHorizons-*.jar' | Remove-Item

# 3. The Tectonic config for this run: the pack's file, with the asked values replaced.
$config = [IO.File]::ReadAllText((Join-Path $Pack 'config\tectonic.json'))
foreach ($key in $Tectonic.Keys) {
    $value = $Tectonic[$key]
    $text = if ($value -is [bool]) { "$value".ToLower() } else { ([double]$value).ToString([Globalization.CultureInfo]::InvariantCulture) }
    $pattern = '("' + [regex]::Escape($key) + '":\s*)(-?[0-9.eE+-]+|true|false)'
    if ($config -notmatch $pattern) { throw "Unknown Tectonic key: $key" }
    $config = [regex]::Replace($config, $pattern, { param($m) $m.Groups[1].Value + $text })
}
New-Item -ItemType Directory -Force (Join-Path $Dir 'config') | Out-Null
[IO.File]::WriteAllText((Join-Path $Dir 'config\tectonic.json'), $config)

# 4. A server nobody joins: local only, its own port, one small world folder per seed.
$world = 'seed-' + ($Seed -replace '[^A-Za-z0-9_-]', '_')
# Written as UTF-8 without a mark at its head, whatever the shell: the server reads it so.
[IO.File]::WriteAllLines((Join-Path $Dir 'server.properties'), [string[]]@(
    'motd=World preview'
    "level-seed=$Seed"
    "level-name=$world"
    'server-ip=127.0.0.1'
    'server-port=25599'
    'enable-rcon=false'
    'view-distance=2'
    'simulation-distance=2'
    # The sampling runs inside one tick. A wide grid takes more than the minute after which the
    # watchdog calls a server crashed and kills it, so the watchdog is off here.
    'max-tick-time=-1'
))

# 5. Run. The mod stops the server itself once the files are written.
Remove-Item (Join-Path $Out 'preview.json'), (Join-Path $Out 'coarse.json') -ErrorAction SilentlyContinue
$watch = [Diagnostics.Stopwatch]::StartNew()
$null = Invoke-Java $Dir (Join-Path $Dir 'last-run.log') @('-Xmx4G', '-XX:+UseZGC', "-Dworldpreview.out=$Out",
    "-Dworldpreview.samples=$Samples", "-Dworldpreview.step=$Step", '-jar', $launcher, 'nogui') -Background

if (-not (Test-Path (Join-Path $Out 'preview.json'))) {
    throw "The preview server ended without a result. See $(Join-Path $Dir 'last-run.log')"
}

} finally { $lock.ReleaseMutex() }

# What this preview was made with, so the page can show the same seed and values next to the map.
[IO.File]::WriteAllText((Join-Path $Out 'run.json'), (@{ seed = $Seed; tectonic = $Tectonic } | ConvertTo-Json))
Write-Host "Preview ready in $Out ($([int]$watch.Elapsed.TotalSeconds) s)"
