[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Command,
    [Parameter(Mandatory)][string]$Directory,
    [switch]$Json,
    [ValidateRange(1, 300)][int]$TimeoutSeconds = 10
)

$ErrorActionPreference = 'Stop'
$inbox = (Resolve-Path -LiteralPath $Directory).Path
if (-not (Test-Path -LiteralPath $inbox -PathType Container)) {
    throw "Console directory does not exist: $inbox"
}
if ([Text.Encoding]::UTF8.GetByteCount($Command) -gt 256 -or $Command -match "[\r\n\x00]") {
    throw 'Send one command of at most 256 UTF-8 bytes.'
}
$requestId = [Guid]::NewGuid().ToString('N')
$staging = Join-Path $inbox "$requestId.tmp"
$request = Join-Path $inbox "$requestId.cmd"
$reply = Join-Path $inbox "$requestId.result.json"
try {
    [IO.File]::WriteAllText($staging, $Command, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $staging -Destination $request
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while (-not (Test-Path -LiteralPath $reply)) {
        if ([DateTime]::UtcNow -ge $deadline) {
            throw 'Console timed out. The game may be stopped or paused; a claimed command may still finish.'
        }
        Start-Sleep -Milliseconds 100
    }
    $rawResult = Get-Content -LiteralPath $reply -Raw
    $result = $rawResult | ConvertFrom-Json
    if ($Json) {
        Write-Output $rawResult
    } else {
        foreach ($line in $result.lines) { Write-Output $line }
        if ($null -ne $result.data) { $result.data | ConvertTo-Json -Depth 100 }
    }
    if (-not $result.ok) { throw 'Console command failed (see output above).' }
}
finally {
    foreach ($path in @($staging, $request, $reply)) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
    }
}
