# Lifeline Recomp: lifeline.env.json read/merge/write (dot-sourced by build.ps1; tested by tests/test_env_json.ps1).
# The file is shared: build.ps1 owns some keys, other tools (e.g. install.ps1: ISO, VOSK_DIR) own others.
#   Merge-LifelineEnv -Path <file> -Owned @{...} [-Defaults @{...}]
#     Owned keys are always written; Defaults only when the key is missing; every other key is kept as is.
#     A file that is not a JSON object (unreadable, invalid, array, empty) is moved to <file>.bad-<timestamp>
#     and the merge starts from nothing. The write is atomic (temp file + rename), UTF-8 without BOM.
#     Returns the merged keys as an ordered hashtable.
function Merge-LifelineEnv {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][hashtable]$Owned, [hashtable]$Defaults = @{})
    $vals = [ordered]@{}
    if (Test-Path -LiteralPath $Path) {
        $obj = $null
        # must be a JSON object; checking the text too, since Windows PowerShell 5.1 unrolls '[{...}]' to its object
        try { $text = [IO.File]::ReadAllText($Path); if ($text.TrimStart([char]0xFEFF, ' ', "`t", "`r", "`n").StartsWith('{')) { $obj = $text.TrimStart([char]0xFEFF) | ConvertFrom-Json -ErrorAction Stop } } catch { $obj = $null }
        if ($obj -is [System.Management.Automation.PSCustomObject]) {
            foreach ($p in $obj.PSObject.Properties) { $vals[$p.Name] = $p.Value }
        } else {
            $bad = "$Path.bad-$(Get-Date -Format yyyyMMdd-HHmmss)"
            Move-Item -LiteralPath $Path -Destination $bad -Force
            Write-Host "warning: $Path was not a JSON object; moved to $bad and starting fresh"
        }
    }
    foreach ($k in ($Defaults.Keys | Sort-Object)) { if (-not $vals.Contains($k)) { $vals[$k] = $Defaults[$k] } }
    foreach ($k in ($Owned.Keys | Sort-Object)) { $vals[$k] = $Owned[$k] }
    $tmp = "$Path.tmp"
    [IO.File]::WriteAllText($tmp, ($vals | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding $false))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
    return $vals
}
