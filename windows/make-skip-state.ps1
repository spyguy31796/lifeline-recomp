<#
Make a "skip the tutorial" save state from YOUR disc, on this PC. PowerShell twin of steam-machine/make-skip-state.sh.
  <Root>\saves\room001.state = frame 52000, first playable room (scene 013, voice context 013.a/os_601).
Replays the tutorial with injected answers (no mic needed) in the same segments (save/load points) as
make-skip-state.sh, skips the intro cutscenes with START, and saves at frame 52000.
Contains no game data: the tutorial answers come from a local file you write yourself (one phrase per line, in
the order the tutorial asks), default <Root>\saves\tutorial-queue.txt. Keep it, the states and the logs on this PC.

  powershell -NoProfile -ExecutionPolicy Bypass -File windows\make-skip-state.ps1 [-Queue <file>] [-Out <state>]
      [-Root <dir>] [-StopAt <frame>] [-DryRun]
  -Root    install root holding lifeline.env.json (PS2RUN, ELF, ISO, PS2_VOICE_ASSETS); default $env:LIFELINE_WORK,
           else %USERPROFILE%\Lifeline\game. Work files go to <Root>\logs\skip-state (emptied at start).
  -Queue   answers file (default <Root>\saves\tutorial-queue.txt). Lines without a leading "FRAME " get "0 ".
  -Out     output state (default <Root>\saves\room001.state; with -StopAt N: <Root>\saves\tut_N.state while N is a
           tutorial frame, else <Root>\saves\state_N.state).
  -StopAt  stop after the segment that ends at this frame and save that state instead (e.g. -StopAt 17300 makes
           the tutorial state at frame 17300). Must be a segment end: 2000 4000 ... 36700 38700 ... 52000 52400.
           The final "room context" / "listening" checks run only on a full run.
  -DryRun  print each segment's environment and ps2run arguments; reads the queue, writes and starts nothing.
Exit codes: 0 ok, 1 failed (bad input, a segment saved no state), 2 ps2run is already running (close the game
first; this script only looks, with Get-Process, and never stops it), or, as in make-skip-state.sh, the finished
state failed a check (room context never loaded / the game does not listen).
Differences from make-skip-state.sh (Windows only):
  - no distrobox; ps2run starts with its working directory in <Root>\logs\skip-state (so voice.log lands there).
  - the queue may have CRLF line ends or a UTF-8 BOM (Notepad); both are removed (ps2run would keep a CR).
  - the only process it ever stops is a ps2run it started itself, when the script is interrupted (Ctrl+C).
  - no environment value is ever empty (Windows drops empty values); nothing is forced off here.
Windows PowerShell 5.1 compatible. ASCII only.
#>
param(
    [string]$Queue = '',
    [string]$Out = '',
    [string]$Root = '',
    [int]$StopAt = 0,
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

function Fail([string]$msg, [int]$code = 1) { [Console]::Error.WriteLine($msg); exit $code }
function FullPath([string]$p) { return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($p) }
function J([string]$a, [string]$b) { return (Join-Path $a $b) }

# --- install root, settings ---
if (-not $Root) { $Root = $env:LIFELINE_WORK }
if (-not $Root) { $hd = $env:USERPROFILE; if (-not $hd) { $hd = $HOME }; $Root = J (J $hd 'Lifeline') 'game' }
$Root = FullPath $Root
# Launch settings: lifeline.env.json (build.ps1 / install.ps1), else a KEY=value lifeline.env; parsed, never executed
# (same reader as run.ps1). Read-only: this script never writes lifeline.env.json.
$CFG = @{}
$JSONFILE = J $Root 'lifeline.env.json'; $ENVFILE = J $Root 'lifeline.env'
if (Test-Path -LiteralPath $JSONFILE -PathType Leaf) {
    $j = [IO.File]::ReadAllText($JSONFILE).TrimStart([char]0xFEFF) | ConvertFrom-Json
    foreach ($pr in $j.PSObject.Properties) { if ($null -ne $pr.Value) { $CFG[$pr.Name] = [string]$pr.Value } }
} elseif (Test-Path -LiteralPath $ENVFILE -PathType Leaf) {
    foreach ($line in [IO.File]::ReadAllLines($ENVFILE)) {
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        if ($t -notmatch '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$') { continue }
        $k = $Matches[1]; $val = $Matches[2]
        if ($val.Length -ge 2 -and (($val.StartsWith('"') -and $val.EndsWith('"')) -or ($val.StartsWith("'") -and $val.EndsWith("'")))) { $val = $val.Substring(1, $val.Length - 2) }
        $CFG[$k] = $val
    }
} else { Fail "neither lifeline.env.json nor lifeline.env in $Root; run build.ps1 / install.ps1 first (or pass -Root)" }
foreach ($n in @('PS2RUN', 'ELF', 'ISO', 'PS2_VOICE_ASSETS')) { if (-not $CFG.ContainsKey($n) -or -not $CFG[$n]) { Fail "$n is not set in lifeline.env.json" } }
$PS2RUN = $CFG['PS2RUN']; $ELF = $CFG['ELF']; $ISO = $CFG['ISO']; $ASSETS = $CFG['PS2_VOICE_ASSETS']

# --- segments (make-skip-state.sh: B=(...) tut, then skip/idle/call/probe) ---
$SEGS = New-Object System.Collections.Generic.List[object]
$B = @(0, 2000, 4000, 6000, 7700, 9300, 11300, 13300, 15300, 17300, 19300, 20100, 21300, 22500, 23700, 25700, 27700, 29700, 31700, 33700, 36700)
for ($i = 0; $i + 1 -lt $B.Count; $i++) { $SEGS.Add(@($B[$i], $B[$i + 1], 'tut')) }
foreach ($s in @(@(36700, 38700, 'skip'), @(38700, 41700, 'skip'), @(41700, 44700, 'skip'), @(44700, 48000, 'idle'),
                 @(48000, 50000, 'idle'), @(50000, 52000, 'call'), @(52000, 52400, 'probe'))) { $SEGS.Add($s) }
$FULL = ($StopAt -eq 0)
$KEEP = 52000   # the state copied to -Out on a full run (the probe segment after it only checks listening)
if (-not $FULL) {
    $ends = @($SEGS | ForEach-Object { $_[1] })
    if ($ends -notcontains $StopAt) { Fail ("-StopAt must be a segment end frame: " + ($ends -join ' ')) }
    $KEEP = $StopAt
}

$T = J (J $Root 'logs') 'skip-state'
if (-not $Queue) { $Queue = J (J $Root 'saves') 'tutorial-queue.txt' }
if (-not $Out) {
    if ($FULL) { $Out = J (J $Root 'saves') 'room001.state' }
    elseif ($StopAt -le 36700) { $Out = J (J $Root 'saves') "tut_$StopAt.state" }
    else { $Out = J (J $Root 'saves') "state_$StopAt.state" }
}
$Queue = FullPath $Queue; $Out = FullPath $Out
if (-not (Test-Path -LiteralPath $Queue -PathType Leaf) -or (Get-Item -LiteralPath $Queue).Length -eq 0) { Fail "queue file missing: $Queue" }
foreach ($p in @($T, $Out, $ELF, $ISO)) {
    if ($p -cmatch '[^\x20-\x7E]') { [Console]::Error.WriteLine("warning: path is not ASCII; ps2run reads it with narrow-char file APIs (untested): $p") }
}

# injector lines: "FRAME phrase" (0 = next listen); same rule as the .sh's sed '/^[0-9]+ /!s/^/0 /'
# ReadAllLines drops CR/LF and a UTF-8 BOM.
$QLINES = New-Object System.Collections.Generic.List[string]
foreach ($line in [IO.File]::ReadAllLines($Queue)) { if ($line -cmatch '^[0-9]+ ') { $QLINES.Add($line) } else { $QLINES.Add('0 ' + $line) } }
$QFILE = J $T 'queue.txt'; $CARD = J $T 'mc.ps2'; $ST = J $T 'st'
function Write-Queue { $sb = New-Object Text.StringBuilder; foreach ($l in $QLINES) { [void]$sb.Append($l).Append("`n") }; [IO.File]::WriteAllText($QFILE, $sb.ToString(), (New-Object Text.UTF8Encoding $false)) }

# --- presses per segment (make-skip-state.sh run()) ---
function Get-Presses([int]$S, [int]$E, [string]$M) {
    $P = New-Object System.Collections.Generic.List[string]
    if ($M -ceq 'tut') {
        if ($S -eq 0) { $P.Add('1300:start'); $P.Add('1420:cross') }
        for ($f = 1600; $f -lt 3250; $f += 90) { if ($f -gt $S -and $f -lt $E) { $P.Add("${f}:square") } }
        for ($tt = 3300; $tt -lt $E; $tt += 400) {
            if ($tt -gt $S) { $P.Add("${tt}:circle:60") }
            for ($f = $tt + 120; $f -lt $tt + 400; $f += 70) { if ($f -gt $S -and $f -lt $E) { $P.Add("${f}:square") } }
        }
    } elseif ($M -ceq 'skip') { for ($f = $S + 30; $f -lt $E - 100; $f += 30) { $P.Add("${f}:start") } }
    elseif ($M -ceq 'call') { $P.Add(('{0}:start' -f ($S + 50))) }         # answer the "press START" call prompt
    elseif ($M -ceq 'probe') { $P.Add(('{0}:circle:60' -f ($S + 100))) }   # does holding circle start listening?
    return , $P.ToArray()
}
function Get-Argv([int]$S, [int]$E, [string]$M) {
    $a = New-Object System.Collections.Generic.List[string]
    foreach ($x in @($ELF, '--disc', $ISO, '--memcard', $CARD)) { $a.Add($x) }
    if ($S -gt 0) { $a.Add('--load-state'); $a.Add((J $ST "$S.state")) }
    $a.Add('--frames'); $a.Add([string]($E + 1)); $a.Add('--save-state'); $a.Add("${E}:" + (J $ST "$E.state"))
    foreach ($p in (Get-Presses $S $E $M)) { $a.Add('--press'); $a.Add($p) }
    return , $a.ToArray()
}
# a loaded state does not carry the voice module's context, so preset it per segment (tutorial / first room)
function Get-Envs([string]$M) {
    $C = '1000.a/os_999'; if ($M -cne 'tut') { $C = '013.a/os_601' }
    return , @(@('PS2_VOICE_CONTEXT', $C), @('PS2_VOICE_INJECT', $QFILE), @('PS2_VOICE_ASSETS', $ASSETS), @('PS2_VOICE_DEBUG', '1'), @('PS2_GPU_LOW_POWER', '1'))
}
# Windows command-line quoting (CommandLineToArgvW / MSVC CRT rules), as in run.ps1.
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

$RUNSEGS = @($SEGS | Where-Object { $_[1] -le $KEEP -or ($FULL -and $_[2] -ceq 'probe') })

if ($DryRun) {
    [Console]::Out.WriteLine("# dry run: nothing written or started")
    [Console]::Out.WriteLine("# exe: $PS2RUN")
    [Console]::Out.WriteLine("# queue: $($QLINES.Count) answers from $Queue")
    [Console]::Out.WriteLine("# out: $Out (state of frame $KEEP)")
    foreach ($sg in $RUNSEGS) {
        $S = $sg[0]; $E = $sg[1]; $M = $sg[2]
        [Console]::Out.WriteLine("segment $S-$E $M")
        foreach ($ev in (Get-Envs $M)) { [Console]::Out.WriteLine("  env " + $ev[0] + "=" + $ev[1]) }
        $av = Get-Argv $S $E $M
        foreach ($x in $av) { [Console]::Out.WriteLine("  arg $x") }
        [Console]::Out.WriteLine('  cmdline ' + (($av | ForEach-Object { Quote-Arg $_ }) -join ' '))
    }
    exit 0
}

# --- refuse while the game runs (only looks; never stops anything it did not start) ---
$running = @(Get-Process -Name 'ps2run' -ErrorAction SilentlyContinue)
if ($running.Count -gt 0) { Fail ("ps2run is running (pid {0}); close the game first. Nothing was changed." -f (($running | ForEach-Object { $_.Id }) -join ',')) 2 }
if (-not (Test-Path -LiteralPath $PS2RUN -PathType Leaf)) { Fail "ps2run not found: $PS2RUN" }

if (Test-Path -LiteralPath $T) { Remove-Item -LiteralPath $T -Recurse -Force }
New-Item -ItemType Directory -Force -Path $ST | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Out) | Out-Null
Write-Queue
$SW = [Diagnostics.Stopwatch]::StartNew()
function Secs { return [int][Math]::Floor($SW.Elapsed.TotalSeconds) }

function Run-Segment([int]$S, [int]$E, [string]$M) {
    $log = J $T "run_$S.log"
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $av = Get-Argv $S $E $M
    $psi.FileName = $PS2RUN; $psi.Arguments = (($av | ForEach-Object { Quote-Arg $_ }) -join ' ')
    $psi.UseShellExecute = $false; $psi.WorkingDirectory = $T
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    foreach ($ev in (Get-Envs $M)) { $psi.EnvironmentVariables[$ev[0]] = $ev[1] }   # child only
    $w = New-Object System.IO.StreamWriter($log, $false, (New-Object Text.UTF8Encoding $false))
    $p = $null
    try {
        $p = [System.Diagnostics.Process]::Start($psi)
        $so = $p.StandardOutput.ReadToEndAsync()   # stdout in the background, stderr (the [voice] lines) streamed
        while ($null -ne ($l = $p.StandardError.ReadLine())) { $w.WriteLine($l) }
        $p.WaitForExit()
        $w.Write($so.Result)
    } finally {
        # only ever the process started just above (e.g. Ctrl+C during a segment)
        if ($null -ne $p -and -not $p.HasExited) { try { $p.Kill() } catch { } }
        $w.Dispose()
    }
    # ps2run's exit code is ignored, as in the .sh (|| true); the saved state decides
    if (-not (Test-Path -LiteralPath (J $ST "$E.state") -PathType Leaf)) { Fail "FAILED: segment $S-$E saved no state (see $log)" }
    $n = @([IO.File]::ReadAllLines($log) | Where-Object { $_.Contains("injected '") }).Count   # drop delivered answers
    if ($n -gt 0) { $QLINES.RemoveRange(0, [Math]::Min($n, $QLINES.Count)); Write-Queue }
    [Console]::Out.WriteLine("  frames $S-$E (${M}): $n answers, $(Secs)s")
}

[Console]::Out.WriteLine("making $Out (logs: $T) ...")
foreach ($sg in $RUNSEGS) { Run-Segment $sg[0] $sg[1] $sg[2] }
Copy-Item -LiteralPath (J $ST "$KEEP.state") -Destination $Out -Force
[Console]::Out.WriteLine("answers left unused: $($QLINES.Count)")
if ($FULL) {
    $ctx = $false
    foreach ($f in @(Get-ChildItem -LiteralPath $T -File -Filter 'run_*.log')) {
        if (@([IO.File]::ReadAllLines($f.FullName) | Where-Object { $_ -match 'context identified.*013\.a/os_601' }).Count) { $ctx = $true; break }
    }
    if (-not $ctx) { Fail 'WARNING: room context 013.a/os_601 was never loaded' 2 }
    $plog = J $T 'run_52000.log'
    if (-not @([IO.File]::ReadAllLines($plog) | Where-Object { $_.Contains('cmd 1 ') }).Count) { Fail "WARNING: the game does not listen in the saved state (see $plog)" 2 }
    [Console]::Out.WriteLine("OK: $Out (first room, 013.a/os_601, listening) in $(Secs)s")
} else {
    [Console]::Out.WriteLine("OK: $Out (frame $KEEP) in $(Secs)s")
}
exit 0
