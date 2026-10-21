# Pester-free checks of the lifeline.env.json merge as install.ps1 uses it: windows/env-json.ps1 (Merge-LifelineEnv,
# shared with build.ps1) with install.ps1's keys. No ISO, no game data. Complements Lead's tests/test_env_json.ps1.
#   pwsh -NoProfile -File windows/tests/test-install-envjson.ps1      (also Windows PowerShell 5.1)
$ErrorActionPreference = 'Stop'
$WIN = Split-Path -Parent $PSScriptRoot
$inst = [IO.File]::ReadAllText((Join-Path $WIN 'install.ps1'))
. (Join-Path $WIN 'env-json.ps1')
$script:fail = 0; $script:n = 0
function Ok([bool]$c, [string]$m) { $script:n++; if ($c) { Write-Host "ok: $m" } else { Write-Host "FAIL: $m"; $script:fail = 1 } }
function Read-Env([string]$p) { [IO.File]::ReadAllText($p) | ConvertFrom-Json }
function Leftovers([string]$d) { @(Get-ChildItem -LiteralPath $d -Force | Where-Object { $_.Name -like '*.tmp*' }).Count }
$T = Join-Path ([IO.Path]::GetTempPath()) ('envjson-qol-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $T | Out-Null
try {
    $f = Join-Path $T 'lifeline.env.json'
    $owned = @{ ISO = 'E:\My Disc (USA).iso'; VOSK_DIR = 'C:\L\game\vosk' }
    $defaults = @{ MEMCARD = 'C:\L\game\saves\lifeline.ps2' }

    Ok ($inst -match "\. \(Join-Path \`$PSScriptRoot 'env-json.ps1'\)" -and $inst -match 'Merge-LifelineEnv -Path \$envf' -and $inst -notmatch 'function Merge-') 'install.ps1 dot-sources env-json.ps1 and has no merge copy of its own'
    Ok ($inst -notmatch '::Replace\([^)]*\$null') 'install.ps1 never passes $null to [IO.File]::Replace'
    # 1. no file yet: Move path
    Merge-LifelineEnv -Path $f -Owned $owned -Defaults $defaults | Out-Null
    $e = Read-Env $f
    Ok ($e.ISO -ceq 'E:\My Disc (USA).iso' -and $e.MEMCARD -ceq 'C:\L\game\saves\lifeline.ps2') 'missing file: created (Move path) with owned keys + defaults'
    Ok ((Leftovers $T) -eq 0) 'missing file: no temp file left'

    # 2. existing file with build.ps1 keys and a value nested deeper than ConvertTo-Json's default depth (2): Replace path
    $deep = '{"PS2RUN":"C:\\L\\game\\ps2run.exe","MEMCARD":"D:\\card.ps2","X":{"a":{"b":{"c":{"d":[1,{"e":"deep"}]}}}}}'
    [IO.File]::WriteAllText($f, $deep)
    $before = (Get-Item -LiteralPath $f).LastWriteTimeUtc
    Merge-LifelineEnv -Path $f -Owned @{ ISO = 'F:\renamed.iso' } -Defaults $defaults | Out-Null
    $e = Read-Env $f
    Ok ($e.X.a.b.c.d[1].e -ceq 'deep' -and $e.X.a.b.c.d[0] -eq 1) 'depth > 2 value round-trips intact (-Depth 10)'
    Ok (([IO.File]::ReadAllText($f)) -notmatch 'System\.Collections|@\{') 'no stringified nested objects in the output'
    Ok ($e.PS2RUN -ceq 'C:\L\game\ps2run.exe' -and $e.MEMCARD -ceq 'D:\card.ps2' -and $e.ISO -ceq 'F:\renamed.iso') 'existing file: foreign keys kept, default not applied over MEMCARD, owned ISO replaced'
    Ok ((Leftovers $T) -eq 0 -and @(Get-ChildItem $T -Filter '*.bad-*').Count -eq 0) 'existing file (Replace path): no temp, no backup left'

    # 2b. a hand-edited lowercase key is replaced, not duplicated
    [IO.File]::WriteAllText($f, '{"iso":"old.iso","PS2RUN":"C:/p.exe"}')
    Merge-LifelineEnv -Path $f -Owned $owned | Out-Null
    $names = @((Read-Env $f).PSObject.Properties.Name)
    Ok ((@($names | Where-Object { $_ -eq 'ISO' }).Count -eq 1) -and ($names -ccontains 'ISO') -and ((Read-Env $f).ISO -ceq 'E:\My Disc (USA).iso')) 'lowercase "iso" key -> one canonical ISO with the new value'
    # 3. relative path is made absolute before any [IO.File] call
    Push-Location $T
    try { [Environment]::CurrentDirectory = [IO.Path]::GetTempPath(); Merge-LifelineEnv -Path 'lifeline.env.json' -Owned @{ ISO = 'G:\rel.iso' } | Out-Null } finally { Pop-Location }
    Ok ((Read-Env $f).ISO -ceq 'G:\rel.iso') 'relative -Path resolves against the PowerShell location, not the process cwd'

    # 4. bad files: every backup gets its own name, nothing overwritten (two in the same second)
    [IO.File]::WriteAllText($f, '{ "ISO": ')
    Merge-LifelineEnv -Path $f -Owned $owned | Out-Null
    [IO.File]::WriteAllText($f, '[1,2]')
    Merge-LifelineEnv -Path $f -Owned $owned | Out-Null
    $bads = @(Get-ChildItem $T -Filter 'lifeline.env.json.bad-*' | Sort-Object Name)
    $texts = @($bads | ForEach-Object { [IO.File]::ReadAllText($_.FullName) })
    Ok ($bads.Count -eq 2 -and ($texts -contains '{ "ISO": ') -and ($texts -contains '[1,2]')) 'two bad files -> two distinct backups, both originals intact'
    # same millisecond (Get-Date pinned): the counter makes -1, -2 instead of overwriting
    function Get-Date { param([string]$Format) ([datetime]'2026-01-02T03:04:05.006').ToString($Format) }
    try {
        $stem = "$f.bad-20260102-030405-006"
        foreach ($junk in 'junk A', 'junk B', 'junk C') { [IO.File]::WriteAllText($f, $junk); Merge-LifelineEnv -Path $f -Owned $owned | Out-Null }
    } finally { Remove-Item Function:\Get-Date }
    Ok (([IO.File]::ReadAllText($stem)) -ceq 'junk A' -and ([IO.File]::ReadAllText("$stem-1")) -ceq 'junk B' -and ([IO.File]::ReadAllText("$stem-2")) -ceq 'junk C') 'same-millisecond bad files -> .bad-<ms>, -1, -2; none overwritten'

    # 5. a failing write leaves no temp file and does not touch an existing file
    $dirTarget = Join-Path $T 'isdir.json'; New-Item -ItemType Directory $dirTarget | Out-Null
    $threw = $false; try { Merge-LifelineEnv -Path $dirTarget -Owned $owned | Out-Null } catch { $threw = $true }
    Ok ($threw -and (Leftovers $T) -eq 0) 'failed write (target is a folder): error raised, temp file cleaned up'

    # 6. UTF-8 BOM input (Windows PowerShell 5.1 Set-Content -Encoding UTF8) is merged; output has no BOM
    [IO.File]::WriteAllBytes($f, [Text.Encoding]::UTF8.GetPreamble() + [Text.Encoding]::UTF8.GetBytes('{"PS2RUN":"C:/x.exe"}'))
    $nb = @(Get-ChildItem $T -Filter '*.bad-*').Count
    Merge-LifelineEnv -Path $f -Owned $owned | Out-Null
    $b = [IO.File]::ReadAllBytes($f)
    Ok ((Read-Env $f).PS2RUN -ceq 'C:/x.exe' -and @(Get-ChildItem $T -Filter '*.bad-*').Count -eq $nb) 'BOM input merged, not backed up'
    Ok (-not ($b[0] -eq 0xEF -and $b[1] -eq 0xBB)) 'output written without a BOM'
} finally { Remove-Item -Recurse -Force $T }
if ($script:fail) { Write-Host "install env-json: FAILURES"; exit 1 }
Write-Host "install env-json: all $($script:n) checks passed"; exit 0
