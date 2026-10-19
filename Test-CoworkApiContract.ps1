#Requires -Version 5.1
<#
    Test-CoworkApiContract.ps1

    Standalone probe - does not import or modify the CoworkBillingPolicy module.
    Run this AFTER granting admin consent for the CopilotCostManagement-* scopes.

    Confirms the 403 is cleared and dumps the real JSON shape of a live policy so
    the payload property names can be verified empirically rather than trusted.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [guid] $TenantId,
    [guid] $ClientId = '14d82eec-204b-4c2f-b7e8-296a70dab67e'  # Microsoft Graph Command Line Tools
)

$ErrorActionPreference = 'Stop'
$base = 'https://graph.microsoft.com/beta/copilot/costManagement'

if (-not (Get-Module -ListAvailable Microsoft.Graph.Authentication)) {
    throw "Install-Module Microsoft.Graph.Authentication -Scope CurrentUser"
}
Import-Module Microsoft.Graph.Authentication -ErrorAction Stop

$scopes = @(
    'CopilotCostManagement.Read.All'
    'CopilotCostManagement-Policy.ReadWrite.All'
    'CopilotCostManagement-Assignment.ReadWrite.All'
)

Write-Host "Connecting (delegated; app-only will NOT satisfy this API)..." -ForegroundColor Cyan
Connect-MgGraph -TenantId $TenantId -ClientId $ClientId -Scopes $scopes `
                -ContextScope Process -NoWelcome -ErrorAction Stop

$ctx = Get-MgContext
Write-Host "Signed in as : $($ctx.Account)"
Write-Host "Granted scope: $(($ctx.Scopes | Where-Object { $_ -like 'CopilotCostManagement*' }) -join ', ')" -ForegroundColor Yellow
if (-not ($ctx.Scopes | Where-Object { $_ -like 'CopilotCostManagement*' })) {
    Write-Warning "No CopilotCostManagement-* scope in the token. Admin consent has NOT applied."
    Write-Warning "A redirect showing admin_consent=True does not prove consent succeeded."
}

function Invoke-Probe {
    param([string]$Label, [string]$Uri)
    Write-Host "`n--- $Label" -ForegroundColor Cyan
    Write-Host "    GET $Uri" -ForegroundColor DarkGray
    try {
        $r = Invoke-MgGraphRequest -Method GET -Uri $Uri -ErrorAction Stop
        Write-Host "    200 OK" -ForegroundColor Green
        $r | ConvertTo-Json -Depth 12
        return $r
    } catch {
        $code = $null
        try { $code = $_.Exception.Response.StatusCode.value__ } catch { }
        switch ($code) {
            403     { Write-Host "    403 Forbidden - scope still missing or role insufficient." -ForegroundColor Red }
            404     { Write-Host "    404 Not Found - route not hydrated in this tenant yet." -ForegroundColor Yellow }
            default { Write-Host "    $code $($_.Exception.Message)" -ForegroundColor Red }
        }
        return $null
    }
}

# The internal preview guide writes this with parentheses, Learn writes it without.
if (-not (Invoke-Probe 'Tenant credit balance (with parens)' "$base/getTenantCreditBalance()")) {
    Invoke-Probe 'Tenant credit balance (no parens)' "$base/getTenantCreditBalance"
}

# $top is a known-broken query option here - deliberately omitted.
$policies = Invoke-Probe 'List spending policies' "$base/spendingPolicies"

if ($policies -and $policies.value -and @($policies.value).Count -gt 0) {
    $first = @($policies.value)[0]
    Write-Host "`n=== Live policy shape - compare against CONTRACT-REFERENCE.md" -ForegroundColor Magenta
    Write-Host "Top-level properties returned:" -ForegroundColor White
    $first.Keys | Sort-Object | ForEach-Object { "  $_" }

    foreach ($p in 'displayName','periodLimit','perUserLimit','billingMethods','status') {
        $present = $first.Keys -contains $p
        Write-Host ("  {0,-16} {1}" -f $p, $(if ($present) { 'PRESENT' } else { 'absent' })) `
                   -ForegroundColor $(if ($present) { 'Green' } else { 'Yellow' })
    }

    $id = $first.id
    Invoke-Probe "Service settings for $id" "$base/spendingPolicies/$id/serviceSettings"
    Invoke-Probe "Alert settings for $id"   "$base/spendingPolicies/$id/emailThresholdSettings"
} elseif ($policies) {
    Write-Host "`nNo existing policies to inspect. Create one in the admin centre first," -ForegroundColor Yellow
    Write-Host "then re-run to capture the real response shape." -ForegroundColor Yellow
}

Disconnect-MgGraph | Out-Null
Write-Host "`nDone." -ForegroundColor Cyan
