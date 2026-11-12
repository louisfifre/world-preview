<#
.SYNOPSIS
Opens the world preview page in a bare browser window, and serves it.

.DESCRIPTION
A web page cannot start a program or read a file, so this script is the small local server behind
the page. It serves page/preview.html on localhost only, gives it the pack's Tectonic values, runs
preview.ps1 in the background when the page asks for a run, and hands the page the results.
The page pings while its window is open; the server stops once the pings stop.

An icon in the notification area says the server is there, turns amber while a preview is
computed, and tells when one is ready or has failed.

.PARAMETER Pack
The folder holding the pack's pack.toml, as in preview.ps1. Read from WORLD_PREVIEW_PACK when omitted.

.PARAMETER Dir
The work folder of the throwaway server, as in preview.ps1. run\preview when omitted.

.PARAMETER Out
Where this server reads and writes previews, <Dir>\out when omitted. The capture script gives its own.

.PARAMETER Port
The local port. A second server on another port (the capture script starts one) lives beside the
first without touching it.

.PARAMETER NoWindow
Serve without opening the browser window (for tests).

.PARAMETER NoTray
Serve without the icon in the notification area (for tests and for the capture script).
#>
param(
    [string]$Pack,
    [string]$Dir,
    [string]$Out,
    [int]$Port = 25590,
    [switch]$NoWindow,
    [switch]$NoTray
)

. "$PSScriptRoot\common.ps1"

$Origin  = "http://localhost:$Port"
$Page    = Join-Path $RepoRoot 'page\preview.html'
$Size    = '1400,940'
$IdleMs  = 90000   # the page pings every 10 s; a hidden window may be slowed down by the browser

function Open-Window {
    if ($NoWindow) { return }
    $browser = Find-AppBrowser
    if (-not $browser) { Start-Process "$Origin/"; return }
    $arguments = "--app=$Origin/", "--window-size=$Size"
    # A browser that is already running must be joined under the profile folder it was started with. The same folder
    # reached by another path (a portable install links its own into the default place) is taken for a second
    # browser on a locked profile, and that one exits without a window.
    $running = Get-CimInstance Win32_Process -Filter "Name='$(Split-Path $browser -Leaf)'" |
        Where-Object { $_.CommandLine -notmatch '--type=' -and $_.CommandLine -notmatch '--headless' } |
        Select-Object -First 1
    if ($running -and $running.CommandLine -match '--user-data-dir=(?:"([^"]+)"|(\S+))') {
        $arguments += "--user-data-dir=`"$($Matches[1])$($Matches[2])`""
    }
    Start-Process $browser -ArgumentList $arguments
}

$listener = [Net.HttpListener]::new()
$listener.Prefixes.Add("$Origin/")
try { $listener.Start() }
catch {
    # The port is taken: a preview server is already running, so only show its window.
    Open-Window
    return
}

# Checked once the port is ours: a wrong pack or folder stops here, before any window opens.
try {
    $Pack = Resolve-Pack $Pack
    if (-not $Dir) { $Dir = $DefaultDir }
    # Full paths: the run happens on another thread, whose current folder is not this one's.
    $Dir = [IO.Path]::GetFullPath($Dir)
    if (-not $Out) { $Out = Join-Path $Dir 'out' }
    $Out = [IO.Path]::GetFullPath($Out)
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

# The sentences of the tray icon.
$TrayText = @{
    idle    = 'World preview'
    busy    = 'World preview: computing a map'
    preview = 'Open the preview'
    quit    = 'Quit'
    ready   = 'The world preview is ready.'
    failed  = 'The world preview failed.'
}

function Start-Tray {
    # It lives on its own thread, because this one spends its time waiting for requests.
    # The two threads only share this table: the server writes Busy, Notify and Stop, the icon writes Ask.
    $shared = [hashtable]::Synchronized(@{ Busy = $false; Notify = $null; Ask = $null; Stop = $false; Text = $TrayText })
    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.ApartmentState = 'STA'
    $runspace.Open()
    $runspace.SessionStateProxy.SetVariable('shared', $shared)
    $shell = [powershell]::Create()
    $shell.Runspace = $runspace
    $null = $shell.AddScript({
        Add-Type -AssemblyName System.Windows.Forms, System.Drawing
        # A block seen from above its corner, the same as the icon of the page: top, left side, right side.
        function New-BlockIcon([string]$top, [string]$left, [string]$right) {
            $bitmap = [Drawing.Bitmap]::new(32, 32)
            $pen = [Drawing.Graphics]::FromImage($bitmap)
            $pen.SmoothingMode = 'AntiAlias'
            # The leading commas keep each face whole: without them the three lists pour into one flat
            # list, nothing is drawn, and the icon is an empty square.
            $faces = @(
                , @($top,   @(16, 2), @(30, 9),  @(16, 16), @(2, 9))
                , @($left,  @(2, 9),  @(16, 16), @(16, 30), @(2, 23))
                , @($right, @(30, 9), @(16, 16), @(16, 30), @(30, 23))
            )
            foreach ($face in $faces) {
                $brush = [Drawing.SolidBrush]::new([Drawing.ColorTranslator]::FromHtml($face[0]))
                $points = [Drawing.PointF[]]($face[1..4] | ForEach-Object { [Drawing.PointF]::new($_[0], $_[1]) })
                $pen.FillPolygon($brush, $points)
            }
            [Drawing.Icon]::FromHandle($bitmap.GetHicon())
        }
        $idle = New-BlockIcon '#7fb850' '#8b6344' '#6b4b33'
        $busy = New-BlockIcon '#e5a44e' '#a8742f' '#75501f'
        $text = $shared.Text
        $icon = [Windows.Forms.NotifyIcon]::new()
        $icon.Icon = $idle
        $icon.Text = $text.idle
        $menu = [Windows.Forms.ContextMenuStrip]::new()
        foreach ($ask in 'preview', 'quit') {
            $item = $menu.Items.Add($text[$ask])
            $item.Tag = $ask
            $item.add_Click({ param($source) $shared.Ask = $source.Tag })
        }
        $icon.ContextMenuStrip = $menu
        $icon.add_DoubleClick({ $shared.Ask = 'preview' })
        $icon.Visible = $true
        $state = @{ Busy = $false }
        $timer = [Windows.Forms.Timer]::new()
        $timer.Interval = 250
        $timer.add_Tick({
            if ($shared.Stop) { $timer.Stop(); $icon.Visible = $false; $icon.Dispose(); [Windows.Forms.Application]::ExitThread(); return }
            if ($shared.Busy -ne $state.Busy) {
                $state.Busy = $shared.Busy
                $icon.Icon = if ($state.Busy) { $busy } else { $idle }
                $icon.Text = if ($state.Busy) { $text.busy } else { $text.idle }
            }
            if ($shared.Notify) {
                $icon.ShowBalloonTip(4000, $text.idle, $shared.Notify, 'None')
                $shared.Notify = $null
            }
        })
        $timer.Start()
        [Windows.Forms.Application]::Run()
    })
    $shared.Done = $shell.BeginInvoke().AsyncWaitHandle
    $shared
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
    # The Java of the run is a child of this process. It generates no chunk, so nothing is left
    # half-written but a throwaway world folder; the run then ends by itself, which frees its folder.
    Get-CimInstance Win32_Process -Filter "ParentProcessId=$PID AND Name LIKE 'java%'" |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

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
    if ($tray) {
        $tray.Busy = $false
        if (-not $stopped) { $tray.Notify = if ($failure) { $TrayText.failed } else { $TrayText.ready } }
    }
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

Open-Window
$tray = if ($NoTray) { $null } else { Start-Tray }
try {
    :serve while ($true) {
        $null = Test-PreviewEnded
        $pending = $listener.GetContextAsync()
        # Waits in short slices, so a choice made in the tray menu and the end of a preview are answered at once.
        $idle = [Diagnostics.Stopwatch]::StartNew()
        while (-not $pending.Wait(300)) {
            if (Test-PreviewEnded) { $idle.Restart() }
            # A preview under way keeps the server up: the time without pings counts from its end.
            if (-not $Run -and $idle.ElapsedMilliseconds -gt $IdleMs) { break serve }
            if ($tray -and $tray.Ask) {
                $ask = $tray.Ask; $tray.Ask = $null
                if ($ask -eq 'quit') { break serve }
                Open-Window
            }
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
                Send-Reply $context 200
            }
            elseif ($method -eq 'GET' -and $path -eq '/api/preview/config') {
                Send-Reply $context 200 (ConvertTo-Json (Get-PackTectonic $Pack))
            }
            elseif ($method -eq 'GET' -and $path -eq '/api/preview/run') {
                $state = if ($Run) {
                    @{ running = $true; seed = $Run.Seed; samples = $Run.Samples; tectonic = $Run.Tectonic
                       seconds = [int]((Get-Date) - $Run.Started).TotalSeconds }
                } else { @{ running = $false; error = $LastFailure; stopped = $LastStopped } }
                Send-Reply $context 200 (ConvertTo-Json $state)
            }
            elseif ($method -eq 'GET' -and $path -match '^/preview/data/((coarse-\d+-)?(heights|biomes)\.bin|preview\.json|coarse\.json|run\.json|section\.json|section-\d\.bin|ores\.json|structures\.json)$') {
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
                $tectonic = @{}
                $valid = $seed -match '^[\w -]{1,64}$'
                foreach ($entry in $body.tectonic.PSObject.Properties) {
                    if ($TectonicKeys -notcontains $entry.Name -or $null -eq ($entry.Value -as [double])) { $valid = $false }
                    else { $tectonic[$entry.Name] = [double]$entry.Value }
                }
                # Grid points per side, one every 16 blocks: from 4096 to 32768 blocks across, by steps of 4096.
                $samples = if ($null -eq $body.samples) { 512 } else { $body.samples -as [int] }
                if ($samples -lt 256 -or $samples -gt 2048 -or $samples % 256) { $valid = $false }
                if (-not $valid) { Send-Reply $context 400 }
                elseif ($Run) { Send-Reply $context 409 (ConvertTo-Json @{ error = 'A preview is already being computed.' }) }
                else {
                    # The sketch of the run before must not pass for the sketch of this one.
                    Remove-Item (Join-Path $Out 'coarse.json') -ErrorAction SilentlyContinue
                    $shell = [powershell]::Create()
                    $null = $shell.AddScript({
                        param($script, $pack, $dir, $seed, $tectonic, $samples, $out)
                        & $script -Pack $pack -Dir $dir -Seed $seed -Tectonic $tectonic -Samples $samples -Out $out *> $null
                    })
                    foreach ($argument in "$PSScriptRoot\preview.ps1", $Pack, $Dir, $seed, $tectonic, $samples, $Out) {
                        $null = $shell.AddArgument($argument)
                    }
                    $Run = @{ Shell = $shell; Handle = $shell.BeginInvoke(); Context = $context
                              Seed = $seed; Samples = $samples; Tectonic = $tectonic; Started = Get-Date }
                    if ($tray) { $tray.Busy = $true }
                }
            }
            elseif ($path -eq '/api/preview/stop') {
                if ($Run) { $Run.Stopped = $true; Stop-RunJava }
                Send-Reply $context 200
            }
            elseif ($path -match '^/api/preview/export/([\w-]{1,90})/((biomes|flat|height|temperature|structures)(-3d)?\.png|section\.png|export\.json)$') {
                # One file of an export: the pictures of the map and what the page measured, kept in a
                # folder of their own so a try can be looked at again, or shown to someone, later.
                $folder = Join-Path (Join-Path $Dir 'exports') $Matches[1]
                $name = $Matches[2]
                if ($request.ContentLength64 -gt 64MB) { Send-Reply $context 413 }
                else {
                    $null = New-Item -ItemType Directory -Force $folder
                    $file = [IO.File]::Create((Join-Path $folder $name))
                    try { $request.InputStream.CopyTo($file) } finally { $file.Dispose() }
                    Send-Reply $context 200 (ConvertTo-Json @{ folder = $folder })
                }
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
    # Let the icon's thread leave by itself. Ending the script while its timer still ticks stops that
    # thread in the middle of a tick, which Windows shows as an error box ("The pipeline has been stopped").
    if ($tray) { $tray.Stop = $true; $null = $tray.Done.WaitOne(3000) }
    # Quitting stops the preview being computed: without a window or an icon, nobody could see it go on,
    # nor stop it, and a wide one takes the machine for many minutes.
    if ($Run) {
        Stop-RunJava
        $null = $Run.Handle.AsyncWaitHandle.WaitOne()
    }
}
