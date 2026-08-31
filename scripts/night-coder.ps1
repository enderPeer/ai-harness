# Day/night switch for the cluster's text tier.
#
#   night-coder.ps1 -Start                  # Qwen3.8-27B at 262k on specht's two AMD cards
#   night-coder.ps1 -Start -WithAdler       # + adler's 4090 over the LAN via llama.cpp RPC
#   night-coder.ps1 -Start -Context 1000000 -WithAdler
#   night-coder.ps1 -Stop                   # back to the GLM, 4090 released to ComfyUI
#   night-coder.ps1 -Status
#
# Nothing is uninstalled in either direction: the GLM keeps its port (8088) and
# config, Qwen keeps its own (8089), and only one is resident at a time because
# specht has 30 GB of VRAM and cannot hold both.
#
# -WithAdler takes the 4090 away from image generation for as long as it runs.
# That is the trade for contexts past ~300k; the RPC script refuses to start if
# ComfyUI is still holding the card, so a night job cannot kill a running batch.
param(
    [switch]$Start,
    [switch]$Stop,
    [switch]$Status,
    [switch]$WithAdler,
    [int]$Context = 262144
)

$connect = 'C:\Program Files\Git\mingw64\bin\connect.exe'
$key = "$env:USERPROFILE\.ssh\id_ed25519"

function Remote($hostName, $socks, $ip, $command) {
    & ssh -o "ProxyCommand=`"$connect`" -S 127.0.0.1:$socks %h %p" -o BatchMode=yes `
        -o ConnectTimeout=15 -i $key "end@$ip" $command 2>&1
}
function Specht($cmd) { Remote 'specht' 1081 '10.72.0.1' $cmd }
function Adler($cmd) { Remote 'adler' 1080 '10.71.0.1' $cmd }

if ($Status -or (-not $Start -and -not $Stop)) {
    Write-Host "`nText tier" -ForegroundColor Cyan
    Specht '~/qwen-service.sh status' | ForEach-Object { "  $_" }
    Write-Host "`nadler 4090" -ForegroundColor Cyan
    Adler '~/rpc-adler.sh status' | ForEach-Object { "  $_" }
    Write-Host "`nReachable from here" -ForegroundColor Cyan
    foreach ($p in @(@{n = 'GLM 131k'; u = 'http://127.0.0.1:9088/health' },
                     @{n = 'Qwen night'; u = 'http://127.0.0.1:9089/health' })) {
        $ok = $false
        try { $null = Invoke-RestMethod -Uri $p.u -TimeoutSec 5; $ok = $true } catch {}
        Write-Host ("  [{0}] {1}" -f $(if ($ok) { 'up  ' } else { 'down' }), $p.n) `
            -ForegroundColor $(if ($ok) { 'Green' } else { 'DarkGray' })
    }
    Write-Host ""
    return
}

if ($Stop) {
    Write-Host "Switching back to day mode…" -ForegroundColor Cyan
    Specht '~/qwen-service.sh glm' | ForEach-Object { "  $_" }
    Adler '~/rpc-adler.sh stop' | ForEach-Object { "  $_" }
    Write-Host "  the 4090 is free for ComfyUI again" -ForegroundColor Green
    return
}

# --- start
if ($WithAdler) {
    Write-Host "Lending adler's 4090 to specht…" -ForegroundColor Cyan
    $out = Adler '~/rpc-adler.sh start'
    $out | ForEach-Object { "  $_" }
    if ($out -match 'refusing') {
        Write-Host "  -> stop ComfyUI on adler first, or accept 262k without it." -ForegroundColor Yellow
        return
    }
}

if ($Context -gt 262144) {
    Write-Host "Context $Context exceeds the model's native 262144 — YaRN will be enabled." -ForegroundColor Yellow
    Write-Host "That stretches position encoding on every prompt, short ones included." -ForegroundColor Yellow
}

Write-Host "Starting the night coder (ctx $Context)…" -ForegroundColor Cyan
Specht "~/qwen-service.sh start $Context" | ForEach-Object { "  $_" }

Write-Host "`nAllocating the KV cache takes a while at this size. Waiting…" -ForegroundColor Cyan
$deadline = (Get-Date).AddMinutes(12)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 15
    try {
        $null = Invoke-RestMethod -Uri 'http://127.0.0.1:9089/health' -TimeoutSec 8
        $props = Invoke-RestMethod -Uri 'http://127.0.0.1:9089/props' -TimeoutSec 10
        $ctx = $props.default_generation_settings.n_ctx
        Write-Host "  up: http://127.0.0.1:9089/  context $ctx" -ForegroundColor Green
        Write-Host "  opencode: --model specht-qwen/qwen3.8-27b`n"
        return
    } catch { Write-Host "  …still loading" -ForegroundColor DarkGray }
}
Write-Host "  did not come up in 12 minutes — check ~/logs/qwen-server.log on specht" -ForegroundColor Yellow
