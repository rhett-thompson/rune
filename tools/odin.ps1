[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]]$OdinArguments
)

$ErrorActionPreference = 'Stop'
if ($env:OS -eq 'Windows_NT') {
    # CMD's inherited lock handle also survives a terminated parent wrapper.
    & (Join-Path $PSScriptRoot 'odin.bat') @OdinArguments
}
else {
    & sh (Join-Path $PSScriptRoot 'odin.sh') @OdinArguments
}
exit $LASTEXITCODE
