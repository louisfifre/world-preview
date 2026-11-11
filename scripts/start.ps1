<#
.SYNOPSIS
The double-click start: asks once which game folder to preview, remembers it, and opens the page.

.DESCRIPTION
"World Preview.cmd" runs this script without a console, for a person who has no pack path to type.
The first time, a window asks for the game folder, the one that holds mods and config; the choice is
kept in run\pack.txt. WORLD_PREVIEW_PACK, when set, wins over the kept choice.

With no console to read, whatever goes wrong before the page opens is said in a message box.

.PARAMETER Choose
Ask for the folder again, even when one is remembered.
#>
param([switch]$Choose)

# The sentences of the windows this script shows.
$Text = @{
    title  = 'World preview'
    choose = 'Choose your Minecraft game folder: the one that holds the "mods" and "config" folders.'
}

Add-Type -AssemblyName System.Windows.Forms
# A window on top to own the others: with no console of ours, they would open behind whatever is on screen.
$owner = [Windows.Forms.Form]::new()
$owner.TopMost = $true

try {
    . "$PSScriptRoot\common.ps1"
    $saved = Join-Path $RepoRoot 'run\pack.txt'
    $pack = $env:WORLD_PREVIEW_PACK
    if (-not $pack -and -not $Choose -and (Test-Path $saved)) { $pack = [IO.File]::ReadAllText($saved).Trim() }
    while ($true) {
        if ($pack) {
            # A folder that does not fit is said, then asked again: the sentence tells what is missing.
            try { $pack = Resolve-Pack $pack; break }
            catch { $null = [Windows.Forms.MessageBox]::Show($owner, $_.Exception.Message, $Text.title) }
        }
        $dialog = [Windows.Forms.FolderBrowserDialog]::new()
        $dialog.Description = $Text.choose
        $dialog.ShowNewFolderButton = $false
        if ($dialog.ShowDialog($owner) -ne 'OK') { return }
        $pack = $dialog.SelectedPath
    }
    New-Item -ItemType Directory -Force (Split-Path $saved) | Out-Null
    [IO.File]::WriteAllText($saved, $pack)
    & "$PSScriptRoot\serve.ps1" -Pack $pack
}
catch { $null = [Windows.Forms.MessageBox]::Show($owner, $_.Exception.Message, $Text.title) }
finally { $owner.Dispose() }
