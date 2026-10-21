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

    # 4. UTF-8 BOM (Windows PowerShell 5.1 Set-Content -Encoding UTF8 writes one) is read, and output has no BOM
    $bom = [Text.Encoding]::UTF8.GetPreamble() + [Text.Encoding]::UTF8.GetBytes('{"VOSK_DIR":"C:/v"}')
    [IO.File]::WriteAllBytes($f, $bom)
    Get-ChildItem $T -Filter '*.bad-*' | Remove-Item
    Merge-LifelineEnv -Path $f -Owned $owned1 -Defaults $defaults | Out-Null
    $bytes = [IO.File]::ReadAllBytes($f)
    Ok ((Read-Env $f).VOSK_DIR -eq 'C:/v' -and @(Get-ChildItem $T -Filter '*.bad-*').Count -eq 0) 'file with a UTF-8 BOM is merged, not backed up'
    Ok (-not ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB)) 'output is written without a BOM'
} finally { Remove-Item -Recurse -Force $T }
if ($script:fail) { Write-Host 'env-json tests: FAILURES'; exit 1 } else { Write-Host 'env-json tests passed'; exit 0 }
