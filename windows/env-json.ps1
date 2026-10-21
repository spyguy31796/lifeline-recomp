# Lifeline Recomp: lifeline.env.json read/merge/write (dot-sourced by build.ps1; tested by tests/test_env_json.ps1).
# The file is shared: build.ps1 owns some keys, other tools (e.g. install.ps1: ISO, VOSK_DIR) own others.
#   Merge-LifelineEnv -Path <file> -Owned @{...} [-Defaults @{...}]
#     Owned keys are always written; Defaults only when the key is missing; every other key is kept as is.
#     Keys match case-insensitively; an Owned/Defaults key found in another case (e.g. "iso") is renamed to
#     the canonical name given here (ISO).
#     A file that is not a JSON object (unreadable, invalid, array, empty) is moved to
#     <file>.bad-<yyyyMMdd-HHmmss-fff>[-N] and the merge starts from nothing.
#     The write is atomic: a temp file in the same directory, then File.Replace (or File.Move when there is
#     no file yet); UTF-8 without BOM. Returns the merged keys as an ordered, case-insensitive dictionary.
function Merge-LifelineEnv {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][hashtable]$Owned, [hashtable]$Defaults = @{})
    $Path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)   # full path for [IO.File]
    $canon = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($k in @($Defaults.Keys) + @($Owned.Keys)) { $canon[[string]$k] = [string]$k }
    $vals = New-Object System.Collections.Specialized.OrderedDictionary ([StringComparer]::OrdinalIgnoreCase)
    if ([IO.File]::Exists($Path)) {
        $obj = $null
        # must be a JSON object; checking the text too, since Windows PowerShell 5.1 unrolls '[{...}]' to its object
        try { $text = [IO.File]::ReadAllText($Path); if ($text.TrimStart([char]0xFEFF, ' ', "`t", "`r", "`n").StartsWith('{')) { $obj = $text.TrimStart([char]0xFEFF) | ConvertFrom-Json -ErrorAction Stop } } catch { $obj = $null }
        if ($obj -is [System.Management.Automation.PSCustomObject]) {
            foreach ($p in $obj.PSObject.Properties) {
                $name = if ($canon.ContainsKey($p.Name)) { $canon[$p.Name] } else { $p.Name }
                if (-not $vals.Contains($name)) { $vals[$name] = $p.Value }
            }
        } else {
            $bad = "$Path.bad-$(Get-Date -Format yyyyMMdd-HHmmss-fff)"
            $n = 0; $try = $bad; while (Test-Path -LiteralPath $try) { $n++; $try = "$bad-$n" }; $bad = $try
            Move-Item -LiteralPath $Path -Destination $bad
            Write-Host "warning: $Path was not a JSON object; moved to $bad and starting fresh"
        }
    }
    foreach ($k in ($Defaults.Keys | Sort-Object)) { if (-not $vals.Contains($k)) { $vals[$k] = $Defaults[$k] } }
    foreach ($k in ($Owned.Keys | Sort-Object)) { $vals[$k] = $Owned[$k] }
    $tmp = "$Path.tmp"   # same directory, so same volume: Replace/Move is a rename
    try {
        [IO.File]::WriteAllText($tmp, ($vals | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding $false))
        # [NullString]::Value: a plain $null would reach .NET as "" (no backup file wanted)
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($tmp, $Path, [NullString]::Value) } else { [IO.File]::Move($tmp, $Path) }
    } finally { if ([IO.File]::Exists($tmp)) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } }
    return $vals
}
