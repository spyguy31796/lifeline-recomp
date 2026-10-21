# Launch Lifeline (native recomp) on Windows. PowerShell twin of steam-machine/run.sh.
#   powershell -NoProfile -ExecutionPolicy Bypass -File run.ps1 [--debug] [--skip-tutorial] [--ps2run <exe>] [--dry-run] [ps2run args...]
#   --debug           voice log -> logs\voice.log (PS2_VOICE_DEBUG=1), PS2_PERF_LOG=1, stderr -> logs\run-*.log
#   --skip-tutorial   start in the first room (saves\room001.state)
#   --ps2run <exe>    ps2run.exe to start (default: PS2RUN from lifeline.env.json, as written by build.ps1;
#                     then ps2run.exe next to this script)
#   --dry-run         print the environment and the command line, start nothing
# Extra args pass through to ps2run (e.g. --fullscreen, --load-state f).
# QoL toggles come from config.ini next to this script (written by the launcher); same rules as run.sh.
# Precedence: variables already in the environment > config.ini > lifeline.env defaults.
# LIFELINE_PRINT_ENV=1 prints the environment that would be passed and exits (same lines as run.sh).
# Windows differences from run.sh:
#   - "Forced off" is passed as 0, never empty (an empty Windows env var is dropped). Both readers treat 0 as off.
#   - SDL_AUDIODRIVER is not set: SDL picks WASAPI, then DirectSound. An exported SDL_AUDIODRIVER (e.g. wasapi,directsound) still wins.
#   - launch paths come from lifeline.env.json (build.ps1) or a KEY=value lifeline.env; parsed, never executed.
#   - config.ini may have CRLF line ends or a UTF-8 BOM (Notepad); both are accepted.
#   - no distrobox. This script never stops or kills any process.
# Windows PowerShell 5.1 compatible. ASCII only.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$HERE = $PSScriptRoot

function Fail([string]$msg) { [Console]::Error.WriteLine($msg); exit 1 }
function EnvVal([string]$n) { return [Environment]::GetEnvironmentVariable($n) }   # $null if unset

# --- leading options (run.sh: --debug / --skip-tutorial, then everything else passes through) ---
$DEBUG = $false; $SKIP = $false; $DRY = $false; $PS2RUN_ARG = $null
$rest = @($args)
while ($rest.Count -gt 0) {
    $a = [string]$rest[0]
    if ($a -ceq '--debug') { $DEBUG = $true }
    elseif ($a -ceq '--skip-tutorial') { $SKIP = $true }
    elseif ($a -ceq '--dry-run') { $DRY = $true }
    elseif ($a -ceq '--ps2run') { if ($rest.Count -lt 2) { Fail '--ps2run needs a path' }; $PS2RUN_ARG = [string]$rest[1]; $rest = @($rest | Select-Object -Skip 1) }
    else { break }
    $rest = @($rest | Select-Object -Skip 1)
}

# --- shell-variable model: $SH holds what run.sh would hold in shell vars; unset names fall back to the env ---
$SH = @{}   # NB: PowerShell names are case-insensitive, so never use $v / $V for anything else
function Get-V([string]$n) { if ($SH.ContainsKey($n)) { return $SH[$n] }; return (EnvVal $n) }
function Test-V([string]$n) { return ($null -ne (Get-V $n)) }                     # bash ${n+x}
function Set-Default([string]$n, [string]$val) {                                    # bash : "${n:=val}"
    $cur = Get-V $n
    if ($null -eq $cur -or $cur -eq '') { $SH[$n] = $val }
}

# lifeline.env must not clobber exported voice paths: remember them, read, restore (run.sh:13-16).
$_m = EnvVal 'PS2_VOICE_VOSK_MODEL'; $_l = EnvVal 'PS2_VOICE_VOSK_LIB'; $_a = EnvVal 'PS2_VOICE_ASSETS'
# Launch settings: lifeline.env.json (written by build.ps1, voice keys merged by install.ps1), or a KEY=value
# lifeline.env (same keys as Linux; parsed, never executed). The JSON wins when both exist.
$JSONFILE = Join-Path $HERE 'lifeline.env.json'; $ENVFILE = Join-Path $HERE 'lifeline.env'
if (Test-Path -LiteralPath $JSONFILE -PathType Leaf) {
    $j = [IO.File]::ReadAllText($JSONFILE) | ConvertFrom-Json
    foreach ($pr in $j.PSObject.Properties) { if ($null -ne $pr.Value) { $SH[$pr.Name] = [string]$pr.Value } }
} elseif (Test-Path -LiteralPath $ENVFILE -PathType Leaf) {
    foreach ($line in [IO.File]::ReadAllLines($ENVFILE)) {
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        if ($t -notmatch '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$') { continue }
        $k = $Matches[1]; $val = $Matches[2]
        if ($val.Length -ge 2 -and (($val.StartsWith('"') -and $val.EndsWith('"')) -or ($val.StartsWith("'") -and $val.EndsWith("'")))) { $val = $val.Substring(1, $val.Length - 2) }
        $SH[$k] = $val
    }
} else { Fail "neither lifeline.env.json nor lifeline.env in $HERE; run build.ps1 / install.ps1 first" }
if (-not $SH.ContainsKey('VOSK_DIR')) { $SH['VOSK_DIR'] = Join-Path $HERE 'vosk' }   # build.ps1 does not write it
if ($_m) { $SH['PS2_VOICE_VOSK_MODEL'] = $_m }; if ($_l) { $SH['PS2_VOICE_VOSK_LIB'] = $_l }; if ($_a) { $SH['PS2_VOICE_ASSETS'] = $_a }

# --- config.ini (env wins: every value is applied like := ) ---
$CFG = EnvVal 'LIFELINE_CONFIG'; if (-not $CFG) { $CFG = Join-Path $HERE 'config.ini' }
$CFG = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($CFG)   # full path for [IO.File]
$CFG_LINES = @(); if (Test-Path -LiteralPath $CFG -PathType Leaf) { $CFG_LINES = [IO.File]::ReadAllLines($CFG) }
# Same rules as run.sh's awk: section line must be exactly [name]; key = text before the first '=' with blanks
# removed; value = text between the first and second '=', cut at ' #' / ' ;', trimmed; first match wins.
function Cfg([string]$section, [string]$key) {
    $in = $false
    foreach ($line in $CFG_LINES) {
        if ($line.StartsWith('[')) { $in = ($line -ceq "[$section]") }
        if (-not $in) { continue }
        $f = $line.Split('=')
        if (($f[0] -replace '[ \t]', '') -cne $key) { continue }
        $fv = ''; if ($f.Count -ge 2) { $fv = $f[1] }
        $fv = $fv -replace '[ \t]+[#;].*$', ''
        return ($fv -replace '^[ \t]+|[ \t\r]+$', '')
    }
    return ''
}
function On([string]$key) { return ((Cfg 'qol' $key) -ceq '1') }

if ($DEBUG) { Set-Default 'PS2_PERF_LOG' '1' }   # once-a-second fps / CPU / GPU / audio / underrun line in logs\run-*.log
$QOL_VARS = @('PS2_PERF_LOG','PS2_AUDIO_BUFFER_MS','PS2_AUDIO_SAMPLES','PS2_INPUT_MAP','PS2_SCALE','PS2_VOICE_OVERLAY','PS2_VOICE_CONFIG','PS2_SAVE_SLOTS','PS2_VOICE_ALWAYS_ON','PS2_WIDESCREEN','PS2_FAST_LOADS','PS2_VOICE_OFF','PS2_VOICE_ALIASES','PS2_VU_CHECK','PS2_SAVE_DIR','PS2_ICON_PACK','PS2_FAST_FORWARD','PS2_FF_MAX')
$sc = Cfg 'qol' 'resolution_scale'; if ($sc -ne '' -and $sc -cne '1') { Set-Default 'PS2_SCALE' $sc }   # item 3
if (On 'voice_readout') { Set-Default 'PS2_VOICE_OVERLAY' '1' }                                         # item 1 (reserved)
if (On 'voice_tuning')  { Set-Default 'PS2_VOICE_CONFIG' (Join-Path $HERE 'voice.ini') }                # item 2 (reserved)
if (On 'save_slots')    { Set-Default 'PS2_SAVE_SLOTS' '1' }                                            # item 4
if ((Get-V 'PS2_SAVE_SLOTS') -ceq '1') { Set-Default 'PS2_SAVE_DIR' (Join-Path $HERE 'saves') }
if (On 'always_on')     { Set-Default 'PS2_VOICE_ALWAYS_ON' '1' }                                       # item 5 (reserved)
if ((On 'large_model') -and -not $_m) {                                                                  # item 6
    $vd = Get-V 'VOSK_DIR'
    if ($vd -and (Test-Path -LiteralPath (Join-Path $vd 'vosk-model-en-us-0.22') -PathType Container)) { $SH['PS2_VOICE_VOSK_MODEL'] = Join-Path $vd 'vosk-model-en-us-0.22' }
}
if (On 'widescreen')    { Set-Default 'PS2_WIDESCREEN' '1' }                                            # item 7
if (On 'faster_loads')  { Set-Default 'PS2_FAST_LOADS' '1' }                                            # item 8 (reserved)
if (-not (Test-V 'PS2_VU_FAST') -and (On 'vu_fast')) { $SH['PS2_VU_FAST'] = '1' }                        # item 9: only unset + config on enables it
# item 10: button icons. ps2 (default) = original glyphs; other names: icons.local\<name> first, then icons\<name>.
$ic = Cfg 'qol' 'button_icons'
if ($ic -ne '' -and $ic -cne 'ps2' -and $ic -cnotmatch '[^A-Za-z0-9_-]') {
    foreach ($d in @((Join-Path (Join-Path $HERE 'icons.local') $ic), (Join-Path (Join-Path $HERE 'icons') $ic))) {
        if (Test-Path -LiteralPath (Join-Path $d 'icons.txt') -PathType Leaf) { Set-Default 'PS2_ICON_PACK' $d; break }
    }
}
if (On 'fast_forward')  { Set-Default 'PS2_FAST_FORWARD' '1' }                                          # item 11
if (-not (Test-V 'PS2_FMV_SKIP') -and (On 'fmv_skip')) { $SH['PS2_FMV_SKIP'] = '1' }                     # item 12
if ((Cfg 'launch' 'voice_off') -ceq '1') { Set-Default 'PS2_VOICE_OFF' '1' }
# Controller bindings + hotkeys: [bindings] -> PS2_INPUT_MAP="circle=b,paddle1;lx=leftx;hk_quit=back&start@1500;..."
if ((Test-Path -LiteralPath $CFG -PathType Leaf) -and -not (Test-V 'PS2_INPUT_MAP')) {
    $in = $false; $out = New-Object System.Collections.Generic.List[string]
    foreach ($line in $CFG_LINES) {
        if ($line.StartsWith('[')) { $in = ($line -ceq '[bindings]') }
        if (-not $in) { continue }
        $eq = $line.IndexOf('='); if ($eq -lt 0) { continue }
        $k = $line.Substring(0, $eq); if ($k -match '^[ \t]*[#;]') { continue }
        $k = $k -replace '[ \t\r]', ''
        $bv = $line.Substring($eq + 1) -replace '[ \t]+[#;].*$', ''
        $bv = $bv -replace '^[ \t]+|[ \t\r]+$', ''
        $out.Add("$k=$bv")
    }
    $SH['PS2_INPUT_MAP'] = ($out -join ';')
}

# --skip-tutorial: start in the first room from saves\room001.state. A loaded state does not tell the voice
# module the active context, so preset it. main has no shared definition of this value: it is inline in
# steam-machine/run.sh:54 (and made by steam-machine/make-skip-state.sh:34). This is the one Windows copy;
# keep it equal to run.sh:54 (windows/tests/compare-run-sh.sh checks that both print the same value).
$EXTRA = @()
if ($SKIP) {
    $st = Join-Path (Join-Path $HERE 'saves') 'room001.state'
    if (-not (Test-Path -LiteralPath $st -PathType Leaf)) { Fail "no $st; make the skip state first" }
    $EXTRA = @('--load-state', $st); Set-Default 'PS2_VOICE_CONTEXT' '013.a/os_601'
}
$LOGS = Join-Path $HERE 'logs'
if (-not $DRY) { New-Item -ItemType Directory -Force -Path $LOGS | Out-Null }
if ($DEBUG) { Set-Default 'PS2_VOICE_DEBUG' '1' } else { Set-Default 'PS2_VOICE_DEBUG' '0' }
Set-Default 'PS2_VOICE_LOG' (Join-Path $LOGS 'voice.log')

# --- the environment handed to ps2run, in run.sh's order (SDL_AUDIODRIVER deliberately absent) ---
$ENVS = New-Object System.Collections.Generic.List[object]
function Add-Env([string]$n, [string]$val) { $ENVS.Add(@($n, $val)) }
Add-Env 'PS2_VOICE_DEBUG' (Get-V 'PS2_VOICE_DEBUG'); Add-Env 'PS2_VOICE_LOG' (Get-V 'PS2_VOICE_LOG')
if (Get-V 'PS2_VOICE_CONTEXT') { Add-Env 'PS2_VOICE_CONTEXT' (Get-V 'PS2_VOICE_CONTEXT') }
foreach ($n in @('PS2_VOICE_VOSK_MODEL','PS2_VOICE_VOSK_LIB','PS2_VOICE_ASSETS')) {
    $val = Get-V $n
    if ($val) { Add-Env $n $val } else { [Console]::Error.WriteLine("warning: $n is not set (lifeline.env.json); voice will not start") }
}
foreach ($n in $QOL_VARS) { $val = Get-V $n; if ($val) { Add-Env $n $val } }
# Set-but-empty forces these off on Linux. Windows cannot carry an empty value, so forced off is 0.
foreach ($n in @('PS2_VU_FAST','PS2_FMV_SKIP')) {
    if (Test-V $n) { $val = Get-V $n; if ($val -eq '') { $val = '0' }; Add-Env $n $val }
}
if (EnvVal 'LIFELINE_PRINT_ENV') { foreach ($e in $ENVS) { [Console]::Out.WriteLine($e[0] + '=' + $e[1]) }; exit 0 }   # headless check

# --- command line ---
$PS2RUN = $PS2RUN_ARG; if (-not $PS2RUN) { $PS2RUN = $SH['PS2RUN'] }
if (-not $PS2RUN) { $PS2RUN = Join-Path $HERE 'ps2run.exe' }
foreach ($n in @('ELF','ISO','MEMCARD')) { if (-not (Get-V $n)) { Fail "$n is not set in lifeline.env.json" } }
$ARGV = @((Get-V 'ELF'), '--disc', (Get-V 'ISO'), '--memcard', (Get-V 'MEMCARD'), '--window') + $EXTRA + @($rest | ForEach-Object { [string]$_ })

# Windows command-line quoting (CommandLineToArgvW / MSVC CRT rules).
function Quote-Arg([string]$s) {
    if ($s.Length -gt 0 -and $s -notmatch '[\s"]') { return $s }
    $sb = New-Object System.Text.StringBuilder; [void]$sb.Append('"'); $bs = 0
    foreach ($c in $s.ToCharArray()) {
        if ($c -eq [char]'\') { $bs++; continue }
        if ($c -eq [char]'"') { [void]$sb.Append('\' * ($bs * 2 + 1)).Append('"'); $bs = 0; continue }
        [void]$sb.Append('\' * $bs).Append($c); $bs = 0
    }
    [void]$sb.Append('\' * ($bs * 2)).Append('"')
    return $sb.ToString()
}
$CMDLINE = ($ARGV | ForEach-Object { Quote-Arg $_ }) -join ' '

if ($DRY) {
    [Console]::Out.WriteLine('# dry run: nothing started')
    foreach ($e in $ENVS) { [Console]::Out.WriteLine($e[0] + '=' + $e[1]) }
    $ad = EnvVal 'SDL_AUDIODRIVER'
    if ($ad) { [Console]::Out.WriteLine("# SDL_AUDIODRIVER=$ad (inherited)") } else { [Console]::Out.WriteLine('# SDL_AUDIODRIVER unset (SDL default: wasapi, then directsound)') }
    [Console]::Out.WriteLine('# exe: ' + $PS2RUN)
    [Console]::Out.WriteLine('# args: ' + $CMDLINE)
    exit 0
}
if (-not (Test-Path -LiteralPath $PS2RUN -PathType Leaf)) { Fail "ps2run not found: $PS2RUN" }

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $PS2RUN; $psi.Arguments = $CMDLINE; $psi.UseShellExecute = $false
$loc = Get-Location; if ($loc.Provider.Name -eq 'FileSystem') { $psi.WorkingDirectory = $loc.ProviderPath }
foreach ($e in $ENVS) { $psi.EnvironmentVariables[$e[0]] = $e[1] }   # child only; this shell's env is untouched
$logw = $null
if ($DEBUG) {
    $runlog = Join-Path $LOGS ('run-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
    [Console]::Error.WriteLine("debug: stderr -> $runlog, voice -> " + (Get-V 'PS2_VOICE_LOG'))
    $psi.RedirectStandardError = $true   # stdout stays on the console, so reading only stderr cannot deadlock
    $logw = New-Object System.IO.StreamWriter($runlog, $true); $logw.AutoFlush = $true
}
$p = [System.Diagnostics.Process]::Start($psi)
if ($logw) {
    try { while ($null -ne ($l = $p.StandardError.ReadLine())) { [Console]::Error.WriteLine($l); $logw.WriteLine($l) } }
    finally { $logw.Dispose() }
}
$p.WaitForExit()
exit $p.ExitCode
