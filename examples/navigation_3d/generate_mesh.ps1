# Rebuild the original, hand-authored walkable center surface used by the demo.
$ErrorActionPreference = 'Stop'
$vertices = [System.Collections.Generic.List[object]]::new()
$triangles = [System.Collections.Generic.List[object]]::new()
$lookup = @{}
function Add-Vertex([double]$x,[double]$y,[double]$z) {
    $key = "$x,$y,$z"
    if (!$lookup.ContainsKey($key)) {
        $lookup[$key] = $vertices.Count
        $vertices.Add(@($x,$y,$z))
    }
    return $lookup[$key]
}
function Add-Quad([double]$x0,[double]$x1,[double]$z0,[double]$z1,[double]$y0,[double]$y1) {
    $a = Add-Vertex $x0 $y0 $z0
    $b = Add-Vertex $x1 $y1 $z0
    $c = Add-Vertex $x1 $y1 $z1
    $d = Add-Vertex $x0 $y0 $z1
    $triangles.Add(@($a,$b,$c))
    $triangles.Add(@($a,$c,$d))
}
foreach ($x in @(-8,-6,-4)) {
    foreach ($z in @(-4,-2,0,2)) {
        if ($x -eq -6 -and $z -eq -2) {continue}
        Add-Quad $x ($x+2) $z ($z+2) 0 0
    }
}
foreach ($x in @(-2,0)) {
    foreach ($z in @(-2,0)) {Add-Quad $x ($x+2) $z ($z+2) (($x+2)/2) (($x+4)/2)}
}
foreach ($x in @(2,4,6)) {
    foreach ($z in @(-4,-2,0,2)) {Add-Quad $x ($x+2) $z ($z+2) 2 2}
}
Add-Quad 10 12 0 2 0 0
$document = [ordered]@{
    '$schema' = '../../schemas/navmesh.schema.json'
    version = 1
    agent_radius = 0.4
    agent_height = 2
    vertices = $vertices.ToArray()
    triangles = $triangles.ToArray()
}
$path = Join-Path $PSScriptRoot 'course.navmesh.json'
[IO.File]::WriteAllText($path, ($document | ConvertTo-Json -Depth 10) + [Environment]::NewLine)
Write-Host "Wrote $($vertices.Count) vertices and $($triangles.Count) triangles."
