# Cowork.Public.ps1
# User-facing entrypoints: validate, import, and report.

function Test-CoworkPolicyFile {
    <#
    .SYNOPSIS
        Validates a policy CSV without creating anything.
    .DESCRIPTION
        Parses the CSV, resolves groups/users/services against the tenant, and applies every
        validation rule. Nothing is written to the tenant.
    .PARAMETER Path
        Path to the policy CSV.
    .PARAMETER Offline
        Skip all tenant lookups (groups, users, existing policies, tenant balance).
        Useful for checking file structure before signing in.
    .PARAMETER ReportPath
        Write the results CSV to this path instead of the default reports folder.
    .EXAMPLE
        Test-CoworkPolicyFile -Path .\policies-sample.csv
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Path,
        [switch]$Offline,
        [string]$ReportPath
    )

    return Invoke-CoworkPolicyImport -Path $Path -Offline:$Offline -ReportPath $ReportPath
}

function Invoke-CoworkPolicyImport {
    <#
    .SYNOPSIS
        Validates a policy CSV and, with -Commit, creates the valid policies.
    .DESCRIPTION
        Validate-only by default. Nothing is ever written to the tenant unless -Commit is
        supplied. Every run produces a results CSV and a transcript log.

        With -Commit, each valid row is created through this sequence:
          POST /spendingPolicies
          POST .../assignedGroups/$ref            (per group, when AssignmentType=Groups)
          POST .../serviceSettings                (per service)
          PATCH .../emailThresholdSettings        (when an alert is configured)
          POST .../emailThresholdSettings/recipients/$ref   (per recipient)

        If any step after the first fails, the policy is deleted so the tenant is never left
        with a half-configured policy.
    .PARAMETER Path
        Path to the policy CSV.
    .PARAMETER Commit
        Actually create the policies. Without this switch the run is validate-only.
    .PARAMETER WhatIfPayload
        Print the method, full URL, and JSON body of every write call instead of sending it.
        Implies no changes are made. Use this to verify endpoint wiring and payload shapes.
    .PARAMETER Offline
        Skip tenant lookups. Cannot be combined with -Commit.
    .PARAMETER ReportPath
        Write the results CSV to this path instead of the default reports folder.
    .PARAMETER ContinueOnFailure
        Keep processing remaining rows after a row fails to create. On by default.
    .EXAMPLE
        Invoke-CoworkPolicyImport -Path .\policies-sample.csv
        Validate only.
    .EXAMPLE
        Invoke-CoworkPolicyImport -Path .\policies-sample.csv -WhatIfPayload
        Show exactly what would be sent.
    .EXAMPLE
        Invoke-CoworkPolicyImport -Path .\policies-sample.csv -Commit
        Validate, then create the valid policies.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Path,
        [switch]$Commit,
        [switch]$WhatIfPayload,
        [switch]$Offline,
        [string]$ReportPath,
        [bool]$ContinueOnFailure = $true
    )

    $ctx = Initialize-CoworkContext
    Start-CoworkLog | Out-Null

    if ($Offline -and $Commit) {
        throw "-Offline cannot be combined with -Commit. Offline mode skips the tenant lookups that creation depends on."
    }

    if (-not $Offline) { Assert-CoworkConnected | Out-Null }

    $ctx.WhatIfPayload = [bool]$WhatIfPayload
    if ($WhatIfPayload) {
        $ctx.PayloadLog.Clear()
        Write-CoworkLog -Level Info -Message "WhatIfPayload mode: no write calls will be sent."
    }

    try {
        # --- Parse ----------------------------------------------------------
        $rows = Import-CoworkPolicyCsv -Path $Path

        # --- Validate -------------------------------------------------------
        Write-CoworkLog -Level Info -Message "Validating $($rows.Count) row(s)..."
        $results = Test-CoworkPolicyRowSet -Rows $rows -SkipTenantLookups:$Offline

        $valid = @($results | Where-Object { $_.Status -eq 'Valid' })
        $invalid = @($results | Where-Object { $_.Status -eq 'Invalid' })
        $warned = @($results | Where-Object { $_.Warnings.Count -gt 0 })

        Write-CoworkLog -Level Info -Message "Validation complete: $($valid.Count) valid, $($invalid.Count) invalid, $($warned.Count) with warnings."

        foreach ($r in $invalid) {
            Write-CoworkLog -Level Error -Message "Row $($r.RowNumber) '$($r.PolicyName)' is INVALID:"
            foreach ($e in $r.Errors) { Write-CoworkLog -Level Error -Message "    - $e" }
        }
        foreach ($r in $warned) {
            foreach ($w in $r.Warnings) {
                Write-CoworkLog -Level Warn -Message "Row $($r.RowNumber) '$($r.PolicyName)': $w"
            }
        }

        # --- Commit ---------------------------------------------------------
        if (-not $Commit) {
            foreach ($r in $valid) { $r.Status = 'WouldCreate' }
            Write-CoworkLog -Level Info -Message "Validate-only run. $($valid.Count) policy/policies would be created. Re-run with -Commit to create them."
        }
        else {
            if ($valid.Count -eq 0) {
                Write-CoworkLog -Level Warn -Message "Nothing to create - no rows passed validation."
            }
            foreach ($r in $valid) {
                $null = New-CoworkPolicyFromRow -Result $r
                if ($r.Status -eq 'Failed' -and -not $ContinueOnFailure) {
                    Write-CoworkLog -Level Error -Message "Stopping: ContinueOnFailure is disabled."
                    break
                }
            }
            Clear-CoworkCache
        }

        # --- Report ---------------------------------------------------------
        $reportFile = Write-CoworkReport -Results $results -ReportPath $ReportPath
        Write-CoworkSummary -Results $results -Commit:$Commit -WhatIfPayload:$WhatIfPayload -ReportPath $reportFile

        if ($WhatIfPayload) {
            $log = Get-CoworkPayloadLog
            Write-CoworkLog -Level Info -Message "WhatIfPayload captured $($log.Count) write call(s). Retrieve them with Get-CoworkPayloadLog."
        }

        return , $results
    }
    finally {
        $ctx.WhatIfPayload = $false
    }
}

function Write-CoworkReport {
    <#
    .SYNOPSIS
        Writes the per-row results CSV.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Results,
        [string]$ReportPath
    )

    if (-not $ReportPath) {
        $dir = Resolve-CoworkOutputDirectory -Kind Report
        $ReportPath = Join-Path $dir ("cowork-policy-results-{0:yyyyMMdd-HHmmss}.csv" -f (Get-Date))
    }

    $rowsOut = foreach ($r in $Results) {
        [pscustomobject]@{
            RowNumber                     = $r.RowNumber
            PolicyName                    = $r.PolicyName
            Status                        = $r.Status
            PolicyId                      = $r.PolicyId
            AssignmentType                = $r.Row.AssignmentType
            Groups                        = ($r.Row.Groups -join '; ')
            ResolvedGroupIds              = (@($r.Row.ResolvedGroups | ForEach-Object { $_.Id }) -join '; ')
            Services                      = ($r.Row.Services -join '; ')
            ResolvedServiceIds            = (@($r.Row.ResolvedServices | ForEach-Object { $_.ServiceId }) -join '; ')
            MonthlySpendingLimitType      = $r.Row.MonthlySpendingLimitType
            MonthlySpendingLimitCredits   = $r.Row.MonthlySpendingLimitCredits
            UserMonthlyBudgetLimitType    = $r.Row.UserMonthlyBudgetLimitType
            UserMonthlyBudgetLimitCredits = $r.Row.UserMonthlyBudgetLimitCredits
            AlertEmails                   = ($r.Row.AlertEmails -join '; ')
            PolicyAlertThreshold          = (Format-CoworkThreshold -Type $r.Row.PolicyAlertThresholdType -Value $r.Row.PolicyAlertThresholdValue)
            UserAlertThreshold            = (Format-CoworkThreshold -Type $r.Row.UserAlertThresholdType -Value $r.Row.UserAlertThresholdValue)
            ErrorCount                    = $r.Errors.Count
            Errors                        = ($r.Errors -join ' | ')
            WarningCount                  = $r.Warnings.Count
            Warnings                      = ($r.Warnings -join ' | ')
            StepsCompleted                = ($r.StepsDone -join ' > ')
            FailedStep                    = $r.FailedStep
            Rollback                      = $r.RollbackResult
        }
    }

    $rowsOut | Export-Csv -LiteralPath $ReportPath -NoTypeInformation -Encoding UTF8
    Write-CoworkLog -Level Success -Message "Report written to $ReportPath"
    return $ReportPath
}

function Format-CoworkThreshold {
    [CmdletBinding()]
    param([string]$Type, $Value)
    if (-not $Type -or $null -eq $Value) { return '' }
    if ($Type -eq 'Percent') { return "$Value%" }
    return "$Value credits"
}

function Write-CoworkSummary {
    [CmdletBinding()]
    param($Results, [switch]$Commit, [switch]$WhatIfPayload, [string]$ReportPath)

    $counts = @{}
    foreach ($r in $Results) {
        if (-not $counts.ContainsKey($r.Status)) { $counts[$r.Status] = 0 }
        $counts[$r.Status]++
    }

    Write-Host ""
    Write-Host "================ Cowork Billing Policy Automator ================" -ForegroundColor Cyan
    $mode = if ($WhatIfPayload) { 'PREVIEW PAYLOADS (no changes made)' }
            elseif ($Commit) { 'COMMIT (policies created)' }
            else { 'VALIDATE ONLY (no changes made)' }
    Write-Host ("  Mode        : " + $mode)
    Write-Host ("  Rows        : " + @($Results).Count)
    foreach ($k in ($counts.Keys | Sort-Object)) {
        $color = switch ($k) {
            'Created'     { 'Green' }
            'Valid'       { 'Green' }
            'WouldCreate' { 'Green' }
            'Invalid'     { 'Red' }
            'Failed'      { 'Red' }
            default       { 'Gray' }
        }
        Write-Host ("  {0,-12}: {1}" -f $k, $counts[$k]) -ForegroundColor $color
    }
    $warnTotal = (@($Results) | ForEach-Object { $_.Warnings.Count } | Measure-Object -Sum).Sum
    Write-Host ("  Warnings    : " + [int]$warnTotal) -ForegroundColor Yellow
    Write-Host ("  Report      : " + $ReportPath)
    Write-Host "================================================================" -ForegroundColor Cyan

    if ((-not $Commit -or $WhatIfPayload) -and ($counts['Valid'] -or $counts['WouldCreate'])) {
        Write-Host "  Re-run with -Commit to create the valid policies." -ForegroundColor Yellow
    }
    Write-Host ""
}
