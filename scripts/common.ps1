# Shared helpers for the world-preview scripts. Dot-source it: . "$PSScriptRoot\common.ps1"

$ErrorActionPreference = 'Stop'

$RepoRoot  = Split-Path $PSScriptRoot -Parent
$ToolsDir  = Join-Path $RepoRoot 'run\tools'
$Bootstrap = Join-Path $ToolsDir 'packwiz-installer-bootstrap.jar'
$BootstrapUrl = 'https://github.com/packwiz/packwiz-installer-bootstrap/releases/download/v0.0.3/packwiz-installer-bootstrap.jar'
$ServePort = 8080
# The default work folder: inside the repository and ignored by git, so a first try needs no choice.
$DefaultDir = Join-Path $RepoRoot 'run\preview'

# The Tectonic values the page may change. They are the sliders, so a pack without Tectonic has nothing to tune here.
$TectonicKeys = 'temperature_scale', 'vegetation_scale', 'temperature_multiplier', 'temperature_offset',
    'vertical_scale', 'flat_terrain_skew', 'erosion_scale', 'ridge_scale', 'continents_scale', 'ocean_offset'

function Resolve-Pack([string]$Pack) {
    # The pack is the one input with no sensible default: -Pack first, then WORLD_PREVIEW_PACK.
    if (-not $Pack) { $Pack = $env:WORLD_PREVIEW_PACK }
    if (-not $Pack) { throw 'No pack given. Pass -Pack <folder holding pack.toml>, or set WORLD_PREVIEW_PACK.' }
    if (-not (Test-Path (Join-Path $Pack 'pack.toml'))) { throw "No pack.toml in $Pack. -Pack is the folder of a packwiz pack." }
    $Pack = (Resolve-Path $Pack).Path
    if (-not (Test-Path (Join-Path $Pack 'config\tectonic.json'))) {
        throw "No config\tectonic.json in $Pack. The sliders are Tectonic's values, so the pack must include Tectonic and its config."
    }
    return $Pack
}

function Get-PackTectonic([string]$Pack) {
    # The values the pack ships: where the sliders start.
    $config = Get-Content (Join-Path $Pack 'config\tectonic.json') -Raw
    $values = @{}
    foreach ($key in $TectonicKeys) {
        if ($config -match ('"' + $key + '":\s*(-?[0-9.eE+-]+)')) { $values[$key] = [double]$Matches[1] }
    }
    $values
}

function Get-FabricServerJar([string]$Pack, [string]$Dir) {
    # The Fabric server launcher for the pack's versions, downloaded once per folder.
    $toml   = Get-Content (Join-Path $Pack 'pack.toml') -Raw
    $mc     = [regex]::Match($toml, 'minecraft\s*=\s*"([^"]+)"').Groups[1].Value
    $loader = [regex]::Match($toml, 'fabric\s*=\s*"([^"]+)"').Groups[1].Value
    if (-not $loader) { throw "The pack in $Pack has no Fabric loader version: the preview mod is a Fabric mod." }
    New-Item -ItemType Directory -Force $Dir | Out-Null
    $jar = Join-Path $Dir "fabric-server-$mc-$loader.jar"
    if (-not (Test-Path $jar)) {
        $installer = (Invoke-RestMethod 'https://meta.fabricmc.net/v2/versions/installer' | ForEach-Object { $_ } |
            Where-Object stable | Select-Object -First 1).version
        $url = "https://meta.fabricmc.net/v2/versions/loader/$mc/$loader/$installer/server/jar"
        Write-Host "Downloading Fabric server launcher from $url"
        Invoke-WebRequest $url -OutFile $jar
    }
    return $jar
}

function Find-AppBrowser {
    # A Chromium browser can show a page as a bare window (--app) and take pictures of one (--headless). Brave first, then Edge.
    foreach ($name in 'brave.exe', 'msedge.exe') {
        foreach ($hive in 'HKCU:', 'HKLM:') {
            $key = "$hive\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\$name"
            $exe = (Get-ItemProperty $key -ErrorAction SilentlyContinue).'(default)'
            if ($exe -and (Test-Path $exe)) { return $exe }
        }
    }
}

function Find-Java {
    # Minecraft 26.x needs Java 25. JAVA_HOME first, then PATH.
    $candidates = @()
    # The user-level value covers shells opened before Java was installed.
    foreach ($javaHome in @($env:JAVA_HOME, [Environment]::GetEnvironmentVariable('JAVA_HOME', 'User'))) {
        if ($javaHome) { $candidates += Join-Path $javaHome 'bin\java.exe' }
    }
    $onPath = Get-Command java -ErrorAction SilentlyContinue
    if ($onPath) { $candidates += $onPath.Source }
    foreach ($c in $candidates) {
        if (Test-Path $c) {
            $v = (& $c -version 2>&1 | Select-Object -First 1) -as [string]
            if ($v -match '"(\d+)') { if ([int]$Matches[1] -ge 25) { return $c } }
        }
    }
    throw 'Java 25 or newer not found. Install it (for example scoop install java/temurin25-jdk) or set JAVA_HOME.'
}

function Find-Packwiz {
    $cmd = Get-Command packwiz -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $goBin = Join-Path $env:USERPROFILE 'go\bin\packwiz.exe'
    if (Test-Path $goBin) { return $goBin }
    throw 'packwiz not found. Install it: go install github.com/packwiz/packwiz@latest'
}

function Get-Bootstrap {
    if (-not (Test-Path $Bootstrap)) {
        New-Item -ItemType Directory -Force $ToolsDir | Out-Null
        Write-Host "Downloading packwiz-installer-bootstrap from $BootstrapUrl"
        Invoke-WebRequest $BootstrapUrl -OutFile $Bootstrap
    }
    return $Bootstrap
}

function Start-PackServer([string]$Pack) {
    # packwiz serve refreshes the index and serves pack.toml over HTTP for the installer.
    $packwiz = Find-Packwiz
    $proc = Start-Process -FilePath $packwiz -ArgumentList @('serve', '--pack-file', "`"$(Join-Path $Pack 'pack.toml')`"", '--port', $ServePort) `
        -WorkingDirectory $Pack -PassThru -WindowStyle Hidden
    $url = "http://localhost:$ServePort/pack.toml"
    for ($i = 0; $i -lt 50; $i++) {
        try { Invoke-WebRequest $url -UseBasicParsing -TimeoutSec 1 | Out-Null; return @{ Process = $proc; Url = $url } }
        catch { Start-Sleep -Milliseconds 200 }
    }
    Stop-Process -Id $proc.Id -ErrorAction SilentlyContinue
    throw "packwiz serve did not answer on $url"
}

function Sync-Pack([string]$Pack, [string]$TargetDir) {
    # The server side of the pack only: the throwaway server is a dedicated server.
    $java = Find-Java
    $jar = Get-Bootstrap
    New-Item -ItemType Directory -Force $TargetDir | Out-Null
    $serve = Start-PackServer $Pack
    try {
        Push-Location $TargetDir
        try {
            & $java -jar $jar -g -s server $serve.Url
            if ($LASTEXITCODE -ne 0) { throw "packwiz-installer exited with code $LASTEXITCODE" }
        } finally { Pop-Location }
    } finally {
        Stop-Process -Id $serve.Process.Id -ErrorAction SilentlyContinue
    }
}
