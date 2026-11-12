<#
.SYNOPSIS
Takes pictures of the preview page without showing a window, so that a change can be looked at.

.DESCRIPTION
Starts a second page server on its own port, with its own preview results, then drives a
headless Chromium browser over the DevTools protocol: open a page, wait until the page says it is
ready, save a PNG. A preview server already running, its window and the preview it shows are never
touched.

A page says it is ready by setting data-ready="1" on its root element, once everything it had to
fetch is drawn. Taking the picture when the page loads is not enough: the data arrives after.

The page reads its state from the address, so most pictures need no click:
/?view=height,relief3d&biome=minecraft:desert. For the rest, a shot can run a line of JavaScript
in the page first.

.PARAMETER Pack
The folder holding the pack's pack.toml, as in preview.ps1. Read from WORLD_PREVIEW_PACK when omitted.

.PARAMETER Dir
The work folder of the throwaway server, as in preview.ps1. run\preview when omitted. The
captured previews land in its out-capture folder, or the one -Previews names.

.PARAMETER Previews
The folder of the work folder where the captured previews land: out-capture when omitted. Another
name keeps the previews of two people capturing at once apart, since a computation replaces them.

.PARAMETER Shots
One hashtable per picture. Name is the file name. Path defaults to /. Size defaults to
'1400,940'. Scheme is 'dark' or 'light'. Eval is JavaScript run once the page is ready. Wait is
how long to let the page settle after that, in milliseconds. Stay keeps the page of the shot before
instead of opening one. Until is a JavaScript condition to wait for before the picture.
Scale is the pixel density (2 gives a picture twice as fine, for an illustration). Clip is a CSS
selector: the picture holds that element only, with Pad pixels around it. Url opens any address
instead of the page, a local file included.
@{ Name = 'relief'; Path = '/?view=height' }, @{ Name = 'light'; Scheme = 'light' }
Without -Shots, the usual set is taken.

.PARAMETER Seed
Computes a preview for this seed first (see preview.ps1). Without it, the last captured preview is
reused, or cap-1 is computed when there is none.

.PARAMETER Tectonic
Tectonic values for that computation, as in preview.ps1.

.PARAMETER Samples
Grid points per side for that computation, as in preview.ps1: from 256 to 2048.

.PARAMETER OutDir
Where the pictures land. run\captures when omitted (not versioned).
#>
param(
    [string]$Pack,
    [string]$Dir,
    [string]$Previews = 'out-capture',
    [hashtable[]]$Shots,
    [string]$Seed,
    [hashtable]$Tectonic = @{},
    [int]$Samples = 512,
    [string]$OutDir
)

. "$PSScriptRoot\common.ps1"

# A pack is needed only to serve the page or to compute; a shot of a local file (the boards) needs neither.
$needsServer = -not $Shots -or @($Shots | Where-Object { -not $_.Url }).Count
$Port = 25591
$DebugPort = 9333
if ($needsServer) {
    $Pack = Resolve-Pack $Pack
    if (-not $Dir) { $Dir = $DefaultDir }
    $Dir = [IO.Path]::GetFullPath($Dir)
    $PreviewOut = Join-Path $Dir $Previews
}
if (-not $OutDir) { $OutDir = Join-Path $RepoRoot 'run\captures' }
New-Item -ItemType Directory -Force $OutDir | Out-Null

if (-not $Shots) {
    $Shots = @(
        @{ Name = 'biomes' }
        @{ Name = 'flat';            Path = '/?view=flat' }
        @{ Name = 'relief';          Path = '/?view=height' }
        @{ Name = 'temperature';     Path = '/?view=temperature' }
        @{ Name = 'structures';      Path = '/?view=structures' }
        @{ Name = 'section';         Path = '/?view=section' }
        @{ Name = '3d';              Path = '/?view=height,relief3d' }
        @{ Name = 'chosen-biomes';   Path = '/?biome=minecraft:desert,minecraft:badlands' }
        @{ Name = 'light';           Scheme = 'light' }
        @{ Name = 'small-window';    Size = '1000,640' }
    )
}

if ($needsServer -and ($Seed -or -not (Test-Path (Join-Path $PreviewOut 'preview.json')))) {
    if (-not $Seed) { $Seed = 'cap-1' }
    & "$PSScriptRoot\preview.ps1" -Pack $Pack -Dir $Dir -Seed $Seed -Tectonic $Tectonic -Samples $Samples -Out $PreviewOut
}

$browserExe = Find-AppBrowser
if (-not $browserExe) { throw 'No Chromium browser found (Brave or Edge).' }

$script:callId = 0
function Send-Cdp($socket, [string]$method, $params = @{}) {
    # One DevTools call: send it, then read messages until its own answer comes back.
    $script:callId++
    $mine = $script:callId
    $json = @{ id = $mine; method = $method; params = $params } | ConvertTo-Json -Depth 6 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $socket.SendAsync([ArraySegment[byte]]::new($bytes), 'Text', $true, [Threading.CancellationToken]::None).Wait()
    $buffer = [byte[]]::new(1MB)
    while ($true) {
        $stream = [IO.MemoryStream]::new()
        do {
            $got = $socket.ReceiveAsync([ArraySegment[byte]]::new($buffer), [Threading.CancellationToken]::None).Result
            $stream.Write($buffer, 0, $got.Count)
        } until ($got.EndOfMessage)
        $reply = [Text.Encoding]::UTF8.GetString($stream.ToArray()) | ConvertFrom-Json
        if ($reply.id -eq $mine) { return $reply.result }
    }
}

$server = if ($needsServer) {
    Start-Process pwsh -PassThru -WindowStyle Hidden -ArgumentList '-NoProfile', '-File',
        "`"$PSScriptRoot\serve.ps1`"", '-NoWindow', '-NoTray', '-Port', $Port,
        '-Pack', "`"$Pack`"", '-Dir', "`"$Dir`"", '-Out', "`"$PreviewOut`""
}
# Its own profile folder: the owner's browser, its tabs and its sign-ins stay out of it.
$browser = Start-Process $browserExe -PassThru -ArgumentList '--headless=new', "--remote-debugging-port=$DebugPort",
    "--user-data-dir=`"$(Join-Path $ToolsDir 'capture-profile')`"", '--hide-scrollbars', '--enable-unsafe-swiftshader', 'about:blank'
try {
    $target = $null
    foreach ($try in 1..60) {
        try { $target = Invoke-RestMethod "http://localhost:$DebugPort/json/new?about:blank" -Method Put; break }
        catch { Start-Sleep -Milliseconds 250 }
    }
    if (-not $target) { throw 'The browser did not open its DevTools port.' }
    if ($server) {
        foreach ($try in 1..60) {
            try { $null = Invoke-WebRequest "http://localhost:$Port/api/ping" -UseBasicParsing -TimeoutSec 2; break }
            catch { Start-Sleep -Milliseconds 250 }
        }
    }
    $socket = [Net.WebSockets.ClientWebSocket]::new()
    $socket.ConnectAsync([Uri]$target.webSocketDebuggerUrl, [Threading.CancellationToken]::None).Wait()
    $null = Send-Cdp $socket 'Page.enable'

    foreach ($shot in $Shots) {
        $path = if ($shot.Path) { $shot.Path } else { '/' }
        $width, $height = ($(if ($shot.Size) { $shot.Size } else { '1400,940' })).Split(',')
        $scheme = if ($shot.Scheme) { $shot.Scheme } else { 'dark' }
        $scale = if ($shot.Scale) { [double]$shot.Scale } else { 1 }
        $null = Send-Cdp $socket 'Emulation.setDeviceMetricsOverride' @{ width = [int]$width; height = [int]$height; deviceScaleFactor = $scale; mobile = $false }
        $null = Send-Cdp $socket 'Emulation.setEmulatedMedia' @{ features = @(@{ name = 'prefers-color-scheme'; value = $scheme }) }
        $url = if ($shot.Url) { $shot.Url } else { "http://localhost:$Port$path" }
        if (-not $shot.Stay) { $null = Send-Cdp $socket 'Page.navigate' @{ url = $url } }
        # Waits for the page to say it is drawn, or for Until. A computation started by an earlier shot no
        # longer holds the server: a page opened while it runs has no map, so follow a run with Stay and Until.
        $ready = $false
        foreach ($try in 1..480) {
            Start-Sleep -Milliseconds 250
            $condition = if ($shot.Until) { $shot.Until } else { "document.documentElement.dataset.ready === '1'" }
            $state = Send-Cdp $socket 'Runtime.evaluate' @{ expression = $condition }
            if ($state.result.value) { $ready = $true; break }
        }
        if ($shot.Eval) { $null = Send-Cdp $socket 'Runtime.evaluate' @{ expression = $shot.Eval; awaitPromise = $true } }
        Start-Sleep -Milliseconds $(if ($shot.Wait) { [int]$shot.Wait } else { 300 })
        $picture = @{ format = 'png' }
        if ($shot.Clip) {
            $pad = [int]$shot.Pad
            $found = (Send-Cdp $socket 'Runtime.evaluate' @{ expression = "JSON.stringify(document.querySelector('$($shot.Clip)')?.getBoundingClientRect() ?? null)" }).result.value
            if (-not $found) { throw "Nothing on the page matches the Clip selector $($shot.Clip)" }
            $box = $found | ConvertFrom-Json
            $picture.clip = @{ x = $box.x - $pad; y = $box.y - $pad; width = $box.width + 2 * $pad; height = $box.height + 2 * $pad; scale = 1 }
        }
        $png = Send-Cdp $socket 'Page.captureScreenshot' $picture
        $file = Join-Path $OutDir "$($shot.Name).png"
        [IO.File]::WriteAllBytes($file, [Convert]::FromBase64String($png.data))
        Write-Host "$file$(if (-not $ready) { '  (the page never said it was ready)' })"
    }
} finally {
    Stop-Process -Id $browser.Id -Force -ErrorAction SilentlyContinue
    if ($server) { Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue }
}
