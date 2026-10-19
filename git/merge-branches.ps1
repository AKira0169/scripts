<#
.SYNOPSIS
  Merge a source branch (default: main) into a target branch (default: dev) across
  the UnifiedPlatform repos, after verifying each repo is clean and up to date.

.DESCRIPTION
  Workspace-wide copy of bg.unified.fe.common\scripts\merge-workspace-branches.ps1, kept in
  the umbrella's scripts\git\. It operates on every repo in the workspace root (see .NOTES).

  main/master: backends use 'master', frontends use 'main'. The two are treated as ONE
  branch: the picker shows "main/master", and each repo merges whichever it has. So
  "main -> uat" merges master -> uat in the backends and main -> uat in the frontends.
  Auto-discovers git repos under the root that actually have BOTH the source and
  target branches (locally or on origin). Repos missing the target branch (e.g.
  bg.unified.fe.common has no 'dev') are listed as ineligible and skipped.

  Flow:
    0. BRANCHES - unless -Source AND -Target are both given (or -Yes), scan every
                  candidate repo for its branches, keep the "common" ones (present in
                  2+ repos: normally main/dev/uat), and interactively ask which branch
                  to merge FROM (source) and INTO (target). Each is shown with a repo
                  count, e.g. "main (7 repos)". Explicit -Source/-Target bypass this
                  and accept ANY branch, including single-repo feature branches.
    1. SELECT   - interactive numbered menu (or -Repos) to choose which repos to merge.
    2. PREFLIGHT- git fetch --prune; report each repo's working-tree state and how far
                  behind origin main/dev are. Repos that are dirty or can't fast-forward
                  are marked and SKIPPED (they are never force-updated or stashed).
    3. CONFIRM  - shows the plan; asks to proceed (skip with -Yes).
    4. MERGE    - per clean repo: ff-pull main, ff-pull dev, merge main -> dev.
                  A conflicting merge is aborted and reported (working tree left clean).
    5. PUSH     - optional. Off by default; prompts in interactive mode, or force -Push.
    6. SUMMARY  - pass/fail table. The original branch of each repo is restored.

.EXAMPLE
  ./merge-workspace-branches.ps1                # interactive: pick source/target, repos, prompt to push
  ./merge-workspace-branches.ps1 -Yes           # all eligible repos, main -> dev, no confirm, no push
  ./merge-workspace-branches.ps1 -Push -Yes     # all eligible, merge AND push, no prompts
  ./merge-workspace-branches.ps1 -Repos bg.unified.fe.core,bg.unified.fe.permits
  ./merge-workspace-branches.ps1 -Source main -Target uat -Push   # explicit branches skip the picker
  ./merge-workspace-branches.ps1 -FetchBranches # fetch --prune every repo before listing branches
  ./merge-workspace-branches.ps1 -Root C:\path\to\UnifiedPlatform

.NOTES
  The workspace root is found dynamically by walking up from this script until a
  folder holding bg.unified.fe.core (or a *.code-workspace file) is found, so the
  script's own folder name and depth don't matter. Override with -Root <path> or the
  UNIFIED_ROOT env var if auto-detection guesses wrong. Uses $LASTEXITCODE for all
  git checks (never $?), and restores the starting branch of every repo it touches.

  Branch discovery reads each repo's EXISTING refs (local heads + origin/*); it does
  not fetch unless you pass -FetchBranches, so a brand-new remote branch may not show
  up until you fetch. The per-repo preflight step still fetches the selected repos.
#>
param(
    [string[]]$Repos,
    [string]$Source = 'main',
    [string]$Target = 'dev',
    [switch]$Push,
    [switch]$Yes,
    [switch]$FetchBranches,
    [string]$Root
)

# NOTE: do NOT set $ErrorActionPreference='Stop'. git writes normal progress
# (e.g. "From https://...") to stderr; under 'Stop' + 2>&1 PowerShell 5.1 wraps
# that as a terminating NativeCommandError and aborts even on a successful git.
# The merge loop uses explicit throw + try/catch, which terminate regardless.
$ErrorActionPreference = 'Continue'

# --- locate this script robustly ---------------------------------------------
$scriptDir = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $scriptDir) { $scriptDir = (Get-Location).Path }

# A directory is the workspace root if it holds the host repo or a *.code-workspace.
function Test-WorkspaceRoot([string]$d) {
    if (Test-Path (Join-Path $d 'bg.unified.fe.core') -PathType Container) { return $true }
    if (Get-ChildItem -Path $d -Filter '*.code-workspace' -File -ErrorAction SilentlyContinue |
            Select-Object -First 1) { return $true }
    return $false
}

# Walk up from the script dir, then the CWD, to find the workspace root.
function Find-WorkspaceRoot([string]$startDir) {
    foreach ($start in @($startDir, (Get-Location).Path)) {
        $d = $start
        while ($d) {
            if (Test-WorkspaceRoot $d) { return $d }
            $parent = Split-Path $d -Parent
            if (-not $parent -or $parent -eq $d) { break }   # reached filesystem root
            $d = $parent
        }
    }
    return $null
}

# --- resolve workspace root (dynamic; folder name/location independent) ------
if ($Root) {
    $root = $Root
} elseif ($env:UNIFIED_ROOT) {
    $root = $env:UNIFIED_ROOT
} else {
    $root = Find-WorkspaceRoot $scriptDir
}
if (-not $root -or -not (Test-Path $root -PathType Container)) {
    Write-Host "ERROR: workspace root not found: '$root'" -ForegroundColor Red
    Write-Host "  Pass -Root <path> or set UNIFIED_ROOT to the folder that holds the repos." -ForegroundColor Red
    exit 1
}
$root = (Resolve-Path $root).Path   # normalize to an absolute path

# --- git helpers (always drive $LASTEXITCODE, never $?) ----------------------
# Capture output + exit code; nothing streamed.
function Git-Cap([string]$dir, [string[]]$gitArgs) {
    Push-Location $dir
    $eap = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'   # keep git's stderr from becoming a terminating error
    try {
        $out  = & git @gitArgs 2>&1               # merge stderr so it's captured, not thrown
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $eap
        Pop-Location
    }
    return [pscustomobject]@{ Code = $code; Out = ($out | Out-String).Trim() }
}

# Run and stream output to the console (for pull/merge/push progress).
# IMPORTANT: pipe stdout through Out-Host so git's output is DISPLAYED but never
# leaks into the function's return value. Returning `& git` output would make the
# function return an array (git stdout + exit code); a caller doing `-ne 0` on that
# array then throws on a perfectly successful command. stderr is left un-redirected
# so it prints plainly to the console (not as red error records).
function Git-Run([string]$dir, [string[]]$gitArgs) {
    Push-Location $dir
    try {
        & git @gitArgs | Out-Host
        $code = $LASTEXITCODE
    } finally { Pop-Location }
    return $code
}

# 'local' | 'remote' | $null  (uses whatever refs currently exist; refine after fetch)
function Get-BranchLoc([string]$dir, [string]$branch) {
    if ((Git-Cap $dir @('rev-parse','--verify','--quiet',"refs/heads/$branch")).Code -eq 0) { return 'local' }
    if ((Git-Cap $dir @('rev-parse','--verify','--quiet',"refs/remotes/origin/$branch")).Code -eq 0) { return 'remote' }
    return $null
}

# Backends use 'master', frontends use 'main': treat the two as one branch and return
# whichever this repo actually has. Any other name must exist as-is. $null = not found.
function Resolve-RepoBranch([string]$dir, [string]$branch) {
    if (Get-BranchLoc $dir $branch) { return $branch }
    $alias = @{ main = 'master'; master = 'main' }[$branch]
    if ($alias -and (Get-BranchLoc $dir $alias)) { return $alias }
    return $null
}

# Picker label: show the main/master pair as one entry.
function Format-BranchName([string]$b) { if ($b -eq 'main') { 'main/master' } else { $b } }

function Get-CurrentBranch([string]$dir) {
    (Git-Cap $dir @('rev-parse','--abbrev-ref','HEAD')).Out
}

function Test-Clean([string]$dir) {
    $r = Git-Cap $dir @('status','--porcelain')
    return ($r.Code -eq 0 -and [string]::IsNullOrWhiteSpace($r.Out))
}

# commits that <ref2> has and <ref1> does not (i.e. how far ref1 is BEHIND ref2)
function Count-Behind([string]$dir, [string]$ref1, [string]$ref2) {
    $r = Git-Cap $dir @('rev-list','--count',"$ref1..$ref2")
    if ($r.Code -ne 0) { return -1 }
    return [int]$r.Out
}

# All branch names known to a repo: local heads + origin/* remote-tracking, with the
# 'origin/' prefix stripped and duplicates removed. Returns a List[string] (may be empty).
function Get-RepoBranches([string]$dir) {
    $names = New-Object System.Collections.Generic.List[string]
    $r = Git-Cap $dir @('for-each-ref','--format=%(refname:short)','refs/heads','refs/remotes/origin')
    if ($r.Code -ne 0) { return $names }
    foreach ($line in ($r.Out -split "`n")) {
        $b = $line.Trim()
        if (-not $b) { continue }
        if ($b -like 'origin/*') { $b = $b.Substring(7) }   # origin/dev -> dev
        if ($b -eq 'origin' -or $b -eq 'HEAD') { continue }  # origin/HEAD symref
        if ($b -eq 'master') { $b = 'main' }                  # count main/master as one branch
        if (-not $names.Contains($b)) { [void]$names.Add($b) }
    }
    return $names
}

# Interactive single-select picker: arrow / j-k to move, enter to confirm, esc to cancel.
# Returns pscustomobject: Status = 'OK' (with .Index, 0-based) | 'CANCEL' | 'UNSUPPORTED'.
function Show-RadioMenu {
    param(
        [string[]]$Items,
        [string]$Title = 'Select one',
        [int]$Default = 0
    )
    $count = $Items.Count
    if ($count -eq 0) { return [pscustomobject]@{ Status = 'OK'; Index = -1 } }

    # Fall back to typed selection if the console can't do raw key input.
    $canRaw = $true
    try {
        if ([System.Console]::IsInputRedirected) { $canRaw = $false }
        $null = [System.Console]::WindowWidth
    } catch { $canRaw = $false }
    if (-not $canRaw) { return [pscustomobject]@{ Status = 'UNSUPPORTED' } }

    $cursor = if ($Default -ge 0 -and $Default -lt $count) { $Default } else { 0 }
    $lines  = $count + 2            # title + hint + items

    # Reserve the region so drawing never scrolls mid-render, then park at its top.
    for ($i = 0; $i -lt $lines; $i++) { Write-Host "" }
    $top = [System.Console]::CursorTop - $lines
    if ($top -lt 0) { $top = 0 }

    $prevVisible = $true
    try { $prevVisible = [System.Console]::CursorVisible } catch {}
    try { [System.Console]::CursorVisible = $false } catch {}

    try {
        $width = 80
        try { $width = [System.Console]::WindowWidth } catch {}
        $pad = [Math]::Max(20, $width - 1)

        $result = $null
        while ($true) {
            [System.Console]::SetCursorPosition(0, $top)
            Write-Host ($Title.PadRight($pad)) -ForegroundColor Cyan
            Write-Host ("  up/down move   enter select   esc cancel".PadRight($pad)) -ForegroundColor DarkGray
            for ($i = 0; $i -lt $count; $i++) {
                $dot  = if ($i -eq $cursor) { '(o)' } else { '( )' }
                $ptr  = if ($i -eq $cursor) { '>' } else { ' ' }
                $line = (" $ptr $dot $($Items[$i])").PadRight($pad)
                if ($line.Length -gt $pad) { $line = $line.Substring(0, $pad) }
                if ($i -eq $cursor) { Write-Host $line -ForegroundColor Yellow }
                else                { Write-Host $line -ForegroundColor Gray }
            }

            $key = [System.Console]::ReadKey($true)
            $k = $key.Key; $ch = $key.KeyChar
            if     ($k -eq 'UpArrow'   -or $ch -eq 'k') { $cursor = ($cursor - 1 + $count) % $count }
            elseif ($k -eq 'DownArrow' -or $ch -eq 'j') { $cursor = ($cursor + 1) % $count }
            elseif ($k -eq 'Enter') {
                $result = [pscustomobject]@{ Status = 'OK'; Index = $cursor }
                break
            }
            elseif ($k -eq 'Escape' -or $ch -eq 'q') {
                $result = [pscustomobject]@{ Status = 'CANCEL' }
                break
            }
        }
        [System.Console]::SetCursorPosition(0, $top + $lines)
        return $result
    } finally {
        try { [System.Console]::CursorVisible = $prevVisible } catch {}
    }
}

# --- discover candidate repos ------------------------------------------------
# A candidate is any immediate subfolder of $root that is a git repo.
$allRepos = Get-ChildItem -Path $root -Directory -ErrorAction SilentlyContinue |
    Where-Object { Test-Path (Join-Path $_.FullName '.git') } |
    Select-Object -ExpandProperty FullName

if ($Repos) {
    # honor an explicit list (validated against $root)
    $allRepos = $Repos | ForEach-Object {
        $p = if (Test-Path $_ -PathType Container) { (Resolve-Path $_).Path } else { Join-Path $root $_ }
        $p
    }
}

# --- choose source/target branches from the "common" set ---------------------
# "Common" = a branch that exists (locally or on origin) in 2+ candidate repos, so
# normally main/dev/uat; per-repo feature branches don't qualify. This picker is
# skipped when -Yes is set or when BOTH -Source and -Target are passed explicitly
# (an explicit branch may be a single-repo one — that still flows through unchanged).
$srcExplicit = $PSBoundParameters.ContainsKey('Source')
$tgtExplicit = $PSBoundParameters.ContainsKey('Target')
$promptBranches = (-not $Yes) -and -not ($srcExplicit -and $tgtExplicit)

if ($promptBranches) {
    if ($FetchBranches) {
        Write-Host "Fetching candidate repos for branch discovery ..." -ForegroundColor DarkGray
        foreach ($d in $allRepos) { Git-Cap $d @('fetch','--prune','origin') | Out-Null }
    }

    # branch name -> list of repo names that have it (across ALL candidate repos)
    $branchRepos = @{}
    foreach ($d in $allRepos) {
        $rn = Split-Path $d -Leaf
        foreach ($b in (Get-RepoBranches $d)) {
            if (-not $branchRepos.ContainsKey($b)) {
                $branchRepos[$b] = New-Object System.Collections.Generic.List[string]
            }
            if (-not $branchRepos[$b].Contains($rn)) { [void]$branchRepos[$b].Add($rn) }
        }
    }
    # keep the shared ones; most-widely-shared first, then alphabetical
    $common = @($branchRepos.GetEnumerator() |
        Where-Object { $_.Value.Count -ge 2 } |
        Sort-Object @{ Expression = { $_.Value.Count }; Descending = $true },
                    @{ Expression = { $_.Key };         Descending = $false })

    if ($common.Count -lt 2) {
        Write-Host "  (fewer than 2 common branches found; using $Source -> $Target)" -ForegroundColor DarkGray
    } else {
        $names  = @($common | ForEach-Object { $_.Key })
        $labels = @($common | ForEach-Object { "{0}  ({1} repo{2})" -f (Format-BranchName $_.Key), $_.Value.Count, $(if ($_.Value.Count -ne 1) { 's' } else { '' }) })

        Write-Host ""
        # --- source ("from") --------------------------------------------------
        $defSrc = [Array]::IndexOf([string[]]$names, $Source); if ($defSrc -lt 0) { $defSrc = 0 }
        $rm = Show-RadioMenu -Items $labels -Title "Merge FROM  (source branch):" -Default $defSrc
        if ($rm.Status -eq 'CANCEL') { Write-Host "Aborted." -ForegroundColor Yellow; exit 0 }
        elseif ($rm.Status -eq 'UNSUPPORTED') {
            Write-Host "Common branches:" -ForegroundColor Cyan
            for ($i = 0; $i -lt $names.Count; $i++) { Write-Host ("  [{0}] {1}" -f ($i + 1), $labels[$i]) }
            $pick = $null
            while ($null -eq $pick) {
                $a = Read-Host "Merge FROM (source) #"
                if ($a -match '^\d+$' -and [int]$a -ge 1 -and [int]$a -le $names.Count) { $pick = [int]$a - 1 }
                else { Write-Host "  invalid, try again." -ForegroundColor Yellow }
            }
            $Source = $names[$pick]
        } else {
            $Source = $names[$rm.Index]
        }

        # --- target ("into") — exclude the chosen source; map back by NAME -----
        $tgtRows   = @($common | Where-Object { $_.Key -ne $Source })
        $tgtNames  = @($tgtRows | ForEach-Object { $_.Key })
        $tgtLabels = @($tgtRows | ForEach-Object { "{0}  ({1} repo{2})" -f (Format-BranchName $_.Key), $_.Value.Count, $(if ($_.Value.Count -ne 1) { 's' } else { '' }) })
        if ($tgtNames.Count -eq 0) {
            Write-Host "No other common branch to merge into. Aborted." -ForegroundColor Yellow; exit 0
        }
        Write-Host ""
        $defTgt = [Array]::IndexOf([string[]]$tgtNames, $Target); if ($defTgt -lt 0) { $defTgt = 0 }
        $rm = Show-RadioMenu -Items $tgtLabels -Title "Merge INTO  (target branch), from '$Source':" -Default $defTgt
        if ($rm.Status -eq 'CANCEL') { Write-Host "Aborted." -ForegroundColor Yellow; exit 0 }
        elseif ($rm.Status -eq 'UNSUPPORTED') {
            for ($i = 0; $i -lt $tgtNames.Count; $i++) { Write-Host ("  [{0}] {1}" -f ($i + 1), $tgtLabels[$i]) }
            $pick = $null
            while ($null -eq $pick) {
                $a = Read-Host "Merge INTO (target) #"
                if ($a -match '^\d+$' -and [int]$a -ge 1 -and [int]$a -le $tgtNames.Count) { $pick = [int]$a - 1 }
                else { Write-Host "  invalid, try again." -ForegroundColor Yellow }
            }
            $Target = $tgtNames[$pick]
        } else {
            $Target = $tgtNames[$rm.Index]
        }

        Write-Host ("Merging  {0}  ->  {1}" -f $Source, $Target) -ForegroundColor Green
    }
}

# Classify: eligible needs BOTH source and target reachable; else ineligible.
$eligible   = @()
$ineligible = @()
foreach ($dir in $allRepos) {
    $name = Split-Path $dir -Leaf
    if (-not (Test-Path (Join-Path $dir '.git'))) {
        $ineligible += [pscustomobject]@{ Name = $name; Dir = $dir; Reason = 'not a git repo' }
        continue
    }
    $src = Resolve-RepoBranch $dir $Source
    $tgt = Resolve-RepoBranch $dir $Target
    if (-not $src) {
        $ineligible += [pscustomobject]@{ Name = $name; Dir = $dir; Reason = "no '$Source' branch" }
    } elseif (-not $tgt) {
        $ineligible += [pscustomobject]@{ Name = $name; Dir = $dir; Reason = "no '$Target' branch" }
    } elseif ($src -eq $tgt) {
        $ineligible += [pscustomobject]@{ Name = $name; Dir = $dir; Reason = "source and target are both '$src'" }
    } else {
        $eligible += [pscustomobject]@{ Name = $name; Dir = $dir; Current = (Get-CurrentBranch $dir); Src = $src; Tgt = $tgt }
    }
}

Write-Host ""
Write-Host "== Merge $Source -> $Target ==" -ForegroundColor Cyan
Write-Host "  root : $root" -ForegroundColor DarkGray

if (-not $eligible) {
    Write-Host "No eligible repos (need both '$Source' and '$Target' branches)." -ForegroundColor Red
    if ($ineligible) { $ineligible | ForEach-Object { Write-Host "  - $($_.Name): $($_.Reason)" -ForegroundColor DarkGray } }
    exit 1
}

# --- selection ---------------------------------------------------------------
# Parse things like: "all", "1,3,5", "1-4", "2,4-6" -> array of 1-based indexes.
function Parse-Selection([string]$text, [int]$max) {
    if ([string]::IsNullOrWhiteSpace($text)) { return 1..$max }              # blank = all
    if ($text.Trim() -match '^(a|all)$') { return 1..$max }
    $picked = New-Object System.Collections.Generic.List[int]
    foreach ($tok in ($text -split '[,\s]+')) {
        $t = $tok.Trim()
        if (-not $t) { continue }
        if ($t -match '^(\d+)\s*-\s*(\d+)$') {
            $a = [int]$Matches[1]; $b = [int]$Matches[2]
            if ($a -gt $b) { $tmp = $a; $a = $b; $b = $tmp }
            for ($i = $a; $i -le $b; $i++) { if ($i -ge 1 -and $i -le $max) { $picked.Add($i) } }
        } elseif ($t -match '^\d+$') {
            $i = [int]$t
            if ($i -ge 1 -and $i -le $max) { $picked.Add($i) }
        } else {
            return $null   # invalid token
        }
    }
    return ($picked | Sort-Object -Unique)
}

# Interactive checkbox picker: arrow/j-k to move, space to toggle, a=all, enter=confirm, esc=cancel.
# Returns a pscustomobject: Status = 'OK' (with .Indices, 0-based) | 'CANCEL' | 'UNSUPPORTED'.
function Show-CheckboxMenu {
    param(
        [string[]]$Items,
        [string]$Title = 'Select items',
        [bool]$PreselectAll = $true
    )
    $count = $Items.Count
    if ($count -eq 0) { return [pscustomobject]@{ Status = 'OK'; Indices = @() } }

    # Fall back to typed selection if the console can't do raw key input.
    $canRaw = $true
    try {
        if ([System.Console]::IsInputRedirected) { $canRaw = $false }
        $null = [System.Console]::WindowWidth
    } catch { $canRaw = $false }
    if (-not $canRaw) { return [pscustomobject]@{ Status = 'UNSUPPORTED' } }

    $checked = New-Object 'bool[]' $count
    for ($i = 0; $i -lt $count; $i++) { $checked[$i] = $PreselectAll }
    $cursor = 0
    $lines  = $count + 3            # title + hint + items + trailing summary line

    # Reserve the region so drawing never scrolls mid-render, then park at its top.
    for ($i = 0; $i -lt $lines; $i++) { Write-Host "" }
    $top = [System.Console]::CursorTop - $lines
    if ($top -lt 0) { $top = 0 }

    $prevVisible = $true
    try { $prevVisible = [System.Console]::CursorVisible } catch {}
    try { [System.Console]::CursorVisible = $false } catch {}

    try {
        $width = 80
        try { $width = [System.Console]::WindowWidth } catch {}
        $pad = [Math]::Max(20, $width - 1)

        $result = $null
        while ($true) {
            [System.Console]::SetCursorPosition(0, $top)
            Write-Host ($Title.PadRight($pad)) -ForegroundColor Cyan
            Write-Host ("  up/down move   space toggle   a all/none   enter confirm   esc cancel".PadRight($pad)) -ForegroundColor DarkGray
            for ($i = 0; $i -lt $count; $i++) {
                $box  = if ($checked[$i]) { '[x]' } else { '[ ]' }
                $ptr  = if ($i -eq $cursor) { '>' } else { ' ' }
                $line = (" $ptr $box $($Items[$i])").PadRight($pad)
                if ($line.Length -gt $pad) { $line = $line.Substring(0, $pad) }
                if ($i -eq $cursor) { Write-Host $line -ForegroundColor Yellow }
                else                { Write-Host $line -ForegroundColor Gray }
            }
            $n = @(0..($count - 1) | Where-Object { $checked[$_] }).Count
            Write-Host ("  $n of $count selected".PadRight($pad)) -ForegroundColor DarkGray

            $key = [System.Console]::ReadKey($true)
            $k = $key.Key; $ch = $key.KeyChar
            if     ($k -eq 'UpArrow'   -or $ch -eq 'k') { $cursor = ($cursor - 1 + $count) % $count }
            elseif ($k -eq 'DownArrow' -or $ch -eq 'j') { $cursor = ($cursor + 1) % $count }
            elseif ($k -eq 'Spacebar') { $checked[$cursor] = -not $checked[$cursor] }
            elseif ($ch -eq 'a' -or $ch -eq 'A') {
                $anyOff = $checked -contains $false
                for ($i = 0; $i -lt $count; $i++) { $checked[$i] = $anyOff }
            }
            elseif ($k -eq 'Enter') {
                $result = [pscustomobject]@{ Status = 'OK'; Indices = @(0..($count - 1) | Where-Object { $checked[$_] }) }
                break
            }
            elseif ($k -eq 'Escape' -or $ch -eq 'q') {
                $result = [pscustomobject]@{ Status = 'CANCEL' }
                break
            }
        }
        [System.Console]::SetCursorPosition(0, $top + $lines)
        return $result
    } finally {
        try { [System.Console]::CursorVisible = $prevVisible } catch {}
    }
}

if ($Repos) {
    $selected = $eligible   # explicit list: take them all (already filtered to eligible)
} else {
    if ($ineligible) {
        Write-Host ""
        Write-Host "Ineligible (skipped):" -ForegroundColor DarkGray
        $ineligible | ForEach-Object { Write-Host ("  - {0}  ({1})" -f $_.Name, $_.Reason) -ForegroundColor DarkGray }
    }

    # Labels for the picker: repo name + the actual branch pair + current branch if not on target.
    $labels = $eligible | ForEach-Object {
        $cur = if ($_.Current -and $_.Current -ne $_.Tgt) { "  (on $($_.Current))" } else { "" }
        "$($_.Name)  [$($_.Src) -> $($_.Tgt)]$cur"
    }

    Write-Host ""
    $menu = Show-CheckboxMenu -Items $labels -Title "Select repos to merge  ($Source -> $Target):"

    if ($menu.Status -eq 'UNSUPPORTED') {
        # No raw key input (piped / non-interactive host) -> typed fallback.
        Write-Host "Eligible repos (have '$Target'):" -ForegroundColor Cyan
        for ($i = 0; $i -lt $eligible.Count; $i++) {
            Write-Host ("  [{0}] {1}" -f ($i + 1), $labels[$i])
        }
        $selected = $null
        while (-not $selected) {
            Write-Host ""
            Write-Host "Select repos  (e.g. 1 3 5  or  1,3,5  or  1-4  or  all;  blank = all)" -ForegroundColor Cyan
            $sel = Read-Host "Selection"
            $idx = Parse-Selection $sel $eligible.Count
            if ($null -eq $idx -or $idx.Count -eq 0) {
                Write-Host "  invalid selection, try again." -ForegroundColor Yellow
                continue
            }
            $selected = $idx | ForEach-Object { $eligible[$_ - 1] }
        }
    } elseif ($menu.Status -eq 'CANCEL') {
        Write-Host "Aborted." -ForegroundColor Yellow
        exit 0
    } else {
        # NOTE: use @(...).Count, not `-not $menu.Indices`. PowerShell coerces a
        # single-element array to that element in a boolean context, so selecting
        # ONLY the first repo gives Indices=@(0) and `-not @(0)` -> `-not 0` -> $true,
        # which would falsely report "No repos selected."
        if (@($menu.Indices).Count -eq 0) {
            Write-Host "No repos selected. Aborted." -ForegroundColor Yellow
            exit 0
        }
        $selected = $menu.Indices | ForEach-Object { $eligible[$_] }
        Write-Host ("Selected: {0}" -f (($selected | ForEach-Object { $_.Name }) -join ', ')) -ForegroundColor Green
    }
}

# --- preflight: fetch + report update state ----------------------------------
Write-Host ""
Write-Host "== Preflight (fetch + status) ==" -ForegroundColor Cyan
$plan = @()
foreach ($repo in $selected) {
    $dir = $repo.Dir; $name = $repo.Name; $S = $repo.Src; $T = $repo.Tgt
    Write-Host ""
    Write-Host "--- $name ---" -ForegroundColor Cyan

    $f = Git-Cap $dir @('fetch','--prune','origin')
    if ($f.Code -ne 0) {
        Write-Host "  fetch FAILED:" -ForegroundColor Red
        Write-Host "  $($f.Out)" -ForegroundColor Red
        $plan += [pscustomobject]@{ Repo = $repo; Ready = $false; Note = 'fetch failed' }
        continue
    }

    $clean = Test-Clean $dir
    # behind counts vs origin (how many commits we'd need to pull)
    $srcBehind = Count-Behind $dir $S "origin/$S"
    $tgtBehind = Count-Behind $dir $T "origin/$T"
    # would the merge actually bring anything? (source commits not yet in target)
    $toMerge   = Count-Behind $dir $T $S

    # ff-safe means local branch is an ancestor of its origin (no local-only commits diverging)
    $srcAhead = Count-Behind $dir "origin/$S" $S   # local-only commits on source
    $tgtAhead = Count-Behind $dir "origin/$T" $T   # local-only commits on target

    $reasons = @()
    if (-not $clean)                          { $reasons += 'dirty working tree' }
    if ($srcBehind -gt 0 -and $srcAhead -gt 0) { $reasons += "$S diverged from origin" }
    if ($tgtBehind -gt 0 -and $tgtAhead -gt 0) { $reasons += "$T diverged from origin" }

    $ready = ($reasons.Count -eq 0)
    Write-Host ("  clean: {0}   {1} behind origin: {2}   {3} behind origin: {4}   to merge: {5}" -f `
        $clean, $S, $srcBehind, $T, $tgtBehind, $toMerge)
    if ($ready) {
        Write-Host "  -> READY" -ForegroundColor Green
    } else {
        Write-Host "  -> SKIP ($($reasons -join '; '))" -ForegroundColor Yellow
    }
    $plan += [pscustomobject]@{ Repo = $repo; Ready = $ready; Note = ($reasons -join '; '); ToMerge = $toMerge }
}

$ready = @($plan | Where-Object { $_.Ready })
if (-not $ready) {
    Write-Host ""
    Write-Host "Nothing ready to merge (all selected repos were skipped)." -ForegroundColor Yellow
    exit 1
}

# --- confirm + push decision -------------------------------------------------
$doPush = [bool]$Push
if (-not $Yes) {
    Write-Host ""
    Write-Host "Plan:" -ForegroundColor Cyan
    Write-Host "  merge  : $Source -> $Target"
    Write-Host ("  repos  : {0} -> {1}" -f $ready.Count, (($ready | ForEach-Object { $_.Repo.Name }) -join ', '))
    if (-not $Push) {
        $a = Read-Host "Push each merged '$Target' to origin afterwards? [y/N]"
        $doPush = ($a -match '^[Yy]')
    }
    Write-Host ("  push   : {0}" -f $(if ($doPush) { 'yes -> origin/' + $Target } else { 'no (local merge only)' }))
    $a = Read-Host "Proceed? [Y/n]"
    if ($a -match '^[Nn]') { Write-Host "Aborted."; exit 0 }
}

# --- merge -------------------------------------------------------------------
$results = @()
foreach ($item in $plan) {
    $repo = $item.Repo; $dir = $repo.Dir; $name = $repo.Name; $S = $repo.Src; $T = $repo.Tgt
    $orig = Get-CurrentBranch $dir

    if (-not $item.Ready) {
        $results += [pscustomobject]@{ Repo = $name; Merge = 'SKIP'; Push = '-'; Note = $item.Note }
        continue
    }

    Write-Host ""
    Write-Host "=== $name ===" -ForegroundColor Cyan
    $mergeStatus = 'PENDING'
    $pushStatus  = '-'
    $note        = ''

    try {
        # 1) update source to latest (fast-forward only)
        if ((Git-Run $dir @('checkout', $S)) -ne 0) { throw "checkout $S failed" }
        if ((Count-Behind $dir $S "origin/$S") -gt 0) {
            Write-Host "  pulling $S ..." -ForegroundColor DarkGray
            if ((Git-Run $dir @('pull','--ff-only','origin',$S)) -ne 0) { throw "pull $S failed" }
        }

        # 2) update target to latest (create local tracking branch if needed)
        if ((Get-BranchLoc $dir $T) -eq 'local') {
            if ((Git-Run $dir @('checkout', $T)) -ne 0) { throw "checkout $T failed" }
            if ((Count-Behind $dir $T "origin/$T") -gt 0) {
                Write-Host "  pulling $T ..." -ForegroundColor DarkGray
                if ((Git-Run $dir @('pull','--ff-only','origin',$T)) -ne 0) { throw "pull $T failed" }
            }
        } else {
            if ((Git-Run $dir @('checkout','-b',$T,"origin/$T")) -ne 0) { throw "create $T failed" }
        }

        # 3) merge source -> target
        $before = (Git-Cap $dir @('rev-parse','HEAD')).Out
        Write-Host "  merging $S -> $T ..." -ForegroundColor DarkGray
        $mcode = Git-Run $dir @('merge','--no-edit',$S)
        if ($mcode -ne 0) {
            Git-Cap $dir @('merge','--abort') | Out-Null   # leave tree clean
            $mergeStatus = 'CONFLICT'
            $note = 'merge conflict (aborted)'
            Write-Host "  CONFLICT - merge aborted, no changes kept." -ForegroundColor Red
        } else {
            $after = (Git-Cap $dir @('rev-parse','HEAD')).Out
            if ($after -eq $before) {
                $mergeStatus = 'UP-TO-DATE'
                Write-Host "  already up to date." -ForegroundColor Green
            } else {
                $mergeStatus = 'MERGED'
                Write-Host "  MERGED." -ForegroundColor Green
            }

            # 4) push (optional) - only if target has commits origin doesn't
            if ($doPush) {
                $ahead = Count-Behind $dir "origin/$T" $T
                if ($ahead -gt 0) {
                    Write-Host "  pushing $T -> origin ($ahead commit(s)) ..." -ForegroundColor DarkGray
                    if ((Git-Run $dir @('push','origin',$T)) -eq 0) {
                        $pushStatus = 'PUSHED'
                        Write-Host "  pushed." -ForegroundColor Green
                    } else {
                        $pushStatus = 'PUSH-FAILED'
                        Write-Host "  push FAILED." -ForegroundColor Red
                    }
                } else {
                    $pushStatus = 'NOTHING'
                }
            }
        }
    } catch {
        $mergeStatus = 'ERROR'
        $note = "$_"
        Write-Host "  ERROR: $_" -ForegroundColor Red
        # best-effort: don't leave a half-done merge in progress
        Git-Cap $dir @('merge','--abort') | Out-Null
    } finally {
        # restore the branch the repo started on
        if ($orig -and (Get-CurrentBranch $dir) -ne $orig) {
            Git-Cap $dir @('checkout', $orig) | Out-Null
        }
    }

    $results += [pscustomobject]@{ Repo = $name; Merge = $mergeStatus; Push = $pushStatus; Note = $note }
}

# --- summary -----------------------------------------------------------------
Write-Host ""
Write-Host "===== Summary ($Source -> $Target) =====" -ForegroundColor Cyan
$results | Format-Table -AutoSize

$bad = @($results | Where-Object { $_.Merge -in @('CONFLICT','ERROR') -or $_.Push -eq 'PUSH-FAILED' })
if ($bad.Count -gt 0) { exit 1 }
exit 0
