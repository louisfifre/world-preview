<#
.SYNOPSIS
Serves the legacy preview page to the page launcher of Outpost Tools, which shows it in a frame.

.DESCRIPTION
Not part of the engine: it stays only while Outpost Tools' page launcher still starts it, and goes
once that launcher stops. It opens no window of its own. A web page cannot start a program or read a
file, so this script is the small local server behind page/preview.html: it serves the page on
localhost only, gives it the pack's Tectonic values, runs the driver (world-preview.exe, built here
when it is missing or stale) in the background when the page asks for a run, and hands the page the
results. It stops when -ParentPid ends, or once the page's pings stop.

.PARAMETER Pack
The folder holding the pack's pack.toml, as the driver's --pack. Read from WORLD_PREVIEW_PACK when omitted.

.PARAMETER Dir
The work folder of the throwaway server, as the driver's --dir. run\preview when omitted.

.PARAMETER Out
Where this server reads and writes previews, <Dir>\out when omitted.

.PARAMETER Exports
Where the page's Export button writes, one folder per export. run\exports when omitted: a folder of
its own, apart from the throwaway server's files, so an export is easy to find and the work folder
can be emptied without losing one.

.PARAMETER Port
The local port.

.PARAMETER NoWindow
Changes nothing: there is no window any more. Kept because Outpost Tools passes it.

.PARAMETER ParentPid
Stop when that process ends: the program that started this server and shows the preview in its own
window ends it so, rather than leaving it to wait for the pings to stop.
#>
param(
    [string]$Pack,
    [string]$Dir,
    [string]$Out,
    [string]$Exports,
    [int]$Port = 25590,
    [switch]$NoWindow,
    [int]$ParentPid
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path $PSScriptRoot -Parent
$DefaultDir = Join-Path $RepoRoot 'run\preview'

function Resolve-Pack([string]$Pack) {
    # The same lookup as the engine's (driver/), which checks the pack again at each run: here it only
    # finds the Tectonic config the page's controls start from.
    if (-not $Pack) { $Pack = $env:WORLD_PREVIEW_PACK }
    if (-not $Pack) { throw 'No pack given. Pass -Pack <a game folder or a packwiz pack>, or set WORLD_PREVIEW_PACK.' }
    if (-not (Test-Path $Pack -PathType Container)) { throw "No such folder: $Pack" }
    $Pack = (Resolve-Path $Pack).Path
    foreach ($folder in $Pack, (Join-Path $Pack 'minecraft'), (Join-Path $Pack '.minecraft')) {
        if (Test-Path (Join-Path $folder 'config\tectonic.json')) { return $folder }
    }
    throw "No config\tectonic.json in $Pack. A run's values are Tectonic's: the mods must include Tectonic, and the game must have started once with it."
}

$Origin = "http://localhost:$Port"
$Page    = Join-Path $RepoRoot 'page\preview.html'
$IdleMs  = 90000   # the page pings every 2 s; a hidden frame may be slowed down by the browser

function Get-PackTectonic([string]$Pack) {
    # Every setting of the pack's Tectonic config, read from the file itself so that none is left out without
    # a word: where the page's controls start. Each comes with its group, its kind (a number, or a switch
    # given as 1 or 0) and the comment Tectonic writes above it, if any. Tectonic writes one setting per line,
    # its groups one level deep. A name met twice would be ambiguous for a run, which replaces a value by
    # its name: it is listed apart and left out.
    $settings = [ordered]@{}
    $duplicates = @()
    $group = ''; $comment = ''
    foreach ($line in [IO.File]::ReadAllLines((Join-Path $Pack 'config\tectonic.json'))) {
        if ($line -match '^\s*//\s*(.*)$') { $comment = $Matches[1]; continue }
        if ($line -match '^\s*"([\w-]+)"\s*:\s*\{') { $group = $Matches[1]; $comment = ''; continue }
        if ($line -match '^\s*"([\w-]+)"\s*:\s*(-?[0-9.eE+-]+|true|false)\s*,?\s*$') {
            $key, $raw = $Matches[1], $Matches[2]
            # The file's own version number, not a setting of the world.
            if ($key -eq 'minor_version') { $comment = ''; continue }
            if ($settings.Contains($key)) { $duplicates += $key }
            else {
                $switch = $raw -in 'true', 'false'
                $settings[$key] = @{ key = $key; group = $group; kind = $(if ($switch) { 'switch' } else { 'number' })
                    value = $(if ($switch) { [double]($raw -eq 'true') } else { [double]::Parse($raw, [Globalization.CultureInfo]::InvariantCulture) })
                    hint = $comment }
            }
        }
        $comment = ''
    }
    foreach ($key in $duplicates) { $settings.Remove($key) }
    @{ settings = @($settings.Values); duplicates = @($duplicates | Select-Object -Unique) }
}

$listener = [Net.HttpListener]::new()
$listener.Prefixes.Add("$Origin/")
# The port is taken: a preview server is already running, and the host's frame is already served.
try { $listener.Start() } catch { return }

try {
    $Pack = Resolve-Pack $Pack
    if (-not $Dir) { $Dir = $DefaultDir }
    # Full paths: the run happens on another thread, whose current folder is not this one's.
    $Dir = [IO.Path]::GetFullPath($Dir)
    if (-not $Out) { $Out = Join-Path $Dir 'out' }
    $Out = [IO.Path]::GetFullPath($Out)
    # Beside the work folder rather than in it, so the work folder can be emptied without losing an export.
    if (-not $Exports) { $Exports = Join-Path $RepoRoot 'run\exports' }
    $Exports = [IO.Path]::GetFullPath($Exports)
} catch { $listener.Stop(); throw }

function Send-Bytes($context, [int]$status, [byte[]]$bytes, [string]$type) {
    $context.Response.StatusCode = $status
    $context.Response.ContentType = $type
    # A preview is replaced in place, so the browser must never reuse an old copy.
    $context.Response.Headers['Cache-Control'] = 'no-store'
    # A page that closed or gave up before its answer makes the write fail. That is its business:
    # the server goes on for the other windows.
    try {
        $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
        $context.Response.Close()
    } catch { $context.Response.Abort() }
}

function Send-Reply($context, [int]$status, [string]$body = '{}', [string]$type = 'application/json') {
    Send-Bytes $context $status ([Text.Encoding]::UTF8.GetBytes($body)) "$type; charset=utf-8"
}

# The preview being computed, if any: its background shell, the handle that says when it has ended, and
# the request that waits for its answer. It runs beside the request loop, so the page can fetch the
# sketch of the map while it waits. A shell of its own rather than a thread job: Windows PowerShell has none.
# It also keeps what was asked and when, for a window opened meanwhile: only the window that asked holds
# the waiting request, and any other one would show an idle page over a server that is computing.
$Run = $null
# What the last run threw, for a window that joined it and has no answer of its own to read.
$LastFailure = $null
# Whether the last run was stopped from the page, which is not a failure.
$LastStopped = $false

function Stop-RunJava {
    # The run is the driver, a child of this process; its server dies with it, through the driver's job
    # object. It generates no chunk, so nothing is left half-written but a throwaway world folder.
    Get-CimInstance Win32_Process -Filter "ParentProcessId=$PID AND Name = 'world-preview.exe'" |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

# The driver, world-preview.exe, built here when it is missing or older than its sources: a run is that
# program, so a page asking for one never waits on a build.
function Get-Driver {
    $driverDir = Join-Path $RepoRoot 'driver'
    $exe = Join-Path $driverDir 'target\release\world-preview.exe'
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
        $previous = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try { & cargo build --release -q --manifest-path (Join-Path $driverDir 'Cargo.toml') 2>&1 | ForEach-Object { Write-Host $_ } }
        finally { $ErrorActionPreference = $previous }
        if ($LASTEXITCODE -ne 0) { throw "The world-preview driver did not build (cargo exited with $LASTEXITCODE)." }
    }
    $exe
}
$Driver = Get-Driver

function Complete-Preview {
    # Answers the request that started the preview, once it has ended.
    $shell, $handle, $context, $stopped = $script:Run.Shell, $script:Run.Handle, $script:Run.Context, $script:Run.Stopped
    $script:Run = $null
    $failure = $null
    try { $null = $shell.EndInvoke($handle) }
    catch {
        # The sentence the run threw sits under the wrapping of the call: the page shows it as it is.
        $inner = $_.Exception
        while ($inner.InnerException) { $inner = $inner.InnerException }
        $failure = $inner.Message
    }
    # A run that was stopped ends on an error of its own, which is no trouble to report.
    if ($stopped) { $failure = $null }
    $script:LastFailure = $failure
    $script:LastStopped = [bool]$stopped
    $shell.Dispose()
    # The page may have been closed meanwhile: nobody to answer then.
    try {
        if ($failure) { Send-Reply $context 500 (ConvertTo-Json @{ error = $failure }) }
        else { Send-Reply $context 200 (ConvertTo-Json @{ stopped = [bool]$stopped }) }
    } catch { }
}

function Test-PreviewEnded {
    # True when a preview was running and has just been answered.
    if (-not $script:Run) { return $false }
    if (-not $script:Run.Handle.IsCompleted) {
        # Stop may have been asked before the run had started its Java: look again until the run ends.
        if ($script:Run.Stopped) { Stop-RunJava }
        return $false
    }
    Complete-Preview
    return $true
}

# A parent already gone would leave this server waiting for pings from a page that no longer exists.
$parent = if ($ParentPid) { Get-Process -Id $ParentPid -ErrorAction SilentlyContinue }
if ($ParentPid -and -not $parent) { $listener.Stop(); return }
try {
    :serve while ($true) {
        $null = Test-PreviewEnded
        $pending = $listener.GetContextAsync()
        # Waits in short slices, so a host that quit and the end of a preview are answered at once.
        $idle = [Diagnostics.Stopwatch]::StartNew()
        while (-not $pending.Wait(300)) {
            if (Test-PreviewEnded) { $idle.Restart() }
            # The host quitting stops this server, a preview under way too: the host asked first.
            if ($parent -and $parent.HasExited) { break serve }
            # A preview under way keeps the server up: the time without pings counts from its end.
            if (-not $Run -and $idle.ElapsedMilliseconds -gt $IdleMs) { break serve }
        }
        $context = $pending.Result
        # One bad request answers 500 and the server carries on.
        try {
            $request = $context.Request
            $method = $request.HttpMethod
            $path = $request.Url.AbsolutePath

            if ($method -eq 'GET' -and $path -eq '/') {
                Send-Reply $context 200 ([IO.File]::ReadAllText($Page)) 'text/html'
            }
            elseif ($method -eq 'GET' -and $path -eq '/api/ping') {
                # The ping also says when the page file last changed, so an open window takes a new page
                # by itself. As text: the number is too long for JavaScript to hold exactly.
                Send-Reply $context 200 "{`"page`":`"$([IO.File]::GetLastWriteTimeUtc($Page).Ticks)`"}"
            }
            elseif ($method -eq 'GET' -and $path -eq '/api/preview/config') {
                Send-Reply $context 200 (ConvertTo-Json (Get-PackTectonic $Pack) -Depth 4)
            }
            elseif ($method -eq 'GET' -and $path -eq '/api/preview/run') {
                $state = if ($Run) {
                    @{ running = $true; seed = $Run.Seed; samples = $Run.Samples; detail = $Run.Detail; tectonic = $Run.Tectonic
                       seconds = [int]((Get-Date) - $Run.Started).TotalSeconds }
                } else { @{ running = $false; error = $LastFailure; stopped = $LastStopped } }
                Send-Reply $context 200 (ConvertTo-Json $state)
            }
            elseif ($method -eq 'GET' -and $path -match '^/preview/data/(((coarse-\d+|partial)-)?(heights|biomes)\.bin|preview\.json|coarse\.json|partial\.json|progress\.json|run\.json|section\.json|section-\d\.bin|ores\.json|structures\.json|timing\.json)$') {
                $file = Join-Path $Out $Matches[1]
                if (Test-Path $file) { Send-Bytes $context 200 ([IO.File]::ReadAllBytes($file)) 'application/octet-stream' }
                else { Send-Reply $context 404 }
            }
            elseif ($method -ne 'POST' -or $request.Headers['Origin'] -ne $Origin) {
                # Only our own page may start anything, not another site open in the browser.
                Send-Reply $context 403
            }
            elseif ($path -eq '/api/preview') {
                # Starts the throwaway server in the background; the answer comes when it is done, under a
                # minute for the default area. Meanwhile the loop answers other requests: pings, the sketch.
                $body = [IO.StreamReader]::new($request.InputStream, [Text.Encoding]::UTF8).ReadToEnd() | ConvertFrom-Json
                $seed = [string]$body.seed
                # The values come as numbers, a switch as 1 or 0; the run writes a switch back as true or false.
                $tectonic = @{}; $asked = @{}
                $kinds = @{}
                foreach ($setting in (Get-PackTectonic $Pack).settings) { $kinds[$setting.key] = $setting.kind }
                $valid = $seed -match '^[\w -]{1,64}$'
                foreach ($entry in $body.tectonic.PSObject.Properties) {
                    $number = $entry.Value -as [double]
                    if (-not $kinds.ContainsKey($entry.Name) -or $null -eq $number) { $valid = $false; continue }
                    $asked[$entry.Name] = $number
                    $tectonic[$entry.Name] = if ($kinds[$entry.Name] -eq 'switch') { $number -ne 0 } else { $number }
                }
                # Grid points per side, counted every 16 blocks: from 4096 to 65536 blocks across, by steps of 4096.
                $samples = if ($null -eq $body.samples) { 512 } else { $body.samples -as [int] }
                if ($samples -lt 256 -or $samples -gt 4096 -or $samples % 256) { $valid = $false }
                # Blocks between two points of the map: 16 for the full map, 32 or 64 to stop at a sketch.
                $detail = if ($null -eq $body.detail) { 16 } else { $body.detail -as [int] }
                if ($detail -notin 16, 32, 64) { $valid = $false }
                # Past 32768 blocks, the full map would hold four times the points of the widest one measured,
                # and its cuts and structures as much more: the coarser details only.
                if ($samples -gt 2048 -and $detail -eq 16) { $valid = $false }
                if (-not $valid) { Send-Reply $context 400 }
                elseif ($Run) { Send-Reply $context 409 (ConvertTo-Json @{ error = 'A preview is already being computed.' }) }
                else {
                    # The sketch, the progress and the draft of the run before must not pass for those of this one.
                    Remove-Item (Join-Path $Out 'coarse.json'), (Join-Path $Out 'progress.json'), (Join-Path $Out 'partial.json') -ErrorAction SilentlyContinue
                    # The driver's own arguments: a switch as true or false, a number written with a dot.
                    $arguments = @('--repo', $RepoRoot, '--pack', $Pack, '--dir', $Dir, '--out', $Out, '--seed', $seed,
                                   '--samples', "$samples", '--step', '16', '--detail', "$detail")
                    foreach ($key in $tectonic.Keys) {
                        $value = $tectonic[$key]
                        $text = if ($value -is [bool]) { "$value".ToLower() } else { ([double]$value).ToString([Globalization.CultureInfo]::InvariantCulture) }
                        $arguments += '--tectonic', "$key=$text"
                    }
                    $shell = [powershell]::Create()
                    $null = $shell.AddScript({
                        param($exe, $arguments)
                        # Its error stream is read as text: what it says there is the sentence the page shows.
                        $errors = @(& $exe @arguments 2>&1 | Where-Object { $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { $_.Exception.Message })
                        if ($LASTEXITCODE -ne 0) {
                            if ($errors.Count) { throw ($errors -join "`n") }
                            throw "The world-preview driver failed (code $LASTEXITCODE)."
                        }
                    })
                    $null = $shell.AddArgument($Driver)
                    $null = $shell.AddArgument($arguments)
                    $Run = @{ Shell = $shell; Handle = $shell.BeginInvoke(); Context = $context
                              Seed = $seed; Samples = $samples; Detail = $detail; Tectonic = $asked; Started = Get-Date }
                }
            }
            elseif ($path -eq '/api/preview/stop') {
                if ($Run) { $Run.Stopped = $true; Stop-RunJava }
                Send-Reply $context 200
            }
            elseif ($path -match '^/api/preview/export/([\w-]{1,90})/((biomes|flat|height|temperature|structures)(-3d)?\.png|section\.png|export\.json)$') {
                # One file of an export: the pictures of the map and what the page measured, kept in a
                # folder of their own so a try can be looked at again, or shown to someone, later.
                $folder = Join-Path $Exports $Matches[1]
                $name = $Matches[2]
                if ($request.ContentLength64 -gt 64MB) { Send-Reply $context 413 }
                else {
                    $null = New-Item -ItemType Directory -Force $folder
                    $file = [IO.File]::Create((Join-Path $folder $name))
                    try { $request.InputStream.CopyTo($file) } finally { $file.Dispose() }
                    Send-Reply $context 200 (ConvertTo-Json @{ folder = $folder })
                }
            }
            elseif ($path -match '^/api/preview/export/([\w-]{1,90})/open$') {
                # A page cannot open a folder on the disk, so it asks here. Only an export's own folder: the
                # name is a plain folder name, so it cannot point anywhere else.
                $folder = Join-Path $Exports $Matches[1]
                if (Test-Path $folder -PathType Container) {
                    Start-Process explorer.exe -ArgumentList "`"$folder`""
                    Send-Reply $context 200
                }
                else { Send-Reply $context 404 }
            }
            else {
                Send-Reply $context 404
            }
        } catch {
            try { Send-Reply $context 500 (ConvertTo-Json @{ error = $_.Exception.Message }) } catch { }
        }
    }
} finally {
    $listener.Stop()
    # Quitting stops the preview being computed: without a host, nobody could see it go on, nor stop it,
    # and a wide one takes the machine for many minutes.
    if ($Run) {
        Stop-RunJava
        $null = $Run.Handle.AsyncWaitHandle.WaitOne()
    }
}
