# Fan out per-file code-map summarization to the local GLM workers (2 parallel slots)
$repo = 'C:\Users\end\dev\ember'
$outDir = Join-Path $PSScriptRoot 'codemap'
New-Item -ItemType Directory -Force $outDir | Out-Null

$files = @(Get-ChildItem $repo -Recurse -File -Include *.rs,*.wgsl,*.sh |
    Where-Object { $_.FullName -notmatch '\\\.git\\' } | Sort-Object FullName)
$files += Get-Item (Join-Path $repo 'web\index.html')
$files += Get-Item (Join-Path $repo 'Cargo.toml')

$sys = @"
You are a senior engineer writing one terse code-map entry for one file of the 'ember' Rust game engine workspace.
Output EXACTLY this markdown, nothing else, max 160 words total:
**Purpose:** <one sentence>
**Key items:** <bulleted list of the important pub types/functions/constants with a few words each>
**Depends on:** <crates/modules this file uses>
**Gotchas:** <non-obvious invariants, protocol/version constants, magic numbers, unsafe blocks, error-prone areas; write 'none noted' if none>
No preamble, no code fences, no restating the file.
"@

$total = $files.Count
$done = 0
$queue = [System.Collections.Queue]::new()
$files | ForEach-Object { $queue.Enqueue($_) }
$running = @()
$sw = [System.Diagnostics.Stopwatch]::StartNew()

while ($queue.Count -gt 0 -or $running.Count -gt 0) {
    while ($running.Count -lt 2 -and $queue.Count -gt 0) {
        $f = $queue.Dequeue()
        $rel = $f.FullName.Replace("$repo\", '')
        $safe = $rel -replace '[\\/]', '__'
        $job = Start-Job -ScriptBlock {
            param($glm, $sys, $filePath, $outFile, $rel)
            $r = & $glm -NoThink -System $sys -File $filePath -Prompt "Write the code-map entry for $rel" -MaxTokens 700 -TimeoutSec 300 2>&1 | Out-String
            Set-Content -Path $outFile -Value $r -Encoding UTF8
        } -ArgumentList 'C:\llama.cpp\glm.ps1', $sys, $f.FullName, (Join-Path $outDir "$safe.md"), $rel
        $running += @{ job = $job; rel = $rel }
    }
    $stillRunning = @()
    foreach ($r in $running) {
        if ($r.job.State -in 'Completed','Failed') {
            $done++
            Write-Output ("[{0}/{1}] {2} ({3})  t={4:N0}s" -f $done, $total, $r.rel, $r.job.State, $sw.Elapsed.TotalSeconds)
            Remove-Job $r.job -Force
        } else { $stillRunning += $r }
    }
    $running = $stillRunning
    Start-Sleep -Milliseconds 500
}

# Assemble into the project-local map
$mapDir = Join-Path $repo '.claude'
New-Item -ItemType Directory -Force $mapDir | Out-Null
$map = "# ember code map`n`nGenerated $(Get-Date -Format yyyy-MM-dd) by local GLM-4.7-Flash workers. Per-file summaries; verify before relying on details.`n"
foreach ($f in $files) {
    $rel = $f.FullName.Replace("$repo\", '')
    $safe = $rel -replace '[\\/]', '__'
    $entry = Get-Content (Join-Path $outDir "$safe.md") -Raw -ErrorAction SilentlyContinue
    $map += "`n## $rel`n$entry"
}
Set-Content -Path (Join-Path $mapDir 'codemap.md') -Value $map -Encoding UTF8
Write-Output "DONE: $total files mapped in $([int]$sw.Elapsed.TotalSeconds)s -> $mapDir\codemap.md"
