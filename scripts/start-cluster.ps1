# Bring the whole harness up and print every UI link.
#
# Idempotent by design: each piece is started only if its port is dead, so this
# is safe to run any time — after a reboot, after a tunnel drops, or just to see
# the links again. -Status only reports.
#
#   pwsh -File start-cluster.ps1            # start what is missing, print links
#   pwsh -File start-cluster.ps1 -Status    # report only, change nothing
param([switch]$Status)

$ErrorActionPreference = 'Continue'
$repo = Split-Path $PSScriptRoot -Parent
$connect = 'C:\Program Files\Git\mingw64\bin\connect.exe'
$key = "$env:USERPROFILE\.ssh\id_ed25519"

function Test-Port([int]$Port) {
    $c = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue
    return [bool]$c
}

function Test-Url([string]$Url, [int]$TimeoutSec = 4) {
    try { $null = Invoke-RestMethod -Uri $Url -TimeoutSec $TimeoutSec; return $true } catch { return $false }
}

function Say($ok, $text) {
    Write-Host ("  [{0}] {1}" -f $(if ($ok) { 'up  ' } else { 'DOWN' }), $text) -ForegroundColor $(if ($ok) { 'Green' } else { 'Yellow' })
}

# --- 1. WireGuard tunnels (userspace; each also opens its TCPClientTunnel ports)
function Start-Wireproxy($name, $socksPort) {
    if (Test-Port $socksPort) { return }
    if ($Status) { return }
    Write-Host "  starting wireproxy $name…"
    Start-Process -FilePath "$env:USERPROFILE\tools\wireproxy.exe" `
        -ArgumentList '-c', "$env:USERPROFILE/.config/wireproxy-$name.conf" -WindowStyle Hidden
    Start-Sleep -Seconds 3
}

# --- 2. Server-side relays: sshd cannot reach a staff user's ports (ssh -L dies
#        with "connect failed"), so a user-context relay puts the service on the
#        wg address for our tunnel IP only. See net/wgexpose.py.
function Start-Relay($host_, $socks, $ip, $bindPort, $targetPort, $allow) {
    if ($Status) { return }
    $remote = "ss -ltn | grep -q ':$bindPort ' || (mkdir -p ~/logs; setsid nohup python3 ~/wgexpose.py $ip`:$bindPort 127.0.0.1:$targetPort --allow $allow >> ~/logs/wgexpose-$targetPort.log 2>&1 < /dev/null &)"
    & ssh -o "ProxyCommand=`"$connect`" -S 127.0.0.1:$socks %h %p" -o BatchMode=yes -o ConnectTimeout=15 `
        -i $key "end@$ip" $remote 2>$null
}

# --- 3. Local services
function Start-Local($label, $port, $file, $argv) {
    if (Test-Port $port) { return }
    if ($Status) { return }
    Write-Host "  starting $label…"
    Start-Process -FilePath $file -ArgumentList $argv -WindowStyle Hidden
}

Write-Host "`nai-harness — bringing the cluster up`n" -ForegroundColor Cyan

Start-Wireproxy 'adler' 1080
Start-Wireproxy 'specht' 1081

Start-Relay 'specht' 1081 '10.72.0.1' 18088 8088 '10.72.0.12'   # llama.cpp 131k
Start-Relay 'adler'  1080 '10.71.0.1' 18188 8188 '10.71.0.12'   # ComfyUI on the 4090

Start-Local 'llama-server (4080)' 8080 'C:\llama.cpp\start-glm-server.cmd' @()
Start-Local 'dashboard' 8090 'pwsh' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', 'C:\llama.cpp\dashboard\dashboard-server.ps1')
Start-Local 'gen3d studio' 8095 'C:\hy3d\venv\Scripts\python.exe' @("$repo\gen3d\gen3d-ui.py")

if (-not $Status) { Start-Sleep -Seconds 6 }   # llama-server needs a moment to map the model

Write-Host "`nInterfaces" -ForegroundColor Cyan
Say (Test-Url 'http://127.0.0.1:8090/api/interfaces' 10) 'dashboard          http://127.0.0.1:8090/   — workers, tokens, links'
Say (Test-Url 'http://127.0.0.1:8095/api/state')        'gen3d studio       http://127.0.0.1:8095/   — image -> GLB, local RTX 4080'
Say (Test-Url 'http://127.0.0.1:8080/health')           'GLM-4.7-Flash      http://127.0.0.1:8080/   — chat, 32k ctx, local RTX 4080'
Say (Test-Url 'http://127.0.0.1:9088/health' 8)         'GLM-4.7-Flash 131k http://127.0.0.1:9088/   — chat, specht 2x AMD'
Say (Test-Url 'http://127.0.0.1:9188/system_stats' 8)   'ComfyUI            http://127.0.0.1:9188/   — images, adler RTX 4090'
Say (Test-Url 'http://127.0.0.1:8096/config' 8)         'opencode           http://127.0.0.1:8096/   — coding agent driving all of the above'
Write-Host ""
