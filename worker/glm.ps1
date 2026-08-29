# glm.ps1 — send a task to the local GLM-4.7-Flash server (OpenAI-compatible, port 8080)
# Streams the response, logging live thinking to C:\llama.cpp\logs\live\<id>.json and the
# finished record (prompt, reasoning, answer, token usage) to C:\llama.cpp\logs\glm-log.jsonl.
# Usage:
#   glm "explain this error: ..."
#   glm -System "You are a code generator. Output only code." "write a python csv parser"
#   glm -File src\main.py "review this file for bugs"
#   glm -NoThink "simple task, skip the reasoning phase"
#   glm -Label "codemap:renderer" -File renderer.rs "summarize"
#   glm -ShowReasoning "hard puzzle..."
param(
    [Parameter(Mandatory = $true, Position = 0)][string]$Prompt,
    [string]$System,
    [string[]]$File,
    [string]$Label,
    [int]$MaxTokens = 8000,
    [double]$Temperature = 0.7,
    [switch]$NoThink,
    [switch]$ShowReasoning,
    [switch]$NoLog,
    [int]$TimeoutSec = 600,
    [string]$Server = "http://127.0.0.1:8080",
    [ValidateSet('', 'specht:8086', 'specht:8087', 'specht:8088', 'adler:8085')][string]$SshWorker = ''
)

$ErrorActionPreference = 'Stop'
if (-not $SshWorker) {
    try { $null = Invoke-RestMethod "$Server/health" -TimeoutSec 3 }
    catch {
        Write-Error "GLM server is not running at $Server. Start it with C:\llama.cpp\start-glm-server.cmd"
        exit 1
    }
}

$userContent = $Prompt
foreach ($f in $File) {
    if (-not (Test-Path $f)) { Write-Error "File not found: $f"; exit 1 }
    $userContent += "`n`n--- FILE: $f ---`n" + (Get-Content $f -Raw)
}

$messages = @()
if ($System) { $messages += @{ role = "system"; content = $System } }
$messages += @{ role = "user"; content = $userContent }

$payload = @{
    messages       = $messages
    max_tokens     = $MaxTokens
    temperature    = $Temperature
    stream         = $true
    stream_options = @{ include_usage = $true }
}
if ($NoThink) { $payload.chat_template_kwargs = @{ enable_thinking = $false } }
$body = $payload | ConvertTo-Json -Depth 10

# --- logging setup ---
$logDir = 'C:\llama.cpp\logs'
$liveDir = Join-Path $logDir 'live'
$id = [guid]::NewGuid().ToString('N').Substring(0, 12)
$tsStart = Get-Date
if (-not $Label) { $Label = ($Prompt -replace '\s+', ' ').Substring(0, [Math]::Min(48, $Prompt.Length)) }
$liveFile = Join-Path $liveDir "$id.json"
if (-not $NoLog) {
    New-Item -ItemType Directory -Force $logDir, $liveDir | Out-Null
}

function Write-Live($phase, $reasoning, $content) {
    if ($NoLog) { return }
    $obj = [ordered]@{
        id = $id; label = $Label; ts_start = $tsStart.ToString('o')
        phase = $phase; prompt_preview = ($Prompt -replace '\s+', ' ').Substring(0, [Math]::Min(160, $Prompt.Length))
        reasoning_so_far = $reasoning; content_so_far = $content
        updated = (Get-Date).ToString('o')
    }
    try { Set-Content -Path $liveFile -Value ($obj | ConvertTo-Json -Depth 4 -Compress) -Encoding UTF8 } catch {}
}

function Append-Log($record) {
    if ($NoLog) { return }
    $line = ($record | ConvertTo-Json -Depth 6 -Compress) + "`n"
    $mtx = [System.Threading.Mutex]::new($false, 'glm-log-append')
    try {
        $null = $mtx.WaitOne(10000)
        [System.IO.File]::AppendAllText((Join-Path $logDir 'glm-log.jsonl'), $line, [System.Text.Encoding]::UTF8)
    } finally { $mtx.ReleaseMutex(); $mtx.Dispose() }
}

Write-Live 'starting' '' ''

# --- streaming request ---
$reasoning = [System.Text.StringBuilder]::new()
$content = [System.Text.StringBuilder]::new()
$usage = $null
$finishReason = $null
$errMsg = $null
$lastLive = [DateTime]::MinValue

if ($SshWorker) {
    # Remote worker transport: sshd port-forwarding is SELinux-blocked on the servers,
    # so POST via curl running server-side (user context). No streaming — final JSON only.
    $whost, $wport = $SshWorker -split ':'
    $sock = if ($whost -eq 'adler') { '1080' } else { '1081' }
    $ip = if ($whost -eq 'adler') { '10.71.0.1' } else { '10.72.0.1' }
    $payload.Remove('stream'); $payload.Remove('stream_options')
    $body = $payload | ConvertTo-Json -Depth 10
    Write-Live 'remote' "(running on $SshWorker - no live stream)" ''
    $usage = $null; $finishReason = $null; $errMsg = $null
    $reasoning = [System.Text.StringBuilder]::new(); $content = [System.Text.StringBuilder]::new()
    try {
        $raw = $body | ssh -o "ProxyCommand=`"C:\Program Files\Git\mingw64\bin\connect.exe`" -S 127.0.0.1:$sock %h %p" -o BatchMode=yes -o ConnectTimeout=15 -i "$env:USERPROFILE\.ssh\id_ed25519" "end@$ip" "curl -s --max-time $TimeoutSec -X POST http://127.0.0.1:$wport/v1/chat/completions -H 'Content-Type: application/json' -d @-" | Out-String
        $j = $raw | ConvertFrom-Json
        if ($j.error) { $errMsg = $j.error.message }
        else {
            $m = $j.choices[0].message
            if ($m.reasoning_content) { $null = $reasoning.Append($m.reasoning_content) }
            if ($m.content) { $null = $content.Append($m.content) }
            $finishReason = $j.choices[0].finish_reason
            $usage = $j.usage
        }
    } catch { $errMsg = "remote call failed: $($_.Exception.Message)" }
    $tsEnd = Get-Date
} else {
$client = [System.Net.Http.HttpClient]::new()
$client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)
try {
    $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, "$Server/v1/chat/completions")
    $req.Content = [System.Net.Http.StringContent]::new($body, [System.Text.Encoding]::UTF8, 'application/json')
    $resp = $client.Send($req, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead)
    if (-not $resp.IsSuccessStatusCode) {
        $errMsg = "HTTP $([int]$resp.StatusCode): $($resp.Content.ReadAsStringAsync().Result)"
        throw $errMsg
    }
    $stream = $resp.Content.ReadAsStream()
    $reader = [System.IO.StreamReader]::new($stream)
    while ($null -ne ($line = $reader.ReadLine())) {
        if (-not $line.StartsWith('data: ')) { continue }
        $data = $line.Substring(6)
        if ($data -eq '[DONE]') { break }
        try { $chunk = $data | ConvertFrom-Json } catch { continue }
        if ($chunk.usage) { $usage = $chunk.usage }
        if ($chunk.choices -and $chunk.choices.Count -gt 0) {
            $c = $chunk.choices[0]
            if ($c.finish_reason) { $finishReason = $c.finish_reason }
            $d = $c.delta
            if ($d) {
                if ($d.PSObject.Properties['reasoning_content'] -and $d.reasoning_content) { $null = $reasoning.Append($d.reasoning_content) }
                if ($d.PSObject.Properties['content'] -and $d.content) { $null = $content.Append($d.content) }
            }
        }
        if (((Get-Date) - $lastLive).TotalMilliseconds -gt 400) {
            $phase = if ($content.Length -gt 0) { 'answering' } else { 'thinking' }
            Write-Live $phase $reasoning.ToString() $content.ToString()
            $lastLive = Get-Date
        }
    }
    $reader.Dispose(); $resp.Dispose()
} catch {
    if (-not $errMsg) { $errMsg = $_.Exception.Message }
} finally {
    $client.Dispose()
}
$tsEnd = Get-Date
}
$durationS = [Math]::Round(($tsEnd - $tsStart).TotalSeconds, 1)
if (-not $NoLog) { Remove-Item $liveFile -Force -ErrorAction SilentlyContinue }

$record = [ordered]@{
    id = $id; label = $Label
    server = if ($SshWorker) { $SshWorker } else { 'local' }
    ts_start = $tsStart.ToString('o'); ts_end = $tsEnd.ToString('o'); duration_s = $durationS
    status = if ($errMsg) { 'error' } else { 'ok' }
    error = $errMsg
    finish_reason = $finishReason
    prompt_tokens = if ($usage) { $usage.prompt_tokens } else { $null }
    completion_tokens = if ($usage) { $usage.completion_tokens } else { $null }
    tps = if ($usage -and $usage.completion_tokens -and $durationS -gt 0) { [Math]::Round($usage.completion_tokens / $durationS, 1) } else { $null }
    nothink = [bool]$NoThink
    files = @($File)
    system = $System
    prompt = $Prompt
    reasoning = $reasoning.ToString()
    content = $content.ToString()
}
Append-Log $record

if ($errMsg) { Write-Error "Request failed: $errMsg"; exit 1 }

if ($ShowReasoning -and $reasoning.Length -gt 0) {
    Write-Host "=== reasoning ===" -ForegroundColor DarkGray
    Write-Host $reasoning.ToString() -ForegroundColor DarkGray
    Write-Host "=== answer ===" -ForegroundColor DarkGray
}
if ($content.Length -eq 0 -and $finishReason -eq 'length') {
    Write-Warning "Model used all $MaxTokens tokens on reasoning without finishing. Retry with a larger -MaxTokens."
}
$content.ToString()
