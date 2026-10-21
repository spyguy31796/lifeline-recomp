<#
Lifeline Recomp: build-from-your-own-disc kit for Windows (core, M-W1). Contains only our code; the
ps2run.exe it builds is game-derived: build it on your own PC from your own disc, never share it.

  powershell -NoProfile -ExecutionPolicy Bypass -File windows\build.ps1 -Iso "C:\path\to\your.iso"

Needs (user-level, nothing system-wide is changed; PATH is set for this process only):
  - Visual Studio 2022 Build Tools with the C++ workload (MSVC STL + Windows SDK, vcvars64.bat, Ninja)
  - LLVM for Windows (clang-cl, lld-link)                         -Llvm   (default <Root>\tools\llvm)
  - wgpu-native Windows release (wgpu-windows-x86_64-msvc-release) -Wgpu   (default <Root>\deps\wgpu-native)
  - SDL2 VC development package (SDL2-devel-2.x-VC)                -Sdl2   (default <Root>\deps\SDL2-*)
  - Python 3.10+                                                  -Python (default <Root>\tools\python312\python.exe)
  - git
Everything lands under -Work (default <Root>\game). <Root> defaults to %USERPROFILE%\Lifeline.
Not yet ported from build.sh (later milestones): Vosk/model download, voice assets, vu_fast selftest,
cpu_tuned flavor, ps2run backup/restore, the sha256 patch marker of patches.sh.
#>
param(
    [Parameter(Mandatory = $true)][string]$Iso,
    [string]$Root = (Join-Path $env:USERPROFILE 'Lifeline'),
    [string]$Work = '',
    [string]$Llvm = '',
    [string]$Wgpu = '',
    [string]$Sdl2 = '',
    [string]$Python = '',
    [string]$IsoSha256 = ''
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
if (-not $Work) { $Work = Join-Path $Root 'game' }
$Work = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Work)   # full path (a relative -Work is fine)
if (-not $Llvm) { $Llvm = Join-Path $Root 'tools\llvm' }
if (-not $Wgpu) { $Wgpu = Join-Path $Root 'deps\wgpu-native' }
if (-not $Sdl2) {   # newest deps\SDL2-*; a missing deps\ or no SDL2-* folder leaves it empty for the check below
    $deps = Join-Path $Root 'deps'
    $d = @(if (Test-Path -LiteralPath $deps) { Get-ChildItem -Directory -LiteralPath $deps -Filter 'SDL2-*' | Sort-Object Name })
    $Sdl2 = if ($d.Count -gt 0) { $d[-1].FullName } else { '' }
}
if (-not $Python) { $Python = Join-Path $Root 'tools\python312\python.exe' }
$Kit = Split-Path -Parent $PSCommandPath          # windows\
$OurCode = Split-Path -Parent $Kit                # repo root: 00NN patches, voice\, input\, ...
$Upstream = 'https://github.com/snuri00/ps2-web-recomp'
$Commit = '1b4808793a12c45125262fd2d5f50a9ec9f7c020'   # same pin as steam-machine/build.sh
$Name = 'lifeline'

New-Item -ItemType Directory -Force $Work | Out-Null
$Prog = Join-Path $Work 'build-progress.log'
$T0 = [Diagnostics.Stopwatch]::StartNew(); $TL = [Diagnostics.Stopwatch]::StartNew()
function Phase([string]$m) { $line = "== [time $(Get-Date -Format HH:mm:ss)] ${m}: $([int]$TL.Elapsed.TotalSeconds)s"; Write-Host $line; Add-Content $Prog $line; $TL.Restart() }
function Fail([string]$m) { Write-Host "error: $m" -ForegroundColor Red; Add-Content $Prog "error: $m"; exit 1 }
function Run([string]$exe, [string[]]$argv, [string]$log = '') {
    # native command with an exit-code check (PowerShell 5.1 does not stop on native failures, and with
    # 'Stop' it would turn a tool's harmless stderr line into an error, so this scope uses 'Continue')
    $ErrorActionPreference = 'Continue'
    if ($log) { & $exe @argv *> $log } else { & $exe @argv }
    if ($LASTEXITCODE -ne 0) { if ($log) { Get-Content $log -Tail 40 | Write-Host }; Fail "$exe failed ($LASTEXITCODE): $($argv -join ' ')" }
}
Add-Content $Prog "== [time $(Get-Date -Format HH:mm:ss)] start ($env:NUMBER_OF_PROCESSORS logical cpus)"

# --- Inputs -------------------------------------------------------------------
$Iso = (Resolve-Path -LiteralPath $Iso).Path
if ($IsoSha256) {
    $h = (Get-FileHash -LiteralPath $Iso -Algorithm SHA256).Hash.ToLower()
    if ($h -ne $IsoSha256.ToLower()) { Fail "ISO sha256 $h does not match $IsoSha256" }
}
foreach ($p in @("$Llvm\bin\clang-cl.exe", "$Llvm\bin\lld-link.exe", "$Wgpu\lib\wgpu_native.lib", $Python)) { if (-not (Test-Path -LiteralPath $p)) { Fail "missing $p" } }
if (-not $Sdl2 -or -not (Test-Path -LiteralPath "$Sdl2\cmake")) { Fail "SDL2 VC package not found: put SDL2-devel-2.x-VC in $Root\deps\ or pass -Sdl2" }

# --- MSVC environment for this process only (vcvars64 inside cmd /c; VS itself is not changed) ---
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vs) { Fail 'Visual Studio / Build Tools with the C++ x64 tools not found (vswhere)' }
$vcvars = Join-Path $vs 'VC\Auxiliary\Build\vcvars64.bat'
foreach ($l in (cmd /c "`"$vcvars`" >nul 2>&1 && set")) { if ($l -match '^([^=]+)=(.*)$') { Set-Item -Path "Env:$($Matches[1])" -Value $Matches[2] } }
$ninjaDir = Join-Path $vs 'Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja'
$env:PATH = "$Llvm\bin;$ninjaDir;$env:PATH"
foreach ($t in 'git', 'cmake', 'ninja', 'clang-cl', 'lld-link') { if (-not (Get-Command $t -ErrorAction SilentlyContinue)) { Fail "missing $t" } }
Write-Host "== $((& clang-cl --version)[0]); cmake $((& cmake --version)[0]); ninja $(& ninja --version)"
Phase deps

# --- Source at the pinned commit + our patches (same list as steam-machine/build.sh) ---
$Src = Join-Path $Work 'ps2-web-recomp'
if (-not (Test-Path "$Src\.git")) {
    # No checkout until core.autocrlf=false is set in this clone only (Git for Windows defaults to true
    # system-wide, which would convert line endings and make the patches fail to apply).
    Run git @('clone', '-q', '--no-checkout', $Upstream, $Src)
    Run git @('-C', $Src, 'config', 'core.autocrlf', 'false')
    Run git @('-C', $Src, 'checkout', '-q', '--detach', $Commit)
}
$bsh = Get-Content -Raw (Join-Path $OurCode 'steam-machine\build.sh')
$list = [regex]::Match($bsh, '(?s)\nPATCHES=\((.*?)\)').Groups[1].Value
$Patches = @([regex]::Matches(($list -replace '#[^\n]*', ''), '\d{4}-[A-Za-z0-9._-]+\.patch') | ForEach-Object { $_.Value })
if ($Patches.Count -lt 1) { Fail 'no PATCHES list found in steam-machine/build.sh' }
function Try-Native([string]$exe, [string[]]$argv) { $ErrorActionPreference = 'Continue'; & $exe @argv 2>$null | Out-Null; return ($LASTEXITCODE -eq 0) }
# Which patches the tree already has: later patches touch the same lines, so (as in patches.sh) only the
# newest one that reverse-applies is checked; it and every patch before it count as applied.
$done = -1
for ($i = $Patches.Count - 1; $i -ge 0; $i--) {
    if (Try-Native git @('-C', $Src, 'apply', '--reverse', '--check', (Join-Path $OurCode $Patches[$i]))) { $done = $i; break }
}
if ($done -ge 0) { Write-Host "patches already applied: $($Patches[0..$done] -join ' ')" } else { Write-Host 'patches already applied: none' }
for ($i = $done + 1; $i -lt $Patches.Count; $i++) {
    $p = $Patches[$i]
    if (-not (Try-Native git @('-C', $Src, 'apply', '--index', (Join-Path $OurCode $p)))) { Fail "$p does not apply to $Src (reset it with git -C `"$Src`" reset --hard and run again)" }
    Write-Host "applied $p"
}
if ((& git -C $Src rev-parse HEAD) -ne $Commit) { Fail "unexpected commit in $Src" }
Phase clone+patch

# --- Host tools (eerecomp) ----------------------------------------------------
$Cfg = @('-G', 'Ninja', '-DCMAKE_BUILD_TYPE=Release', '-DCMAKE_C_COMPILER=clang-cl', '-DCMAKE_CXX_COMPILER=clang-cl', '-DCMAKE_LINKER=lld-link',
         "-DPS2_WGPU_DIR=$($Wgpu -replace '\\','/')")
$Tools = Join-Path $Src 'build\tools'
Run cmake (@('-S', $Src, '-B', $Tools) + $Cfg) (Join-Path $Work 'cmake-tools.log')
Run ninja @('-C', $Tools, 'eerecomp') (Join-Path $Work 'ninja-tools.log')
Phase 'host tools'

# --- Disc: SYSTEM.CNF -> boot program (read from your ISO; stays on this PC) ---
$Game = Join-Path $Src "games\$Name"; $Disc = Join-Path $Game 'disc'; $Gen = Join-Path $Src "generated\$Name"
New-Item -ItemType Directory -Force $Disc, $Gen | Out-Null
$DiscPy = Join-Path $Src 'scripts\disc.py'
Run $Python @('-I', $DiscPy, 'extract', $Iso, $Disc, 'SYSTEM.CNF') (Join-Path $Work 'disc.log')
$boot = (Select-String -Path (Join-Path $Disc 'SYSTEM.CNF') -Pattern '^BOOT2\s*=\s*(.*)$').Matches[0].Groups[1].Value.Trim()
$program = ($boot -replace '^.*\\', '') -replace ';.*$', ''
if (-not $program) { Fail 'SYSTEM.CNF names no BOOT2 program' }
Run $Python @('-I', $DiscPy, 'extract', $Iso, $Disc, $program) (Join-Path $Work 'disc.log')
$Elf = Join-Path $Disc $program
$mods = @()
if (Try-Native $Python @('-I', '-c', "import sys; sys.exit(0 if b'SNR2' in open(sys.argv[1],'rb').read() else 1)", $Elf)) {
    Run $Python @('-I', $DiscPy, 'modules', $Iso, (Join-Path $Game 'modules')) (Join-Path $Work 'disc.log')
    $mods = @('--modules', (Join-Path $Game 'modules'))
}
Phase disc

# --- Translate with every EE hook address (voice + widescreen + FMV overrides) ---
$Entries = Join-Path $Game 'entries.txt'; if (-not (Test-Path $Entries)) { New-Item -ItemType File $Entries | Out-Null }
$Ov = Join-Path $Work 'overrides.txt'
Get-Content (Join-Path $OurCode 'voice\overrides.txt'), (Join-Path $OurCode 'widescreen\overrides.txt'), (Join-Path $OurCode 'fmv\overrides.txt') | Set-Content -Encoding ASCII $Ov
Run (Join-Path $Tools 'eerecomp.exe') (@($Elf, '--entries', $Entries) + $mods + @('--overrides', $Ov, '--out', $Gen)) (Join-Path $Work 'eerecomp.log')
Get-Content (Join-Path $Work 'eerecomp.log') -Tail 1 | Write-Host
Phase translate

# --- ps2run.exe -----------------------------------------------------------------
$Extra = @('voice', 'input', 'icons', 'widescreen', 'fmv') | ForEach-Object { Get-ChildItem (Join-Path $OurCode $_) -Filter *.cpp } | ForEach-Object { $_.FullName -replace '\\', '/' }
$Nat = Join-Path $Src "build\native-$Name"
Run cmake (@('-S', $Src, '-B', $Nat) + $Cfg + @("-DPS2_GENERATED=$($Gen -replace '\\','/')", "-DPS2_EXTRA_SOURCES=$($Extra -join ';')",
          "-DSDL2_DIR=$(("$Sdl2\cmake") -replace '\\','/')")) (Join-Path $Work 'cmake-native.log')
Run ninja @('-C', $Nat, 'ps2run') (Join-Path $Nat 'ninja.log')
$Exe = Join-Path $Nat 'ps2run.exe'
if (-not (Test-Path $Exe)) { Fail 'ps2run.exe was not built' }
Phase 'ps2run'

# --- Launch settings for run.ps1 (later milestone) / by hand ----------------------
New-Item -ItemType Directory -Force (Join-Path $Work 'saves'), (Join-Path $Work 'logs') | Out-Null
# Merge, don't rewrite: build.ps1 owns the build outputs; the rest are defaults that a value already in the file
# (e.g. ISO / VOSK_DIR from install.ps1) wins over; unknown keys are kept.
# Note ISO is a default only: once the file has an ISO (from install.ps1 or an earlier build), -Iso does
# not override it; this build reads -Iso, but launches keep the ISO in the file (edit the file to change it).
. (Join-Path $Kit 'env-json.ps1')
Merge-LifelineEnv -Path (Join-Path $Work 'lifeline.env.json') -Owned @{ SRC = $Src; PS2RUN = $Exe; ELF = $Elf } -Defaults @{
    ISO = $Iso; MEMCARD = (Join-Path $Work 'saves\lifeline.ps2')
    PS2_VOICE_VOSK_MODEL = (Join-Path $Work 'vosk\vosk-model-small-en-us-0.15'); PS2_VOICE_VOSK_LIB = (Join-Path $Work 'vosk\vosk\libvosk.dll')
    PS2_VOICE_ASSETS = (Join-Path $Work 'voice-assets') } | Out-Null
$total = "== [time] total: $([int]$T0.Elapsed.TotalSeconds)s"; Write-Host $total; Add-Content $Prog $total
Write-Host "== built. Launch: & `"$Exe`" `"$Elf`" --disc `"$Iso`" --memcard `"$(Join-Path $Work 'saves\lifeline.ps2')`" --window   (game-derived build; keep it on this PC)"
