<#
.SYNOPSIS
  Run `npm i` in every npm project of the workspace that needs it.

.DESCRIPTION
  Finds package.json files (with dependencies) inside the nested repos, top-most per
  folder tree only, so library manifests like fe.common/projects/unified/common are skipped.
  A project "needs install" when:
    - node_modules is missing, or
    - package.json or package-lock.json is newer than node_modules/.package-lock.json
      (npm rewrites that file on every install, so a pull that changes deps makes it stale).

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts/npm/npm-install.ps1           # only where needed
  ... -File npm-install.ps1 -DryRun                     # just list what needs install
  ... -File npm-install.ps1 -All                        # install everywhere
  ... -File npm-install.ps1 -Repos fe.core,sso          # filter by repo name
#>
param(
    [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path,
    [string[]]$Repos = @(),
    [switch]$All,
    [switch]$DryRun
)

$ErrorActionPreference = 'Continue'
$skipDirs = '\\(node_modules|dist|bin|obj|\.angular|release-[^\\]*)\\'

$repoDirs = Get-ChildItem -Path $Root -Directory | Where-Object { Test-Path (Join-Path $_.FullName '.git') }
$Repos = @($Repos | ForEach-Object { $_ -split '[,\s]+' } | Where-Object { $_ })
if ($Repos.Count -gt 0) {
    $repoDirs = $repoDirs | Where-Object { $n = $_.Name; $Repos | Where-Object { $n -like "*$_*" } }
}

# ---- discover projects ------------------------------------------------------
$projects = @()
foreach ($r in $repoDirs) {
    $found = Get-ChildItem $r.FullName -Recurse -Depth 3 -Filter package.json -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch $skipDirs } |
        Sort-Object { $_.DirectoryName.Length }
    $kept = @()
    foreach ($f in $found) {
        $dir = $f.DirectoryName
        if ($kept | Where-Object { $dir.StartsWith("$_\") }) { continue }   # nested under another project
        $pkg = Get-Content $f.FullName -Raw | ConvertFrom-Json
        if (-not ($pkg.dependencies -or $pkg.devDependencies)) { continue }
        $kept += $dir
    }
    $projects += $kept
}

function Get-InstallReason([string]$dir) {
    $marker = Join-Path $dir 'node_modules\.package-lock.json'
    if (-not (Test-Path (Join-Path $dir 'node_modules'))) { return 'no node_modules' }
    if (-not (Test-Path $marker)) { return 'no install marker' }
    $installed = (Get-Item $marker).LastWriteTimeUtc
    foreach ($f in 'package.json', 'package-lock.json') {
        $p = Join-Path $dir $f
        if ((Test-Path $p) -and (Get-Item $p).LastWriteTimeUtc -gt $installed) { return "$f changed" }
    }
    return $null
}

# ---- plan -------------------------------------------------------------------
$plan = foreach ($dir in $projects) {
    $reason = Get-InstallReason $dir
    if ($All -and -not $reason) { $reason = 'forced (-All)' }
    [pscustomobject]@{ Project = $dir.Substring($Root.Length + 1); Dir = $dir; Reason = $reason }
}
$todo = @($plan | Where-Object { $_.Reason })

Write-Host "Found $($plan.Count) npm projects, $($todo.Count) need install." -ForegroundColor Cyan
foreach ($p in $plan) {
    if ($p.Reason) { Write-Host ("  [install] {0}  ({1})" -f $p.Project, $p.Reason) -ForegroundColor Yellow }
    else           { Write-Host ("  [ok]      {0}" -f $p.Project) -ForegroundColor DarkGray }
}
if ($DryRun -or $todo.Count -eq 0) { exit 0 }

# ---- install ----------------------------------------------------------------
$results = @()
foreach ($p in $todo) {
    Write-Host "`n=== npm i : $($p.Project) ===" -ForegroundColor Cyan
    if (-not (Test-Path (Join-Path $p.Dir '.npmrc')) -and (Select-String -Path (Join-Path $p.Dir 'package.json') -Pattern '@borderguardsunifiedplatform/' -Quiet)) {
        Write-Host "  warning: no .npmrc here; @borderguardsunifiedplatform/* needs a GitHub Packages token." -ForegroundColor DarkYellow
    }
    Push-Location $p.Dir
    try { & npm i --no-fund --no-audit | Out-Host; $code = $LASTEXITCODE } finally { Pop-Location }
    $status = if ($code -eq 0) { 'OK' } else { "FAILED ($code)" }
    Write-Host "  -> $status" -ForegroundColor $(if ($code -eq 0) { 'Green' } else { 'Red' })
    $results += [pscustomobject]@{ Project = $p.Project; Result = $status }
}

Write-Host "`n===== Summary =====" -ForegroundColor Cyan
$results | Format-Table -AutoSize | Out-String | Write-Host
if (@($results | Where-Object { $_.Result -ne 'OK' }).Count -gt 0) { exit 1 }
