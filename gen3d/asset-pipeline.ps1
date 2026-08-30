# End-to-end asset pipeline: ComfyUI art -> Hunyuan3D (multi-view when several
# views are given) -> Blender cleanup -> game-ready GLB.
#
# Art comes from our own ComfyUI on adler, reached through the WireGuard tunnel
# at 127.0.0.1:9188. It needs no credentials: it is our instance, not a hosted
# gallery, so /view serves the outputs directly.
#
# Usage:
#   asset-pipeline -List                                   # what ComfyUI has made lately
#   asset-pipeline -Out hero.glb -Files vet-helmet-front_00001_.png
#   asset-pipeline -Out hero.glb -Files front.png,back.png,left.png,right.png
#
# -Files takes ComfyUI output filenames, local paths, or a mix. Several files
# are treated as views in the order front, back, left, right.
param(
    [string]$Out,
    [string[]]$Files,
    [int]$TargetTris = 30000,
    [string]$Comfy = 'http://127.0.0.1:9188',
    [int]$ListCount = 20,
    [switch]$List
)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot

function Get-ComfyOutputs {
    # /history is newest-last; walk it backwards so the most recent art is first.
    $h = Invoke-RestMethod -Uri "$Comfy/history" -TimeoutSec 20
    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($prompt in @($h.PSObject.Properties)) {
        foreach ($node in @($prompt.Value.outputs.PSObject.Properties)) {
            foreach ($img in @($node.Value.images)) {
                if ($img.type -eq 'output' -and $names -notcontains $img.filename) { $names.Add($img.filename) }
            }
        }
    }
    $names.Reverse()
    return $names
}

if ($List) {
    $names = Get-ComfyOutputs
    if (-not $names.Count) { Write-Output "ComfyUI has no outputs yet."; exit 0 }
    Write-Output "Recent ComfyUI outputs ($Comfy):"
    $names | Select-Object -First $ListCount | ForEach-Object { Write-Output "  $_" }
    exit 0
}

if (-not $Out -or -not $Files) { Write-Error "-Out and -Files are required (or use -List)"; exit 2 }

$work = Join-Path $env:TEMP ("asset-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $work | Out-Null

# 1. Collect the views: local files are used as-is, everything else is pulled
#    from ComfyUI by output filename.
$local = @()
foreach ($f in $Files) {
    if (Test-Path $f) {
        $dst = Join-Path $work (Split-Path $f -Leaf)
        Copy-Item $f $dst -Force
        Write-Output "[pipeline] local $(Split-Path $f -Leaf) ($([math]::Round((Get-Item $dst).Length / 1KB)) KB)"
    }
    else {
        $dst = Join-Path $work $f
        $code = curl.exe -s -o $dst --get --data-urlencode "filename=$f" --data-urlencode "type=output" `
            --data-urlencode "subfolder=" -w '%{http_code}' "$Comfy/view"
        if ($code -ne '200') {
            Write-Error "ComfyUI has no output named '$f' (HTTP $code). Run with -List to see what it has."
            exit 1
        }
        Write-Output "[pipeline] fetched $f ($([math]::Round((Get-Item $dst).Length / 1KB)) KB)"
    }
    $local += $dst
}

# 2. Mesh on the local 4080: multi-view when >1 image, single otherwise. Pauses
#    the GLM worker for VRAM, restarts after.
taskkill /im llama-server.exe /f 2>$null | Out-Null
Start-Sleep -Seconds 2
$raw = Join-Path $work 'raw.glb'
if ($local.Count -gt 1) {
    C:\hy3d\venv\Scripts\python.exe (Join-Path $here 'gen3d_mv.py') $raw @local
}
else {
    C:\hy3d\venv\Scripts\python.exe (Join-Path $here 'gen3d.py') $local[0] $raw
}
Start-Process -WindowStyle Hidden cmd -ArgumentList '/c', 'C:\llama.cpp\start-glm-server.cmd'
if (-not (Test-Path $raw)) { Write-Error "mesh generation failed"; exit 1 }

# 3. Blender polish: merge, normals, crisp-edge smoothing, decimate to target.
$blender = (Get-Command blender -ErrorAction SilentlyContinue).Source
if (-not $blender) {
    $blender = (Get-ChildItem "C:\Program Files\Blender Foundation" -Recurse -Filter blender.exe -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
}
if ($blender -and (Test-Path $blender)) {
    & $blender --background --python (Join-Path $here 'blender_optimize.py') -- $raw $Out $TargetTris 2>&1 |
        Select-String '\[blender\]|Error' | ForEach-Object { $_.Line }
}
else {
    Write-Output "[pipeline] blender not found; shipping unpolished mesh"
    Copy-Item $raw $Out -Force
}
Write-Output "[pipeline] DONE: $Out ($([math]::Round((Get-Item $Out).Length / 1MB, 1)) MB)"
Remove-Item $work -Recurse -Force -Confirm:$false
