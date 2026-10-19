<#
.SYNOPSIS
  Delete local branches whose remote branch no longer exists, in every workspace repo.

.DESCRIPTION
  - Runs `fetch --all --prune` first so the "gone" status is current.
  - Targets only branches that tracked a remote branch which was deleted ([gone]).
    Branches that were never pushed are listed but never deleted (they may hold unpushed work).
  - Uses `git branch -d` (refuses unmerged branches). With -Force it uses `-D`.
  - Never deletes the checked-out branch or one checked out in another worktree.
  - -DryRun only lists what would be deleted.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts/git/prune-local.ps1 -DryRun
  ... -File prune-local.ps1 -Force -Repos fe.core
#>
param(
    [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path,
    [string[]]$Repos = @(),
    [switch]$Force,
    [switch]$DryRun
)

$ErrorActionPreference = 'Continue'

function Invoke-Git {
    param([string]$Dir, [string[]]$GitArgs)
    $out = & git -C $Dir @GitArgs 2>&1 | ForEach-Object { "$_" }
    [pscustomobject]@{ Code = $LASTEXITCODE; Out = ($out -join "`n").Trim() }
}

$repoDirs = @()
if (Test-Path (Join-Path $Root '.git')) { $repoDirs += Get-Item $Root }
$repoDirs += Get-ChildItem -Path $Root -Directory | Where-Object { Test-Path (Join-Path $_.FullName '.git') }
$Repos = @($Repos | ForEach-Object { $_ -split '[,\s]+' } | Where-Object { $_ })
if ($Repos.Count -gt 0) {
    $repoDirs = $repoDirs | Where-Object { $n = $_.Name; $Repos | Where-Object { $n -like "*$_*" } }
}
if (-not $repoDirs) { Write-Host "No git repos found under $Root"; exit 1 }

$mode = if ($DryRun) { 'DRY RUN' } elseif ($Force) { 'force (-D)' } else { 'safe (-d)' }
Write-Host "Pruning local branches whose remote is gone in $($repoDirs.Count) repos [$mode]..." -ForegroundColor Cyan

$totalDeleted = 0; $totalKept = 0
foreach ($d in $repoDirs) {
    $dir = $d.FullName
    $name = if ($dir -eq $Root) { '(umbrella)' } else { $d.Name }

    $f = Invoke-Git $dir @('fetch', '--all', '--prune', '--quiet')
    if ($f.Code -ne 0) { Write-Host "$name : fetch FAILED, skipped. $($f.Out)" -ForegroundColor Red; continue }

    $current = (Invoke-Git $dir @('branch', '--show-current')).Out
    $wtBranches = (Invoke-Git $dir @('worktree', 'list', '--porcelain')).Out -split "`n" |
        Where-Object { $_ -like 'branch refs/heads/*' } | ForEach-Object { $_.Substring(18) }

    $lines = (Invoke-Git $dir @('for-each-ref', '--format=%(refname:short)|%(upstream:short)|%(upstream:track)', 'refs/heads')).Out -split "`n" | Where-Object { $_ }
    $deleted = @(); $kept = @(); $neverPushed = @()

    foreach ($line in $lines) {
        $b, $up, $track = $line.Split('|')
        if (-not $up) { $neverPushed += $b; continue }
        if ($track -ne '[gone]') { continue }
        if ($b -eq $current -or $wtBranches -contains $b) { $kept += "$b(checked out)"; continue }
        if ($DryRun) { $deleted += $b; continue }
        $flag = if ($Force) { '-D' } else { '-d' }
        $r = Invoke-Git $dir @('branch', $flag, $b)
        if ($r.Code -eq 0) { $deleted += $b } else { $kept += "$b(not merged)" }
    }

    if ($deleted -or $kept -or $neverPushed) {
        Write-Host "`n$name" -ForegroundColor Yellow
        if ($deleted)     { Write-Host ("  {0}: {1}" -f $(if ($DryRun) { 'would delete' } else { 'deleted' }), ($deleted -join ', ')) -ForegroundColor Green }
        if ($kept)        { Write-Host "  kept: $($kept -join ', ')" -ForegroundColor Red }
        if ($neverPushed) { Write-Host "  never pushed (not touched): $($neverPushed -join ', ')" -ForegroundColor DarkGray }
    }
    $totalDeleted += $deleted.Count; $totalKept += $kept.Count
}

$verb = if ($DryRun) { 'would be deleted' } else { 'deleted' }
Write-Host "`nSummary: $totalDeleted branches $verb, $totalKept kept." -ForegroundColor Cyan
if ($totalKept -gt 0 -and -not $Force -and -not $DryRun) {
    Write-Host "'not merged' branches were kept to protect unmerged commits (common after squash-merge). Use prune:force to delete them anyway." -ForegroundColor DarkYellow
}
