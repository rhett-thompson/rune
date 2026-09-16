#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$R3DSource,
    [Parameter(Mandatory)][string]$AssimpSource,
    [Parameter(Mandatory)][string]$RaylibHeaders,
    [string]$Zig = 'zig',
    [ValidateSet('Windows', 'Linux', 'All')][string]$Target = $(if ($IsWindows) { 'Windows' } else { 'Linux' })
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$nativeRoot = Join-Path $repositoryRoot 'third_party/r3d-importer'
$pins = Get-Content -LiteralPath (Join-Path $nativeRoot 'sources.json') -Raw | ConvertFrom-Json
$zigCommand = (Get-Command $Zig -ErrorAction Stop).Source
$zigVersion = (& $zigCommand version | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $zigVersion -ne $pins.zig) { throw "Expected Zig $($pins.zig); found '$zigVersion'." }
if ($Target -in @('Windows', 'All') -and !$IsWindows) { throw 'Windows builds require a Windows host with the MSVC headers and Windows SDK.' }
$R3DSource = (Resolve-Path -LiteralPath $R3DSource).Path
$AssimpSource = (Resolve-Path -LiteralPath $AssimpSource).Path
$RaylibHeaders = (Resolve-Path -LiteralPath $RaylibHeaders).Path
foreach ($header in $pins.headers.PSObject.Properties) {
    $path = Join-Path $RaylibHeaders $header.Name
    if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $header.Value) {
        throw "Header does not match the pinned raylib revision: $path"
    }
}

function Invoke-Checked([string]$Executable, [string[]]$Arguments) {
    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Command failed with exit code ${LASTEXITCODE}: $Executable" }
}

# Export immutable revisions; never edit the caller's source checkouts.
$work = Join-Path $repositoryRoot "build/r3d-importer-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $work -Force | Out-Null
function Export-Source([string]$Source, [string]$Revision, [string]$Name, [string[]]$Paths) {
    $destination = Join-Path $work $Name
    New-Item -ItemType Directory -Path $destination -Force | Out-Null
    $archive = Join-Path $work "$Name.tar"
    Invoke-Checked 'git' (@('-C', $Source, 'archive', '--format=tar', "--output=$archive", $Revision) + $Paths)
    Invoke-Checked 'tar' @('-xf', $archive, '-C', $destination)
    return $destination
}
$r3d = Export-Source $R3DSource $pins.r3d 'r3d' @('include', 'src', 'external/uthash')
$assimp = Export-Source $AssimpSource $pins.assimp 'assimp' @('include')
# Give the exported tree its own root: otherwise git apply can discover Rune's
# parent repository and silently skip src/ paths from this nested directory.
Invoke-Checked 'git' @('-C', $r3d, 'init', '--quiet')
Invoke-Checked 'git' @('-C', $r3d, 'apply', '--check', (Join-Path $nativeRoot 'fbx-pivots.patch'))
Invoke-Checked 'git' @('-C', $r3d, 'apply', (Join-Path $nativeRoot 'fbx-pivots.patch'))
Invoke-Checked 'git' @('-C', $r3d, 'apply', '--reverse', '--check', (Join-Path $nativeRoot 'fbx-pivots.patch'))
$headers = Join-Path $work 'headers'
New-Item -ItemType Directory -Path (Join-Path $headers 'assimp') -Force | Out-Null
foreach ($header in $pins.headers.PSObject.Properties) {
    Copy-Item -LiteralPath (Join-Path $RaylibHeaders $header.Name) -Destination $headers
}
@'
#define R3D_SUPPORT_ASSIMP
#define R3D_TRACELOG(level, msg, ...) TraceLog(level, "R3D: " msg, ##__VA_ARGS__)
'@ | Set-Content -LiteralPath (Join-Path $headers 'r3d_config.h') -Encoding utf8
$config = Get-Content -LiteralPath (Join-Path $assimp 'include/assimp/config.h.in') -Raw
$config.Replace('#cmakedefine ASSIMP_DOUBLE_PRECISION 1', '/* float precision */') |
    Set-Content -LiteralPath (Join-Path $headers 'assimp/config.h') -Encoding utf8
Copy-Item -LiteralPath (Join-Path $nativeRoot 'animation_clips.c') -Destination $work
@'
#include "r3d/src/r3d_importer.c"
#include "animation_clips.c"
'@ | Set-Content -LiteralPath (Join-Path $work 'importer.c') -Encoding utf8

$targets = if ($Target -eq 'All') { @('Windows', 'Linux') } else { @($Target) }
$outputs = @()
$previousCache = $env:ZIG_GLOBAL_CACHE_DIR
try {
    $env:ZIG_GLOBAL_CACHE_DIR = Join-Path $repositoryRoot 'build/zig-cache'
    foreach ($platform in $targets) {
        $triple = if ($platform -eq 'Windows') { 'x86_64-windows-msvc' } else { 'x86_64-linux-gnu' }
        $object = Join-Path $work $(if ($platform -eq 'Windows') { 'importer.obj' } else { 'importer.o' })
        $name = if ($platform -eq 'Windows') { 'importer.lib' } else { 'libimporter.a' }
        $library = Join-Path $work $name
        Invoke-Checked $zigCommand @(
            'cc', '-target', $triple, '-c', (Join-Path $work 'importer.c'),
            '-O2', '-DNDEBUG', '-D_CRT_SECURE_NO_WARNINGS', '-std=c11',
            '-DR3D_LoadImporter=Rune_LoadImporter',
            '-DR3D_LoadImporterFromMemory=Rune_LoadImporterFromMemory',
            '-DR3D_UnloadImporter=Rune_UnloadImporter',
            "-I$headers", "-I$r3d/include", "-I$r3d/external/uthash", "-I$assimp/include",
            '-o', $object
        )
        Invoke-Checked $zigCommand @('ar', 'rcs', $library, $object)
        $outputs += @{ Source = $library; Directory = (Join-Path $nativeRoot $platform.ToLowerInvariant()) }
    }
    # Publish only after every requested compilation succeeds.
    foreach ($output in $outputs) {
        New-Item -ItemType Directory -Path $output.Directory -Force | Out-Null
        Copy-Item -LiteralPath $output.Source -Destination $output.Directory -Force
        Get-FileHash -LiteralPath $output.Source -Algorithm SHA256
    }
} finally {
    $env:ZIG_GLOBAL_CACHE_DIR = $previousCache
}
