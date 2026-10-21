<#
Lifeline Recomp: Windows install steps for voice (Vosk, model, voice assets, aliases) from YOUR OWN disc.
Mirrors steam-machine/build.sh:118-184 and lifeline_launcher.py install(). Contains only our code; everything it
writes is under -Root and stays on this PC. It does not build ps2run.exe (that is build.ps1), and it never touches
<Root>\launcher-venv, <Root>\ps2-web-recomp, or the tools\ and deps\ folders next to <Root>.

  powershell -NoProfile -ExecutionPolicy Bypass -File windows\install.ps1 -Iso "C:\path\Life Line (USA).iso" [-Root C:\Users\you\Lifeline\game] [-DryRun]

  -Root          install root = build.ps1's -Work (default %USERPROFILE%\Lifeline\game, i.e. C:\Users\<user>\Lifeline\game on
                 <pc-name>). Must be ASCII-only (Vosk/narrow fopen paths). Never Lifeline\tools or Lifeline\deps.
  -Iso           your ISO; sha256 and size are checked before anything else (default %USERPROFILE%\Downloads\Life Line (USA).iso)
  -Kit           our repo checkout (default: the folder above this script)
  -Src           upstream ps2-web-recomp checkout that has scripts\disc.py (default <Root>\ps2-web-recomp, as build.ps1 makes it)
  -PyExe/-PyArgs Python 3 to run the stdlib-only tools (default: py -3)
  -WheelPath     use an already downloaded vosk-0.3.45-py3-none-win_amd64.whl (still sha256-checked)
  -ModelZipPath  use an already downloaded vosk-model-small-en-us-0.15.zip (still sha256-checked)
  -SkipVosk      skip the Vosk library and model steps
  -DryRun        do every read-only check (ISO hash, game closed, what is missing) and print what would be written
Exit codes: 0 ok, 1 failed, 2 game is running (close it first; this script never stops it), 3 ISO check failed.
Windows PowerShell 5.1 compatible. ASCII only.
#>
[CmdletBinding()]
param(
    [string]$Root, [string]$Iso, [string]$Kit, [string]$Src,
    [string]$PyExe = 'py', [string]$PyArgs = '-3',
    [string]$WheelPath, [string]$ModelZipPath,
    [switch]$SkipVosk, [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest is very slow with the progress bar on 5.1

# --- pinned inputs ---------------------------------------------------------------
$ISO_SHA256 = 'cb0bebe97770d7964b0c003bae204a610f784bc9611656596af8f6a8265c5d38'   # Alec's verified dump (windows-port-plan.md section 7)
$ISO_SIZE   = 3777593344
$VOSK_VER   = '0.3.45'
$WHEEL      = "vosk-$VOSK_VER-py3-none-win_amd64.whl"
$WHEEL_URL  = "https://files.pythonhosted.org/packages/c0/4c/deb0861f7da9696f8a255f1731bb73e9412cca29c4b3888a3fcb2a930a59/$WHEEL"
$WHEEL_SHA  = '6994ddc68556c7e5730c3b6f6bad13320e3519b13ce3ed2aa25a86724e7c10ac'   # PyPI JSON digest
$DLLS = [ordered]@{   # wheel vosk/<name> -> sha256 (voice-section.md section 2)
    'libvosk.dll'         = '9331c2f6a32cf77141af27c9750e79532718f51bbc2e3cea3c60f14ca4251e4e'
    'libstdc++-6.dll'     = 'a1d96a848a567d7657e152cfe92e2fd62da412968cc11ec8bdb04bf20ebc5747'
    'libgcc_s_seh-1.dll'  = '201bf8a54ebb490f93ea4beb20740a483bf67036b90b5720f32d0c746a72d1e9'
    'libwinpthread-1.dll' = '92caeb8a4ea281c674003462a233f3b445b685b0a6f93eb11254feda2dda9cde'
}
$MODEL      = 'vosk-model-small-en-us-0.15'                                         # Apache-2.0
$MODEL_URL  = "https://alphacephei.com/vosk/models/$MODEL.zip"
$MODEL_SHA  = '30f26242c4eb449f948e42cb302dd7a686cb29a3423a8367f99ff41780942498'   # same as build.sh MODEL_SHA

# --- helpers -----------------------------------------------------------------------
$script:LOG = $null
function Say([string]$m) { Write-Host $m; if ($script:LOG) { Add-Content -LiteralPath $script:LOG -Value $m -Encoding Ascii } }
function Die([string]$m, [int]$code = 1) { Say "ERROR: $m"; exit $code }
function Plan([string]$m) { if ($DryRun) { Say "  [dry-run] would $m" } else { Say "  $m" } }
function Sha256([string]$p) { return (Get-FileHash -Algorithm SHA256 -LiteralPath $p).Hash.ToLowerInvariant() }
function FullPath([string]$p) { return [IO.Path]::GetFullPath($p) }
function Fwd([string]$p) { return $p.Replace('\', '/') }   # paths spliced into Python source (T5): never backslashes
function Is-Empty-Dir([string]$d) { return (-not (Test-Path -LiteralPath $d -PathType Container)) -or (@(Get-ChildItem -LiteralPath $d -Force).Count -eq 0) }
function Need-Space([string]$dir, [int]$mb) {
    $free = (New-Object IO.DriveInfo ([IO.Path]::GetPathRoot((FullPath $dir)))).AvailableFreeSpace
    if ($free -lt ([int64]$mb * 1MB)) { Die ("not enough free space in {0}: need {1} MB, have {2} MB" -f $dir, $mb, [int64]($free / 1MB)) }
}
$PY_ARGS = @($PyArgs -split '\s+' | Where-Object { $_ -ne '' })
function Py { $ErrorActionPreference = 'Continue'; & $PyExe @PY_ARGS @args | Out-Host; return $LASTEXITCODE }   # Continue: a tool's stderr line must not throw on 5.1
# url dest sha256 -> verified file at dest (.part removed on any failure); an existing dest with the right sha is reused.
function Fetch([string]$url, [string]$dest, [string]$sha) {
    if ((Test-Path -LiteralPath $dest -PathType Leaf) -and ((Sha256 $dest) -eq $sha)) { Say "  reusing verified $dest"; return }
    $part = "$dest.part"; Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $part
    } catch { Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue; Die "download failed: $url ($($_.Exception.Message))" }
    $got = Sha256 $part
    if ($got -ne $sha) { Remove-Item -LiteralPath $part -Force; Die "sha256 mismatch: $url (got $got)" }
    Move-Item -LiteralPath $part -Destination $dest -Force
}
function Use-Local([string]$path, [string]$sha, [string]$what) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { Die "$what not found: $path" }
    $got = Sha256 $path; if ($got -ne $sha) { Die "sha256 mismatch for $what ${path}: got $got" }
}
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

# --- arguments and path rules -------------------------------------------------------------
$HOMEDIR = $env:USERPROFILE; if (-not $HOMEDIR) { $HOMEDIR = $HOME }
if (-not $Root) { $Root = Join-Path (Join-Path $HOMEDIR 'Lifeline') 'game' }
if (-not $Iso)  { $Iso = Join-Path (Join-Path $HOMEDIR 'Downloads') 'Life Line (USA).iso' }
if (-not $Kit)  { $Kit = Split-Path -Parent $PSScriptRoot }
$Root = FullPath $Root; $Iso = FullPath $Iso; $Kit = FullPath $Kit
if (-not $Src)  { $Src = Join-Path $Root 'ps2-web-recomp' }
$Src = FullPath $Src
$segs = @($Root.Split([char[]]@('\', '/')) | Where-Object { $_ -ne '' })
for ($i = 1; $i -lt $segs.Count; $i++) {   # Lifeline\tools, Lifeline\deps (Lead's toolchain) and the launcher venv are off limits
    if (($segs[$i - 1] -eq 'Lifeline' -and ($segs[$i] -eq 'tools' -or $segs[$i] -eq 'deps')) -or $segs[$i] -eq 'launcher-venv') { Die "install root must not be inside Lifeline\tools, Lifeline\deps or launcher-venv: $Root" }
}
if ($Root -cmatch '[^\x20-\x7E]') { Die "install root must be ASCII-only (Vosk model and log paths): $Root" }
foreach ($p in @($Root, $Iso)) { if ($p.Contains("'")) { Die "path must not contain a quote (it is passed into Python source): $p" } }
if ($Iso -cmatch '[^\x20-\x7E]') { Say "warning: ISO path is not ASCII; ps2run reads it with narrow-char file APIs (untested): $Iso" }
Say ("== Lifeline install{0}: root={1} iso={2} kit={3} src={4}" -f ($(if ($DryRun) { ' (dry run)' } else { '' })), $Root, $Iso, $Kit, $Src)

# --- the game must be closed (never stopped by us) ----------------------------------------
$running = @(Get-Process -Name 'ps2run' -ErrorAction SilentlyContinue)
if ($running.Count -gt 0) { Die ("ps2run is running (pid {0}); close the game and run the install again. Nothing was changed." -f (($running | ForEach-Object { $_.Id }) -join ',')) 2 }

# --- your ISO: size + sha256 before use ------------------------------------------------
if (-not (Test-Path -LiteralPath $Iso -PathType Leaf)) { Die "ISO not found: $Iso" 3 }
$isoLen = (Get-Item -LiteralPath $Iso).Length
if ($isoLen -ne $ISO_SIZE) { Die "ISO size $isoLen does not match the expected $ISO_SIZE bytes; refusing to use it" 3 }
Say '  checking ISO sha256 (reads the whole file) ...'
$isoSha = Sha256 $Iso
if ($isoSha -ne $ISO_SHA256) { Die "ISO sha256 $isoSha does not match the expected $ISO_SHA256; refusing to use it" 3 }
Say "  ISO ok: $isoLen bytes, sha256 $isoSha"

if (-not $DryRun) {
    foreach ($d in @($Root, (Join-Path $Root 'logs'), (Join-Path $Root 'saves'))) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    $script:LOG = Join-Path (Join-Path $Root 'logs') ('install-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
}

# --- Step 0: back up the user's own alias fixes; restored byte for byte whatever happens ------
$ASSETS = Join-Path $Root 'voice-assets'
$LOCAL  = Join-Path $ASSETS 'aliases.local.tsv'
$KEEP = $null; if (Test-Path -LiteralPath $LOCAL -PathType Leaf) { $KEEP = [IO.File]::ReadAllBytes($LOCAL); Say ("  backed up aliases.local.tsv ({0} bytes)" -f $KEEP.Length) }
function Same-Bytes([byte[]]$a, [byte[]]$b) {
    if ($a.Length -ne $b.Length) { return $false }
    for ($i = 0; $i -lt $a.Length; $i++) { if ($a[$i] -ne $b[$i]) { return $false } }
    return $true
}
$ALIASES_OK = $false
try {
    $VOSK = Join-Path $Root 'vosk'; $VOSKLIB = Join-Path $VOSK 'vosk'; $MODELDIR = Join-Path $VOSK $MODEL
    # --- Step 1: Vosk library (all four DLLs together, only if any is missing) ----------------
    if ($SkipVosk) { Say '== vosk: skipped (-SkipVosk)' } else {
        $missing = @($DLLS.Keys | Where-Object { -not (Test-Path -LiteralPath (Join-Path $VOSKLIB $_) -PathType Leaf) })
        if ($missing.Count -eq 0) {
            Say '== vosk: library present'
            foreach ($n in $DLLS.Keys) { if ((Sha256 (Join-Path $VOSKLIB $n)) -ne $DLLS[$n]) { Say "  warning: $n differs from the pinned $VOSK_VER build; delete $VOSKLIB and install again to replace all four" } }
        } else {
            Say ("== vosk: missing {0}; writing all four DLLs from {1}" -f ($missing -join ', '), $WHEEL)
            $whl = Join-Path $VOSK $WHEEL
            if ($DryRun) { Plan "fetch $WHEEL_URL (sha256 $WHEEL_SHA) and extract $($DLLS.Keys -join ', ') into $VOSKLIB" } else {
                New-Item -ItemType Directory -Force -Path $VOSK | Out-Null
                Need-Space $VOSK 40
                if ($WheelPath) { Use-Local $WheelPath $WHEEL_SHA 'wheel'; $whl = FullPath $WheelPath } else { Fetch $WHEEL_URL $whl $WHEEL_SHA }
                $stage = Join-Path $VOSK '.stage-dll'
                if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
                New-Item -ItemType Directory -Force -Path $stage | Out-Null
                try {
                    $z = [IO.Compression.ZipFile]::OpenRead($whl)
                    try {
                        foreach ($n in $DLLS.Keys) {
                            $e = $z.GetEntry("vosk/$n"); if ($null -eq $e) { Die "wheel has no vosk/$n" }
                            [IO.Compression.ZipFileExtensions]::ExtractToFile($e, (Join-Path $stage $n), $true)
                        }
                    } finally { $z.Dispose() }
                    foreach ($n in $DLLS.Keys) { $got = Sha256 (Join-Path $stage $n); if ($got -ne $DLLS[$n]) { Die "sha256 mismatch for extracted ${n}: $got" } }
                    New-Item -ItemType Directory -Force -Path $VOSKLIB | Out-Null
                    foreach ($n in $DLLS.Keys) { Move-Item -LiteralPath (Join-Path $stage $n) -Destination (Join-Path $VOSKLIB $n) -Force }
                } finally { if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force } }
                foreach ($n in $DLLS.Keys) { if ((Sha256 (Join-Path $VOSKLIB $n)) -ne $DLLS[$n]) { Die "verify failed: $(Join-Path $VOSKLIB $n)" } }
                Say "  wrote and verified 4 DLLs in $VOSKLIB"
            }
        }
        # --- Step 2: Vosk model (only if missing) --------------------------------------------
        if (Test-Path -LiteralPath $MODELDIR -PathType Container) { Say "== model: $MODEL present" } else {
            Say "== model: $MODEL missing"
            if ($DryRun) { Plan "fetch $MODEL_URL (sha256 $MODEL_SHA) and unpack it into $MODELDIR" } else {
                New-Item -ItemType Directory -Force -Path $VOSK | Out-Null
                Need-Space $VOSK 200
                $mz = Join-Path $VOSK "$MODEL.zip"
                if ($ModelZipPath) { Use-Local $ModelZipPath $MODEL_SHA 'model zip'; $mz = FullPath $ModelZipPath } else { Fetch $MODEL_URL $mz $MODEL_SHA }
                $stage = Join-Path $VOSK ".unpack-$MODEL"
                if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
                New-Item -ItemType Directory -Force -Path $stage | Out-Null
                try {
                    $base = (FullPath $stage).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
                    $z = [IO.Compression.ZipFile]::OpenRead($mz); $nfiles = 0
                    try {
                        foreach ($e in $z.Entries) {
                            $dest = FullPath (Join-Path $stage $e.FullName)
                            if (-not $dest.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) { Die "unsafe path in model zip: $($e.FullName)" }
                            if ($e.FullName.EndsWith('/')) { New-Item -ItemType Directory -Force -Path $dest | Out-Null; continue }
                            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
                            [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $dest, $true)
                            if ((Get-Item -LiteralPath $dest).Length -ne $e.Length) { Die "verify failed (size): $($e.FullName)" }
                            $nfiles++
                        }
                    } finally { $z.Dispose() }
                    $unpacked = Join-Path $stage $MODEL
                    if (-not (Test-Path -LiteralPath $unpacked -PathType Container)) { Die "model zip has no $MODEL/ folder" }
                    Move-Item -LiteralPath $unpacked -Destination $MODELDIR
                } finally { if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force } }
                Say "  unpacked and size-checked $nfiles files into $MODELDIR"
            }
        }
    }

    # --- Step 3: voice assets from YOUR ISO (only if voice-assets is missing or empty) ----------
    if (-not (Is-Empty-Dir $ASSETS)) { Say '== voice assets: present (kept)' } else {
        Say '== voice assets: extracting from your ISO'
        $disc = Join-Path (Join-Path $Src 'scripts') 'disc.py'
        $tools = Join-Path (Join-Path $Kit 'voice') 'tools'
        $meta = Join-Path $Root 'iso-meta'
        $stage = Join-Path $Root 'voice-assets.partial'
        if ($DryRun) {
            Plan "run disc.py extract (ISO path passed directly) -> $(Join-Path $meta 'OS.FAT'), then the arcx/fat wrapper -> $ASSETS (forward-slash paths)"
        } else {
            if (-not (Test-Path -LiteralPath $disc -PathType Leaf)) { Die "upstream disc.py not found: $disc (pass -Src)" }
            foreach ($t in @('arcx.py', 'fat.py')) { if (-not (Test-Path -LiteralPath (Join-Path $tools $t) -PathType Leaf)) { Die "missing $(Join-Path $tools $t) (pass -Kit)" } }
            $rc = Py '-I' (Fwd $disc) 'extract' (Fwd $Iso) (Fwd $meta) 'OS.FAT'
            if ($rc -ne 0) { Die "disc.py failed (exit $rc)" }
            $fat = Join-Path $meta 'OS.FAT'
            if (-not (Test-Path -LiteralPath $fat -PathType Leaf)) { Die "disc.py did not write $fat" }
            if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }   # our own leftover from an interrupted run
            # Same wrapper as steam-machine/build.sh:157-168 (the three dev-box paths baked into arcx.py/fat.py are
            # swapped for this machine's). Every path is passed with forward slashes so no backslash lands in Python source.
            $wrapper = @'
import os, sys
tools, fat, iso, out = sys.argv[1:]
src = open(os.path.join(tools, 'arcx.py')).read()
fatsrc = open(os.path.join(tools, 'fat.py')).read().split('for e in ents')[0]
src = src.replace("exec(open(os.path.join(os.path.dirname(__file__),'fat.py')).read().split('for e in ents')[0])", 'exec(FATSRC)')
fatsrc = fatsrc.replace('<repo-root>/private/iso/OS.FAT', fat)
src = src.replace('<repo-root>/dump/Life Line (USA).iso', iso).replace('<repo-root>/private/asr_files', out)
g = {'__file__': os.path.join(tools, 'arcx.py'), '__name__': '__main__', 'FATSRC': fatsrc}
import contextlib, io
with contextlib.redirect_stdout(io.StringIO()):
    exec(compile(src, 'arcx.py', 'exec'), g)
print('voice assets:', len(os.listdir(out)), 'folders')
'@
            $wf = [IO.Path]::GetTempFileName()
            try {
                [IO.File]::WriteAllText($wf, $wrapper, (New-Object System.Text.ASCIIEncoding))
                $rc = Py (Fwd $wf) (Fwd $tools) (Fwd $fat) (Fwd $Iso) (Fwd $stage)
            } finally { Remove-Item -LiteralPath $wf -Force -ErrorAction SilentlyContinue }
            if ($rc -ne 0) { Die "voice asset extraction failed (exit $rc); $stage left for inspection" }
            if (Is-Empty-Dir $stage) { Die "voice asset extraction wrote nothing" }
            if (Test-Path -LiteralPath $ASSETS) { Remove-Item -LiteralPath $ASSETS -Force -Recurse }   # it is empty (checked above)
            Move-Item -LiteralPath $stage -Destination $ASSETS
            Say ("  voice assets: {0} folders (compare with the Steam Machine install)" -f @(Get-ChildItem -LiteralPath $ASSETS -Directory).Count)
        }
    }

    # --- Step 4: spoken-form aliases, every install; a failure is not fatal ----------------------
    Say '== aliases: rebuilding aliases.tsv / aliases.unresolved.txt'
    $ba = Join-Path (Join-Path (Join-Path $Kit 'voice') 'tools') 'build_aliases.py'
    if ($DryRun) { Plan "run $PyExe $PyArgs $ba --assets $ASSETS --model $MODELDIR (non-fatal)" } else {
        try { $rc = Py $ba '--assets' $ASSETS '--model' $MODELDIR } catch { $rc = "error: $($_.Exception.Message)" }
        if ($rc -eq 0) { $ALIASES_OK = $true } else { Say "  aliases step failed ($rc); game still playable" }
    }

    # --- Step 5: launch config + run.ps1 + shipped icon packs -------------------------------------
    # lifeline.env.json is build.ps1's file: keep its keys (SRC, PS2RUN, ELF, ...), set ours, write it back.
    $envf = Join-Path $Root 'lifeline.env.json'
    $set = [ordered]@{
        'ISO' = $Iso; 'VOSK_DIR' = $VOSK
        'PS2_VOICE_VOSK_MODEL' = $MODELDIR; 'PS2_VOICE_VOSK_LIB' = (Join-Path $VOSKLIB 'libvosk.dll'); 'PS2_VOICE_ASSETS' = $ASSETS
    }
    $kv = [ordered]@{}
    if (Test-Path -LiteralPath $envf -PathType Leaf) {
        $j = [IO.File]::ReadAllText($envf) | ConvertFrom-Json
        foreach ($pr in $j.PSObject.Properties) { $kv[$pr.Name] = $pr.Value }
    }
    foreach ($k in $set.Keys) { $kv[$k] = $set[$k] }
    if (-not $kv.Contains('MEMCARD')) { $kv['MEMCARD'] = Join-Path (Join-Path $Root 'saves') 'lifeline.ps2' }
    $text = (New-Object PSObject -Property $kv | ConvertTo-Json) + "`r`n"
    $runSrc = Join-Path (Join-Path $Kit 'windows') 'run.ps1'; $runDst = Join-Path $Root 'run.ps1'
    $packs = Join-Path (Join-Path $Kit 'icons') 'packs'
    if ($DryRun) {
        Plan "merge into $envf : $(($set.Keys) -join ', ') (build.ps1 keys kept)"
        Plan "copy $runSrc -> $runDst"
        Plan "replace $(Join-Path $Root 'icons') with $packs (icons.local is never touched)"
    } else {
        $tmp = "$envf.tmp"; [IO.File]::WriteAllText($tmp, $text, (New-Object System.Text.UTF8Encoding($false))); Move-Item -LiteralPath $tmp -Destination $envf -Force
        $back = [IO.File]::ReadAllText($envf) | ConvertFrom-Json
        foreach ($k in $kv.Keys) { if ([string]$back.$k -cne [string]$kv[$k]) { Die "verify failed: $envf ($k)" } }
        Say "  wrote $envf"
        if (Test-Path -LiteralPath $runSrc -PathType Leaf) {
            Copy-Item -LiteralPath $runSrc -Destination $runDst -Force
            if ((Sha256 $runSrc) -ne (Sha256 $runDst)) { Die "verify failed: $runDst" }
            Say "  installed run.ps1"
        } else { Say "  warning: $runSrc not found; run.ps1 not installed" }
        if (Test-Path -LiteralPath $packs -PathType Container) {
            $new = Join-Path $Root 'icons.new'; $cur = Join-Path $Root 'icons'
            if (Test-Path -LiteralPath $new) { Remove-Item -LiteralPath $new -Recurse -Force }
            Copy-Item -LiteralPath $packs -Destination $new -Recurse
            if (Test-Path -LiteralPath $cur) { Remove-Item -LiteralPath $cur -Recurse -Force }
            Move-Item -LiteralPath $new -Destination $cur
            Say '  installed shipped icon packs'
        }
    }
} finally {
    # never lose the user's own alias fixes, whatever happened above (lifeline_launcher.py:276-279)
    if ($null -ne $KEEP -and -not $DryRun) {
        $now = $null; if (Test-Path -LiteralPath $LOCAL -PathType Leaf) { $now = [IO.File]::ReadAllBytes($LOCAL) }
        if ($null -eq $now -or -not (Same-Bytes $now $KEEP)) {
            New-Item -ItemType Directory -Force -Path $ASSETS | Out-Null
            $tmp = "$LOCAL.tmp"; [IO.File]::WriteAllBytes($tmp, $KEEP); Move-Item -LiteralPath $tmp -Destination $LOCAL -Force
            Say '  restored aliases.local.tsv'
        }
        if (-not (Same-Bytes ([IO.File]::ReadAllBytes($LOCAL)) $KEEP)) { Say 'ERROR: aliases.local.tsv could not be restored byte for byte'; exit 1 }
    }
}
if ($DryRun) { Say '== dry run done: nothing was written' }
elseif ($ALIASES_OK) { Say '== install done' } else { Say '== install done (aliases step failed; game still playable)' }
exit 0
