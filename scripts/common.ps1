# Shared helpers for the world-preview scripts. Dot-source it: . "$PSScriptRoot\common.ps1"
# Everything a person runs (start, serve, preview) must work under Windows PowerShell 5.1, the one
# every Windows has: nobody should install a shell to see a map.

$ErrorActionPreference = 'Stop'
# Windows PowerShell started from PowerShell 7 inherits its module folders, and takes PowerShell 7's copies of its
# own modules from there: Get-FileHash is then missing and every run fails. Those folders go before any command
# loads a module.
if ($PSVersionTable.PSEdition -eq 'Desktop') {
    $env:PSModulePath = ($env:PSModulePath -split ';' | Where-Object { $_ -and $_ -notmatch '\\PowerShell\\' }) -join ';'
}
# Windows PowerShell draws a progress bar that makes a download many times slower, and may still offer old TLS only.
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$RepoRoot  = Split-Path $PSScriptRoot -Parent
$ToolsDir  = Join-Path $RepoRoot 'run\tools'
$Bootstrap = Join-Path $ToolsDir 'packwiz-installer-bootstrap.jar'
$BootstrapUrl = 'https://github.com/packwiz/packwiz-installer-bootstrap/releases/download/v0.0.3/packwiz-installer-bootstrap.jar'
# The default work folder: inside the repository and ignored by git, so a first try needs no choice.
$DefaultDir = Join-Path $RepoRoot 'run\preview'

# The Tectonic values the page may change. They are the sliders, so a pack without Tectonic has nothing to tune here.
$TectonicKeys = 'temperature_scale', 'vegetation_scale', 'temperature_multiplier', 'temperature_offset',
    'vegetation_multiplier', 'vegetation_offset', 'vertical_scale', 'flat_terrain_skew', 'erosion_scale', 'ridge_scale', 'continents_scale', 'ocean_offset'

function Resolve-Pack([string]$Pack) {
    # The pack is the one input with no sensible default: -Pack first, then WORLD_PREVIEW_PACK.
    # It is either a packwiz pack (pack.toml) or a plain game folder (mods and config), the one a launcher plays from.
    if (-not $Pack) { $Pack = $env:WORLD_PREVIEW_PACK }
    if (-not $Pack) { throw 'No pack given. Pass -Pack <a game folder or a packwiz pack>, or set WORLD_PREVIEW_PACK.' }
    if (-not (Test-Path $Pack -PathType Container)) { throw "No such folder: $Pack" }
    $Pack = (Resolve-Path $Pack).Path
    # A launcher's instance keeps its game folder one level down, and the instance is the folder people find first.
    $found = $null
    foreach ($folder in $Pack, (Join-Path $Pack 'minecraft'), (Join-Path $Pack '.minecraft')) {
        if ((Test-Path (Join-Path $folder 'pack.toml')) -or (Test-Path (Join-Path $folder 'mods'))) { $found = $folder; break }
    }
    if (-not $found) { throw "No mods folder and no pack.toml in $Pack. Choose the game folder, the one that holds mods and config." }
    if (-not (Test-Path (Join-Path $found 'config\tectonic.json'))) {
        throw "No config\tectonic.json in $found. The sliders are Tectonic's values: the mods must include Tectonic, and the game must have started once with it so that its config exists."
    }
    return $found
}

function Test-PackwizPack([string]$Pack) { Test-Path (Join-Path $Pack 'pack.toml') }

function Get-PackTectonic([string]$Pack) {
    # The values the pack ships: where the sliders start.
    $config = [IO.File]::ReadAllText((Join-Path $Pack 'config\tectonic.json'))
    $values = @{}
    foreach ($key in $TectonicKeys) {
        if ($config -match ('"' + $key + '":\s*(-?[0-9.eE+-]+)')) { $values[$key] = [double]$Matches[1] }
    }
    $values
}

function Get-FabricServerJar([string]$Pack, [string]$Dir) {
    # The Fabric server launcher, downloaded once per folder. A packwiz pack names its versions; a game
    # folder does not, so it gets those the mod is built for, the only game version the mod runs on anyway.
    $file = if (Test-PackwizPack $Pack) { Join-Path $Pack 'pack.toml' } else { Join-Path $RepoRoot 'mod\gradle.properties' }
    $text   = [IO.File]::ReadAllText($file)
    $mc     = [regex]::Match($text, '(?m)^\s*minecraft(?:_version)?\s*=\s*"?([^"\s]+)').Groups[1].Value
    $loader = [regex]::Match($text, '(?m)^\s*(?:fabric|loader_version)\s*=\s*"?([^"\s]+)').Groups[1].Value
    if (-not $mc -or -not $loader) { throw "No Minecraft and Fabric loader versions in $file : the preview mod is a Fabric mod." }
    New-Item -ItemType Directory -Force $Dir | Out-Null
    $jar = Join-Path $Dir "fabric-server-$mc-$loader.jar"
    if (-not (Test-Path $jar)) {
        $installer = (Invoke-RestMethod 'https://meta.fabricmc.net/v2/versions/installer' | ForEach-Object { $_ } |
            Where-Object stable | Select-Object -First 1).version
        $url = "https://meta.fabricmc.net/v2/versions/loader/$mc/$loader/$installer/server/jar"
        Write-Host "Downloading Fabric server launcher from $url"
        Invoke-WebRequest $url -OutFile $jar -UseBasicParsing
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

function Test-Java([string]$Exe) {
    # Minecraft 26.x needs Java 25. java prints its version on the error stream, which Windows PowerShell
    # turns into errors: they must not stop the script here.
    if (-not (Test-Path $Exe)) { return $false }
    $ErrorActionPreference = 'Continue'
    $version = & $Exe -version 2>&1 | Out-String
    return ($version -match 'version "(\d+)' -and [int]$Matches[1] -ge 25)
}

function Find-Java {
    # JAVA_HOME first, then PATH. The user-level value covers shells opened before Java was installed.
    $candidates = @()
    foreach ($javaHome in @($env:JAVA_HOME, [Environment]::GetEnvironmentVariable('JAVA_HOME', 'User'))) {
        if ($javaHome) { $candidates += Join-Path $javaHome 'bin\java.exe' }
    }
    $onPath = Get-Command java -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($onPath) { $candidates += $onPath.Source }
    foreach ($candidate in $candidates) { if (Test-Java $candidate) { return $candidate } }
    # Whoever has played Minecraft 26 already has the right Java: each launcher downloads its own and
    # keeps it in a folder of its own, off the PATH.
    $roots = "$env:LOCALAPPDATA\Packages\Microsoft.4297127D64EC6_8wekyb3d8bbwe\LocalCache\Local\runtime",
        "$env:APPDATA\.minecraft\runtime",
        "${env:ProgramFiles(x86)}\Minecraft Launcher\runtime",
        "$env:APPDATA\PrismLauncher\java",
        "$env:APPDATA\ModrinthApp\meta\java_versions",
        "$env:USERPROFILE\curseforge\minecraft\Install\runtime"
    foreach ($root in $roots) {
        if (-not (Test-Path $root)) { continue }
        foreach ($exe in Get-ChildItem $root -Recurse -Filter java.exe -ErrorAction SilentlyContinue) {
            if (Test-Java $exe.FullName) { return $exe.FullName }
        }
    }
    throw 'Java 25 or newer was not found. Start Minecraft 26 once from its launcher, which downloads its own Java, or install Java 25 from https://adoptium.net'
}

function Invoke-Java([string]$WorkDir, [string]$Log, [string[]]$Arguments, [switch]$Background) {
    # Runs java in a folder, its output in a log and its errors in a second one beside it, and gives the exit code.
    # Through Start-Process and files, because Windows PowerShell stops a script on the first line a program
    # writes to its error stream once that stream is redirected, and Java writes its warnings there.
    $quoted = $Arguments | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }
    $errors = [IO.Path]::ChangeExtension($Log, '.errors.log')
    $start = @{ FilePath = (Find-Java); ArgumentList = $quoted; WorkingDirectory = $WorkDir; NoNewWindow = $true; PassThru = $true
        RedirectStandardOutput = $Log; RedirectStandardError = $errors }
    if (-not $Background) { return (Start-Process @start -Wait).ExitCode }
    # A long computation steps aside: below the normal priority, Windows serves every other program
    # first, the window the person is looking at among them, and gives this one what is left.
    $process = Start-Process @start
    # Asked for while the process lives, or its exit code is lost once it has ended.
    $null = $process.Handle
    try { $process.PriorityClass = 'BelowNormal' } catch { }
    $process.WaitForExit()
    return $process.ExitCode
}

function Get-Bootstrap {
    if (-not (Test-Path $Bootstrap)) {
        New-Item -ItemType Directory -Force $ToolsDir | Out-Null
        Write-Host "Downloading packwiz-installer-bootstrap from $BootstrapUrl"
        Invoke-WebRequest $BootstrapUrl -OutFile $Bootstrap -UseBasicParsing
    }
    return $Bootstrap
}

function Get-PackStamp([string]$Pack) {
    # Changes when the pack's mods do, so the work folder is filled again only then.
    if (Test-PackwizPack $Pack) {
        return (Get-FileHash (Join-Path $Pack 'pack.toml')).Hash + (Get-FileHash (Join-Path $Pack 'index.toml')).Hash
    }
    $jars = Get-ChildItem (Join-Path $Pack 'mods') -Filter '*.jar' | Sort-Object Name
    return $Pack + '|' + (($jars | ForEach-Object { "$($_.Name):$($_.Length):$($_.LastWriteTimeUtc.Ticks)" }) -join '|')
}

function Sync-Pack([string]$Pack, [string]$TargetDir) {
    # Puts the pack's mods and config into the throwaway server's folder.
    New-Item -ItemType Directory -Force (Join-Path $TargetDir 'mods') | Out-Null
    if (Test-PackwizPack $Pack) {
        # The server side of the pack only: the throwaway server is a dedicated server. packwiz-installer
        # reads the pack straight from the disk, so the packwiz tool itself is not needed.
        $log = Join-Path $TargetDir 'last-sync.log'
        $code = Invoke-Java $TargetDir $log @('-jar', (Get-Bootstrap), '-g', '-s', 'server', ([Uri](Join-Path $Pack 'pack.toml')).AbsoluteUri)
        if ($code -ne 0) {
            throw "The pack's mods could not be installed (packwiz-installer, code $code). See $log. A pack edited by hand needs 'packwiz refresh' first, so that its index matches its files."
        }
        return
    }
    # A game folder: the same jars and the same config as the game. Fabric leaves a mod made for the
    # client alone on a server, as long as the mod says so.
    Get-ChildItem (Join-Path $TargetDir 'mods') -Filter '*.jar' | Remove-Item
    Copy-Item (Join-Path $Pack 'mods\*.jar') (Join-Path $TargetDir 'mods')
    Copy-Item (Join-Path $Pack 'config') $TargetDir -Recurse -Force
}
