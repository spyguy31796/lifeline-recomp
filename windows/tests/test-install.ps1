<#
Pester-free checks for windows/install.ps1. Needs YOUR ISO (the real, sha-checked one; it is only hashed and read)
and Python 3. Uses stub disc.py / arcx.py / fat.py / build_aliases.py (no game data), so no voice assets are really
extracted; the real Vosk wheel and model are used (downloaded, or pass -WheelPath / -ModelZipPath).
Everything is written to a fresh temp folder that is removed at the end. It stops no process except its own
ps2run stand-in (section 4), and only by that stand-in's PID if it has not exited by itself. A real game must be
closed: install.ps1 refuses while any ps2run runs (on a shared Linux box, run this in its own PID namespace,
e.g. unshare -Urpf --mount-proc pwsh ...).
  powershell -NoProfile -ExecutionPolicy Bypass -File windows\tests\test-install.ps1 -Iso "C:\path\to\your.iso"
  pwsh -NoProfile -File windows/tests/test-install.ps1 -Iso /path/to/your.iso -PyExe python3 -PyArgs ' ' -VenvPython /usr/bin/python3
-VenvPython: a Python 3.10+ to test the real launcher-venv step with (creates a venv in the temp folder and pip-installs
the pinned pygame-ce; needs network). Without it only the launcher files and the missing-Python path are checked.
#>
param([Parameter(Mandatory = $true)][string]$Iso, [string]$PyExe = 'py', [string]$PyArgs = '-3', [string]$WheelPath, [string]$ModelZipPath,
      [string]$VenvPython, [switch]$Keep)
$ErrorActionPreference = 'Stop'
$REPO = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$INSTALL = Join-Path (Join-Path $REPO 'windows') 'install.ps1'
$T = Join-Path ([IO.Path]::GetTempPath()) ('lifeline-install-test-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$script:fails = 0; $script:n = 0
function Check([bool]$c, [string]$what) { $script:n++; if ($c) { Write-Host "ok: $what" } else { $script:fails++; Write-Host "FAIL: $what" } }
# number of entries in a folder, -1 if it does not exist (a missing folder must be a FAIL line, not a throw)
function Count-In([string]$p, [switch]$Dirs) {
    if (-not (Test-Path -LiteralPath $p -PathType Container)) { return -1 }
    if ($Dirs) { return @(Get-ChildItem -LiteralPath $p -Directory -Force).Count } else { return @(Get-ChildItem -LiteralPath $p -Force).Count }
}
function J { $p = $args[0]; foreach ($s in $args[1..($args.Count - 1)]) { $p = Join-Path $p $s }; return $p }
function W([string]$p, [string]$text) { New-Item -ItemType Directory -Force -Path (Split-Path -Parent $p) | Out-Null; [IO.File]::WriteAllText($p, $text) }
function Sha([string]$p) { return (Get-FileHash -Algorithm SHA256 -LiteralPath $p).Hash.ToLowerInvariant() }
function Install([hashtable]$extra) {
    $p = @{ Kit = $KIT; Src = $SRC; Iso = $Iso; PyExe = $PyExe; PyArgs = $PyArgs }
    if ($WheelPath) { $p.WheelPath = $WheelPath }; if ($ModelZipPath) { $p.ModelZipPath = $ModelZipPath }
    $p.SkipLauncher = $true   # the launcher step is tested on its own (section 9)
    foreach ($k in $extra.Keys) { $p[$k] = $extra[$k] }
    if ($p.ContainsKey('Launcher')) { $p.Remove('Launcher'); $p.Remove('SkipLauncher') }
    $global:LASTEXITCODE = 0
    try { & $INSTALL @p *>&1 | ForEach-Object { "    | $_" } | Out-Host } catch { Write-Host "    threw: $($_.Exception.Message)"; return 99 }
    return $LASTEXITCODE
}
$sleeper = $null
try {
    # --- stub kit + upstream (our own dummy files; the three dev-box paths are what the wrapper must swap) ---
    $KIT = J $T 'kit'; $SRC = J $T 'src'
    New-Item -ItemType Directory -Force -Path (J $KIT 'windows') | Out-Null
    Copy-Item -LiteralPath (J $REPO 'windows' 'run.ps1') -Destination (J $KIT 'windows' 'run.ps1')
    Copy-Item -LiteralPath (J $REPO 'icons' 'packs') -Destination (J $KIT 'icons' 'packs') -Recurse -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path (J $KIT 'icons' 'packs'))) { New-Item -ItemType Directory -Force (J $KIT 'icons') | Out-Null; Copy-Item -LiteralPath (J $REPO 'icons' 'packs') -Destination (J $KIT 'icons') -Recurse }
    W (J $SRC 'scripts' 'disc.py') @'
import os, sys
cmd, image, dest = sys.argv[1:4]
assert cmd == 'extract' and os.path.isfile(image), (cmd, image)
os.makedirs(dest, exist_ok=True)
open(os.path.join(dest, sys.argv[4]), 'wb').write(b'stub')
'@
    W (J $KIT 'voice' 'tools' 'fat.py') @'
d=open('<repo-root>/private/iso/OS.FAT','rb').read()
ents=[1,2,3]
for e in ents: print(e)
'@
    W (J $KIT 'voice' 'tools' 'arcx.py') @'
import os,sys
sys.path.insert(0,os.path.dirname(__file__))
exec(open(os.path.join(os.path.dirname(__file__),'fat.py')).read().split('for e in ents')[0])
assert d == b'stub'
iso=open('<repo-root>/dump/Life Line (USA).iso','rb')
out='<repo-root>/private/asr_files'; os.makedirs(out,exist_ok=True)
for e in ents: os.makedirs(os.path.join(out,'stub%d' % e), exist_ok=True)
open(os.path.join(out,'stub1','paths.txt'),'w').write(iso.name + '\n' + out + '\n')
'@
    W (J $KIT 'voice' 'tools' 'build_aliases.py') @'
import argparse, os, sys
ap = argparse.ArgumentParser(); ap.add_argument('--assets'); ap.add_argument('--model'); a = ap.parse_args()
open(os.path.join(a.assets, 'aliases.tsv'), 'w').write('stub\n')
if os.environ.get('LIFELINE_TEST_ALIASES_DELETE'):
    os.remove(os.path.join(a.assets, 'aliases.local.tsv'))
if os.environ.get('LIFELINE_TEST_ALIASES_FAIL'):
    open(os.path.join(a.assets, 'aliases.local.tsv'), 'wb').write(b'CLOBBERED')
    sys.exit(4)
'@
    Copy-Item -LiteralPath (J $REPO 'voice' 'tools' 'extract_assets.py') -Destination (J $KIT 'voice' 'tools' 'extract_assets.py')   # the real one
    New-Item -ItemType Directory -Force -Path (J $KIT 'steam-machine' 'launcher') | Out-Null   # the real launcher (our code only)
    foreach ($f in 'lifeline_launcher.py', 'bindings.py') { Copy-Item -LiteralPath (J $REPO 'steam-machine' 'launcher' $f) -Destination (J $KIT 'steam-machine' 'launcher' $f) }
    $ROOT = J $T 'game'
    Check ((Count-In (J $T 'no-such-folder')) -eq -1) 'a missing folder counts as -1 (a FAIL line, not a throw)'

    # 1. wrong ISO: refused before anything is written
    $bad = J $T 'bad.iso'; W $bad 'not a disc'
    Check ((Install @{ Root = $ROOT; Iso = $bad }) -eq 3) 'wrong ISO -> exit 3'
    Check (-not (Test-Path $ROOT)) 'wrong ISO -> nothing written'
    # 2. non-ASCII root
    Check ((Install @{ Root = (J $T ('g' + [char]0x00E9 + 'me')) }) -eq 1) 'non-ASCII root -> exit 1'
    Check ((Install @{ Root = (J $T 'Lifeline' 'tools' 'x') }) -eq 1) 'root inside Lifeline\tools -> exit 1'
    Check ((Install @{ Root = (J $T 'Lifeline' 'game' 'launcher-venv') }) -eq 1) 'root inside launcher-venv -> exit 1'
    # Python default: Lifeline\tools\python312\python.exe if present (only run), else py -3 with a warning
    $savedProfile = $env:USERPROFILE
    try {
        $env:USERPROFILE = J $T 'profile'
        $o = & $INSTALL -Root (J $T 'pyroot') -Iso $Iso -Kit $KIT -Src $SRC -DryRun -SkipVosk -SkipLauncher *>&1 | Out-String
        Check ($o -match 'warning: .*python312.python\.exe not found; using py -3' -and $o -match 'python=py -3') 'no tools python -> py -3 with a warning'
        $tp = J $T 'profile' 'Lifeline' 'tools' 'python312' 'python.exe'; W $tp ''
        $o = & $INSTALL -Root (J $T 'pyroot') -Iso $Iso -Kit $KIT -Src $SRC -DryRun -SkipVosk -SkipLauncher *>&1 | Out-String
        Check ($o -match [regex]::Escape("python=$tp") -and $o -notmatch 'warning: .*not found') 'tools python312 is the default when present'
        Check (-not (Test-Path (J $T 'pyroot'))) 'python default checks wrote nothing'
    } finally { $env:USERPROFILE = $savedProfile }
    # 3. dry run: real ISO check, but no writes at all
    Check ((Install @{ Root = $ROOT; DryRun = $true }) -eq 0) 'dry run -> exit 0'
    Check (-not (Test-Path $ROOT)) 'dry run -> nothing written'
    # 4. game running -> refused (a harmless sleeper renamed ps2run; it exits on its own, or is stopped by its own PID in the finally below)
    $sleeper = $null
    if ($IsLinux -or $IsMacOS) { $exe = J $T 'ps2run'; Copy-Item '/bin/sleep' $exe; $sleeper = Start-Process -FilePath $exe -ArgumentList '6' -PassThru }
    else { $exe = J $T 'ps2run.exe'; Copy-Item (Join-Path $PSHOME 'powershell.exe') $exe -ErrorAction SilentlyContinue
           if (Test-Path $exe) { $sleeper = Start-Process -FilePath $exe -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 6' -PassThru -WindowStyle Hidden } }
    if ($sleeper) {
        Start-Sleep -Milliseconds 500
        Check ((Install @{ Root = $ROOT; SkipVosk = $true }) -eq 2) 'ps2run running -> exit 2'
        Check (-not (Test-Path $ROOT)) 'ps2run running -> nothing written'
        $sleeper.WaitForExit(); Check ($sleeper.ExitCode -eq 0) 'the running ps2run was not touched (it exited by itself, code 0)'
    } else { Write-Host 'skip: could not start a stand-in ps2run' }
    # 5. fresh install
    Check ((Install @{ Root = $ROOT }) -eq 0) 'fresh install -> exit 0'
    $pins = @{ 'libvosk.dll' = '9331c2f6a32cf77141af27c9750e79532718f51bbc2e3cea3c60f14ca4251e4e'; 'libstdc++-6.dll' = 'a1d96a848a567d7657e152cfe92e2fd62da412968cc11ec8bdb04bf20ebc5747'
               'libgcc_s_seh-1.dll' = '201bf8a54ebb490f93ea4beb20740a483bf67036b90b5720f32d0c746a72d1e9'; 'libwinpthread-1.dll' = '92caeb8a4ea281c674003462a233f3b445b685b0a6f93eb11254feda2dda9cde' }
    foreach ($k in $pins.Keys) { $f = J $ROOT 'vosk' 'vosk' $k; Check ((Test-Path $f) -and (Sha $f) -eq $pins[$k]) "vosk\vosk\$k present with pinned sha256" }
    Check ((Count-In (J $ROOT 'vosk' 'vosk')) -eq 4) 'vosk\vosk holds exactly the four DLLs'
    Check (Test-Path (J $ROOT 'vosk' 'vosk-model-small-en-us-0.15' 'conf' 'model.conf')) 'small model unpacked'
    Check (-not (Test-Path (J $ROOT 'vosk' '.unpack-vosk-model-small-en-us-0.15'))) 'model staging removed'
    Check ((Count-In (J $ROOT 'voice-assets') -Dirs) -eq 3) 'voice assets extracted via extract_assets.py (3 stub folders)'
    $pf = J $ROOT 'voice-assets' 'stub1' 'paths.txt'; $paths = @('', ''); if (Test-Path -LiteralPath $pf) { $paths = [IO.File]::ReadAllLines($pf) }
    Check ($paths[0] -ceq [IO.Path]::GetFullPath($Iso) -and $paths[1] -ceq (J $ROOT 'voice-assets.partial')) "extract_assets.py got the ISO path directly, unchanged: $($paths[0])"
    Check (-not (Test-Path (J $ROOT 'voice-assets.partial'))) 'assets staging renamed away'
    Check (Test-Path (J $ROOT 'voice-assets' 'aliases.tsv')) 'aliases.tsv built'
    $ej = [IO.File]::ReadAllText((J $ROOT 'lifeline.env.json')) | ConvertFrom-Json
    foreach ($k in 'ISO', 'VOSK_DIR', 'PS2_VOICE_VOSK_MODEL', 'PS2_VOICE_VOSK_LIB', 'PS2_VOICE_ASSETS', 'MEMCARD') { Check ([bool]$ej.$k) "lifeline.env.json has $k" }
    Check ($ej.PS2_VOICE_VOSK_LIB -ceq (J $ROOT 'vosk' 'vosk' 'libvosk.dll')) 'PS2_VOICE_VOSK_LIB points at vosk\vosk\libvosk.dll'
    Check ($ej.KIT -ceq $KIT) 'lifeline.env.json KIT = the repo checkout (the launcher finds windows\build.ps1 there)'
    Check ((Sha (J $ROOT 'run.ps1')) -eq (Sha (J $REPO 'windows' 'run.ps1'))) 'run.ps1 installed'
    # the installed run.ps1 reads the merged lifeline.env.json (dry run: nothing started)
    $ej2 = [IO.File]::ReadAllText((J $ROOT 'lifeline.env.json')) | ConvertFrom-Json
    $ej2 | Add-Member -NotePropertyName ELF -NotePropertyValue (J $ROOT 'boot.elf') -Force
    [IO.File]::WriteAllText((J $ROOT 'lifeline.env.json'), ($ej2 | ConvertTo-Json))
    $psexe = (Get-Process -Id $PID).Path
    $dry = & $psexe -NoProfile -ExecutionPolicy Bypass -File (J $ROOT 'run.ps1') --dry-run 2>&1 | Out-String
    Check ($dry -match [regex]::Escape('PS2_VOICE_VOSK_LIB=' + (J $ROOT 'vosk' 'vosk' 'libvosk.dll'))) 'run.ps1 --dry-run uses the installed voice paths'
    Check ($dry -match [regex]::Escape('# exe: ' + (J $ROOT 'ps2run.exe'))) 'run.ps1 without PS2RUN falls back to ps2run.exe next to it'
    # 6. re-install: user aliases.local.tsv kept byte for byte even when the aliases step clobbers it and fails
    $local = J $ROOT 'voice-assets' 'aliases.local.tsv'
    $bytes = [byte[]](0xEF, 0xBB, 0xBF) + [Text.Encoding]::ASCII.GetBytes("# my fixes`r`nword`tother words`r`n")
    [IO.File]::WriteAllBytes($local, $bytes)
    $ej | Add-Member -NotePropertyName PS2RUN -NotePropertyValue 'C:\Users\<user>\Lifeline\game\ps2-web-recomp\build\native-lifeline\ps2run.exe' -Force   # as build.ps1 writes it
    [IO.File]::WriteAllText((J $ROOT 'lifeline.env.json'), ($ej | ConvertTo-Json))
    $dllTimes = @{}; foreach ($k in $pins.Keys) { $dllTimes[$k] = (Get-Item (J $ROOT 'vosk' 'vosk' $k)).LastWriteTimeUtc }
    $env:LIFELINE_TEST_ALIASES_FAIL = '1'
    try { $rc = Install @{ Root = $ROOT } } finally { Remove-Item Env:LIFELINE_TEST_ALIASES_FAIL -ErrorAction SilentlyContinue }
    Check ($rc -eq 0) 'aliases step failing is not fatal -> exit 0'
    $after = [IO.File]::ReadAllBytes($local)
    Check (($after.Length -eq $bytes.Length) -and (-not (Compare-Object $after $bytes -SyncWindow 0))) 'aliases.local.tsv restored byte for byte'
    Check (-not (Test-Path "$local.tmp")) 'no restore temp file left'
    # 6b. aliases.local.tsv deleted by a step: restored through File.Move (the target is gone), still byte for byte
    $env:LIFELINE_TEST_ALIASES_DELETE = '1'
    try { $rc = Install @{ Root = $ROOT; SkipVosk = $true } } finally { Remove-Item Env:LIFELINE_TEST_ALIASES_DELETE -ErrorAction SilentlyContinue }
    $after = if (Test-Path $local) { [IO.File]::ReadAllBytes($local) } else { [byte[]]@() }
    Check ($rc -eq 0 -and ($after.Length -eq $bytes.Length) -and (-not (Compare-Object $after $bytes -SyncWindow 0))) 'deleted aliases.local.tsv restored byte for byte (Move path)'
    Check (-not (Test-Path "$local.tmp")) 'no restore temp file left (Move path)'
    $same = $true; foreach ($k in $pins.Keys) { if ((Get-Item (J $ROOT 'vosk' 'vosk' $k)).LastWriteTimeUtc -ne $dllTimes[$k]) { $same = $false } }
    Check $same 'DLLs present -> not rewritten'
    Check ((Count-In (J $ROOT 'voice-assets') -Dirs) -eq 3) 'voice assets present -> kept'
    Check ((([IO.File]::ReadAllText((J $ROOT 'lifeline.env.json')) | ConvertFrom-Json).PS2RUN) -ceq 'C:\Users\<user>\Lifeline\game\ps2-web-recomp\build\native-lifeline\ps2run.exe') 'lifeline.env.json keeps build.ps1 keys (PS2RUN)'
    # 7. one DLL missing -> all four written together
    Remove-Item (J $ROOT 'vosk' 'vosk' 'libgcc_s_seh-1.dll')
    $old = [DateTime]::new(2001, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)   # extraction keeps the zip's own times, so mark the survivors
    foreach ($k in $pins.Keys) { $f = J $ROOT 'vosk' 'vosk' $k; if (Test-Path $f) { (Get-Item $f).LastWriteTimeUtc = $old }; $dllTimes[$k] = $old }
    Check ((Install @{ Root = $ROOT }) -eq 0) 'one DLL missing -> exit 0'
    $all = $true; foreach ($k in $pins.Keys) { $f = J $ROOT 'vosk' 'vosk' $k; if (-not (Test-Path $f) -or (Sha $f) -ne $pins[$k] -or (Get-Item $f).LastWriteTimeUtc -eq $dllTimes[$k]) { $all = $false } }
    Check $all 'all four DLLs rewritten and verified'
    # 8. a renamed ISO: its resolved path is stored as ISO and run.ps1 passes that to --disc
    $ren = J $T 'my renamed disc.iso'
    try { New-Item -ItemType SymbolicLink -Path $ren -Target $Iso -ErrorAction Stop | Out-Null } catch { $ren = $null }
    if ($ren) {
        Check ((Install @{ Root = $ROOT; Iso = $ren; SkipVosk = $true }) -eq 0) 'renamed ISO (symlink, same bytes) -> exit 0'
        Check ((([IO.File]::ReadAllText((J $ROOT 'lifeline.env.json')) | ConvertFrom-Json).ISO) -ceq $ren) 'lifeline.env.json ISO = the renamed path'
        $ej3 = [IO.File]::ReadAllText((J $ROOT 'lifeline.env.json')) | ConvertFrom-Json
        $ej3 | Add-Member -NotePropertyName ELF -NotePropertyValue (J $ROOT 'boot.elf') -Force   # build.ps1's key
        [IO.File]::WriteAllText((J $ROOT 'lifeline.env.json'), ($ej3 | ConvertTo-Json))
        $dry = & $psexe -NoProfile -ExecutionPolicy Bypass -File (J $ROOT 'run.ps1') --dry-run 2>&1 | Out-String
        Check ($dry -match [regex]::Escape('--disc "' + $ren + '"')) 'run.ps1 passes the stored (renamed) ISO path to --disc'
    } else { Write-Host 'skip: cannot make a symlink here (Windows without Developer Mode); renamed-ISO check not run' }
    # 9. launcher: files into <Root>\launcher, launcher-venv only if missing (never under tools\), launcher.ps1 wiring
    $LDIR = J $ROOT 'launcher'; $VENV = J $ROOT 'launcher-venv'
    $noPy = J $T 'profile' 'no-python312' 'python.exe'
    $o = & $INSTALL -Root $ROOT -Iso $Iso -Kit $KIT -Src $SRC -PyExe $PyExe -PyArgs $PyArgs -SkipVosk -DryRun -VenvPython $noPy *>&1 | Out-String
    Check ($o -match 'would copy lifeline_launcher.py, bindings.py, launcher.ps1, launcher.cmd' -and -not (Test-Path $LDIR)) 'launcher dry run: plans the copy, writes nothing'
    Check ($o -match 'launcher-venv: missing' -and $o -match [regex]::Escape("$noPy not found") -and -not (Test-Path $VENV)) 'launcher dry run: missing venv python reported, no venv'
    $o = & $INSTALL -Root $ROOT -Iso $Iso -Kit $KIT -Src $SRC -PyExe $PyExe -PyArgs $PyArgs -SkipVosk -VenvPython $noPy *>&1 | Out-String
    Check ($LASTEXITCODE -eq 0 -and $o -match 'launcher step failed; game still playable') 'no venv python -> warning, still exit 0'
    $lf = @{ 'lifeline_launcher.py' = (J $REPO 'steam-machine' 'launcher' 'lifeline_launcher.py'); 'bindings.py' = (J $REPO 'steam-machine' 'launcher' 'bindings.py')
             'launcher.ps1' = (J $REPO 'windows' 'launcher.ps1'); 'launcher.cmd' = (J $REPO 'windows' 'launcher.cmd') }
    $okf = $true; foreach ($k in $lf.Keys) { $d = J $LDIR $k; if (-not (Test-Path $d) -or (Sha $d) -ne (Sha $lf[$k])) { $okf = $false } }
    Check ($okf -and (Count-In $LDIR) -eq 4) 'launcher files installed byte for byte (4 files, no temp left)'
    Check (-not (Test-Path $VENV)) 'no venv python -> no launcher-venv'
    $env:LIFELINE_WORK = $ROOT
    try {
        $o = & $psexe -NoProfile -ExecutionPolicy Bypass -File (J $LDIR 'launcher.ps1') --dry-run 2>&1 | Out-String
        Check ($LASTEXITCODE -eq 1 -and $o -match 'launcher-venv.*is missing. Run windows\\install.ps1') 'launcher.ps1 without launcher-venv -> exit 1 with the install hint'
        if ($VenvPython) {
            $o = & $INSTALL -Root $ROOT -Iso $Iso -Kit $KIT -Src $SRC -PyExe $PyExe -PyArgs $PyArgs -SkipVosk -VenvPython $VenvPython *>&1 | Out-String
            $vpy = J $VENV 'Scripts' 'python.exe'; if (-not (Test-Path $vpy)) { $vpy = J $VENV 'bin' 'python' }
            Check ($LASTEXITCODE -eq 0 -and $o -match 'launcher-venv: missing; creating it' -and $o -match 'launcher-venv ready') 'launcher-venv created from -VenvPython'
            $ver = & $vpy -c 'import os; os.environ["PYGAME_HIDE_SUPPORT_PROMPT"] = "1"; import pygame; print(pygame.version.ver)' 2>$null
            Check ($ver -eq '2.5.8') "launcher-venv has the pinned pygame-ce ($ver)"
            $t0 = (Get-Item $vpy).LastWriteTimeUtc
            $o = & $INSTALL -Root $ROOT -Iso $Iso -Kit $KIT -Src $SRC -PyExe $PyExe -PyArgs $PyArgs -SkipVosk -VenvPython $noPy *>&1 | Out-String
            Check ($LASTEXITCODE -eq 0 -and $o -match 'launcher-venv: present \(kept\)' -and $o -notmatch 'launcher step failed' -and (Get-Item $vpy).LastWriteTimeUtc -eq $t0) 'launcher-venv present -> kept, not recreated'
            # the installed launcher.ps1 runs the installed lifeline_launcher.py with the venv python and LIFELINE_WORK
            $o = & $psexe -NoProfile -ExecutionPolicy Bypass -File (J $LDIR 'launcher.ps1') --dry-run 2>&1 | Out-String
            $want = if ($IsLinux -or $IsMacOS) { [regex]::Escape((J $ROOT 'run.sh') + ' --debug --fullscreen') } else { '-File "?' + [regex]::Escape((J $ROOT 'run.ps1')) + '"? --debug --fullscreen' }
            Check ($LASTEXITCODE -eq 0 -and $o -match $want) "launcher.ps1 --dry-run -> $($o.Trim())"
            $o = & $psexe -NoProfile -ExecutionPolicy Bypass -File (J $REPO 'windows' 'launcher.ps1') --dry-run 2>&1 | Out-String
            Check ($LASTEXITCODE -eq 0 -and $o -match $want) 'repo windows\launcher.ps1 finds steam-machine\launcher\lifeline_launcher.py'
        } else { Write-Host 'skip: no -VenvPython; real launcher-venv creation not tested' }
    } finally { Remove-Item Env:LIFELINE_WORK -ErrorAction SilentlyContinue }
} catch {
    # anything unexpected is a FAIL with its line, and the summary below still runs
    Check $false "test threw at line $($_.InvocationInfo.ScriptLineNumber): $($_.Exception.Message)"
} finally {
    # our own ps2run stand-in: normally it has exited by itself; if not, stop exactly it (by its PID), nothing else
    if ($sleeper -and -not $sleeper.HasExited) { Stop-Process -Id $sleeper.Id -ErrorAction SilentlyContinue; $sleeper.WaitForExit() }
    if ($Keep) { Write-Host "kept $T" } else { Remove-Item -LiteralPath $T -Recurse -Force -ErrorAction SilentlyContinue }
}
if ($script:fails) { Write-Host "install.ps1: $($script:fails) of $($script:n) checks FAILED"; exit 1 }
Write-Host "install.ps1: all $($script:n) checks passed"; exit 0
