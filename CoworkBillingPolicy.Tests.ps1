<#
.SYNOPSIS
    Pester tests for the Cowork Billing Policy Automator.
.DESCRIPTION
    Every test mocks Invoke-CoworkGraphRequest, which is the single Graph entry point,
    so the whole suite runs offline with no tenant and no sign-in.

    Run with:
        Invoke-Pester .\CoworkBillingPolicy.Tests.ps1

    Compatible with Pester 5.
#>

BeforeAll {
    $script:Root = $PSScriptRoot
    Import-Module (Join-Path $Root 'CoworkBillingPolicy.psd1') -Force

    # -------------------------------------------------------------------
    # Test doubles
    #
    # These are deliberately $global: - Pester executes a -ModuleName mock body
    # inside the module's session state, where $script: would resolve to the
    # module scope rather than this test file.
    # -------------------------------------------------------------------
    $global:CwFakeGroups = @{
        'engineering team'     = 'g0000000-0000-0000-0000-000000000001'
        'finance department'   = 'g0000000-0000-0000-0000-000000000002'
        'ambiguous group'      = 'AMBIGUOUS'
    }
    $global:CwFakeUsers = @{
        'admin@contoso.com'    = 'u0000000-0000-0000-0000-000000000001'
        'finops@contoso.com'   = 'u0000000-0000-0000-0000-000000000002'
    }
    $global:CwTenantCredits = 1000000
    $global:CwExistingPolicies = @()
    $global:CwCreatedPolicies = [System.Collections.ArrayList]::new()
    $global:CwDeletedPolicies = [System.Collections.ArrayList]::new()
    $global:CwFailOnPath = $null

    function New-TestCsv {
        param([string[]]$DataRows)
        $header = 'PolicyName,AssignmentType,Groups,Services,MonthlySpendingLimitType,MonthlySpendingLimitCredits,UserMonthlyBudgetLimitType,UserMonthlyBudgetLimitCredits,AlertEmails,PolicyAlertThresholdType,PolicyAlertThresholdValue,UserAlertThresholdType,UserAlertThresholdValue'
        $path = Join-Path ([System.IO.Path]::GetTempPath()) ("cowork-test-{0}.csv" -f ([guid]::NewGuid()))
        Set-Content -LiteralPath $path -Value (@($header) + $DataRows) -Encoding UTF8
        return $path
    }

    function Invoke-TestValidation {
        param([string[]]$DataRows)
        $path = New-TestCsv -DataRows $DataRows
        try {
            $rows = Import-CoworkPolicyCsv -Path $path
            return , (Test-CoworkPolicyRowSet -Rows $rows)
        }
        finally {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
    }

    function Get-RowErrors { param($Results, [int]$Index = 0) return @($Results[$Index].Errors) }
    function Get-RowWarnings { param($Results, [int]$Index = 0) return @($Results[$Index].Warnings) }
    function Test-HasError { param($Results, [int]$Index = 0, [string]$Pattern)
        return [bool](@($Results[$Index].Errors) | Where-Object { $_ -match $Pattern })
    }
    function Test-HasWarning { param($Results, [int]$Index = 0, [string]$Pattern)
        return [bool](@($Results[$Index].Warnings) | Where-Object { $_ -match $Pattern })
    }
}

Describe 'CoworkBillingPolicy' {
    BeforeEach {
        Clear-CoworkCache
        $global:CwCreatedPolicies.Clear()
        $global:CwDeletedPolicies.Clear()
        $global:CwFailOnPath = $null
        $global:CwTenantCredits = 1000000
        $global:CwExistingPolicies = @()

        # The single mock point for every Graph call in the module.
        Mock -ModuleName CoworkBillingPolicy Invoke-CoworkGraphRequest {
            param($Path, $Method, $Body, [switch]$All, [switch]$IsWrite, [switch]$SuppressWhatIf, $BillingRootOverride)

            if ($global:CwFailOnPath -and $Path -like $global:CwFailOnPath) {
                throw "Simulated failure for path '$Path'."
            }

            switch -Regex ($Path) {

                '^getTenantCreditBalance' {
                    return [pscustomobject]@{ totalCredits = $global:CwTenantCredits; consumedCredits = 0 }
                }

                '^spendingPolicies/?$' {
                    if ($Method -eq 'POST') {
                        $id = "p-$([guid]::NewGuid())"
                        [void]$global:CwCreatedPolicies.Add([pscustomobject]@{ Id = $id; Body = $Body })
                        return [pscustomobject]@{ id = $id; displayName = $Body.displayName }
                    }
                    return , @($global:CwExistingPolicies)
                }

                '^spendingPolicies/[^/]+$' {
                    if ($Method -eq 'DELETE') {
                        [void]$global:CwDeletedPolicies.Add($Path)
                        return $null
                    }
                    $id = ($Path -split '/')[1]
                    $c = @($global:CwCreatedPolicies | Where-Object { $_.Id -eq $id })
                    if ($c.Count -gt 0) {
                        return [pscustomobject]@{
                            id                 = $id
                            displayName        = $c[0].Body.displayName
                            monthlyCreditLimit = $c[0].Body.monthlyCreditLimit
                        }
                    }
                    return [pscustomobject]@{ id = $id }
                }

                'assignedGroups' { if ($Method -eq 'POST') { return $null }; return , @() }
                'serviceSettings' { if ($Method -eq 'POST') { return $null }; return , @() }
                'recipients' { if ($Method -eq 'POST') { return $null }; return , @() }
                'emailThresholdSettings' { if ($Method -eq 'PATCH') { return $null }; return [pscustomobject]@{ isEnabled = $true } }

                '^directory:groups/' {
                    $id = ($Path -split '/')[1]
                    return [pscustomobject]@{ id = $id; displayName = 'By Id Group' }
                }

                '^directory:groups\?' {
                    $decoded = [uri]::UnescapeDataString($Path)
                    if ($decoded -match "displayName eq '([^']*)'") {
                        $name = $Matches[1].ToLowerInvariant()
                        if ($name -eq 'ambiguous group') {
                            return , @(
                                [pscustomobject]@{ id = 'dup-1'; displayName = 'Ambiguous Group' },
                                [pscustomobject]@{ id = 'dup-2'; displayName = 'Ambiguous Group' }
                            )
                        }
                        if ($global:CwFakeGroups.ContainsKey($name)) {
                            return , @([pscustomobject]@{ id = $global:CwFakeGroups[$name]; displayName = $Matches[1] })
                        }
                    }
                    return , @()
                }

                '^directory:users/' {
                    $seg = [uri]::UnescapeDataString((($Path -split '/')[1] -split '\?')[0]).ToLowerInvariant()
                    if ($global:CwFakeUsers.ContainsKey($seg)) {
                        return [pscustomobject]@{ id = $global:CwFakeUsers[$seg]; userPrincipalName = $seg }
                    }
                    throw "User '$seg' not found (simulated 404)."
                }

                '^directory:users\?' { return , @() }

                default { return $null }
            }
        }
    }

}
Describe 'CSV parsing' {

    It 'parses a well-formed row and splits semicolon multi-values' {
        $path = New-TestCsv -DataRows @('Cowork Standard Policy,Groups,Engineering Team;Finance Department,Copilot Cowork;Copilot Studio,Limited,12000,Limited,7000,admin@contoso.com,Percent,80,Percent,70')
        try {
            $rows = Import-CoworkPolicyCsv -Path $path
            $rows.Count | Should -Be 1
            $rows[0].Groups.Count | Should -Be 2
            $rows[0].Services.Count | Should -Be 2
            $rows[0].AlertEmails.Count | Should -Be 1
            $rows[0].AssignmentType | Should -Be 'Groups'
        }
        finally { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
    }

    It 'normalizes enum casing and spacing' {
        $path = New-TestCsv -DataRows @('Cowork Standard Policy,all users,,Copilot Cowork,no limit,,NO_LIMIT,,,,,,')
        try {
            $rows = Import-CoworkPolicyCsv -Path $path
            $rows[0].AssignmentType | Should -Be 'AllUsers'
            $rows[0].MonthlySpendingLimitType | Should -Be 'NoLimit'
            $rows[0].UserMonthlyBudgetLimitType | Should -Be 'NoLimit'
        }
        finally { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
    }

    It 'throws when a required column is missing' {
        $path = Join-Path ([System.IO.Path]::GetTempPath()) ("cowork-bad-{0}.csv" -f ([guid]::NewGuid()))
        Set-Content -LiteralPath $path -Value @('PolicyName,AssignmentType', 'Cowork Standard Policy,AllUsers') -Encoding UTF8
        try {
            { Import-CoworkPolicyCsv -Path $path } | Should -Throw -ExpectedMessage '*missing required column*'
        }
        finally { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Rule 1 - policy name' {

    It 'rejects a name shorter than 10 characters' {
        $r = Invoke-TestValidation @('Short,AllUsers,,Copilot Cowork,Limited,12000,Limited,7000,,,,,')
        Test-HasError -Results $r -Pattern 'at least 10 characters' | Should -BeTrue
        $r[0].Status | Should -Be 'Invalid'
    }

    It 'accepts a name of exactly 10 characters' {
        $r = Invoke-TestValidation @('TenCharsOK,AllUsers,,Copilot Cowork,Limited,12000,Limited,7000,,,,,')
        Test-HasError -Results $r -Pattern 'at least 10 characters' | Should -BeFalse
    }

    It 'rejects duplicate names within the same file' {
        $r = Invoke-TestValidation @(
            'Cowork Standard Policy,AllUsers,,Copilot Cowork,Limited,12000,Limited,7000,,,,,',
            'Cowork Standard Policy,AllUsers,,Copilot Cowork,Limited,12000,Limited,7000,,,,,'
        )
        Test-HasError -Results $r -Index 1 -Pattern 'Duplicate PolicyName' | Should -BeTrue
    }

    It 'rejects a name that already exists in the tenant' {
        $global:CwExistingPolicies = @([pscustomobject]@{ id = 'existing-1'; displayName = 'Cowork Standard Policy' })
        $r = Invoke-TestValidation @('Cowork Standard Policy,AllUsers,,Copilot Cowork,Limited,12000,Limited,7000,,,,,')
        Test-HasError -Results $r -Pattern 'already exists in the tenant' | Should -BeTrue
    }
}

Describe 'Rules 2 and 3 - assignment and groups' {

    It 'rejects an unknown AssignmentType' {
        $r = Invoke-TestValidation @('Cowork Standard Policy,Everyone,,Copilot Cowork,Limited,12000,Limited,7000,,,,,')
        Test-HasError -Results $r -Pattern "AssignmentType must be" | Should -BeTrue
    }

    It 'requires Groups when AssignmentType is Groups' {
        $r = Invoke-TestValidation @('Cowork Standard Policy,Groups,,Copilot Cowork,Limited,12000,Limited,7000,,,,,')
        Test-HasError -Results $r -Pattern 'Groups is required' | Should -BeTrue
    }

    It 'resolves a known group' {
        $r = Invoke-TestValidation @('Cowork Standard Policy,Groups,Engineering Team,Copilot Cowork,Limited,12000,Limited,7000,,,,,')
        $r[0].Status | Should -Be 'Valid'
        $r[0].Row.ResolvedGroups.Count | Should -Be 1
    }

    It 'rejects a group that does not exist' {
        $r = Invoke-TestValidation @('Cowork Standard Policy,Groups,No Such Group,Copilot Cowork,Limited,12000,Limited,7000,,,,,')
        Test-HasError -Results $r -Pattern 'was not found in the tenant' | Should -BeTrue
    }

    It 'rejects an ambiguous group display name' {
        $r = Invoke-TestValidation @('Cowork Standard Policy,Groups,Ambiguous Group,Copilot Cowork,Limited,12000,Limited,7000,,,,,')
        Test-HasError -Results $r -Pattern 'is ambiguous' | Should -BeTrue
    }

    It 'warns that Groups is ignored for AllUsers' {
        $r = Invoke-TestValidation @('Cowork Standard Policy,AllUsers,Engineering Team,Copilot Cowork,Limited,12000,Limited,7000,,,,,')
        Test-HasWarning -Results $r -Pattern 'ignored because AssignmentType' | Should -BeTrue
    }
}

Describe 'Rule 4 - services' {

    It 'resolves Copilot Cowork from the catalog' {
        $r = Invoke-TestValidation @('Cowork Standard Policy,AllUsers,,Copilot Cowork,Limited,12000,Limited,7000,,,,,')
        $r[0].Row.ResolvedServices.Count | Should -Be 1
        $r[0].Status | Should -Be 'Valid'
    }

    It 'resolves an alias' {
        $r = Invoke-TestValidation @('Cowork Standard Policy,AllUsers,,Cowork,Limited,12000,Limited,7000,,,,,')
        $r[0].Row.ResolvedServices.Count | Should -Be 1
    }

    It 'rejects an unknown service' {
        $r = Invoke-TestValidation @('Cowork Standard Policy,AllUsers,,Totally Unknown Agent,Limited,12000,Limited,7000,,,,,')
        Test-HasError -Results $r -Pattern 'Unknown service' | Should -BeTrue
    }

    It 'requires at least one service' {
        $r = Invoke-TestValidation @('Cowork Standard Policy,AllUsers,,,Limited,12000,Limited,7000,,,,,')
        Test-HasError -Results $r -Pattern 'Services is required' | Should -BeTrue
    }

    It 'passes a raw GUID through unmapped' {
        $g = [guid]::NewGuid().ToString()
        $r = Invoke-TestValidation @("Cowork Standard Policy,AllUsers,,$g,Limited,12000,Limited,7000,,,,,")
        $r[0].Row.ResolvedServices[0].ServiceId | Should -Be $g
    }
}

Describe 'Rules 5 and 6 - policy monthly limit' {

    It 'rejects a limit below the 4000 minimum' {
        $r = Invoke-TestValidation @('Cowork Standard Policy,AllUsers,,Copilot Cowork,Limited,3000,Limited,2000,,,,,')
        Test-HasError -Results $r -Pattern 'at least 4000 credits' | Should -BeTrue
    }

    It 'accepts exactly 4000 but warns it is below the recommendation' {
        $r = Invoke-TestValidation @('Cowork Standard Policy,AllUsers,,Copilot Cowork,Limited,4000,Limited,2000,,,,,')
        Test-HasError -Results $r -Pattern 'at least 4000 credits' | Should -BeFalse
        Test-HasWarning -Results $r -Pattern 'suggest 10000 or more' | Should -BeTrue
    }

    It 'does not warn at or above the 10000 recommendation' {
        $r = Invoke-TestValidation @('Cowork Standard Policy,AllUsers,,Copilot Cowork,Limited,10000,Limited,7000,,,,,')
        Test-HasWarning -Results $r -Pattern 'suggest 10000 or more' | Should -BeFalse
    }

    It 'requires credits when the type is Limited' {
        $r = Invoke-TestValidation @('Cowork Standard Policy,AllUsers,,Copilot Cowork,Limited,,NoLimit,,,,,,')
        Test-HasError -Results $r -Pattern 'MonthlySpendingLimitCredits is required' | Should -BeTrue
    }

    It 'rejects a non-numeric credit value' {
        $r = Invoke-TestValidation @('Cowork Standard Policy,AllUsers,,Copilot Cowork,Limited,lots,NoLimit,,,,,,')
        Test-HasError -Results $r -Pattern 'must be a number' | Should -BeTrue
    }

    It 'tolerates thousands separators' {
        $path = New-TestCsv -DataRows @('"Cowork Standard Policy",AllUsers,,Copilot Cowork,Limited,"12,000",NoLimit,,,,,,')
        try {
            $rows = Import-CoworkPolicyCsv -Path $path
            $res = Test-CoworkPolicyRowSet -Rows $rows
            $res[0].Row.MonthlySpendingLimitCredits | Should -Be 12000
        }
        finally { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
    }

    It 'warns that credits are ignored when the type is NoLimit' {
        $r = Invoke-TestValidation @('Cowork Standard Policy,AllUsers,,Copilot Cowork,NoLimit,12000,NoLimit,,,,,,')
        Test-HasWarning -Results $r -Pattern 'ignored because MonthlySpendingLimitType' | Should -BeTrue
    }
}

Describe 'Rules 7 and 8 - per-user budget limit' {

    It 'rejects a user budget below the 2000 minimum' {
        $r = Invoke-TestValidation @('Cowork Standard Policy,AllUsers,,Copilot Cowork,Limited,12000,Limited,1500,,,,,')
        Test-HasError -Results $r -Pattern 'at least 2000 credits' | Should -BeTrue
    }

    It 'accepts exactly 2000 but warns it is below the recommendation' {
        $r = Invoke-TestValidation @('Cowork Standard Policy,AllUsers,,Copilot Cowork,Limited,12000,Limited,2000,,,,,')
        Test-HasError -Results $r -Pattern 'at least 2000 credits' | Should -BeFalse
        Test-HasWarning -Results $r -Pattern 'suggest 7000 or more' | Should -BeTrue
    }

    It 'rejects a user budget greater than the policy limit' {
        $r = Invoke-TestValidation @('Cowork Standard Policy,AllUsers,,Copilot Cowork,Limited,5000,Limited,9000,,,,,')
        Test-HasError -Results $r -Pattern 'cannot exceed MonthlySpendingLimitCredits' | Should -BeTrue
    }

    It 'allows a user budget equal to the policy limit' {
        $r = Invoke-TestValidation @('Cowork Standard Policy,AllUsers,,Copilot Cowork,Limited,8000,Limited,8000,,,,,')
        Test-HasError -Results $r -Pattern 'cannot exceed MonthlySpendingLimitCredits' | Should -BeFalse
    }
}

Describe 'Rule 9 - tenant credit ceiling' {

    It 'rejects rows whose combined limits exceed the tenant balance' {
        $global:CwTenantCredits = 15000
        $r = Invoke-TestValidation @(
            'Cowork Policy Alpha One,AllUsers,,Copilot Cowork,Limited,10000,NoLimit,,,,,,',
            'Cowork Policy Beta Two,AllUsers,,Copilot Cowork,Limited,10000,NoLimit,,,,,,'
        )
        Test-HasError -Results $r -Pattern 'Tenant credit ceiling exceeded' | Should -BeTrue
    }

    It 'counts existing policy commitments toward the ceiling' {
        $global:CwTenantCredits = 15000
        $global:CwExistingPolicies = @([pscustomobject]@{ id = 'e1'; displayName = 'Existing One'; monthlyCreditLimit = 12000 })
        $r = Invoke-TestValidation @('Cowork Policy Alpha One,AllUsers,,Copilot Cowork,Limited,10000,NoLimit,,,,,,')
        Test-HasError -Results $r -Pattern 'Tenant credit ceiling exceeded' | Should -BeTrue
    }

    It 'warns above the 80% utilization threshold' {
        $global:CwTenantCredits = 10000
        $r = Invoke-TestValidation @('Cowork Policy Alpha One,AllUsers,,Copilot Cowork,Limited,9000,NoLimit,,,,,,')
        Test-HasWarning -Results $r -Pattern 'utilization' | Should -BeTrue
    }

    It 'stays quiet well below the threshold' {
        $global:CwTenantCredits = 1000000
        $r = Invoke-TestValidation @('Cowork Policy Alpha One,AllUsers,,Copilot Cowork,Limited,10000,NoLimit,,,,,,')
        Test-HasWarning -Results $r -Pattern 'utilization' | Should -BeFalse
    }
}

Describe 'Rules 10 to 15 - alerts' {

    It 'rejects a percentage above 100' {
        $r = Invoke-TestValidation @('Cowork Standard Policy,AllUsers,,Copilot Cowork,Limited,12000,Limited,7000,admin@contoso.com,Percent,150,,')
        Test-HasError -Results $r -Pattern 'must be between 1 and 100' | Should -BeTrue
    }

    It 'accepts exactly 100 percent' {
        $r = Invoke-TestValidation @('Cowork Standard Policy,AllUsers,,Copilot Cowork,Limited,12000,Limited,7000,admin@contoso.com,Percent,100,,')
        Test-HasError -Results $r -Pattern 'must be between 1 and 100' | Should -BeFalse
    }

    It 'rejects a credit threshold that exceeds the policy limit' {
        $r = Invoke-TestValidation @('Cowork Standard Policy,AllUsers,,Copilot Cowork,Limited,12000,Limited,7000,admin@contoso.com,Credits,20000,,')
        Test-HasError -Results $r -Pattern 'cannot exceed MonthlySpendingLimitCredits' | Should -BeTrue
    }

    It 'rejects a percentage threshold when the policy has no limit' {
        $r = Invoke-TestValidation @('Cowork Standard Policy,AllUsers,,Copilot Cowork,NoLimit,,NoLimit,,admin@contoso.com,Percent,80,,')
        Test-HasError -Results $r -Pattern "is 'Percent' but MonthlySpendingLimitType is 'NoLimit'" | Should -BeTrue
    }

    It 'rejects a user alert when no per-user budget limit is configured, with an explicit message' {
        $r = Invoke-TestValidation @('Cowork Standard Policy,AllUsers,,Copilot Cowork,Limited,12000,NoLimit,,admin@contoso.com,Percent,80,Percent,75')
        Test-HasError -Results $r -Pattern 'A user spending alert cannot be configured because no per-user monthly budget limit is set' | Should -BeTrue
    }

    It 'allows a user alert when the per-user budget limit is configured' {
        $r = Invoke-TestValidation @('Cowork Standard Policy,AllUsers,,Copilot Cowork,Limited,12000,Limited,7000,admin@contoso.com,Percent,80,Percent,75')
        $r[0].Status | Should -Be 'Valid'
    }

    It 'requires recipients when a threshold is set' {
        $r = Invoke-TestValidation @('Cowork Standard Policy,AllUsers,,Copilot Cowork,Limited,12000,Limited,7000,,Percent,80,,')
        Test-HasError -Results $r -Pattern 'AlertEmails is required' | Should -BeTrue
    }

    It 'rejects recipients with no threshold' {
        $r = Invoke-TestValidation @('Cowork Standard Policy,AllUsers,,Copilot Cowork,Limited,12000,Limited,7000,admin@contoso.com,,,,')
        Test-HasError -Results $r -Pattern 'no alert threshold is configured' | Should -BeTrue
    }

    It 'rejects a threshold value with no type' {
        $r = Invoke-TestValidation @('Cowork Standard Policy,AllUsers,,Copilot Cowork,Limited,12000,Limited,7000,admin@contoso.com,,80,,')
        Test-HasError -Results $r -Pattern 'PolicyAlertThresholdValue is .80. but PolicyAlertThresholdType is empty' | Should -BeTrue
    }

    It 'rejects a threshold type with no value' {
        $r = Invoke-TestValidation @('Cowork Standard Policy,AllUsers,,Copilot Cowork,Limited,12000,Limited,7000,admin@contoso.com,Percent,,,')
        Test-HasError -Results $r -Pattern 'PolicyAlertThresholdValue is empty' | Should -BeTrue
    }

    It 'rejects an unresolvable recipient' {
        $r = Invoke-TestValidation @('Cowork Standard Policy,AllUsers,,Copilot Cowork,Limited,12000,Limited,7000,ghost@contoso.com,Percent,80,,')
        Test-HasError -Results $r -Pattern 'was not found in the tenant' | Should -BeTrue
    }

    It 'warns when a threshold is above 90 percent' {
        $r = Invoke-TestValidation @('Cowork Standard Policy,AllUsers,,Copilot Cowork,Limited,12000,Limited,7000,admin@contoso.com,Percent,95,,')
        Test-HasWarning -Results $r -Pattern 'little time to react' | Should -BeTrue
    }

    It 'warns when a limited policy has no alert at all' {
        $r = Invoke-TestValidation @('Cowork Standard Policy,AllUsers,,Copilot Cowork,Limited,12000,NoLimit,,,,,,')
        Test-HasWarning -Results $r -Pattern 'No spending alert is configured' | Should -BeTrue
    }
}

Describe 'Payload builders' {

    It 'uses allUsersSpendingPolicy for AllUsers' {
        $r = Invoke-TestValidation @('Cowork Standard Policy,AllUsers,,Copilot Cowork,Limited,12000,Limited,7000,,,,,')
        $p = New-CoworkSpendingPolicyPayload -Row $r[0].Row
        $p['@odata.type'] | Should -Be '#microsoft.graph.allUsersSpendingPolicy'
        $p['monthlyCreditLimit'] | Should -Be 12000
        $p['userMonthlyCreditLimit'] | Should -Be 7000
    }

    It 'uses selectedGroupsSpendingPolicy for Groups' {
        $r = Invoke-TestValidation @('Cowork Standard Policy,Groups,Engineering Team,Copilot Cowork,Limited,12000,NoLimit,,,,,,')
        $p = New-CoworkSpendingPolicyPayload -Row $r[0].Row
        $p['@odata.type'] | Should -Be '#microsoft.graph.selectedGroupsSpendingPolicy'
        $p['isUserMonthlyCreditLimitEnabled'] | Should -BeFalse
    }

    It 'emits percentage and credit thresholds in the right fields' {
        $r = Invoke-TestValidation @('Cowork Standard Policy,AllUsers,,Copilot Cowork,Limited,12000,Limited,7000,admin@contoso.com,Percent,80,Credits,5000')
        $t = New-CoworkEmailThresholdPayload -Row $r[0].Row
        $t['thresholdPercentage'] | Should -Be 80
        $t['userThresholdCredits'] | Should -Be 5000
        $t['isEnabled'] | Should -BeTrue
    }

    It 'builds an OData $ref body' {
        $b = New-CoworkDirectoryRefPayload -EntitySet 'groups' -Id 'abc-123'
        $b['@odata.id'] | Should -Match 'groups/abc-123$'
    }
}

Describe 'Creation and rollback' {

    It 'creates a policy and records every step' {
        $r = Invoke-TestValidation @('Cowork Standard Policy,Groups,Engineering Team,Copilot Cowork,Limited,12000,Limited,7000,admin@contoso.com,Percent,80,Percent,70')
        $r[0].Status | Should -Be 'Valid'

        $out = New-CoworkPolicyFromRow -Result $r[0]
        $out.Status | Should -Be 'Created'
        $out.PolicyId | Should -Not -BeNullOrEmpty
        ($out.StepsDone -join ',') | Should -Match 'CreatePolicy'
        ($out.StepsDone -join ',') | Should -Match 'AssignGroups'
        ($out.StepsDone -join ',') | Should -Match 'ServiceSettings'
        ($out.StepsDone -join ',') | Should -Match 'AlertThresholds'
        ($out.StepsDone -join ',') | Should -Match 'AlertRecipients'
        $global:CwDeletedPolicies.Count | Should -Be 0
    }

    It 'rolls back by deleting the policy when a later step fails' {
        $r = Invoke-TestValidation @('Cowork Standard Policy,AllUsers,,Copilot Cowork,Limited,12000,Limited,7000,admin@contoso.com,Percent,80,,')
                $global:CwFailOnPath = '*serviceSettings*'

        $out = New-CoworkPolicyFromRow -Result $r[0]
        $out.Status | Should -Be 'Failed'
        $out.FailedStep | Should -Be 'ServiceSettings'
        $out.RollbackResult | Should -Be 'RolledBack'
                $global:CwDeletedPolicies.Count | Should -Be 1
    }

    It 'does not attempt rollback when the initial create fails' {
        $r = Invoke-TestValidation @('Cowork Standard Policy,AllUsers,,Copilot Cowork,Limited,12000,Limited,7000,,,,,')
        $global:CwFailOnPath = 'spendingPolicies'

        $out = New-CoworkPolicyFromRow -Result $r[0]
        $out.Status | Should -Be 'Failed'
        $out.RollbackResult | Should -Be 'NotNeeded'
        $global:CwDeletedPolicies.Count | Should -Be 0
    }

    It 'reports a rollback failure instead of swallowing it' {
        $r = Invoke-TestValidation @('Cowork Standard Policy,AllUsers,,Copilot Cowork,Limited,12000,NoLimit,,,,,,')
        $global:CwFailOnPath = '*serviceSettings*'

        Mock -ModuleName CoworkBillingPolicy Invoke-CoworkPolicyRollback { return 'RollbackFailed: simulated' }
        $out = New-CoworkPolicyFromRow -Result $r[0]
        $out.RollbackResult | Should -Match 'RollbackFailed'
    }
}

Describe 'End-to-end import' {

    It 'does not write anything in validate-only mode' {
        Mock -ModuleName CoworkBillingPolicy Assert-CoworkConnected { return [pscustomobject]@{ Account = 'test@contoso.com' } }
        $path = New-TestCsv -DataRows @('Cowork Standard Policy,AllUsers,,Copilot Cowork,Limited,12000,Limited,7000,admin@contoso.com,Percent,80,Percent,70')
        try {
            $res = Invoke-CoworkPolicyImport -Path $path
            $res[0].Status | Should -Be 'WouldCreate'
            $global:CwCreatedPolicies.Count | Should -Be 0
        }
        finally { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
    }

    It 'creates policies when -Commit is supplied' {
        Mock -ModuleName CoworkBillingPolicy Assert-CoworkConnected { return [pscustomobject]@{ Account = 'test@contoso.com' } }
        $path = New-TestCsv -DataRows @('Cowork Standard Policy,AllUsers,,Copilot Cowork,Limited,12000,Limited,7000,admin@contoso.com,Percent,80,Percent,70')
        try {
            $res = Invoke-CoworkPolicyImport -Path $path -Commit
            $res[0].Status | Should -Be 'Created'
            $global:CwCreatedPolicies.Count | Should -Be 1
        }
        finally { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
    }

    It 'skips invalid rows and creates only the valid ones' {
        Mock -ModuleName CoworkBillingPolicy Assert-CoworkConnected { return [pscustomobject]@{ Account = 'test@contoso.com' } }
        $path = New-TestCsv -DataRows @(
            'Short,AllUsers,,Copilot Cowork,Limited,12000,NoLimit,,,,,,',
            'Cowork Standard Policy,AllUsers,,Copilot Cowork,Limited,12000,NoLimit,,,,,,'
        )
        try {
            $res = Invoke-CoworkPolicyImport -Path $path -Commit
            $res[0].Status | Should -Be 'Invalid'
            $res[1].Status | Should -Be 'Created'
            $global:CwCreatedPolicies.Count | Should -Be 1
        }
        finally { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
    }

    It 'rejects -Offline combined with -Commit' {
        $path = New-TestCsv -DataRows @('Cowork Standard Policy,AllUsers,,Copilot Cowork,Limited,12000,NoLimit,,,,,,')
        try {
            { Invoke-CoworkPolicyImport -Path $path -Offline -Commit } | Should -Throw -ExpectedMessage '*cannot be combined*'
        }
        finally { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Shipped sample files' {

    It 'validates the shipped valid sample with no errors' {
        Mock -ModuleName CoworkBillingPolicy Assert-CoworkConnected { return [pscustomobject]@{ Account = 'test@contoso.com' } }
        $global:CwFakeGroups['platform engineering'] = 'g-003'
        $global:CwFakeGroups['executive leadership'] = 'g-004'
        $global:CwFakeUsers['billing-admins@contoso.com'] = 'u-003'
        $global:CwFakeUsers['ops-lead@contoso.com'] = 'u-004'
        $global:CwFakeUsers['finance-ops@contoso.com'] = 'u-005'

        $sample = Join-Path $script:Root 'policies-sample.csv'
        $rows = Import-CoworkPolicyCsv -Path $sample
        $rows.Count | Should -Be 4
    }

    It 'flags every row of the shipped invalid sample' {
        $sample = Join-Path $script:Root 'policies-invalid-sample.csv'
        $rows = Import-CoworkPolicyCsv -Path $sample
        $res = Test-CoworkPolicyRowSet -Rows $rows
        @($res | Where-Object { $_.Status -eq 'Invalid' }).Count | Should -Be $rows.Count
    }

    AfterAll {
        'CwFakeGroups', 'CwFakeUsers', 'CwTenantCredits', 'CwExistingPolicies',
        'CwCreatedPolicies', 'CwDeletedPolicies', 'CwFailOnPath' | ForEach-Object {
            Remove-Variable -Name $_ -Scope Global -ErrorAction SilentlyContinue
        }
    }
}
