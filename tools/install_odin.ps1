#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Destination
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$toolchain = Get-Content -LiteralPath (Join-Path $repositoryRoot 'toolchain.json') -Raw | ConvertFrom-Json
if ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne 'X64' -or (!$IsWindows -and !$IsLinux)) {
    throw 'The pinned toolchain installer currently supports Windows AMD64 and Linux AMD64.'
}
$platform = if ($IsWindows) { 'windows-amd64' } else { 'linux-amd64' }
$asset = $toolchain.archives.$platform
if (!$asset -or $asset.sha256 -notmatch '^[0-9a-f]{64}$') {
    throw "No checksummed Odin archive is configured for $platform."
}
$installRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Destination)
if (Test-Path -LiteralPath $installRoot) {
    throw "Destination already exists: $installRoot. Choose a new directory."
}
New-Item -ItemType Directory -Path $installRoot | Out-Null
$archive = Join-Path $installRoot $asset.name
$url = "https://github.com/odin-lang/Odin/releases/download/$($toolchain.odin_release)/$($asset.name)"
Invoke-WebRequest -Uri $url -OutFile $archive
if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $asset.sha256) {
    throw 'Odin archive checksum mismatch; nothing was extracted.'
}
if ($IsWindows) {
    Expand-Archive -LiteralPath $archive -DestinationPath $installRoot
} else {
    & tar -xzf $archive -C $installRoot
    if ($LASTEXITCODE -ne 0) { throw 'Could not extract the Odin toolchain.' }
}
$compilerName = if ($IsWindows) { 'odin.exe' } else { 'odin' }
$compilers = @(Get-ChildItem -LiteralPath $installRoot -Recurse -File -Filter $compilerName |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.DirectoryName 'core') })
if ($compilers.Count -ne 1) { throw 'Expected exactly one compiler with its core library in the archive.' }
$compilerDirectory = $compilers[0].DirectoryName
& $compilers[0].FullName version
if ($LASTEXITCODE -ne 0) { throw 'The downloaded compiler could not start; check the OS dependencies.' }
if ($IsLinux) {
    # The pinned Linux release ships the bindings but omits native Box2D archives.
    # Its own versioned build script produces both AMD64 instruction-set variants.
    $box2dRoot = Join-Path $compilerDirectory 'vendor/box2d'
    $box2dLibraries = @('lib/box2d_other_amd64_sse2.a', 'lib/box2d_other_amd64_avx2.a')
    $missingLibraries = @($box2dLibraries | Where-Object { !(Test-Path -LiteralPath (Join-Path $box2dRoot $_)) })
    if ($missingLibraries.Count -gt 0) {
        foreach ($dependency in @('bash', 'curl', 'cmake', 'make', 'cc')) {
            Get-Command $dependency -ErrorAction Stop | Out-Null
        }
        Write-Host 'Building the native Box2D libraries with the pinned Odin vendor script...'
        & bash (Join-Path $box2dRoot 'build_box2d.sh')
        if ($LASTEXITCODE -ne 0) { throw 'The native Box2D dependency build failed.' }
        foreach ($library in $box2dLibraries) {
            if (!(Test-Path -LiteralPath (Join-Path $box2dRoot $library))) {
                throw "Box2D build did not produce $library"
            }
        }
    }
}
Write-Host "Installed Odin. Add this directory to PATH: $compilerDirectory"
