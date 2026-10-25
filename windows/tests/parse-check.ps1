<#
Parse every PowerShell file under windows\ (no execution) and check the house rules: ASCII only, launcher.cmd has
CRLF line ends and calls launcher.ps1 with -NoProfile -ExecutionPolicy Bypass -File.
  powershell -NoProfile -ExecutionPolicy Bypass -File windows\tests\parse-check.ps1     (or pwsh -File ...)
#>
$ErrorActionPreference = 'Stop'
$W = Split-Path -Parent $PSScriptRoot
$fails = 0; $n = 0
function Check([bool]$c, [string]$what) { $script:n++; if ($c) { Write-Host "ok: $what" } else { $script:fails++; Write-Host "FAIL: $what" } }
$files = @(Get-ChildItem -LiteralPath $W -Recurse -File -Filter '*.ps1' | Sort-Object FullName)
foreach ($f in $files) {
    $tok = $null; $err = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tok, [ref]$err)
    $rel = $f.FullName.Substring($W.Length + 1)
    Check (@($err).Count -eq 0) ("parses: $rel" + $(if (@($err).Count) { ' -> ' + ((@($err) | ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Message)" }) -join '; ') } else { '' }))
}
foreach ($f in @($files) + @(Get-ChildItem -LiteralPath $W -File -Filter '*.cmd') + @(Get-ChildItem -LiteralPath $W -File -Filter '*.txt')) {
    $b = [IO.File]::ReadAllBytes($f.FullName); $bad = @($b | Where-Object { $_ -gt 0x7E -or ($_ -lt 0x20 -and $_ -ne 9 -and $_ -ne 10 -and $_ -ne 13) }).Count
    Check ($bad -eq 0) "ASCII only: $($f.Name)"
}
$cmd = Join-Path $W 'launcher.cmd'; $t = [IO.File]::ReadAllText($cmd)
Check (($t -split "`r`n").Count -gt 1 -and ($t -replace "`r`n", '') -notmatch "`n") 'launcher.cmd uses CRLF line ends'
Check ($t -match 'powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0launcher\.ps1" %\*') 'launcher.cmd runs launcher.ps1 next to it, passing arguments'
Check ($t -match 'exit /b %ERRORLEVEL%') 'launcher.cmd returns the exit code'
# make-skip-state.ps1 must replay the same segments as steam-machine/make-skip-state.sh (full parity test:
# tests/compare-skip-state-sh.sh). Static check: the tutorial boundaries B=(...) and the later "run S E mode" calls.
$sh = Join-Path (Join-Path (Split-Path -Parent $W) 'steam-machine') 'make-skip-state.sh'; $ps = Join-Path $W 'make-skip-state.ps1'
if (Test-Path -LiteralPath $sh) {
    $shT = [IO.File]::ReadAllText($sh); $psT = [IO.File]::ReadAllText($ps)
    $shB = if ($shT -match '(?m)^B=\(([0-9 ]+)\)') { ($Matches[1].Trim() -split '\s+') -join ',' } else { 'none' }
    $psB = if ($psT -match '(?m)^\$B = @\(([0-9, ]+)\)') { ($Matches[1] -replace '\s', '') } else { 'none' }
    Check ($shB -ne 'none' -and $shB -eq $psB) "make-skip-state.ps1: tutorial segment boundaries = make-skip-state.sh ($psB)"
    $shR = @([regex]::Matches($shT, 'run (\d+) (\d+) (skip|idle|call|probe)') | ForEach-Object { $_.Groups[1].Value + '-' + $_.Groups[2].Value + '-' + $_.Groups[3].Value }) -join ','
    $psR = @([regex]::Matches($psT, "@\((\d+), (\d+), '(skip|idle|call|probe)'\)") | ForEach-Object { $_.Groups[1].Value + '-' + $_.Groups[2].Value + '-' + $_.Groups[3].Value }) -join ','
    Check ($shR -ne '' -and $shR -eq $psR) "make-skip-state.ps1: later segments = make-skip-state.sh ($psR)"
    foreach ($c in @('1000.a/os_999', '013.a/os_601', 'PS2_VOICE_INJECT', 'PS2_GPU_LOW_POWER')) {
        Check ($shT.Contains($c) -and $psT.Contains($c)) "make-skip-state.ps1 and .sh both set $c"
    }
}
if ($fails) { Write-Host "parse-check: $fails of $n checks FAILED"; exit 1 }
Write-Host "parse-check: all $n checks passed"; exit 0
