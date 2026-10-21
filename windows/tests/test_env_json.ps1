# Test for windows/env-json.ps1 (Merge-LifelineEnv), the lifeline.env.json merge used by build.ps1.
# No game data, no build: pwsh windows/tests/test_env_json.ps1   (also runs under Windows PowerShell 5.1)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'env-json.ps1')
$script:fail = 0
function Ok([bool]$c, [string]$m) { if ($c) { Write-Host "ok: $m" } else { Write-Host "FAIL: $m"; $script:fail = 1 } }
function Read-Env([string]$p) { [IO.File]::ReadAllText($p) | ConvertFrom-Json }
$T = Join-Path ([IO.Path]::GetTempPath()) ("envjson-" + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $T | Out-Null
try {
    $f = Join-Path $T 'lifeline.env.json'
    $owned1 = @{ SRC = 'C:/w/src'; PS2RUN = 'C:/w/ps2run.exe'; ELF = 'C:/w/boot.elf' }
    $defaults = @{ ISO = 'C:/default.iso'; MEMCARD = 'C:/w/saves/card.ps2' }

    # 1. missing file: owned + defaults
    Ok (-not (Test-Path $f)) 'missing file: precondition'
    Merge-LifelineEnv -Path $f -Owned $owned1 -Defaults $defaults | Out-Null
    $e = Read-Env $f
    Ok ($e.PS2RUN -eq 'C:/w/ps2run.exe' -and $e.ISO -eq 'C:/default.iso' -and $e.MEMCARD -eq 'C:/w/saves/card.ps2' -and @(Get-ChildItem $T -Filter '*.bad-*').Count -eq 0) 'missing file: created with owned keys and defaults, no backup'

    # 2. another tool (install.ps1) sets its keys, including ISO; a rebuild must keep them
    $e | Add-Member -NotePropertyName VOSK_DIR -NotePropertyValue 'D:/vosk dir'
    $e | Add-Member -NotePropertyName QOL_EXTRA -NotePropertyValue @{ nested = 1 }
    $e.ISO = 'E:/My Disc (USA).iso'
    [IO.File]::WriteAllText($f, ($e | ConvertTo-Json -Depth 10))
    $owned2 = @{ SRC = 'C:/w2/src'; PS2RUN = 'C:/w2/ps2run.exe'; ELF = 'C:/w2/boot.elf' }
    Merge-LifelineEnv -Path $f -Owned $owned2 -Defaults $defaults | Out-Null
    $e = Read-Env $f
    Ok ($e.VOSK_DIR -eq 'D:/vosk dir') 'rebuild keeps foreign key VOSK_DIR'
    Ok ($e.ISO -eq 'E:/My Disc (USA).iso') 'rebuild keeps ISO set by another tool (default does not overwrite)'
    Ok ($e.QOL_EXTRA.nested -eq 1) 'rebuild keeps a nested foreign value'
    Ok ($e.PS2RUN -eq 'C:/w2/ps2run.exe' -and $e.SRC -eq 'C:/w2/src' -and $e.ELF -eq 'C:/w2/boot.elf') 'rebuild updates the keys build.ps1 owns'
    Ok (@(Get-ChildItem $T -Filter '*.bad-*').Count -eq 0 -and -not (Test-Path "$f.tmp")) 'valid file: no backup, no temp file left (atomic write: temp + rename)'

    # 3. invalid / non-object files: backed up, then fresh
    $cases = [ordered]@{ 'invalid JSON' = '{ "ISO": '; 'empty file' = ''; 'JSON array' = '[{"ISO":"x"}]'; 'JSON string' = '"hello"' }
    foreach ($name in $cases.Keys) {
        Get-ChildItem $T -Filter '*.bad-*' | Remove-Item
        [IO.File]::WriteAllText($f, $cases[$name])
        Merge-LifelineEnv -Path $f -Owned $owned1 -Defaults $defaults | Out-Null
        $bad = @(Get-ChildItem $T -Filter 'lifeline.env.json.bad-*')
        $e = Read-Env $f
        Ok ($bad.Count -eq 1 -and [IO.File]::ReadAllText($bad[0].FullName) -eq $cases[$name]) "${name}: original backed up unchanged"
        Ok ($e.PS2RUN -eq 'C:/w/ps2run.exe' -and $e.ISO -eq 'C:/default.iso' -and @($e.PSObject.Properties).Count -eq 5) "${name}: fresh file with owned keys + defaults only"
    }

    # 3b. two bad files in a row, with the clock frozen so both get the same timestamp: the counter keeps them apart
    Get-ChildItem $T -Filter '*.bad-*' | Remove-Item
    function Get-Date { '20260101-000000-000' }   # shadows the cmdlet for Merge-LifelineEnv
    try {
        [IO.File]::WriteAllText($f, 'bad one'); Merge-LifelineEnv -Path $f -Owned $owned1 -Defaults $defaults | Out-Null
        [IO.File]::WriteAllText($f, 'bad two'); Merge-LifelineEnv -Path $f -Owned $owned1 -Defaults $defaults | Out-Null
    } finally { Remove-Item Function:\Get-Date }
    Ok ((Test-Path "$f.bad-20260101-000000-000") -and (Test-Path "$f.bad-20260101-000000-000-1")) 'same timestamp: second backup gets a -1 counter'
    $bad = @(Get-ChildItem $T -Filter 'lifeline.env.json.bad-*' | ForEach-Object { [IO.File]::ReadAllText($_.FullName) } | Sort-Object)
    Ok ($bad.Count -eq 2 -and $bad[0] -eq 'bad one' -and $bad[1] -eq 'bad two') 'two bad files in a row: two separate backups, both kept unchanged'

    # 3c. keys match case-insensitively; owned/default keys are renamed to the canonical upper case
    Get-ChildItem $T -Filter '*.bad-*' | Remove-Item
    [IO.File]::WriteAllText($f, '{"iso":"E:/mine.iso","ps2run":"C:/old.exe","Vosk_Dir":"D:/v"}')
    Merge-LifelineEnv -Path $f -Owned $owned1 -Defaults $defaults | Out-Null
    $names = @((Read-Env $f).PSObject.Properties | ForEach-Object Name)
    $e = Read-Env $f
    Ok ($e.ISO -eq 'E:/mine.iso' -and $names -ccontains 'ISO' -and -not ($names -ccontains 'iso')) 'lowercase "iso" is treated as ISO (kept, not defaulted) and written as ISO'
    Ok ($e.PS2RUN -eq 'C:/w/ps2run.exe' -and $names -ccontains 'PS2RUN' -and -not ($names -ccontains 'ps2run')) 'lowercase "ps2run" is the owned PS2RUN: updated and written as PS2RUN'
    Ok ($names -ccontains 'Vosk_Dir' -and $names.Count -eq 6) 'a foreign key keeps its own case; no duplicate keys'

    # 3d. a relative path is resolved against the current location
    Push-Location $T
    try { Merge-LifelineEnv -Path 'lifeline.env.json' -Owned $owned2 -Defaults $defaults | Out-Null } finally { Pop-Location }
    Ok ((Read-Env $f).PS2RUN -eq 'C:/w2/ps2run.exe' -and -not (Test-Path "$f.tmp")) 'relative -Path: merged in place, no temp file left'

    # 4. UTF-8 BOM (Windows PowerShell 5.1 Set-Content -Encoding UTF8 writes one) is read, and output has no BOM
    $bom = [Text.Encoding]::UTF8.GetPreamble() + [Text.Encoding]::UTF8.GetBytes('{"VOSK_DIR":"C:/v"}')
    [IO.File]::WriteAllBytes($f, $bom)
    Get-ChildItem $T -Filter '*.bad-*' | Remove-Item
    Merge-LifelineEnv -Path $f -Owned $owned1 -Defaults $defaults | Out-Null
    $bytes = [IO.File]::ReadAllBytes($f)
    Ok ((Read-Env $f).VOSK_DIR -eq 'C:/v' -and @(Get-ChildItem $T -Filter '*.bad-*').Count -eq 0) 'file with a UTF-8 BOM is merged, not backed up'
    Ok (-not ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB)) 'output is written without a BOM'

    # 5. KIT: build.ps1 owns it (as install.ps1 does), so the launcher can find KIT\windows\build.ps1 + install.ps1
    #    before install.ps1 has ever run. Both write the repo root (the folder above windows\).
    $WIN = Split-Path -Parent $PSScriptRoot; $REPO = Split-Path -Parent $WIN
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $WIN 'build.ps1'), [ref]$null, [ref]$null)
    $merge = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Merge-LifelineEnv' }, $true))
    $ownedAst = $null
    if ($merge.Count -eq 1) {
        $els = $merge[0].CommandElements
        for ($i = 0; $i -lt $els.Count - 1; $i++) { if ($els[$i] -is [Management.Automation.Language.CommandParameterAst] -and $els[$i].ParameterName -eq 'Owned') { $ownedAst = $els[$i + 1] } }
    }
    $kitVal = $null
    if ($ownedAst -is [Management.Automation.Language.HashtableAst]) { foreach ($kv in $ownedAst.KeyValuePairs) { if ($kv.Item1.Extent.Text -eq 'KIT') { $kitVal = $kv.Item2.Extent.Text } } }
    Ok ($merge.Count -eq 1 -and $kitVal -eq '$OurCode') "build.ps1: one Merge-LifelineEnv call, KIT = `$OurCode in -Owned (got: $kitVal)"
    $assign = @{}
    foreach ($a in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -in @('$Kit', '$OurCode') }, $false)) { $assign[$a.Left.Extent.Text] = $a.Right.Extent.Text }
    Ok ($assign['$Kit'] -eq 'Split-Path -Parent $PSCommandPath' -and $assign['$OurCode'] -eq 'Split-Path -Parent $Kit') 'build.ps1: $OurCode is the folder above the folder build.ps1 runs from'
    $buildKit = Split-Path -Parent (Split-Path -Parent (Join-Path $WIN 'build.ps1'))   # what build.ps1 computes for this checkout
    $instSrc = [IO.File]::ReadAllText((Join-Path $WIN 'install.ps1'))
    Ok ($buildKit -eq $REPO -and $instSrc.Contains('$Kit = Split-Path -Parent $PSScriptRoot')) "build.ps1 KIT ($buildKit) = install.ps1's default -Kit (the repo root)"
    # an existing file from install.ps1 (lowercase "kit", stale path) is updated by a rebuild; install keys are kept
    Get-ChildItem $T -Filter '*.bad-*' | Remove-Item
    [IO.File]::WriteAllText($f, '{"kit":"C:/old/checkout","VOSK_DIR":"C:/v","ISO":"E:/mine.iso"}')
    Merge-LifelineEnv -Path $f -Owned ($owned2 + @{ KIT = $REPO }) -Defaults $defaults | Out-Null
    $e = Read-Env $f; $names = @($e.PSObject.Properties | ForEach-Object Name)
    Ok ($e.KIT -ceq $REPO -and $names -ccontains 'KIT' -and -not ($names -ccontains 'kit')) 'rebuild updates a stale lowercase "kit" to KIT = this checkout'
    Ok ($e.VOSK_DIR -eq 'C:/v' -and $e.ISO -eq 'E:/mine.iso' -and $e.PS2RUN -eq 'C:/w2/ps2run.exe') 'KIT update keeps install.ps1 keys and updates the build keys'
    # install.ps1 then writes the same KIT: no change, no duplicate key
    Merge-LifelineEnv -Path $f -Owned @{ ISO = 'E:/mine.iso'; KIT = $REPO } -Defaults @{} | Out-Null
    $names2 = @((Read-Env $f).PSObject.Properties | ForEach-Object Name)
    Ok ((Read-Env $f).KIT -ceq $REPO -and @($names2 | Where-Object { $_ -eq 'KIT' }).Count -eq 1) 'build.ps1 and install.ps1 agree on KIT: one key, same value'
} finally { Remove-Item -Recurse -Force $T }
if ($script:fail) { Write-Host 'env-json tests: FAILURES'; exit 1 } else { Write-Host 'env-json tests passed'; exit 0 }
