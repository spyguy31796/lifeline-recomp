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
if ($fails) { Write-Host "parse-check: $fails of $n checks FAILED"; exit 1 }
Write-Host "parse-check: all $n checks passed"; exit 0
