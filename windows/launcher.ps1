<#
Lifeline Recomp launcher for Windows (the Linux launcher.sh). Steam ("Add a non-Steam game") should point at
launcher.cmd next to this file, which runs:
  powershell -NoProfile -ExecutionPolicy Bypass -File launcher.ps1 [launcher args, e.g. --dry-run, --fullscreen]

Runs lifeline_launcher.py with <Root>\launcher-venv\Scripts\python.exe (Python 3.12 + pygame-ce, made by install.ps1).
<Root> = $env:LIFELINE_WORK, default %USERPROFILE%\Lifeline\game. Unlike launcher.sh this never creates the venv or
pip-installs anything: install.ps1 owns that (from Lifeline\tools\python312, only if missing).
Works from the installed copy (<Root>\launcher\launcher.ps1 next to lifeline_launcher.py) and from the repo
(windows\launcher.ps1, using steam-machine\launcher\lifeline_launcher.py). Never stops any process.
Windows PowerShell 5.1 compatible. ASCII only.
#>
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

$HOMEDIR = $env:USERPROFILE; if (-not $HOMEDIR) { $HOMEDIR = $HOME }
$WORK = $env:LIFELINE_WORK; if (-not $WORK) { $WORK = Join-Path (Join-Path $HOMEDIR 'Lifeline') 'game' }
$WORK = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($WORK)

function Show-Error([string]$m) {   # the zenity dialog of launcher.sh; also on the console and in launcher.log
    [Console]::Error.WriteLine($m)
    try { if (Test-Path -LiteralPath $WORK -PathType Container) { Add-Content -LiteralPath (Join-Path $WORK 'launcher.log') -Value $m -Encoding Ascii } } catch { }
    try { Add-Type -AssemblyName System.Windows.Forms; [void][Windows.Forms.MessageBox]::Show($m, 'Lifeline Recomp') } catch { }
}

$VENV = Join-Path $WORK 'launcher-venv'
$PY = Join-Path (Join-Path $VENV 'Scripts') 'python.exe'
if (-not (Test-Path -LiteralPath $PY -PathType Leaf) -and [IO.Path]::DirectorySeparatorChar -ne '\') { $PY = Join-Path (Join-Path $VENV 'bin') 'python' }   # pwsh on Linux (tests only)

$SCRIPT = Join-Path $PSScriptRoot 'lifeline_launcher.py'
if (-not (Test-Path -LiteralPath $SCRIPT -PathType Leaf)) { $SCRIPT = Join-Path (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'steam-machine') 'launcher') 'lifeline_launcher.py' }
if (-not (Test-Path -LiteralPath $SCRIPT -PathType Leaf)) { Show-Error "Lifeline launcher: lifeline_launcher.py not found next to $PSScriptRoot. Run windows\install.ps1 again."; exit 1 }

if (-not (Test-Path -LiteralPath $PY -PathType Leaf)) {
    Show-Error "Lifeline launcher: $PY is missing. Run windows\install.ps1 (it creates launcher-venv from Lifeline\tools\python312)."; exit 1
}
$ErrorActionPreference = 'Continue'   # a Python warning on stderr must not throw on 5.1
& $PY -c 'import pygame' *> $null
if ($LASTEXITCODE -ne 0) { Show-Error "Lifeline launcher: pygame-ce is not installed in $VENV. Run windows\install.ps1 again (needs network once)."; exit 1 }

$env:LIFELINE_WORK = $WORK   # the launcher and the run.ps1 it starts use the same install root
& $PY $SCRIPT @args
exit $LASTEXITCODE
