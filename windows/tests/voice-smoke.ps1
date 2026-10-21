<#
Lifeline Recomp, Windows voice smoke (M-W2). Runs the ps2run.exe that build.ps1 made, headless, for a fixed
number of frames and checks the voice start-up lines in its log. Uses the paths in <Work>\lifeline.env.json
(PS2RUN, ELF, ISO, PS2_VOICE_VOSK_MODEL, PS2_VOICE_VOSK_LIB, PS2_VOICE_ASSETS). Close the game first: the
script refuses to start while a ps2run process is running, and it never stops one.

Mic mode (default): boot with the live microphone.
  powershell -NoProfile -ExecutionPolicy Bypass -File windows\tests\voice-smoke.ps1
  Checks:
    [input] voice hooks: busy=1 context=1 after_load=1 pad_circle=1   (all four hooks resolved)
    [voice] vosk backend: model ..., audio source sdl-mic                (libvosk.dll loaded; on failure the
                                                                          log has "[voice] vosk: <path>: LoadLibrary
                                                                          failed, error <code> <text>" or "missing <symbol>")
    [voice] mic: SDL audio driver <driver>, capture device (default) <name>, <Hz> Hz, format 0x<fmt>, <n> ch, <n> samples

WAV mode: the recognizer hears WAV files instead of the mic (same env variables ps2run reads on Linux:
PS2_VOICE_WAV_SCHEDULE, a file of "FRAME C:\path\clip.wav" lines, or PS2_VOICE_WAV_DIR, a folder of .wav
files played in name order; 16 kHz mono 16-bit). To repeat the Linux recipe, pass the same save state,
schedule, context and circle press as the private on-box notes:
  ... voice-smoke.ps1 -WavSchedule C:\path\sched.txt -State C:\path\your.state -Context <ctx> -Press <frame>:circle:60 -Frames <n>
  Checks the hook and backend lines (audio source wav), then prints the "cmd 1" / "cmd 2" lines and the
  recognition line (ACCEPT or REJECT, with conf=); compare frames and conf with the Linux run.
  Needs PS2_VOICE_ASSETS in lifeline.env.json, pointing at the voice assets extracted from your own disc
  (mic mode does not need it).
Exit code 0 = every check passed. The log is kept in <Work>\logs\voice-smoke-<time>.log (game-derived; keep it on this PC).
#>
param(
    [string]$Work = (Join-Path (Join-Path $env:USERPROFILE 'Lifeline') 'game'),
    [int]$Frames = 900,
    [string]$WavSchedule = '',
    [string]$WavDir = '',
    [string]$State = '',
    [string]$Context = '',
    [string[]]$Press = @()
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$Work = [IO.Path]::GetFullPath($Work)
$envFile = Join-Path $Work 'lifeline.env.json'
if (-not (Test-Path -LiteralPath $envFile)) { Write-Host "FAIL: $envFile not found (run windows\build.ps1 first)"; exit 2 }
$cfg = Get-Content -Raw -LiteralPath $envFile | ConvertFrom-Json
function Need([string]$k) {
    $p = $cfg.PSObject.Properties | Where-Object { $_.Name -eq $k } | Select-Object -First 1
    if (-not $p -or -not $p.Value) { Write-Host "FAIL: $k missing in $envFile"; exit 2 }
    return [string]$p.Value
}
$exe = Need 'PS2RUN'; $elf = Need 'ELF'; $iso = Need 'ISO'
if (Get-Process -Name ps2run -ErrorAction SilentlyContinue) { Write-Host 'FAIL: ps2run is running; close the game first (this script does not stop it)'; exit 2 }

$wav = [bool]($WavSchedule -or $WavDir)
foreach ($k in 'PS2_VOICE_VOSK_MODEL', 'PS2_VOICE_VOSK_LIB') { Set-Item "env:$k" (Need $k) }
# Voice assets (context names, phrase tables from your disc) are needed for the WAV recipe only; the mic check
# runs without them. Use the value from the file when there is one, else leave the variable unset.
$assets = $cfg.PSObject.Properties | Where-Object { $_.Name -eq 'PS2_VOICE_ASSETS' } | Select-Object -First 1
if ($wav) { $env:PS2_VOICE_ASSETS = Need 'PS2_VOICE_ASSETS' }
elseif ($assets -and $assets.Value) { $env:PS2_VOICE_ASSETS = [string]$assets.Value }
else { Remove-Item env:PS2_VOICE_ASSETS -ErrorAction SilentlyContinue }
Remove-Item env:PS2_VOICE_WAV_SCHEDULE, env:PS2_VOICE_WAV_DIR, env:PS2_VOICE_CONTEXT -ErrorAction SilentlyContinue
if ($WavSchedule) { $env:PS2_VOICE_WAV_SCHEDULE = [IO.Path]::GetFullPath($WavSchedule) }
elseif ($WavDir) { $env:PS2_VOICE_WAV_DIR = [IO.Path]::GetFullPath($WavDir) }
if ($Context) { $env:PS2_VOICE_CONTEXT = $Context }
$logs = Join-Path $Work 'logs'; New-Item -ItemType Directory -Force $logs | Out-Null
$ts = Get-Date -Format 'yyyyMMdd-HHmmss'
$log = Join-Path $logs "voice-smoke-$ts.log"
$env:PS2_VOICE_DEBUG = '1'; $env:PS2_VOICE_LOG = Join-Path $logs "voice-smoke-$ts.voice.log"
$card = Join-Path ([IO.Path]::GetTempPath()) "lifeline-voice-smoke-$ts.ps2"   # fresh card: never touches your saves

$argv = @($elf, '--disc', $iso, '--memcard', $card, '--frames', "$Frames")
if ($State) { $argv += @('--load-state', [IO.Path]::GetFullPath($State)) }
foreach ($p in $Press) { $argv += @('--press', $p) }
$q = ($argv | ForEach-Object { '"' + ($_ -replace '"', '\"') + '"' }) -join ' '   # Start-Process on 5.1 does not quote
Write-Host "== $exe $q"
$out = "$log.stdout"
$proc = Start-Process -FilePath $exe -ArgumentList $q -WorkingDirectory (Split-Path -Parent $exe) -NoNewWindow -Wait -PassThru `
    -RedirectStandardError $log -RedirectStandardOutput $out
Add-Content -LiteralPath $log -Value (Get-Content -LiteralPath $out); Remove-Item -LiteralPath $out
Remove-Item -LiteralPath $card -ErrorAction SilentlyContinue
$text = @(Get-Content -LiteralPath $log)
Write-Host "== ps2run exit $($proc.ExitCode), log $log"

$fail = 0
function Check([string]$what, [string]$pattern) {
    $hit = @($text | Where-Object { $_ -match $pattern })
    if ($hit.Count) { Write-Host "PASS $what"; $hit | Select-Object -First 3 | ForEach-Object { Write-Host "     $_" } }
    else { Write-Host "FAIL $what (no line matching: $pattern)"; $script:fail++ }
}
Check 'voice hooks all 1' '^\[input\] voice hooks: busy=1 context=1 after_load=1 pad_circle=1$'
if ($wav) { Check 'vosk backend (wav)' '^\[voice\] vosk backend: .*audio source wav$' }
else {
    Check 'vosk backend (mic)' '^\[voice\] vosk backend: .*audio source sdl-mic$'
    Check 'mic driver/device line' '^\[voice\] mic: SDL audio driver '
}
if ($wav) {
    Check 'cmd 1' '^\[voice\] f\d+ cmd 1 '
    Check 'cmd 2' '^\[voice\] f\d+ cmd 2 '
    Check 'recognition line' '^\[voice\] f\d+ ctx=.* conf=\d+ .*(ACCEPT|REJECT)'
}
if ($fail) {
    Write-Host '-- voice/vosk/mic lines in the log:'
    $text | Where-Object { $_ -match '^\[voice\] (vosk|mic|SDL capture)' } | ForEach-Object { Write-Host "     $_" }
}
Write-Host $(if ($fail) { "voice-smoke: $fail check(s) FAILED" } else { 'voice-smoke: all OK' })
exit $(if ($fail) { 1 } else { 0 })
