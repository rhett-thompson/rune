[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Path,
    [string]$Name
)

$ErrorActionPreference = 'Stop'
$engineRoot = Split-Path -Parent $PSScriptRoot
$destination = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
if (Test-Path -LiteralPath $destination) {
    throw "Destination already exists: $destination. Choose a new directory."
}
if ([string]::IsNullOrWhiteSpace($Name)) { $Name = Split-Path -Leaf $destination }
if ([string]::IsNullOrWhiteSpace($Name)) { throw 'The project needs a non-empty name.' }

New-Item -ItemType Directory -Path $destination | Out-Null
Get-ChildItem -LiteralPath (Join-Path $engineRoot 'templates/blank_project') -Force |
    Where-Object { $_.Name -ne 'build' } |
    Copy-Item -Destination $destination -Recurse -Force
Copy-Item -LiteralPath (Join-Path $engineRoot 'schemas') -Destination (Join-Path $destination 'schemas') -Recurse

function Write-ProjectJson([string]$relativePath, [string]$schema) {
    $file = Join-Path $destination $relativePath
    $document = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
    $document.'$schema' = $schema
    if ($relativePath -eq 'project.json') {
        $document.name = $Name
        $document.window.title = $Name
    }
    [IO.File]::WriteAllText($file, ($document | ConvertTo-Json -Depth 32) + [Environment]::NewLine)
}
Write-ProjectJson 'project.json' 'schemas/project.schema.json'
Write-ProjectJson 'scenes/main.scene.json' '../schemas/scene.schema.json'
Write-ProjectJson 'input/default.input.json' '../schemas/input.schema.json'
Write-Host "Created $destination"
Write-Host 'Run build.ps1 in the new project with -RuneRoot pointing to this engine checkout.'
