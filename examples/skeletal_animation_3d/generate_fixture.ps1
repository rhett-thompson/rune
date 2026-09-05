# Generates the example's original two-joint model; no external artwork.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$stream = [IO.MemoryStream]::new()
$writer = [IO.BinaryWriter]::new($stream)
$views = [Collections.Generic.List[object]]::new()
$accessors = [Collections.Generic.List[object]]::new()
function Add-Accessor($Values, [string]$Type, [int]$Components, [int]$ComponentType = 5126, $Minimum = $null, $Maximum = $null) {
    while ($stream.Position % 4) { $writer.Write([byte]0) }
    $offset = $stream.Position
    foreach ($value in $Values) {
        if ($ComponentType -eq 5123) { $writer.Write([uint16]$value) }
        else { $writer.Write([single]$value) }
    }
    $viewIndex = $views.Count
    $views.Add(@{ buffer = 0; byteOffset = $offset; byteLength = $stream.Position - $offset })
    $accessor = @{ bufferView = $viewIndex; componentType = $ComponentType; count = $Values.Count / $Components; type = $Type }
    if ($null -ne $Minimum) { $accessor.min = $Minimum; $accessor.max = $Maximum }
    $accessorIndex = $accessors.Count
    $accessors.Add($accessor)
    return $accessorIndex
}
$positions = [Collections.Generic.List[single]]::new()
$normals = [Collections.Generic.List[single]]::new()
$joints = [Collections.Generic.List[uint16]]::new()
$weights = [Collections.Generic.List[single]]::new()
$indices = [Collections.Generic.List[uint16]]::new()
$faces = @(
    @{ n=@(0,0,1); v=@(@(-1,0,1),@(1,0,1),@(1,1,1),@(-1,1,1)) },
    @{ n=@(0,0,-1); v=@(@(1,0,-1),@(-1,0,-1),@(-1,1,-1),@(1,1,-1)) },
    @{ n=@(1,0,0); v=@(@(1,0,1),@(1,0,-1),@(1,1,-1),@(1,1,1)) },
    @{ n=@(-1,0,0); v=@(@(-1,0,-1),@(-1,0,1),@(-1,1,1),@(-1,1,-1)) },
    @{ n=@(0,1,0); v=@(@(-1,1,1),@(1,1,1),@(1,1,-1),@(-1,1,-1)) },
    @{ n=@(0,-1,0); v=@(@(-1,0,-1),@(1,0,-1),@(1,0,1),@(-1,0,1)) }
)
foreach ($bone in 0..1) {
    foreach ($face in $faces) {
        $base = $positions.Count / 3
        foreach ($v in $face.v) {
            $positions.AddRange([single[]]@(($v[0]*0.18), ($v[1]+$bone), ($v[2]*0.18)))
            $normals.AddRange([single[]]$face.n)
            $joints.AddRange([uint16[]]@($bone,0,0,0))
            $weights.AddRange([single[]]@(1,0,0,0))
        }
        foreach ($index in @(0,1,2,0,2,3)) { $indices.Add([uint16]($base+$index)) }
    }
}
$position = Add-Accessor $positions 'VEC3' 3 5126 @(-0.18,0,-0.18) @(0.18,2,0.18)
$normal = Add-Accessor $normals 'VEC3' 3
$joint = Add-Accessor $joints 'VEC4' 4 5123
$weight = Add-Accessor $weights 'VEC4' 4
$indexAccessor = Add-Accessor $indices 'SCALAR' 1 5123
$inverseBinds = Add-Accessor @(1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1, 1,0,0,0,0,1,0,0,0,0,1,0,0,-1,0,1) 'MAT4' 16
$times = Add-Accessor @(0,0.5,1,1.5,2) 'SCALAR' 1 5126 @(0) @(2)
function Rotation-Keys($Angles) {
    $values = [Collections.Generic.List[single]]::new()
    foreach ($angle in $Angles) {
        $half = $angle * [Math]::PI / 360
        $values.AddRange([single[]]@(0,0,[Math]::Sin($half),[Math]::Cos($half)))
    }
    return Add-Accessor $values 'VEC4' 4
}
$bend = Rotation-Keys @(0,75,0,-75,0)
$sway = Rotation-Keys @(-25,0,25,0,-25)
$document = @{
    asset = @{ version='2.0'; generator='Rune two-joint fixture generator' }
    scene = 0
    scenes = @(@{ nodes=@(0,1) })
    nodes = @(
        @{ name='Arm'; mesh=0; skin=0 },
        @{ name='Root'; children=@(2) },
        @{ name='Tip'; translation=@(0,1,0) }
    )
    skins = @(@{ joints=@(1,2); skeleton=1; inverseBindMatrices=$inverseBinds })
    meshes = @(@{ primitives=@(@{ attributes=@{ POSITION=$position; NORMAL=$normal; JOINTS_0=$joint; WEIGHTS_0=$weight }; indices=$indexAccessor }) })
    animations = @(
        @{ name='bend'; samplers=@(@{ input=$times; output=$bend; interpolation='LINEAR' }); channels=@(@{ sampler=0; target=@{ node=2; path='rotation' } }) },
        @{ name='sway'; samplers=@(@{ input=$times; output=$sway; interpolation='LINEAR' }); channels=@(@{ sampler=0; target=@{ node=1; path='rotation' } }) }
    )
    buffers = @(@{ byteLength=$stream.Length; uri='data:application/octet-stream;base64,'+[Convert]::ToBase64String($stream.ToArray()) })
    bufferViews = $views.ToArray()
    accessors = $accessors.ToArray()
}
$directory = Join-Path $PSScriptRoot 'assets'
$null = New-Item -ItemType Directory -Path $directory -Force
[IO.File]::WriteAllText((Join-Path $directory 'arm.gltf'), ($document | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
$writer.Dispose()
$stream.Dispose()
