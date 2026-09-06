#requires -Version 7.0
[CmdletBinding()]
param(
    [string]$RuneRoot = $env:RUNE_ROOT,
    [switch]$Run,
    [switch]$Release,
    [string[]]$GameArguments = @()
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RuneRoot)) {
    throw 'Pass -RuneRoot <engine-directory>, or set RUNE_ROOT to your Rune checkout.'
}
$engineRoot = (Resolve-Path -LiteralPath $RuneRoot).Path
if (!(Test-Path -LiteralPath (Join-Path $engineRoot 'rune/core/core.odin'))) {
    throw "Rune engine was not found at $engineRoot"
}
$compiler = (Get-Command odin -ErrorAction Stop).Source
$gameRoot = $PSScriptRoot
$outputDirectory = Join-Path $gameRoot 'build'
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
$executableName = if ($IsWindows) { 'game.exe' } else { 'game' }
$executable = Join-Path $outputDirectory $executableName

Push-Location $gameRoot
try {
    $buildArguments = @('build', '.', "-collection:rune=$(Join-Path $engineRoot 'rune')", "-out:$executable")
    if ($Release) { $buildArguments += '-o:speed' }
    & $compiler @buildArguments
    if ($LASTEXITCODE -ne 0) { throw "Game build failed (exit $LASTEXITCODE)." }
    Write-Host "Built $executable"
    if ($Run) {
        & $executable @GameArguments
        if ($LASTEXITCODE -ne 0) { throw "Game exited with code $LASTEXITCODE." }
    }
}
finally { Pop-Location }
