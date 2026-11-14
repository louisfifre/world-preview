<#
.SYNOPSIS
Opens the world preview page in a bare browser window, and serves it.

.DESCRIPTION
A web page cannot start a program or read a file, so this script is the small local server behind
the page. It serves page/preview.html on localhost only, gives it the pack's Tectonic values, runs
preview.ps1 in the background when the page asks for a run, and hands the page the results.
The window is the application: it opens on a browser profile of its own (run\browser), and closing it
stops the server and any preview being computed. Opening it again while it runs shows that window.
The page also pings while it is open, so a server whose window it cannot follow (another page holds
the preview, or no browser could show a bare window) stops once the pings stop.

.PARAMETER Pack
The folder holding the pack's pack.toml, as in preview.ps1. Read from WORLD_PREVIEW_PACK when omitted.

.PARAMETER Dir
The work folder of the throwaway server, as in preview.ps1. run\preview when omitted.

.PARAMETER Out
Where this server reads and writes previews, <Dir>\out when omitted. The capture script gives its own.

.PARAMETER Exports
Where the page's Export button writes, one folder per export. run\exports when omitted: a folder of
its own, apart from the throwaway server's files, so an export is easy to find and the work folder
can be emptied without losing one.

.PARAMETER Port
The local port. A second server on another port (the capture script starts one) lives beside the
first without touching it.

.PARAMETER NoWindow
Serve without opening the browser window: for tests, and for a page that shows the preview inside its own.

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

. "$PSScriptRoot\common.ps1"

$Origin  = "http://localhost:$Port"
$Page    = Join-Path $RepoRoot 'page\preview.html'
$Size    = '1400,940'
$BrowserProfile = Join-Path $RepoRoot 'run\browser'
$IdleMs  = 90000   # the page pings every 2 s; a hidden window may be slowed down by the browser

function Open-Window {
    if ($NoWindow) { return }
    Open-AppWindow "$Origin/" $Size $BrowserProfile
}

$listener = [Net.HttpListener]::new()
$listener.Prefixes.Add("$Origin/")
try { $listener.Start() }
catch {
    # The port is taken: a preview server is already running, so only show its window, or open one on it.
    if (-not $NoWindow -and -not (Show-AppWindow $BrowserProfile)) { $null = Open-Window }
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
    if (-not $Exports) { $Exports = $DefaultExports }
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

$window = Open-Window
# A parent already gone would leave this server waiting for pings from a page that no longer exists.
$parent = if ($ParentPid) { Get-Process -Id $ParentPid -ErrorAction SilentlyContinue }
if ($ParentPid -and -not $parent) { $listener.Stop(); return }
try {
    :serve while ($true) {
        $null = Test-PreviewEnded
        $pending = $listener.GetContextAsync()
        # Waits in short slices, so a closed window and the end of a preview are answered at once.
        $idle = [Diagnostics.Stopwatch]::StartNew()
        while (-not $pending.Wait(300)) {
            if (Test-PreviewEnded) { $idle.Restart() }
            # Closing the window quits, a preview under way too: the page asked first.
            if ($window -and $window.HasExited) { break serve }
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
                    $shell = [powershell]::Create()
                    $null = $shell.AddScript({
                        param($script, $pack, $dir, $seed, $tectonic, $samples, $detail, $out)
                        & $script -Pack $pack -Dir $dir -Seed $seed -Tectonic $tectonic -Samples $samples -Detail $detail -Out $out *> $null
                    })
                    foreach ($argument in "$PSScriptRoot\preview.ps1", $Pack, $Dir, $seed, $tectonic, $samples, $detail, $Out) {
                        $null = $shell.AddArgument($argument)
                    }
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
    # Quitting stops the preview being computed: without a window, nobody could see it go on, nor stop it,
    # and a wide one takes the machine for many minutes.
    if ($Run) {
        Stop-RunJava
        $null = $Run.Handle.AsyncWaitHandle.WaitOne()
    }
}
