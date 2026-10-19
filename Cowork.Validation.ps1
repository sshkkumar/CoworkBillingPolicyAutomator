# Cowork.Validation.ps1
# All validation rules. Errors reject a row; warnings are advisory only.

function New-CoworkRowResult {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Row)

    return [pscustomobject]@{
        RowNumber   = $Row.RowNumber
        PolicyName  = $Row.PolicyName
        Status      = 'Pending'
        Errors      = (New-Object System.Collections.ArrayList)
        Warnings    = (New-Object System.Collections.ArrayList)
        Row         = $Row
        PolicyId    = $null
        StepsDone   = (New-Object System.Collections.ArrayList)
        FailedStep  = $null
        RollbackResult = $null
    }
}

function Add-CoworkError {
    param($Result, [string]$Message)
    [void]$Result.Errors.Add($Message)
}

function Add-CoworkWarning {
    param($Result, [string]$Message)
    [void]$Result.Warnings.Add($Message)
}

function Test-CoworkPolicyRowSet {
    <#
    .SYNOPSIS
        Validates every row of a parsed CSV and returns one result object per row.
    .PARAMETER Rows
        Output of Import-CoworkPolicyCsv.
    .PARAMETER SkipTenantLookups
        Skip all online lookups (groups, users, tenant balance, existing policies).
        Used by offline tests.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Rows,
        [switch]$SkipTenantLookups
    )

    $ctx = Get-CoworkContext
    $limits = $ctx.Config.Limits
    $behaviour = $ctx.Config.Behaviour

    $results = @(@($Rows) | ForEach-Object { New-CoworkRowResult -Row $_ })

    # --- Online context -----------------------------------------------------
    $existingPolicies = @()
    $existingNames = @{}
    $tenantTotal = $null
    $existingCommitted = 0.0

    if (-not $SkipTenantLookups) {
        try {
            $existingPolicies = @(Get-CoworkSpendingPolicy)
            foreach ($p in $existingPolicies) {
                $n = Get-CoworkFirstStringProperty -Object $p -Names @('displayName', 'name')
                if ($n) { $existingNames[$n.Trim().ToLowerInvariant()] = (Get-CoworkObjectId -Object $p) }
                $lim = Get-CoworkPolicyLimitCredits -Policy $p
                if ($null -ne $lim) { $existingCommitted += $lim }
            }
        }
        catch {
            Write-CoworkLog -Level Warn -Message "Could not list existing spending policies - duplicate-name and tenant-ceiling checks will be skipped. $($_.Exception.Message)"
        }

        try {
            $bal = Get-CoworkTenantCreditBalance
            $tenantTotal = $bal.TotalCredits
        }
        catch {
            Write-CoworkLog -Level Warn -Message "Could not read tenant credit balance - tenant-ceiling validation will be skipped. $($_.Exception.Message)"
        }
    }

    # --- Per-row rules ------------------------------------------------------
    $seenNames = @{}

    foreach ($res in $results) {
        $row = $res.Row

        # Order matters: limits are parsed before the alert rules compare thresholds to them.
        Test-CoworkRuleName            -Result $res -Row $row -Limits $limits -SeenNames $seenNames -ExistingNames $existingNames | Out-Null
        Test-CoworkRuleAssignment      -Result $res -Row $row -SkipLookups:$SkipTenantLookups | Out-Null
        Test-CoworkRuleServices        -Result $res -Row $row | Out-Null
        Test-CoworkRulePolicyLimit     -Result $res -Row $row -Limits $limits | Out-Null
        Test-CoworkRuleUserLimit       -Result $res -Row $row -Limits $limits -Behaviour $behaviour | Out-Null
        Test-CoworkRuleAlerts          -Result $res -Row $row -Limits $limits -SkipLookups:$SkipTenantLookups | Out-Null

        $res.Status = if ($res.Errors.Count -gt 0) { 'Invalid' } else { 'Valid' }
    }

    # --- Cross-row / tenant ceiling ----------------------------------------
    Test-CoworkRuleTenantCeiling -Results $results -TenantTotal $tenantTotal `
        -ExistingCommitted $existingCommitted -Limits $limits -Behaviour $behaviour

    foreach ($res in $results) {
        $res.Status = if ($res.Errors.Count -gt 0) { 'Invalid' } else { 'Valid' }
    }

    return , $results
}

# ---------------------------------------------------------------------------
# Rule 1 - policy name
# ---------------------------------------------------------------------------
function Test-CoworkRuleName {
    param($Result, $Row, $Limits, $SeenNames, $ExistingNames)

    $name = $Row.PolicyName

    if ([string]::IsNullOrWhiteSpace($name)) {
        Add-CoworkError $Result "PolicyName is required."
        return
    }

    $min = [int]$Limits.PolicyNameMinLength
    $max = [int]$Limits.PolicyNameMaxLength

    if ($name.Length -lt $min) {
        Add-CoworkError $Result "PolicyName must be at least $min characters. '$name' is $($name.Length)."
    }
    if ($max -gt 0 -and $name.Length -gt $max) {
        Add-CoworkError $Result "PolicyName must be $max characters or fewer. '$name' is $($name.Length)."
    }

    $key = $name.Trim().ToLowerInvariant()

    if ($SeenNames.ContainsKey($key)) {
        Add-CoworkError $Result "Duplicate PolicyName '$name' - already used on CSV row $($SeenNames[$key])."
    }
    else {
        $SeenNames[$key] = $Row.RowNumber
    }

    if ($ExistingNames.ContainsKey($key)) {
        Add-CoworkError $Result "A spending policy named '$name' already exists in the tenant (id $($ExistingNames[$key])). Policy names must be unique."
    }
}

# ---------------------------------------------------------------------------
# Rules 2 & 3 - assignment target and group resolution
# ---------------------------------------------------------------------------
function Test-CoworkRuleAssignment {
    param($Result, $Row, [switch]$SkipLookups)

    if (-not $Row.AssignmentType) {
        Add-CoworkError $Result "AssignmentType must be 'AllUsers' or 'Groups'. Received '$($Row.AssignmentTypeRaw)'."
        return
    }

    if ($Row.AssignmentType -eq 'AllUsers') {
        if ($Row.Groups.Count -gt 0) {
            Add-CoworkWarning $Result "Groups column is ignored because AssignmentType is 'AllUsers'."
        }
        return
    }

    if ($Row.Groups.Count -eq 0) {
        Add-CoworkError $Result "Groups is required when AssignmentType is 'Groups'. Provide one or more group display names or object ids separated by ';'."
        return
    }

    $dupes = @($Row.Groups | Group-Object { $_.ToLowerInvariant() } | Where-Object { $_.Count -gt 1 })
    foreach ($d in $dupes) {
        Add-CoworkWarning $Result "Group '$($d.Group[0])' is listed $($d.Count) times; duplicates are ignored."
    }

    if ($SkipLookups) { return }

    $resolved = New-Object System.Collections.ArrayList
    foreach ($g in ($Row.Groups | Select-Object -Unique)) {
        $r = Resolve-CoworkGroup -Group $g
        if ($r.Resolved) { [void]$resolved.Add($r) }
        else { Add-CoworkError $Result $r.Error }
    }
    $Row.ResolvedGroups = $resolved.ToArray()
}

# ---------------------------------------------------------------------------
# Rule 4 - services / agents
# ---------------------------------------------------------------------------
function Test-CoworkRuleServices {
    param($Result, $Row)

    if ($Row.Services.Count -eq 0) {
        Add-CoworkError $Result "Services is required. Provide one or more agent/service names separated by ';' (for example 'Copilot Cowork')."
        return
    }

    $dupes = @($Row.Services | Group-Object { $_.ToLowerInvariant() } | Where-Object { $_.Count -gt 1 })
    foreach ($d in $dupes) {
        Add-CoworkWarning $Result "Service '$($d.Group[0])' is listed $($d.Count) times; duplicates are ignored."
    }

    $resolved = New-Object System.Collections.ArrayList
    $seenIds = @{}

    foreach ($s in ($Row.Services | Select-Object -Unique)) {
        $r = Resolve-CoworkService -Name $s
        if (-not $r.Resolved) {
            Add-CoworkError $Result $r.Error
            continue
        }
        if ($seenIds.ContainsKey($r.ServiceId)) {
            Add-CoworkWarning $Result "Services '$s' and '$($seenIds[$r.ServiceId])' both map to serviceId '$($r.ServiceId)'; it will be added once."
            continue
        }
        $seenIds[$r.ServiceId] = $s
        [void]$resolved.Add($r)
    }

    $Row.ResolvedServices = $resolved.ToArray()
}

# ---------------------------------------------------------------------------
# Rules 5, 6 - policy monthly spending limit
# ---------------------------------------------------------------------------
function Test-CoworkRulePolicyLimit {
    param($Result, $Row, $Limits)

    if (-not $Row.MonthlySpendingLimitType) {
        Add-CoworkError $Result "MonthlySpendingLimitType must be 'NoLimit' or 'Limited'. Received '$($Row.MonthlySpendingLimitTypeRaw)'."
        return
    }

    $parsed = ConvertTo-CoworkWholeNumber -Value $Row.MonthlySpendingLimitCreditsRaw -FieldName 'MonthlySpendingLimitCredits'
    if ($parsed.Error) {
        Add-CoworkError $Result $parsed.Error
        return
    }

    if ($Row.MonthlySpendingLimitType -eq 'NoLimit') {
        if ($null -ne $parsed.Value) {
            Add-CoworkWarning $Result "MonthlySpendingLimitCredits ('$($Row.MonthlySpendingLimitCreditsRaw)') is ignored because MonthlySpendingLimitType is 'NoLimit'."
        }
        $Row.MonthlySpendingLimitCredits = $null
        return
    }

    if ($null -eq $parsed.Value) {
        Add-CoworkError $Result "MonthlySpendingLimitCredits is required when MonthlySpendingLimitType is 'Limited'."
        return
    }

    $min = [double]$Limits.PolicyMonthlyCreditsMinimum
    $rec = [double]$Limits.PolicyMonthlyCreditsRecommended

    if ($parsed.Value -le 0) {
        Add-CoworkError $Result "MonthlySpendingLimitCredits must be greater than zero. Received $($parsed.Value)."
        return
    }
    if ($parsed.Value -lt $min) {
        Add-CoworkError $Result "MonthlySpendingLimitCredits must be at least $min credits. Received $($parsed.Value)."
        return
    }
    if ($parsed.Value -lt $rec) {
        Add-CoworkWarning $Result "MonthlySpendingLimitCredits is $($parsed.Value). Industry usage trends suggest $rec or more for a policy limit."
    }

    $Row.MonthlySpendingLimitCredits = $parsed.Value
}

# ---------------------------------------------------------------------------
# Rules 7, 8 - per-user monthly budget limit
# ---------------------------------------------------------------------------
function Test-CoworkRuleUserLimit {
    param($Result, $Row, $Limits, $Behaviour)

    if (-not $Row.UserMonthlyBudgetLimitType) {
        Add-CoworkError $Result "UserMonthlyBudgetLimitType must be 'NoLimit' or 'Limited'. Received '$($Row.UserMonthlyBudgetLimitTypeRaw)'."
        return
    }

    $parsed = ConvertTo-CoworkWholeNumber -Value $Row.UserMonthlyBudgetLimitCreditsRaw -FieldName 'UserMonthlyBudgetLimitCredits'
    if ($parsed.Error) {
        Add-CoworkError $Result $parsed.Error
        return
    }

    if ($Row.UserMonthlyBudgetLimitType -eq 'NoLimit') {
        if ($null -ne $parsed.Value) {
            Add-CoworkWarning $Result "UserMonthlyBudgetLimitCredits ('$($Row.UserMonthlyBudgetLimitCreditsRaw)') is ignored because UserMonthlyBudgetLimitType is 'NoLimit'."
        }
        $Row.UserMonthlyBudgetLimitCredits = $null
        return
    }

    if ($null -eq $parsed.Value) {
        Add-CoworkError $Result "UserMonthlyBudgetLimitCredits is required when UserMonthlyBudgetLimitType is 'Limited'."
        return
    }

    $min = [double]$Limits.UserMonthlyCreditsMinimum
    $rec = [double]$Limits.UserMonthlyCreditsRecommended

    if ($parsed.Value -le 0) {
        Add-CoworkError $Result "UserMonthlyBudgetLimitCredits must be greater than zero. Received $($parsed.Value)."
        return
    }
    if ($parsed.Value -lt $min) {
        Add-CoworkError $Result "UserMonthlyBudgetLimitCredits must be at least $min credits. Received $($parsed.Value)."
        return
    }
    if ($parsed.Value -lt $rec) {
        Add-CoworkWarning $Result "UserMonthlyBudgetLimitCredits is $($parsed.Value). Industry usage trends suggest $rec or more for a per-user budget."
    }

    $Row.UserMonthlyBudgetLimitCredits = $parsed.Value

    if ($Behaviour.EnforceUserLimitNotAbovePolicyLimit -and
        $Row.MonthlySpendingLimitType -eq 'Limited' -and
        $null -ne $Row.MonthlySpendingLimitCredits -and
        $parsed.Value -gt $Row.MonthlySpendingLimitCredits) {
        Add-CoworkError $Result "UserMonthlyBudgetLimitCredits ($($parsed.Value)) cannot exceed MonthlySpendingLimitCredits ($($Row.MonthlySpendingLimitCredits)) - a single user may not be allowed more credits than the whole policy."
    }
}

# ---------------------------------------------------------------------------
# Rules 10-15 - alerts
# ---------------------------------------------------------------------------
function Test-CoworkRuleAlerts {
    param($Result, $Row, $Limits, [switch]$SkipLookups)

    $policyPair = Test-CoworkThresholdPair -Result $Result -Row $Row -Limits $Limits -Scope 'Policy'
    $userPair   = Test-CoworkThresholdPair -Result $Result -Row $Row -Limits $Limits -Scope 'User'

    $hasAnyThreshold = $policyPair -or $userPair

    # Rule 14 - recipients are required whenever a threshold is configured.
    if ($hasAnyThreshold -and $Row.AlertEmails.Count -eq 0) {
        Add-CoworkError $Result "AlertEmails is required when an alert threshold is configured. Alerts cannot be created without at least one recipient."
    }

    if (-not $hasAnyThreshold -and $Row.AlertEmails.Count -gt 0) {
        Add-CoworkError $Result "AlertEmails is set but no alert threshold is configured. Set PolicyAlertThresholdType/Value and/or UserAlertThresholdType/Value, or clear AlertEmails."
    }

    # Warning - a limited policy with no alert at all.
    if (-not $hasAnyThreshold -and $Row.MonthlySpendingLimitType -eq 'Limited') {
        Add-CoworkWarning $Result "No spending alert is configured for a policy that has a monthly spending limit. Consider adding an alert so overspend is noticed before the limit is reached."
    }

    if ($Row.AlertEmails.Count -eq 0 -or $SkipLookups) { return }

    $resolved = New-Object System.Collections.ArrayList
    foreach ($e in ($Row.AlertEmails | Select-Object -Unique)) {
        $parsedGuid = [guid]::Empty
        $isGuid = [guid]::TryParse($e, [ref]$parsedGuid)
        if ($e -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$' -and -not $isGuid) {
            Add-CoworkError $Result "AlertEmails entry '$e' is not a valid email address or user object id."
            continue
        }
        $r = Resolve-CoworkRecipient -Recipient $e
        if ($r.Resolved) { [void]$resolved.Add($r) }
        else { Add-CoworkError $Result $r.Error }
    }
    $Row.ResolvedRecipients = $resolved.ToArray()
}

function Test-CoworkThresholdPair {
    <#
    .SYNOPSIS
        Validates one threshold type/value pair (Policy or User scope).
    .OUTPUTS
        $true when a usable threshold is configured for this scope.
    #>
    param($Result, $Row, $Limits, [ValidateSet('Policy', 'User')][string]$Scope)

    if ($Scope -eq 'Policy') {
        $typeRaw   = $Row.PolicyAlertThresholdTypeRaw
        $type      = $Row.PolicyAlertThresholdType
        $valueRaw  = $Row.PolicyAlertThresholdValueRaw
        $typeCol   = 'PolicyAlertThresholdType'
        $valueCol  = 'PolicyAlertThresholdValue'
        $limitType = $Row.MonthlySpendingLimitType
        $limitVal  = $Row.MonthlySpendingLimitCredits
        $limitCol  = 'MonthlySpendingLimitType'
        $limitValCol = 'MonthlySpendingLimitCredits'
    }
    else {
        $typeRaw   = $Row.UserAlertThresholdTypeRaw
        $type      = $Row.UserAlertThresholdType
        $valueRaw  = $Row.UserAlertThresholdValueRaw
        $typeCol   = 'UserAlertThresholdType'
        $valueCol  = 'UserAlertThresholdValue'
        $limitType = $Row.UserMonthlyBudgetLimitType
        $limitVal  = $Row.UserMonthlyBudgetLimitCredits
        $limitCol  = 'UserMonthlyBudgetLimitType'
        $limitValCol = 'UserMonthlyBudgetLimitCredits'
    }

    $hasType  = -not [string]::IsNullOrWhiteSpace($typeRaw)
    $hasValue = -not [string]::IsNullOrWhiteSpace($valueRaw)

    if (-not $hasType -and -not $hasValue) { return $false }

    # Rule 15 - type and value must be supplied together.
    if ($hasType -and -not $hasValue) {
        Add-CoworkError $Result "$typeCol is '$typeRaw' but $valueCol is empty. Both must be supplied together."
        return $false
    }
    if ($hasValue -and -not $hasType) {
        Add-CoworkError $Result "$valueCol is '$valueRaw' but $typeCol is empty. Set $typeCol to 'Percent' or 'Credits'."
        return $false
    }

    if (-not $type) {
        Add-CoworkError $Result "$typeCol must be 'Percent' or 'Credits'. Received '$typeRaw'."
        return $false
    }

    # Rule 13 - a user alert requires a configured per-user budget limit.
    if ($Scope -eq 'User' -and $limitType -ne 'Limited') {
        Add-CoworkError $Result ("A user spending alert cannot be configured because no per-user monthly budget limit is set " +
            "($limitCol is '$(if ($limitType) { $limitType } else { $Row.UserMonthlyBudgetLimitTypeRaw })'). " +
            "Set $limitCol to 'Limited' with $limitValCol, or clear $typeCol and $valueCol.")
        return $false
    }

    $parsed = ConvertTo-CoworkWholeNumber -Value $valueRaw -FieldName $valueCol -AllowDecimal:($type -eq 'Percent')
    if ($parsed.Error) {
        Add-CoworkError $Result $parsed.Error
        return $false
    }

    $value = $parsed.Value

    if ($type -eq 'Percent') {
        # Rule 12 - percent thresholds are meaningless without a limit to measure against.
        if ($limitType -ne 'Limited') {
            Add-CoworkError $Result ("$typeCol is 'Percent' but $limitCol is 'NoLimit'. A percentage threshold requires a configured " +
                "limit to calculate against. Use 'Credits' instead, or set $limitCol to 'Limited'.")
            return $false
        }

        $pmin = [double]$Limits.AlertPercentMinimum
        $pmax = [double]$Limits.AlertPercentMaximum
        $phigh = [double]$Limits.AlertPercentHighWarning

        # Rule 10
        if ($value -lt $pmin -or $value -gt $pmax) {
            Add-CoworkError $Result "$valueCol must be between $pmin and $pmax when $typeCol is 'Percent'. Received $value."
            return $false
        }
        if ($value -gt $phigh) {
            Add-CoworkWarning $Result "$valueCol is $value%. Alerting above $phigh% leaves little time to react before the limit is reached."
        }
    }
    else {
        if ($value -le 0) {
            Add-CoworkError $Result "$valueCol must be greater than zero. Received $value."
            return $false
        }

        # Rule 11 - a credit threshold cannot exceed the limit it is measured against.
        if ($limitType -eq 'Limited' -and $null -ne $limitVal) {
            if ($value -gt $limitVal) {
                Add-CoworkError $Result "$valueCol ($value credits) cannot exceed $limitValCol ($limitVal credits) - the alert would never fire."
                return $false
            }
            $pct = [math]::Round(($value / $limitVal) * 100, 1)
            if ($pct -gt [double]$Limits.AlertPercentHighWarning) {
                Add-CoworkWarning $Result "$valueCol ($value credits) is $pct% of $limitValCol. That leaves little time to react before the limit is reached."
            }
        }
        elseif ($limitType -eq 'NoLimit') {
            Add-CoworkWarning $Result "$valueCol is an absolute credit threshold while $limitCol is 'NoLimit'. The alert will fire on consumption, but there is no limit to stop spending."
        }
    }

    if ($Scope -eq 'Policy') { $Row.PolicyAlertThresholdValue = $value } else { $Row.UserAlertThresholdValue = $value }
    return $true
}

# ---------------------------------------------------------------------------
# Rule 9 - tenant credit ceiling across all policies
# ---------------------------------------------------------------------------
function Test-CoworkRuleTenantCeiling {
    param($Results, $TenantTotal, [double]$ExistingCommitted, $Limits, $Behaviour)

    if (-not $Behaviour.EnforceTenantBalanceCeiling) { return }
    if ($null -eq $TenantTotal -or $TenantTotal -le 0) { return }

    $valid = @($Results | Where-Object { $_.Errors.Count -eq 0 })

    $newCommitted = 0.0
    foreach ($r in $valid) {
        if ($r.Row.MonthlySpendingLimitType -eq 'Limited' -and $null -ne $r.Row.MonthlySpendingLimitCredits) {
            $newCommitted += [double]$r.Row.MonthlySpendingLimitCredits
        }
    }

    $total = $ExistingCommitted + $newCommitted
    if ($total -le 0) { return }

    $utilization = [math]::Round(($total / $TenantTotal) * 100, 1)

    if ($total -gt $TenantTotal) {
        $over = $total - $TenantTotal
        foreach ($r in $valid) {
            if ($r.Row.MonthlySpendingLimitType -eq 'Limited' -and $null -ne $r.Row.MonthlySpendingLimitCredits) {
                Add-CoworkError $r ("Tenant credit ceiling exceeded. Existing policies commit $ExistingCommitted credits, " +
                    "this file adds $newCommitted, totalling $total against a tenant balance of $TenantTotal " +
                    "($over credits over). Reduce MonthlySpendingLimitCredits across the file or purchase more credits.")
            }
        }
        Write-CoworkLog -Level Error -Message "Tenant credit ceiling exceeded: $total committed vs $TenantTotal available."
        return
    }

    $warnAt = [double]$Limits.TenantBalanceWarnUtilizationPercent
    if ($utilization -gt $warnAt) {
        foreach ($r in $valid) {
            if ($r.Row.MonthlySpendingLimitType -eq 'Limited' -and $null -ne $r.Row.MonthlySpendingLimitCredits) {
                Add-CoworkWarning $r "Committed policy credits total $total of $TenantTotal tenant credits ($utilization% utilization), above the $warnAt% advisory threshold."
            }
        }
        Write-CoworkLog -Level Warn -Message "Tenant credit utilization after this run: $utilization%."
    }
    else {
        Write-CoworkLog -Level Info -Message "Tenant credit utilization after this run: $utilization% ($total of $TenantTotal)."
    }
}
