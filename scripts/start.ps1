<#
.SYNOPSIS
The double-click start: asks once which game folder to preview, remembers it, and opens the page.

.DESCRIPTION
"World Preview.cmd" runs this script without a console, for a person who has no pack path to type.
The first time, a window asks for the game folder, the one that holds mods and config; the choice is
kept in run\pack.txt. WORLD_PREVIEW_PACK, when set, wins over the kept choice.

With no console to read, whatever goes wrong before the page opens is said in a message box.

.PARAMETER Pack
The game folder, when it is given rather than asked: a folder dropped on "World Preview.cmd" arrives here.

.PARAMETER Choose
Ask for the folder again, even when one is remembered.
#>
param([string]$Pack, [switch]$Choose)

# The sentences of the windows this script shows.
$Text = @{
    title  = 'World preview'
    choose = 'Open your Minecraft game folder, the one that holds "mods" and "config", then click Open'
    here   = 'This folder'
}

Add-Type -AssemblyName System.Windows.Forms
# A window on top to own the others: with no console of ours, they would open behind whatever is on screen.
$owner = [Windows.Forms.Form]::new()
$owner.TopMost = $true

try {
    . "$PSScriptRoot\common.ps1"
    $saved = Join-Path $RepoRoot 'run\pack.txt'
    $pack = if ($Pack) { $Pack } else { $env:WORLD_PREVIEW_PACK }
    if (-not $pack -and -not $Choose -and (Test-Path $saved)) { $pack = [IO.File]::ReadAllText($saved).Trim() }
    while ($true) {
        if ($pack) {
            # A folder that does not fit is said, then asked again: the sentence tells what is missing.
            try { $pack = Resolve-Pack $pack; break }
            catch { $null = [Windows.Forms.MessageBox]::Show($owner, $_.Exception.Message, $Text.title) }
        }
        # The window that opens files, asked for a folder: under Windows PowerShell the one made for folders
        # is a bare tree with no address bar, and game folders sit under AppData, which that tree hides.
        # A name that is no file lets Open answer with the folder being looked at.
        $dialog = [Windows.Forms.OpenFileDialog]::new()
        $dialog.Title = $Text.choose
        $dialog.ValidateNames = $false
        $dialog.CheckFileExists = $false
        $dialog.FileName = $Text.here
        if ($dialog.ShowDialog($owner) -ne 'OK') { return }
        $pack = Split-Path $dialog.FileName
        # Someone who went one step too far, into mods or config, meant the folder above.
        if ((Split-Path $pack -Leaf) -in 'mods', 'config') { $pack = Split-Path $pack }
    }
    New-Item -ItemType Directory -Force (Split-Path $saved) | Out-Null
    [IO.File]::WriteAllText($saved, $pack)
    & "$PSScriptRoot\serve.ps1" -Pack $pack
}
catch { $null = [Windows.Forms.MessageBox]::Show($owner, $_.Exception.Message, $Text.title) }
finally { $owner.Dispose() }
