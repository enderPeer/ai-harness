# End-to-end asset pipeline: gallery download -> Hunyuan3D (multi-view when
# several images given) -> Blender cleanup -> game-ready GLB.
#
# Usage:
#   asset-pipeline -Out hero.glb -Files bild-...front.png,bild-...back.png,...
# Requires $env:GALLERY_KEY (read-only gallery API key).
param(
    [Parameter(Mandatory = $true)][string]$Out,
    [Parameter(Mandatory = $true)][string[]]$Files,
    [int]$TargetTris = 30000
)
$ErrorActionPreference = 'Stop'
if (-not $env:GALLERY_KEY) { Write-Error "GALLERY_KEY not set"; exit 1 }

$work = Join-Path $env:TEMP ("asset-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $work | Out-Null

# 1. Download all views from the gallery.
$local = @()
foreach ($f in $Files) {
    $dst = Join-Path $work $f
    $code = curl.exe -s -o $dst -w '%{http_code}' -H "Authorization: Bearer $env:GALLERY_KEY" "https://iamthelabel.xyz/api/image?file=$f"
    if ($code -ne '200') { Write-Error "download $f failed: HTTP $code"; exit 1 }
    Write-Output "[pipeline] $f ($([math]::Round((Get-Item $dst).Length/1KB)) KB)"
    $local += $dst
}

# 2. Mesh: multi-view when >1 image, single otherwise. Pauses the local GLM
#    worker for VRAM, restarts after.
taskkill /im llama-server.exe /f 2>$null | Out-Null
Start-Sleep -Seconds 2
$raw = Join-Path $work 'raw.glb'
if ($local.Count -gt 1) {
    C:\hy3d\venv\Scripts\python.exe C:\hy3d\gen3d_mv.py $raw @local
} else {
    C:\hy3d\venv\Scripts\python.exe C:\hy3d\gen3d.py $local[0] $raw
}
Start-Process -WindowStyle Hidden cmd -ArgumentList '/c', 'C:\llama.cpp\start-glm-server.cmd'
if (-not (Test-Path $raw)) { Write-Error "mesh generation failed"; exit 1 }

# 3. Blender polish: merge, normals, crisp-edge smoothing, decimate to target.
$blender = (Get-Command blender -ErrorAction SilentlyContinue).Source
if (-not $blender) {
    $blender = (Get-ChildItem "C:\Program Files\Blender Foundation" -Recurse -Filter blender.exe -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
}
if (Test-Path $blender) {
    & $blender --background --python C:\hy3d\blender_optimize.py -- $raw $Out $TargetTris 2>&1 |
        Select-String '\[blender\]|Error' | ForEach-Object { $_.Line }
} else {
    Write-Output "[pipeline] blender not found; shipping unpolished mesh"
    Copy-Item $raw $Out -Force
}
Write-Output "[pipeline] DONE: $Out ($([math]::Round((Get-Item $Out).Length/1MB, 1)) MB)"
Remove-Item $work -Recurse -Force -Confirm:$false
