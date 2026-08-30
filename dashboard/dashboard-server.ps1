$root = $PSScriptRoot
$url = "http://127.0.0.1:8090/"
$listener = [System.Net.HttpListener]::new(); $listener.Prefixes.Add($url)
try { $listener.Start(); Write-Host "Server running at $url" }
catch { Write-Error "Could not bind $url : $($_.Exception.Message)"; exit 1 }

while ($true) {
    $context = $null
    try {
        $context = $listener.GetContext()
        $path = $context.Request.Url.AbsolutePath
        $ct = "application/json"; $resp = $null

        if ($path -eq "/" -or $path -eq "/index.html") {
            $f = Join-Path $root "dashboard.html"
            if (Test-Path $f) { $resp = [System.IO.File]::ReadAllText($f); $ct = "text/html" }
            else { $resp = "404 File Not Found"; $ct = "text/plain"; $context.Response.StatusCode = 404 }
        }
        elseif ($path -eq "/api/log") {
            $l = "C:\llama.cpp\logs\glm-log.jsonl"
            $recs = @()
            if (Test-Path $l) {
                $lines = Get-Content $l -Tail 500
                foreach ($ln in $lines) { if ($ln) { try { $recs += $ln | ConvertFrom-Json } catch {} } }
            }
            $resp = ConvertTo-Json -InputObject @($recs) -Depth 20 -Compress
        }
        elseif ($path -eq "/api/live") {
            $lp = "C:\llama.cpp\logs\live"
            $recs = @()
            if (Test-Path $lp) {
                Get-ChildItem $lp -Filter "*.json" | ForEach-Object {
                    try {
                        $r = $_ | Get-Content -Raw | ConvertFrom-Json
                        # a worker that stopped updating >60s ago was killed mid-run: clean up its orphan
                        if ($r.updated -and ((Get-Date) - [datetime]$r.updated).TotalSeconds -gt 60) {
                            Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
                        } else { $recs += $r }
                    } catch {}
                }
            }
            $resp = ConvertTo-Json -InputObject @($recs) -Depth 20 -Compress
        }
        elseif ($path -eq "/api/slots") {
            # Every worker is a plain HTTP call now: the wireproxy TCPClientTunnels
            # (9088 specht, 9188 adler) replaced the old ssh+curl hop, so remote
            # workers poll as fast as the local one. 5s cache is plenty.
            if (-not $script:slotCacheAt -or ((Get-Date) - $script:slotCacheAt).TotalSeconds -gt 5) {
                $all = @()
                $workers = @(
                    @{ name = 'local-4080'; url = 'http://127.0.0.1:8080' },
                    @{ name = 'specht-bigctx-131k'; url = 'http://127.0.0.1:9088' }
                )
                foreach ($w in $workers) {
                    try {
                        $s = Invoke-RestMethod -Uri "$($w.url)/slots" -TimeoutSec 4
                        foreach ($slot in @($s)) { $slot | Add-Member -NotePropertyName worker -NotePropertyValue $w.name -Force; $all += $slot }
                    } catch {}
                }
                $script:slotCache = ConvertTo-Json -InputObject @($all) -Depth 20 -Compress
                $script:slotCacheAt = Get-Date
            }
            $resp = $script:slotCache
        }
        elseif ($path -eq "/api/interfaces") {
            # Live index of every UI in the cluster - what the links panel renders.
            if (-not $script:ifState) {
                $script:ifState = @(
                    @{ name = 'gen3d studio'; where = 'local RTX 4080'; url = 'http://127.0.0.1:8095/'; probe = 'http://127.0.0.1:8095/api/state'; what = 'image -> GLB (Hunyuan3D)'; up = $false; at = [datetime]::MinValue },
                    @{ name = 'GLM-4.7-Flash'; where = 'local RTX 4080'; url = 'http://127.0.0.1:8080/'; probe = 'http://127.0.0.1:8080/health'; what = 'chat / 32k ctx'; up = $false; at = [datetime]::MinValue },
                    @{ name = 'GLM-4.7-Flash 131k'; where = 'specht 2x AMD'; url = 'http://127.0.0.1:9088/'; probe = 'http://127.0.0.1:9088/health'; what = 'chat / whole-codebase ctx'; up = $false; at = [datetime]::MinValue },
                    @{ name = 'ComfyUI'; where = 'adler RTX 4090'; url = 'http://127.0.0.1:9188/'; probe = 'http://127.0.0.1:9188/system_stats'; what = 'image generation'; up = $false; at = [datetime]::MinValue }
                )
            }
            # One probe per request, oldest first: this listener serves requests
            # one at a time, so probing all four inline would stall every other
            # panel on the page for as long as the slowest endpoint takes.
            $stale = $script:ifState | Sort-Object { $_.at } | Select-Object -First 1
            try { $null = Invoke-RestMethod -Uri $stale.probe -TimeoutSec 3; $stale.up = $true } catch { $stale.up = $false }
            $stale.at = Get-Date
            $view = foreach ($i in $script:ifState) {
                [PSCustomObject]@{ name = $i.name; where = $i.where; url = $i.url; what = $i.what; up = $i.up; checked = if ($i.at -eq [datetime]::MinValue) { $null } else { $i.at.ToString('o') } }
            }
            $resp = ConvertTo-Json -InputObject @($view) -Depth 5 -Compress
        }
        elseif ($path -eq "/api/fable") {
            # Fable/Claude session usage: sum token usage across this project's transcripts, cached 60s
            if (-not $script:fableCacheAt -or ((Get-Date) - $script:fableCacheAt).TotalSeconds -gt 60) {
                $in = [long]0; $out = [long]0; $cache = [long]0; $agents = 0; $wf = 0
                $proj = "C:\Users\end\.claude\projects\C--Users-end-dev"
                Get-ChildItem $proj -Recurse -Filter *.jsonl -ErrorAction SilentlyContinue | ForEach-Object {
                    if ($_.Name -like 'agent-*') { $agents++ }
                    if ($_.Name -eq 'journal.jsonl') { $wf++ }
                    $t = [System.IO.File]::ReadAllText($_.FullName)
                    foreach ($m in [regex]::Matches($t, '"output_tokens":(\d+)')) { $out += [long]$m.Groups[1].Value }
                    foreach ($m in [regex]::Matches($t, '"input_tokens":(\d+)')) { $in += [long]$m.Groups[1].Value }
                    foreach ($m in [regex]::Matches($t, '"cache_read_input_tokens":(\d+)')) { $cache += [long]$m.Groups[1].Value }
                }
                $script:fableCache = [PSCustomObject]@{ input_tokens = $in; output_tokens = $out; cache_read_tokens = $cache; agent_transcripts = $agents; workflows = $wf } | ConvertTo-Json -Compress
                $script:fableCacheAt = Get-Date
            }
            $resp = $script:fableCache
        }
        elseif ($path -eq "/api/gpu") {
            try {
                $out = (nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu --format=csv,noheader,nounits | Select-Object -First 1)
                $p = $out -split ','
                $obj = [PSCustomObject]@{util=[int]$p[0]; vram_used=[int]$p[1]; vram_total=[int]$p[2]; temp=[int]$p[3]}
                $resp = $obj | ConvertTo-Json -Depth 20 -Compress
            }
            catch { $resp = "{}" }
        }
        else {
            $resp = "404 Not Found"; $ct = "text/plain"; $context.Response.StatusCode = 404
        }

        $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$resp)
        $context.Response.ContentType = "$ct; charset=utf-8"
        $context.Response.Headers.Add("Cache-Control", "no-store")
        $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
        $context.Response.Close()
    }
    catch {
        try {
            if ($context) {
                $bytes = [System.Text.Encoding]::UTF8.GetBytes("500 Internal Server Error: $($_.Exception.Message)")
                $context.Response.StatusCode = 500
                $context.Response.ContentType = "text/plain; charset=utf-8"
                $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                $context.Response.Close()
            } else { Start-Sleep -Milliseconds 200 }
        } catch {}
    }
}
