[CmdletBinding()]
param(
    [string]$Zig = 'zig',
    [ValidateSet('Windows', 'Linux', 'All')][string]$Target = 'All'
)
$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$nativeRoot = Join-Path $repositoryRoot 'third_party/rune-image'
$pins = Get-Content -LiteralPath (Join-Path $nativeRoot 'sources.json') -Raw | ConvertFrom-Json
if ((& $Zig version) -ne $pins.zig) { throw "Expected Zig $($pins.zig)." }
$headerHash = (Get-FileHash -LiteralPath (Join-Path $nativeRoot 'stb_image.h') -Algorithm SHA256).Hash
if ($headerHash -ne $pins.stb_image_sha256) { throw 'Private stb_image.h does not match sources.json.' }
$buildRoot = Join-Path $repositoryRoot 'build/image-decode-native'
New-Item -ItemType Directory -Force $buildRoot | Out-Null
$env:ZIG_GLOBAL_CACHE_DIR = Join-Path $repositoryRoot 'build/zig-cache'
$targets = if ($Target -eq 'All') { @('Windows', 'Linux') } else { @($Target) }
foreach ($nativeTarget in $targets) {
    $isWindowsTarget = $nativeTarget -eq 'Windows'
    $triple = if ($isWindowsTarget) { 'x86_64-windows-msvc' } else { 'x86_64-linux-gnu' }
    $objectName = if ($isWindowsTarget) { 'image_decode.obj' } else { 'image_decode.o' }
    $libraryName = if ($isWindowsTarget) { 'image_decode.lib' } else { 'libimage_decode.a' }
    $objectPath = Join-Path $buildRoot $objectName
    $libraryPath = Join-Path $buildRoot $libraryName
    & $Zig cc -target $triple -c (Join-Path $nativeRoot 'image_decode.c') -std=c11 -O2 -DNDEBUG -D_CRT_SECURE_NO_WARNINGS -o $objectPath
    if ($LASTEXITCODE -ne 0) { throw "Decoder compile failed for $nativeTarget." }
    & $Zig ar rcs $libraryPath $objectPath
    if ($LASTEXITCODE -ne 0) { throw "Decoder archive failed for $nativeTarget." }
    $destination = Join-Path $nativeRoot $nativeTarget.ToLowerInvariant()
    New-Item -ItemType Directory -Force $destination | Out-Null
    Copy-Item -LiteralPath $libraryPath -Destination (Join-Path $destination $libraryName)
    Write-Output "Built isolated image decoder for $nativeTarget."
}
