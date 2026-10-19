#Requires -Version 5.1
<#
.SYNOPSIS
    Restores Start-CoworkPolicyGui.ps1 to the original unpatched version.
.DESCRIPTION
    Scans every _backup-gui* folder, ignores any copy that is empty, truncated
    or already contains a layout patch, and restores the oldest clean one.
    Run this any time a patch leaves the GUI in a bad state.
#>
[CmdletBinding()]
param([string]$Folder = $PSScriptRoot)

$ErrorActionPreference = 'Stop'
if (-not $Folder) { $Folder = (Get-Location).Path }

$target = Join-Path $Folder 'Start-CoworkPolicyGui.ps1'
if (-not (Test-Path $target)) { throw "Not found: $target" }

$marker  = 'Repair-CoworkGuiLayout'
$utf8bom = New-Object System.Text.UTF8Encoding($true)

Write-Host "Scanning backups in $Folder" -ForegroundColor Cyan
$candidates = @()
foreach ($d in (Get-ChildItem -Path $Folder -Directory -Filter '_backup-gui*' | Sort-Object Name)) {
    $c = Join-Path $d.FullName 'Start-CoworkPolicyGui.ps1'
    if (-not (Test-Path $c)) { Write-Host ("  {0,-34} no GUI file" -f $d.Name); continue }
    $t = [System.IO.File]::ReadAllText($c)
    $patched = $t -match [regex]::Escape($marker)
    $state = if ($t.Length -lt 5000) { 'TOO SMALL' } elseif ($patched) { 'already patched' } else { 'CLEAN' }
    Write-Host ("  {0,-34} {1,7} chars  {2}" -f $d.Name, $t.Length, $state)
    if ($state -eq 'CLEAN') { $candidates += [pscustomobject]@{ Path = $c; Text = $t } }
}

if ($candidates.Count -eq 0) { throw "No clean backup found. Do not overwrite anything - send this output instead." }

$pick = $candidates[0]
Copy-Item $target "$target.broken" -Force
[System.IO.File]::WriteAllText($target, $pick.Text, $utf8bom)

Write-Host ""
Write-Host "Restored from : $($pick.Path)" -ForegroundColor Green
Write-Host "Broken copy   : $target.broken  (kept for diagnosis)"
Write-Host "Now run       : .\Launch-CoworkGui.cmd"
