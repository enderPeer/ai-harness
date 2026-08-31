# The night shift: hand the overnight coder a task list, review the results with
# coffee.
#
#   night-shift.ps1 -Tasks night\tasks.md
#   night-shift.ps1 -Tasks night\tasks.md -Repo C:\Users\end\dev\ember -TaskMinutes 90
#   night-shift.ps1 -Tasks night\tasks.md -DryRun      # show the plan, run nothing
#
# Each task gets its own git worktree and its own branch, so the agent can never
# touch your working tree, never lands on main, and never pushes. What you get
# in the morning is one folder per task holding the diff, the files touched and
# the full transcript — plus a summary you can skim in a minute.
#
# The model this drives is slow on purpose. At ~17 tok/s a night is roughly
# 500k tokens, which is a lot of code but not infinite: give it tasks that are
# self-contained, and prefer six small ones over one enormous one, because a
# task that goes wrong wastes only its own slot.
param(
    [Parameter(Mandatory = $true)][string]$Tasks,
    [string]$Repo = (Get-Location).Path,
    [string]$Model = 'specht-qwen/qwen3.8-27b',
    [string]$Command = 'ultra',
    [int]$TaskMinutes = 60,
    [string]$ReviewDir,
    [switch]$DryRun
)

$ErrorActionPreference = 'Continue'
$opencode = "$env:USERPROFILE\tools\opencode\opencode.exe"
if (-not (Test-Path $opencode)) { Write-Error "opencode not found at $opencode"; exit 1 }
if (-not (Test-Path $Tasks)) { Write-Error "task list not found: $Tasks"; exit 1 }
if (-not (Test-Path (Join-Path $Repo '.git'))) { Write-Error "$Repo is not a git repository"; exit 1 }

if (-not $ReviewDir) {
    $ReviewDir = Join-Path $Repo "night-review\$(Get-Date -Format 'yyyy-MM-dd')"
}
$worktreeRoot = Join-Path ([System.IO.Path]::GetTempPath()) "night-shift"

# --- parse the task list: every "## heading" starts a new task, its body is the brief
$taskList = @()
$current = $null
foreach ($line in Get-Content $Tasks) {
    if ($line -match '^##\s+(.+?)\s*$') {
        if ($current) { $taskList += $current }
        $slug = ($matches[1] -replace '[^A-Za-z0-9]+', '-').Trim('-').ToLower()
        $current = [ordered]@{ title = $matches[1]; slug = $slug; body = @() }
    }
    elseif ($current) { $current.body += $line }
}
if ($current) { $taskList += $current }

if (-not $taskList.Count) {
    Write-Error "no tasks found in $Tasks — each task needs a '## Title' heading"
    exit 1
}

Write-Host "`nNight shift: $($taskList.Count) task(s) from $Tasks" -ForegroundColor Cyan
Write-Host "  repo    : $Repo"
Write-Host "  model   : $Model"
Write-Host "  budget  : $TaskMinutes min/task  (~$([int]($TaskMinutes * 60 * 17 / 1000))k tokens each at 17 tok/s)"
Write-Host "  review  : $ReviewDir`n"
foreach ($t in $taskList) { Write-Host "  - $($t.title)" -ForegroundColor DarkGray }
Write-Host ""

if ($DryRun) { Write-Host "dry run — nothing executed`n" -ForegroundColor Yellow; return }

# Fail fast rather than discovering at 3am that the tier is off shift.
try { $null = Invoke-RestMethod -Uri 'http://127.0.0.1:9089/health' -TimeoutSec 10 }
catch {
    Write-Error "the night coder is not answering on 127.0.0.1:9089. Start it with: night-coder.ps1 -Start"
    exit 1
}

New-Item -ItemType Directory -Force $ReviewDir | Out-Null
New-Item -ItemType Directory -Force $worktreeRoot | Out-Null
$summary = @()

foreach ($task in $taskList) {
    $started = Get-Date
    $branch = "night/$($task.slug)"
    $tree = Join-Path $worktreeRoot $task.slug
    $out = Join-Path $ReviewDir $task.slug
    New-Item -ItemType Directory -Force $out | Out-Null

    Write-Host "=== $($task.title)" -ForegroundColor Cyan
    Write-Host "    branch $branch"

    # Fresh worktree per task: the agent works on a clone-like checkout, so a
    # botched run costs nothing but a branch you delete.
    git -C $Repo worktree remove --force $tree 2>$null | Out-Null
    git -C $Repo branch -D $branch 2>$null | Out-Null
    $mk = git -C $Repo worktree add -b $branch $tree 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "    could not create worktree: $mk" -ForegroundColor Red
        $summary += [pscustomobject]@{ Task = $task.title; Status = 'worktree failed'; Files = 0; Minutes = 0; Branch = '' }
        continue
    }

    $brief = ($task.body -join "`n").Trim()
    $log = Join-Path $out 'transcript.txt'

    $env:NODE_EXTRA_CA_CERTS = "$env:USERPROFILE\.config\barza-llama.crt"
    $p = Start-Process -FilePath $opencode `
        -ArgumentList @('run', '--model', $Model, '--command', $Command, $brief) `
        -WorkingDirectory $tree -NoNewWindow -PassThru `
        -RedirectStandardOutput $log -RedirectStandardError (Join-Path $out 'stderr.txt')

    if (-not $p.WaitForExit($TaskMinutes * 60 * 1000)) {
        Write-Host "    over budget at $TaskMinutes min — stopping this task" -ForegroundColor Yellow
        try { $p.Kill($true) } catch {}
        $status = "timeout after $TaskMinutes min"
    }
    else { $status = if ($p.ExitCode -eq 0) { 'ok' } else { "exit $($p.ExitCode)" } }

    # Capture whatever it produced, committed or not.
    git -C $tree add -A 2>&1 | Out-Null
    git -C $tree diff --cached > (Join-Path $out 'changes.diff')
    $files = @(git -C $tree diff --cached --name-only) | Where-Object { $_ }
    $files | Set-Content (Join-Path $out 'files-touched.txt')
    if ($files.Count) {
        git -C $tree -c user.name='night-shift' -c user.email='night@ai-harness' `
            commit -q -m "night shift: $($task.title)" 2>&1 | Out-Null
    }

    $minutes = [math]::Round(((Get-Date) - $started).TotalMinutes, 1)
    Write-Host "    $status — $($files.Count) file(s), $minutes min" -ForegroundColor $(if ($files.Count) { 'Green' } else { 'Yellow' })

    $summary += [pscustomobject]@{
        Task = $task.title; Status = $status; Files = $files.Count
        Minutes = $minutes; Branch = $(if ($files.Count) { $branch } else { '' })
    }

    # Keep the branch, drop the checkout — `git switch night/<slug>` recovers it.
    git -C $Repo worktree remove --force $tree 2>$null | Out-Null
    if (-not $files.Count) { git -C $Repo branch -D $branch 2>$null | Out-Null }
}

$summary | Export-Csv (Join-Path $ReviewDir 'summary.csv') -NoTypeInformation
$md = @("# Night shift — $(Get-Date -Format 'yyyy-MM-dd HH:mm')", "",
        "Model: $Model   Repo: $Repo", "",
        "| Task | Status | Files | Min | Branch |", "|---|---|---|---|---|")
$md += $summary | ForEach-Object { "| $($_.Task) | $($_.Status) | $($_.Files) | $($_.Minutes) | $($_.Branch) |" }
$md += @("", "Review a task with:", '```bash', "git -C `"$Repo`" switch <branch>", '```',
         "Nothing was pushed and nothing landed on main.")
$md -join "`n" | Set-Content (Join-Path $ReviewDir 'README.md') -Encoding utf8

Write-Host "`nDone. Review: $ReviewDir" -ForegroundColor Cyan
$summary | Format-Table -AutoSize | Out-String | Write-Host
