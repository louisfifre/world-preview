<#
.SYNOPSIS
Makes the ready-to-use folder: what a person who only plays downloads, unzips and double-clicks.

.DESCRIPTION
Builds the mod, then gathers in run\package\world-preview-<version> the few files a run needs: the
start file, the page, the scripts a person runs, and the mod already built, so that nobody else needs
Gradle or waits for a build. The folder is zipped beside itself, ready to attach to a release.

The mod's version (mod\build.gradle) names the folder and the zip.
#>

. "$PSScriptRoot\common.ps1"

$modRoot = Join-Path $RepoRoot 'mod'
Write-Host 'Building the world-preview mod'
$env:JAVA_HOME = Split-Path (Split-Path (Find-Java))
Push-Location $modRoot
try {
    & .\gradlew.bat build --console=plain -q
    if ($LASTEXITCODE -ne 0) { throw 'The world-preview mod did not build.' }
} finally { Pop-Location }
$jar = Get-ChildItem (Join-Path $modRoot 'build\libs') -Filter 'world-preview-*.jar' | Sort-Object LastWriteTime | Select-Object -Last 1

$name = $jar.BaseName
$stage = Join-Path $RepoRoot "run\package\$name"
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
# The same places as in the repository, so the scripts find everything without knowing which one they run from.
# The mod comes without its sources: that is how preview.ps1 knows it must take the jar as it is.
$files = @{
    'World Preview.cmd' = ''
    'README.md'         = ''
    'LICENSE'           = ''
    'page\preview.html' = 'page'
    'scripts\start.ps1'   = 'scripts'
    'scripts\serve.ps1'   = 'scripts'
    'scripts\preview.ps1' = 'scripts'
    'scripts\common.ps1'  = 'scripts'
    'mod\gradle.properties' = 'mod'
}
foreach ($file in $files.Keys) {
    $target = Join-Path $stage $files[$file]
    New-Item -ItemType Directory -Force $target | Out-Null
    Copy-Item (Join-Path $RepoRoot $file) $target
}
$libs = Join-Path $stage 'mod\build\libs'
New-Item -ItemType Directory -Force $libs | Out-Null
Copy-Item $jar.FullName $libs

$zip = "$stage.zip"
if (Test-Path $zip) { Remove-Item $zip }
Compress-Archive -Path $stage -DestinationPath $zip
Write-Host "Ready: $zip"
