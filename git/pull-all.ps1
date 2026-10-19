<#
.SYNOPSIS
  Fetch every nested repo in the workspace and fast-forward every local branch to its upstream.

.DESCRIPTION
  Safe by design: it never merges, rebases, stashes, resets or discards anything.
  - Fetches all remotes (with --prune and --tags) for every repo, in parallel.
  - Fast-forwards each local branch that is strictly behind its upstream.
    * Non-checked-out branches are moved with a guarded update-ref (only if still at the old SHA).
    * The checked-out branch is updated with `merge --ff-only`, only when the working tree is clean.
  - Skips and reports branches that are diverged, ahead (unpushed), dirty, or whose upstream is gone.
  - With -TrackAll, also creates local tracking branches for remote branches that have no local copy.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts/git/pull-all.ps1
  ... -File pull-all.ps1 -TrackAll
  ... -File pull-all.ps1 -Repos fe.core,be.eskan
#>
param(
    [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path,
    [string[]]$Repos = @(),
    [switch]$TrackAll,
    [switch]$FetchOnly,
    [int]$Throttle = 6
)

$ErrorActionPreference = 'Continue'

function Invoke-Git {
    param([string]$Dir, [string[]]$GitArgs)
    $out = & git -C $Dir @GitArgs 2>&1 | ForEach-Object { "$_" }
    [pscustomobject]@{ Code = $LASTEXITCODE; Out = ($out -join "`n").Trim() }
}

# ---- discover repos -------------------------------------------------------
$repoDirs = @()
if (Test-Path (Join-Path $Root '.git')) { $repoDirs += Get-Item $Root }
$repoDirs += Get-ChildItem -Path $Root -Directory | Where-Object { Test-Path (Join-Path $_.FullName '.git') }
$Repos = @($Repos | ForEach-Object { $_ -split '[,\s]+' } | Where-Object { $_ })
if ($Repos.Count -gt 0) {
    $repoDirs = $repoDirs | Where-Object { $n = $_.Name; $Repos | Where-Object { $n -like "*$_*" } }
}
if (-not $repoDirs) { Write-Host "No git repos found under $Root"; exit 1 }

Write-Host "Fetching $($repoDirs.Count) repos (throttle $Throttle)..." -ForegroundColor Cyan

# ---- phase 1: parallel fetch ---------------------------------------------
$fetchResults = @{}
$queue = [System.Collections.Queue]::new(@($repoDirs))
$jobs = @()
while ($queue.Count -gt 0 -or $jobs.Count -gt 0) {
    while ($queue.Count -gt 0 -and $jobs.Count -lt $Throttle) {
        $d = $queue.Dequeue()
        $jobs += Start-Job -Name $d.FullName -ScriptBlock {
            param($dir)
            $o = & git -C $dir fetch --all --prune --tags --quiet 2>&1 | ForEach-Object { "$_" }
            [pscustomobject]@{ Code = $LASTEXITCODE; Out = ($o -join "`n").Trim() }
        } -ArgumentList $d.FullName
    }
    $done = Wait-Job -Job $jobs -Any -Timeout 300
    if (-not $done) { break }
    foreach ($j in @($jobs | Where-Object { $_.State -ne 'Running' })) {
        $fetchResults[$j.Name] = Receive-Job $j
        Remove-Job $j
        $jobs = @($jobs | Where-Object { $_.Id -ne $j.Id })
    }
}
foreach ($j in $jobs) { $fetchResults[$j.Name] = [pscustomobject]@{ Code = 124; Out = 'fetch timed out' }; Remove-Job $j -Force }

# ---- phase 2: fast-forward branches --------------------------------------
$rows = @()
foreach ($d in $repoDirs) {
    $dir = $d.FullName
    $name = if ($dir -eq $Root) { '(umbrella)' } else { $d.Name }
    $f = $fetchResults[$dir]
    $updated = @(); $skipped = @(); $created = @(); $ahead = @()
    $fetchStatus = if ($f -and $f.Code -eq 0) { 'ok' } else { "FAILED: $($f.Out)" }

    if ($FetchOnly -or $fetchStatus -ne 'ok') {
        $rows += [pscustomobject]@{ Repo = $name; Fetch = $fetchStatus; Updated = ''; Created = ''; Ahead = ''; Skipped = '' }
        continue
    }

    $current = (Invoke-Git $dir @('branch', '--show-current')).Out
    $dirty = [bool](Invoke-Git $dir @('status', '--porcelain', '--untracked-files=no')).Out

    # branches checked out in other worktrees must not be moved from here
    $wtBranches = (Invoke-Git $dir @('worktree', 'list', '--porcelain')).Out -split "`n" |
        Where-Object { $_ -like 'branch refs/heads/*' } | ForEach-Object { $_.Substring(18) }

    $fmt = '%(refname:short)|%(upstream:short)|%(upstream:track)'
    $branches = (Invoke-Git $dir @('for-each-ref', "--format=$fmt", 'refs/heads')).Out -split "`n" | Where-Object { $_ }

    foreach ($line in $branches) {
        $parts = $line.Split('|')
        $b = $parts[0]; $up = $parts[1]; $track = $parts[2]
        if (-not $up) { continue }
        if ($track -eq '[gone]') { $skipped += "$b(upstream gone)"; continue }

        $counts = (Invoke-Git $dir @('rev-list', '--left-right', '--count', "$b...$up")).Out -split '\s+'
        $nAhead = [int]$counts[0]; $nBehind = [int]$counts[1]

        if ($nAhead -gt 0 -and $nBehind -gt 0) { $skipped += "$b(diverged +$nAhead/-$nBehind)"; continue }
        if ($nAhead -gt 0) { $ahead += "$b(+$nAhead)"; continue }
        if ($nBehind -eq 0) { continue }

        if ($b -eq $current) {
            if ($dirty) { $skipped += "$b(dirty, -$nBehind)"; continue }
            $r = Invoke-Git $dir @('merge', '--ff-only', '--quiet', $up)
        } elseif ($wtBranches -contains $b) {
            $skipped += "$b(in other worktree)"; continue
        } else {
            $old = (Invoke-Git $dir @('rev-parse', "refs/heads/$b")).Out
            $new = (Invoke-Git $dir @('rev-parse', $up)).Out
            $r = Invoke-Git $dir @('update-ref', '-m', 'git-latest: fast-forward', "refs/heads/$b", $new, $old)
        }
        if ($r.Code -eq 0) { $updated += "$b(-$nBehind)" } else { $skipped += "$b(error)" }
    }

    if ($TrackAll) {
        $locals = $branches | ForEach-Object { $_.Split('|')[0] }
        $remotes = (Invoke-Git $dir @('for-each-ref', '--format=%(refname:short)', 'refs/remotes')).Out -split "`n" |
            Where-Object { $_ -and $_ -notmatch '/HEAD$' -and $_ -match '/' }
        foreach ($rb in $remotes) {
            $local = $rb.Substring($rb.IndexOf('/') + 1)
            if ($locals -contains $local) { continue }
            $r = Invoke-Git $dir @('branch', '--quiet', '--track', $local, $rb)
            if ($r.Code -eq 0) { $created += $local; $locals += $local }
        }
    }

    $rows += [pscustomobject]@{
        Repo    = "$name [$current]"
        Fetch   = $fetchStatus
        Updated = $updated -join ', '
        Created = if ($created.Count -gt 5) { "$($created.Count) branches" } else { $created -join ', ' }
        Ahead   = $ahead -join ', '
        Skipped = $skipped -join ', '
    }
}

# ---- report ---------------------------------------------------------------
$rows | Format-List | Out-String -Width 4096 | Write-Host
$failed = @($rows | Where-Object { $_.Fetch -ne 'ok' }).Count
$upd = @($rows | Where-Object { $_.Updated }).Count
$skp = @($rows | Where-Object { $_.Skipped }).Count
Write-Host ("Summary: {0} repos, {1} with updates, {2} with skipped branches, {3} fetch failures" -f $rows.Count, $upd, $skp, $failed) -ForegroundColor Cyan
if ($failed -gt 0) { exit 2 }
