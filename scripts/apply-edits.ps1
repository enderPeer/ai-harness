param([string]$EditFile, [string]$TargetFile)
$text = Get-Content $EditFile -Raw
$target = Get-Content $TargetFile -Raw
$pattern = '(?s)### EDIT (\d+)\s*\r?\n<<<FIND\r?\n(.*?)\r?\n===REPLACE\r?\n(.*?)\r?\n>>>'
$edits = [regex]::Matches($text, $pattern)
"parsed edits: $($edits.Count)"
$applied = 0
foreach ($e in $edits) {
    $n = $e.Groups[1].Value; $find = $e.Groups[2].Value; $repl = $e.Groups[3].Value
    # normalize line endings for matching
    $findN = $find -replace "`r`n", "`n"
    $targetN = $target -replace "`r`n", "`n"
    $count = ([regex]::Matches($targetN, [regex]::Escape($findN))).Count
    if ($count -eq 1) {
        $idx = $targetN.IndexOf($findN)
        $targetN = $targetN.Substring(0, $idx) + ($repl -replace "`r`n", "`n") + $targetN.Substring($idx + $findN.Length)
        $target = $targetN
        $applied++
        "EDIT ${n}: applied"
    } elseif ($count -eq 0) { "EDIT ${n}: FIND NOT FOUND (skipped)" }
    else { "EDIT ${n}: FIND AMBIGUOUS x$count (skipped)" }
}
Set-Content -Path $TargetFile -Value $target -Encoding UTF8 -NoNewline
"applied $applied of $($edits.Count)"
