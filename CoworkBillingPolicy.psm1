# CoworkBillingPolicy.psm1
# Bulk creation of Microsoft Copilot Cowork spending (billing) policies from CSV.

# Strict mode is deliberately NOT enabled: Graph responses are shape-variable and the
# module probes for optional properties throughout.
$ErrorActionPreference = 'Stop'

$script:CoworkModuleRoot = $PSScriptRoot

$partFiles = @(
    'Cowork.Config.ps1'
    'Cowork.GraphClient.ps1'
    'Cowork.Lookups.ps1'
    'Cowork.CsvSchema.ps1'
    'Cowork.Validation.ps1'
    'Cowork.Creation.ps1'
    'Cowork.Public.ps1'
)

foreach ($f in $partFiles) {
    $p = Join-Path $PSScriptRoot $f
    if (-not (Test-Path -LiteralPath $p)) {
        throw "CoworkBillingPolicy is missing required file '$f'. Expected at: $p"
    }
    . $p
}

Export-ModuleMember -Function @(
    # Connection
    'Connect-CoworkPolicy'
    'Disconnect-CoworkPolicy'
    'Test-CoworkPolicyConnection'
    'Set-CoworkBillingRootPath'

    # Main workflow
    'Test-CoworkPolicyFile'
    'Invoke-CoworkPolicyImport'
    'New-CoworkPolicyTemplate'

    # Reading tenant state
    'Get-CoworkTenantCreditBalance'
    'Get-CoworkSpendingPolicy'
    'Get-CoworkUserBalance'
    'Get-CoworkServiceCatalog'

    # Diagnostics / support
    'Get-CoworkCsvColumn'
    'Get-CoworkPayloadLog'
    'Invoke-CoworkGraphRequest'
    'Initialize-CoworkContext'
    'Get-CoworkContext'
    'Clear-CoworkCache'
    'Register-CoworkLogSink'
    'Unregister-CoworkLogSink'
    'Write-CoworkLog'

    # Exposed for the GUI and for tests
    'Import-CoworkPolicyCsv'
    'Test-CoworkPolicyRowSet'
    'New-CoworkPolicyFromRow'
    'Write-CoworkReport'
    'Resolve-CoworkService'
    'Resolve-CoworkGroup'
    'Resolve-CoworkRecipient'
    'New-CoworkSpendingPolicyPayload'
    'New-CoworkEmailThresholdPayload'
    'New-CoworkServiceSettingPayload'
    'New-CoworkDirectoryRefPayload'
)
