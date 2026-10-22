@{
    RootModule        = 'CoworkBillingPolicy.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'b7e9a4c1-5f3d-4a86-9c21-0d47f8e26b3a'
    Author            = 'Cowork Billing Policy Automator'
    CompanyName       = 'Microsoft'
    Description       = 'Create and safely delete Microsoft Copilot Cowork spending (billing) policies, with pre-flight validation, preview-by-default workflows, ETag protection, and rollback on partial failure.'

    PowerShellVersion = '5.1'

    # Microsoft.Graph.Authentication is required for anything that talks to the tenant, but it is
    # deliberately NOT declared in RequiredModules: that would block Import-Module outright on a
    # machine without the Graph SDK, and offline work (Import-CoworkPolicyCsv, -Offline validation,
    # the Pester suite) needs no Graph at all. Connect-CoworkPolicy checks for it and emits the
    # exact Install-Module command if it is missing.

    FunctionsToExport = @(
        'Connect-CoworkPolicy'
        'Disconnect-CoworkPolicy'
        'Test-CoworkPolicyConnection'
        'Set-CoworkBillingRootPath'
        'Test-CoworkPolicyFile'
        'Invoke-CoworkPolicyImport'
        'Remove-CoworkSpendingPolicy'
        'New-CoworkPolicyTemplate'
        'Get-CoworkTenantCreditBalance'
        'Get-CoworkSpendingPolicy'
        'Get-CoworkUserBalance'
        'Get-CoworkServiceCatalog'
        'Get-CoworkCsvColumn'
        'Get-CoworkPayloadLog'
        'Invoke-CoworkGraphRequest'
        'Initialize-CoworkContext'
        'Get-CoworkContext'
        'Clear-CoworkCache'
        'Register-CoworkLogSink'
        'Unregister-CoworkLogSink'
        'Write-CoworkLog'
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

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags = @('Microsoft365', 'Copilot', 'Cowork', 'Billing', 'SpendingPolicy', 'Graph')
        }
    }
}
