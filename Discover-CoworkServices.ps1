#Requires -Version 5.1
<#
.SYNOPSIS
    Discovers the real serviceId values accepted by the Copilot cost management API.
.DESCRIPTION
    POST /spendingPolicies is rejecting our hard-coded serviceId 'cowork' with
    "serviceSettings contains an unsupported serviceId or state."

    This script finds the correct value. It runs in two stages:

      Stage 1 (read-only, always runs)
        Probes every GET endpoint that could expose a service catalogue and
        pulls out distinct serviceId values. If anyone in the tenant has
        already created a spending policy in the admin portal, stage 1 will
        return the authoritative answer immediately.

      Stage 2 (-TryCandidates, opt-in)
        If stage 1 finds nothing, probes candidate ids by POSTing a throwaway
        policy for each one and reading the error. Any policy that is actually
        created is deleted again straight away. Probe policies are named
        zzz-probe-<guid> and target selectedGroups with NO groups assigned,
        so they apply to nobody even in the window before deletion.

.EXAMPLE
    .\Discover-CoworkServices.ps1
.EXAMPLE
    .\Discover-CoworkServices.ps1 -TryCandidates
#>
[CmdletBinding()]
param(
    [switch]$TryCandidates,
    [string[]]$Candidates,
    [string]$Root = 'copilot/costManagement'
)

$ErrorActionPreference = 'Stop'
$base = "https://graph.microsoft.com/beta/$($Root.Trim('/'))"

function Write-Head($t) {
    Write-Host ''
    Write-Host ('=' * 78) -ForegroundColor DarkGray
    Write-Host $t -ForegroundColor Cyan
    Write-Host ('=' * 78) -ForegroundColor DarkGray
}

# ---------------------------------------------------------------- connection
if (-not (Get-Module -ListAvailable Microsoft.Graph.Authentication)) {
    throw 'Microsoft.Graph.Authentication is not installed.'
}
Import-Module Microsoft.Graph.Authentication -ErrorAction Stop

$ctx = $null
try { $ctx = Get-MgContext } catch { }
if (-not $ctx) {
    $scopes = @(
        'CopilotCostManagement.Read.All'
        'CopilotCostManagement-Policy.Read.All'
        'CopilotCostManagement-Policy.ReadWrite.All'
        'CopilotCostManagement-UserData.Read.All'
    )
    Write-Host 'Not connected - signing in...' -ForegroundColor Yellow
    Connect-MgGraph -Scopes $scopes -NoWelcome
    $ctx = Get-MgContext
}
Write-Host ("Account : {0}" -f $ctx.Account)
Write-Host ("Tenant  : {0}" -f $ctx.TenantId)
Write-Host ("Base    : {0}" -f $base)

# ------------------------------------------------------------------ helpers
function Invoke-Probe {
    param([string]$Method, [string]$Url, $Body)
    $r = [ordered]@{ Method = $Method; Url = $Url; Status = $null; Error = $null; Data = $null }
    try {
        $p = @{ Method = $Method; Uri = $Url; OutputType = 'PSObject'; ErrorAction = 'Stop' }
        if ($null -ne $Body) {
            $p.Body        = ($Body | ConvertTo-Json -Depth 10 -Compress)
            $p.ContentType = 'application/json'
        }
        $r.Data   = Invoke-MgGraphRequest @p
        $r.Status = 200
    } catch {
        $resp = $null
        try { $resp = $_.Exception.Response } catch { }
        if ($resp -and $resp.StatusCode) { $r.Status = [int]$resp.StatusCode }
        $txt = "$($_.Exception.Message)"
        if ($txt -match '"message"\s*:\s*"([^"]+)"') { $txt = $Matches[1] }
        $r.Error = $txt
    }
    [pscustomobject]$r
}

# Recursively collect anything that looks like a service identifier.
function Get-ServiceIdHits {
    param($Node, [string]$Path = '$')
    $hits = @()
    if ($null -eq $Node) { return $hits }

    if ($Node -is [System.Collections.IDictionary]) {
        foreach ($k in $Node.Keys) {
            $v = $Node[$k]
            if ($k -match '^(serviceId|serviceName|servicePlanId)$' -and $v -is [string]) {
                $hits += [pscustomobject]@{ Path = "$Path.$k"; Key = $k; Value = $v }
            }
            $hits += Get-ServiceIdHits -Node $v -Path "$Path.$k"
        }
        return $hits
    }

    if ($Node -is [System.Collections.IEnumerable] -and $Node -isnot [string]) {
        $i = 0
        foreach ($item in $Node) { $hits += Get-ServiceIdHits -Node $item -Path "$Path[$i]"; $i++ }
        return $hits
    }

    if ($Node -is [psobject] -and $Node.PSObject.Properties.Count) {
        foreach ($p in $Node.PSObject.Properties) {
            if ($p.Name -match '^(serviceId|serviceName|servicePlanId)$' -and $p.Value -is [string]) {
                $hits += [pscustomobject]@{ Path = "$Path.$($p.Name)"; Key = $p.Name; Value = $p.Value }
            }
            $hits += Get-ServiceIdHits -Node $p.Value -Path "$Path.$($p.Name)"
        }
    }
    return $hits
}

# ------------------------------------------------------- stage 1: read-only
Write-Head 'STAGE 1 - read-only discovery'

$me = $null
try { $me = (Invoke-MgGraphRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/me?$select=id' -OutputType PSObject).id } catch { }

$urls = @(
    "$base/spendingPolicies"
    "$base/spendingPolicies?`$expand=serviceSettings"
    "$base/getTenantCreditBalance()"
    "$base/services"
    "$base/serviceCatalog"
    "$base/spendingPolicyServices"
)
if ($me) {
    $urls += "$base/userBalances/$me"
    $urls += "$base/userBalances/$me/serviceBalances"
}

$all = @()
foreach ($u in $urls) {
    $r = Invoke-Probe -Method GET -Url $u
    $all += $r
    $short = $u.Replace($base, '')
    if ($r.Status -eq 200) {
        Write-Host ("  [200] {0}" -f $short) -ForegroundColor Green
    } else {
        Write-Host ("  [{0,3}] {1}  {2}" -f ($r.Status, $short, $r.Error)) -ForegroundColor DarkGray
    }
}

$found = @()
foreach ($r in ($all | Where-Object Status -eq 200)) {
    $hits = Get-ServiceIdHits -Node $r.Data
    foreach ($h in $hits) {
        $found += [pscustomobject]@{ Source = $r.Url.Replace($base, ''); Key = $h.Key; Value = $h.Value }
    }
}

# Dump any successful policy payload in full - the most useful evidence there is.
$pol = $all | Where-Object { $_.Status -eq 200 -and $_.Url -match 'spendingPolicies' } | Select-Object -First 1
if ($pol -and $pol.Data) {
    Write-Head 'Existing spendingPolicies payload (verbatim)'
    $pol.Data | ConvertTo-Json -Depth 12
}

if ($found.Count) {
    Write-Head 'SERVICE IDs FOUND'
    $found | Sort-Object Value, Key -Unique | Format-Table -AutoSize
    Write-Host 'Use the serviceId value above. Apply it with:' -ForegroundColor Green
    Write-Host '    .\Set-CoworkServiceId.ps1 -NewId <value>' -ForegroundColor Green
} else {
    Write-Host ''
    Write-Host 'No serviceId found by read-only probing.' -ForegroundColor Yellow
    Write-Host 'Most likely this tenant has no spending policy yet.' -ForegroundColor Yellow
    Write-Host 'Either create one by hand in the admin portal and re-run this script,' -ForegroundColor Yellow
    Write-Host 'or run:  .\Discover-CoworkServices.ps1 -TryCandidates' -ForegroundColor Yellow
}

# ------------------------------------------------------ stage 2: candidates
if (-not $TryCandidates) { return }

Write-Head 'STAGE 2 - candidate probing (creates and deletes throwaway policies)'

if (-not $Candidates -or $Candidates.Count -eq 0) {
    $Candidates = @(
        'cowork'
        'Cowork'
        'copilotCowork'
        'CopilotCowork'
        'microsoftCopilotCowork'
        'microsoft.cowork'
        'microsoft365Cowork'
        'm365Cowork'
        'copilot'
        'microsoftCopilot'
        'agentsAndServices'
    )
}

# If stage 1 surfaced any ids, probe those first - they are far more likely.
if ($found.Count) {
    $Candidates = @(($found | Select-Object -ExpandProperty Value -Unique)) + $Candidates
    $Candidates = $Candidates | Select-Object -Unique
}

$results = @()
foreach ($c in $Candidates) {
    $name = "zzz-probe-$([guid]::NewGuid().ToString('N').Substring(0,12))"
    $body = @{
        '@odata.type'   = '#microsoft.graph.selectedGroupsSpendingPolicy'
        displayName     = $name
        periodLimit     = @{ '@odata.type' = '#microsoft.graph.limitedCostManagementQuantity'; value = 4000; unit = 'copilotCredit' }
        perUserLimit    = @{ '@odata.type' = '#microsoft.graph.limitedCostManagementQuantity'; value = 2000; unit = 'copilotCredit' }
        serviceSettings = @(@{ serviceId = $c; state = 'enabled' })
    }

    $r = Invoke-Probe -Method POST -Url "$base/spendingPolicies" -Body $body
    $ok = ($r.Status -eq 200 -or ($r.Data -and $r.Data.id))

    if ($ok) {
        Write-Host ("  ACCEPTED  '{0}'" -f $c) -ForegroundColor Green
        $id = $null
        try { $id = $r.Data.id } catch { }
        if ($id) {
            $d = Invoke-Probe -Method DELETE -Url "$base/spendingPolicies/$id"
            if ($d.Error) {
                Write-Host ("    WARNING: probe policy {0} could not be deleted - remove it by hand." -f $id) -ForegroundColor Red
            } else {
                Write-Host ("    cleaned up {0}" -f $id) -ForegroundColor DarkGray
            }
        }
    } else {
        $msg = $r.Error
        $tag = if ($msg -match 'unsupported serviceId') { 'rejected (serviceId)' } else { 'other error' }
        Write-Host ("  {0,-10} '{1}'  {2}" -f ($tag, $c, $msg)) -ForegroundColor DarkGray
    }

    $results += [pscustomobject]@{ Candidate = $c; Accepted = $ok; Status = $r.Status; Error = $r.Error }
    Start-Sleep -Milliseconds 600   # the API rate-limits aggressively
}

Write-Head 'CANDIDATE RESULTS'
$results | Format-Table -AutoSize

$win = $results | Where-Object Accepted | Select-Object -First 1
if ($win) {
    Write-Host ("Correct serviceId: '{0}'" -f $win.Candidate) -ForegroundColor Green
    Write-Host ("Apply it with:  .\Set-CoworkServiceId.ps1 -NewId '{0}'" -f $win.Candidate) -ForegroundColor Green
    return
}

Write-Host 'No candidate serviceId accepted.' -ForegroundColor Yellow

# --------------------------------------------------- stage 3: state values
# The error names "serviceId or state", so if no id works the fault may be the
# state value instead. Hold the id steady and vary the state.
Write-Head 'STAGE 3 - state value probing'

$stateResults = @()
foreach ($s in @('enabled', 'disabled', 'included', 'allowed', 'active', 'on', 'notConfigured')) {
    $name = "zzz-probe-$([guid]::NewGuid().ToString('N').Substring(0,12))"
    $body = @{
        '@odata.type'   = '#microsoft.graph.selectedGroupsSpendingPolicy'
        displayName     = $name
        periodLimit     = @{ '@odata.type' = '#microsoft.graph.limitedCostManagementQuantity'; value = 4000; unit = 'copilotCredit' }
        perUserLimit    = @{ '@odata.type' = '#microsoft.graph.limitedCostManagementQuantity'; value = 2000; unit = 'copilotCredit' }
        serviceSettings = @(@{ serviceId = $Candidates[0]; state = $s })
    }
    $r  = Invoke-Probe -Method POST -Url "$base/spendingPolicies" -Body $body
    $ok = ($r.Status -eq 200 -or ($r.Data -and $r.Data.id))
    if ($ok) {
        Write-Host ("  ACCEPTED state '{0}'" -f $s) -ForegroundColor Green
        $id = $null; try { $id = $r.Data.id } catch { }
        if ($id) { $null = Invoke-Probe -Method DELETE -Url "$base/spendingPolicies/$id" }
    } else {
        Write-Host ("  rejected  state '{0}'  {1}" -f $s, $r.Error) -ForegroundColor DarkGray
    }
    $stateResults += [pscustomobject]@{ State = $s; Accepted = $ok; Error = $r.Error }
    Start-Sleep -Milliseconds 600
}

Write-Head 'STATE RESULTS'
$stateResults | Format-Table -AutoSize

Write-Host ''
Write-Host 'If nothing was accepted, the decisive step is:' -ForegroundColor Yellow
Write-Host '  1. Create ONE spending policy by hand in the admin portal.' -ForegroundColor Yellow
Write-Host '  2. Re-run:  .\Discover-CoworkServices.ps1' -ForegroundColor Yellow
Write-Host '     Stage 1 will print that policy verbatim, including the real serviceId.' -ForegroundColor Yellow
Write-Host 'Send me that output and I will wire the correct value in.' -ForegroundColor Yellow
