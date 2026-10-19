#Requires -Version 5.1
<#
.SYNOPSIS
    Shows, and optionally rewrites, the hard-coded Cowork serviceId in the module.
.DESCRIPTION
    Run with no arguments to AUDIT: every place the old serviceId literal appears
    is listed with file, line number and surrounding text. Nothing is modified.

    Run with -NewId <value> -Apply to REWRITE those literals. Every touched file
    is backed up first, and each rewritten .ps1 is re-parsed with the PowerShell
    AST before it is saved. If a file would no longer parse, nothing is written.

    Only quoted string literals that are EXACTLY equal to -OldId are touched, so
    words like "Cowork" inside display names, comments and file names are left
    alone.
.EXAMPLE
    .\Set-CoworkServiceId.ps1
.EXAMPLE
    .\Set-CoworkServiceId.ps1 -NewId 'copilotCowork' -Apply
#>
[CmdletBinding()]
param(
    [string]$NewId,
    [string]$OldId  = 'cowork',
    [string]$Folder = $PSScriptRoot,
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
if (-not $Folder) { $Folder = (Get-Location).Path }
if ($Apply -and -not $NewId) { throw 'Specify -NewId when using -Apply.' }

$files = @()
$files += Get-ChildItem -Path $Folder -Filter 'Cowork.*.ps1'  -File -ErrorAction SilentlyContinue
$files += Get-ChildItem -Path $Folder -Filter '*.psm1'        -File -ErrorAction SilentlyContinue
$files += Get-ChildItem -Path $Folder -Filter 'config.json'   -File -ErrorAction SilentlyContinue
$files = $files | Sort-Object FullName -Unique

if (-not $files) { throw "No module files found in $Folder" }

# A quoted literal exactly equal to $OldId: 'cowork' or "cowork", case-insensitive.
$esc     = [regex]::Escape($OldId)
$pattern = "(?<q>['""])$esc\k<q>"
$rx      = [regex]::new($pattern, 'IgnoreCase')

Write-Host ("Scanning {0} file(s) in {1}" -f $files.Count, $Folder) -ForegroundColor Cyan
Write-Host ("Looking for quoted literal: {0}" -f $OldId) -ForegroundColor Cyan
Write-Host ''

$plan = @()
foreach ($f in $files) {
    $lines = [System.IO.File]::ReadAllLines($f.FullName)
    $hits  = @()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($rx.IsMatch($lines[$i])) { $hits += [pscustomobject]@{ Line = $i + 1; Text = $lines[$i].Trim() } }
    }
    if ($hits.Count) {
        Write-Host $f.Name -ForegroundColor Yellow
        foreach ($h in $hits) { Write-Host ("  {0,5}: {1}" -f $h.Line, $h.Text) }
        Write-Host ''
        $plan += [pscustomobject]@{ File = $f; Hits = $hits }
    }
}

if (-not $plan) {
    Write-Host "No quoted literal '$OldId' found." -ForegroundColor Red
    Write-Host 'The serviceId may be built dynamically. Search manually with:' -ForegroundColor Red
    Write-Host ("    Select-String -Path '{0}\*.ps1' -Pattern 'serviceId' -Context 2,2" -f $Folder) -ForegroundColor Red
    return
}

$total = ($plan | ForEach-Object { $_.Hits.Count } | Measure-Object -Sum).Sum
Write-Host ("{0} occurrence(s) across {1} file(s)." -f $total, $plan.Count) -ForegroundColor Cyan

if (-not $Apply) {
    Write-Host ''
    Write-Host 'AUDIT ONLY - nothing changed.' -ForegroundColor Green
    Write-Host 'To apply:  .\Set-CoworkServiceId.ps1 -NewId ''<value>'' -Apply' -ForegroundColor Green
    return
}

# ------------------------------------------------------------------- apply
$stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$backup  = Join-Path $Folder "_backup-serviceid-$stamp"
New-Item -ItemType Directory -Path $backup -Force | Out-Null
$utf8bom = New-Object System.Text.UTF8Encoding($true)

$written = 0
foreach ($p in $plan) {
    $f    = $p.File
    $text = [System.IO.File]::ReadAllText($f.FullName)
    $new  = $rx.Replace($text, { param($m) "$($m.Groups['q'].Value)$NewId$($m.Groups['q'].Value)" })

    if ($new -eq $text) { continue }

    if ($f.Extension -eq '.json') {
        try { $null = $new | ConvertFrom-Json } catch {
            Write-Host ("  SKIPPED {0} - result is not valid JSON: {1}" -f $f.Name, $_.Exception.Message) -ForegroundColor Red
            continue
        }
    } else {
        $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseInput($new, [ref]$null, [ref]$errors)
        if ($errors -and $errors.Count) {
            Write-Host ("  SKIPPED {0} - result does not parse: {1}" -f $f.Name, $errors[0].Message) -ForegroundColor Red
            continue
        }
    }

    Copy-Item $f.FullName (Join-Path $backup $f.Name) -Force
    [System.IO.File]::WriteAllText($f.FullName, $new, $utf8bom)
    Write-Host ("  updated {0} ({1} occurrence(s))" -f $f.Name, $p.Hits.Count) -ForegroundColor Green
    $written++
}

Write-Host ''
Write-Host ("Rewrote '{0}' -> '{1}' in {2} file(s)." -f $OldId, $NewId, $written) -ForegroundColor Green
Write-Host ("Backup: {0}" -f $backup)
Write-Host ''
Write-Host 'Now re-test:' -ForegroundColor Cyan
Write-Host '    Import-Module .\CoworkBillingPolicy.psd1 -Force'
Write-Host '    Invoke-CoworkPolicyImport -Path .\policies-Zava.csv -WhatIfPayload'
Write-Host '    Get-CoworkPayloadLog | ConvertTo-Json -Depth 10'
