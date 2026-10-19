# Cowork.Creation.ps1
# Multi-step policy creation, rollback on partial failure, and read-back verification.

function New-CoworkPolicyFromRow {
    <#
    .SYNOPSIS
        Creates one spending policy from a validated row.
    .DESCRIPTION
        Steps, in the order the API requires:
          1. POST   /spendingPolicies                                     (serviceSettings inline - required)
          2. POST   /spendingPolicies/{id}/microsoft.graph.selectedGroupsSpendingPolicy/assignedGroups/$ref  (per group)
          3. PATCH  /spendingPolicies/{id}/emailThresholdSettings         (thresholds, isEnabled = false)
          4. POST   /spendingPolicies/{id}/emailThresholdSettings/recipients/$ref                            (per recipient)
          5. PATCH  /spendingPolicies/{id}/emailThresholdSettings         (isEnabled = true)

        Alerting cannot be enabled until at least one recipient exists, which is why
        step 3 writes the thresholds disabled and step 5 turns them on afterwards.

        Newly created policies are DISABLED by Graph. Enabling them is a separate
        admin action and is deliberately not done here.

        If any step after step 1 fails and RollbackOnPartialFailure is enabled, the
        policy is deleted so the tenant is never left half-configured.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Result)

    $ctx = Get-CoworkContext
    $row = $Result.Row
    $behaviour = $ctx.Config.Behaviour
    $policyId = $null

    # Recipient $ref calls want If-Match with the parent policy ETag. Only send it
    # if the Graph wrapper actually accepts a -Headers argument.
    $supportsHeaders = (Get-Command Invoke-CoworkGraphRequest).Parameters.ContainsKey('Headers')

    try {
        # --- Step 1: create the policy, services included ---------------------
        $Result.FailedStep = 'CreatePolicy'
        $payload = New-CoworkSpendingPolicyPayload -Row $row
        Write-CoworkLog -Level Info -Message "Creating policy '$($row.PolicyName)'..."
        $created = Invoke-CoworkGraphRequest -Path 'spendingPolicies' -Method POST -Body $payload

        $policyId = Get-CoworkObjectId -Object $created
        if (-not $policyId) {
            throw "The create call succeeded but no policy id was returned. Cannot continue configuring this policy."
        }
        $Result.PolicyId = $policyId
        [void]$Result.StepsDone.Add('CreatePolicy')
        [void]$Result.StepsDone.Add("ServiceSettings($(@($row.ResolvedServices).Count))")
        foreach ($s in @($row.ResolvedServices)) {
            Write-CoworkLog -Level Info -Message "  Enabled service '$($s.Name)' ($($s.ServiceId))."
        }
        Write-CoworkLog -Level Success -Message "Created policy '$($row.PolicyName)' (id $policyId). Note: new policies are created disabled."

        $etag = Get-CoworkPolicyETag -Object $created -PolicyId $policyId

        # --- Step 2: assign groups --------------------------------------------
        if ($row.AssignmentType -eq 'Groups') {
            if ([string]::IsNullOrWhiteSpace($etag)) {
                throw "Graph did not return an ETag for the created policy. An If-Match header is required for group assignment."
            }
            $Result.FailedStep = 'AssignGroups'
            foreach ($g in $row.ResolvedGroups) {
                $body = New-CoworkDirectoryRefPayload -EntitySet 'groups' -Id $g.Id
                $path = "spendingPolicies/$policyId/microsoft.graph.selectedGroupsSpendingPolicy/assignedGroups/`$ref"
                $groupExtra = @{}
                if ($supportsHeaders -and $etag) { $groupExtra['Headers'] = @{ 'If-Match' = $etag } }
                Invoke-CoworkGraphRequest -Path $path -Method POST -Body $body @groupExtra | Out-Null
                Write-CoworkLog -Level Info -Message "  Assigned group '$($g.DisplayName)' ($($g.Id))."
            }
            [void]$Result.StepsDone.Add("AssignGroups($($row.ResolvedGroups.Count))")
            # The assignedGroups write advances the parent policy ETag.
            $etag = Get-CoworkPolicyETag -PolicyId $policyId
        }

        # --- Steps 3-5: alerts -------------------------------------------------
        $userAlertNote = Test-CoworkUserAlertSupported -Row $row
        if ($userAlertNote) {
            Add-CoworkWarning $Result $userAlertNote
            Write-CoworkLog -Level Warn -Message "  $userAlertNote"
        }

        $thresholdBody = New-CoworkEmailThresholdPayload -Row $row -Enabled $false
        if ($thresholdBody.Keys.Count -gt 0) {
            $Result.FailedStep = 'AlertThresholds'
            if ([string]::IsNullOrWhiteSpace($etag)) {
                throw "Graph did not return an ETag for the policy. An If-Match header is required for alert threshold updates."
            }
            Invoke-CoworkGraphRequest -Path "spendingPolicies/$policyId/emailThresholdSettings" -Method PATCH -Body $thresholdBody -Headers @{ 'If-Match' = $etag } | Out-Null
            [void]$Result.StepsDone.Add('AlertThresholds')
            # Updating threshold settings advances the parent policy ETag.
            $etag = Get-CoworkPolicyETag -PolicyId $policyId
            Write-CoworkLog -Level Info -Message "  Wrote alert thresholds (disabled until recipients exist)."

            $Result.FailedStep = 'AlertRecipients'
            foreach ($rcpt in $row.ResolvedRecipients) {
                $body = New-CoworkDirectoryRefPayload -EntitySet 'users' -Id $rcpt.Id
                $path = "spendingPolicies/$policyId/emailThresholdSettings/recipients/`$ref"
                $extra = @{}
                if ($supportsHeaders -and $etag) { $extra['Headers'] = @{ 'If-Match' = $etag } }
                if (-not $extra.ContainsKey('Headers')) {
                    throw "Graph did not return an ETag for the policy. An If-Match header is required for alert recipient updates."
                }
                Invoke-CoworkGraphRequest -Path $path -Method POST -Body $body @extra | Out-Null
                Write-CoworkLog -Level Info -Message "  Added alert recipient '$($rcpt.UserPrincipalName)'."
                $etag = Get-CoworkPolicyETag -PolicyId $policyId
            }
            [void]$Result.StepsDone.Add("AlertRecipients($($row.ResolvedRecipients.Count))")

            if (@($row.ResolvedRecipients).Count -gt 0) {
                $Result.FailedStep = 'EnableAlerts'
                $enableBody = New-CoworkEmailThresholdPayload -Row $row -Enabled $true
                if ([string]::IsNullOrWhiteSpace($etag)) {
                    throw "Graph did not return an ETag for the policy. An If-Match header is required to enable alerts."
                }
                Invoke-CoworkGraphRequest -Path "spendingPolicies/$policyId/emailThresholdSettings" -Method PATCH -Body $enableBody -Headers @{ 'If-Match' = $etag } | Out-Null
                [void]$Result.StepsDone.Add('EnableAlerts')
                Write-CoworkLog -Level Info -Message "  Enabled alerting."
            }
            else {
                Add-CoworkWarning $Result "Alert thresholds were written but no recipients resolved, so alerting was left disabled. The API requires at least one recipient before alerts can be enabled."
            }
        }

        # --- Verification ------------------------------------------------------
        $Result.FailedStep = $null
        # In preview mode nothing was actually written, so don't claim it was.
        $Result.Status = if ($ctx.WhatIfPayload) { 'WouldCreate' } else { 'Created' }

        if ($behaviour.VerifyAfterCreate -and -not $ctx.WhatIfPayload) {
            $issues = Test-CoworkCreatedPolicy -PolicyId $policyId -Row $row
            foreach ($i in $issues) { Add-CoworkWarning $Result $i }
            if ($issues.Count -eq 0) {
                Write-CoworkLog -Level Success -Message "Verified policy '$($row.PolicyName)' matches the CSV intent."
            }
            else {
                Write-CoworkLog -Level Warn -Message "Policy '$($row.PolicyName)' created, but verification found $($issues.Count) difference(s)."
            }
        }

        return $Result
    }
    catch {
        $failedStep = $Result.FailedStep
        $msg = $_.Exception.Message
        Add-CoworkError $Result "Creation failed at step '$failedStep': $msg"
        $Result.Status = 'Failed'
        Write-CoworkLog -Level Error -Message "Policy '$($row.PolicyName)' failed at step '$failedStep': $msg"

        if ($policyId -and $behaviour.RollbackOnPartialFailure) {
            $Result.RollbackResult = Invoke-CoworkPolicyRollback -PolicyId $policyId -PolicyName $row.PolicyName
        }
        elseif ($policyId) {
            $Result.RollbackResult = 'Skipped (RollbackOnPartialFailure is disabled)'
            Add-CoworkWarning $Result "Policy $policyId was left partially configured because rollback is disabled. Completed steps: $($Result.StepsDone -join ', ')."
        }
        else {
            $Result.RollbackResult = 'NotNeeded'
        }

        return $Result
    }
}

function Get-CoworkPolicyETag {
    <#
    .SYNOPSIS
        Best-effort ETag for a spending policy, used as If-Match on recipient $ref writes.
    #>
    [CmdletBinding()]
    param($Object, [string]$PolicyId)

    $names = @('@odata.etag', 'ETag', 'etag')

    foreach ($n in $names) {
        if ($Object -and $Object.PSObject.Properties.Name -contains $n -and $Object.$n) {
            return [string]$Object.$n
        }
    }

    if ((Get-CoworkContext).WhatIfPayload -or $PolicyId -like 'whatif-*') { return $null }

    try {
        $p = Invoke-CoworkGraphRequest -Path "spendingPolicies/$PolicyId" -Method GET -SuppressWhatIf
        foreach ($n in $names) {
            if ($p -and $p.PSObject.Properties.Name -contains $n -and $p.$n) {
                return [string]$p.$n
            }
        }
    }
    catch {
        Write-CoworkLog -Level Debug -Message "Could not read ETag for policy $PolicyId. $($_.Exception.Message)"
    }

    return $null
}

function Invoke-CoworkPolicyRollback {
    <#
    .SYNOPSIS
        Deletes a partially-created policy.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PolicyId,
        [string]$PolicyName
    )

    # In -WhatIfPayload mode nothing was actually created and $PolicyId is a synthetic
    # 'whatif-*' value, so the real DELETE below (which bypasses WhatIf on purpose, to
    # guarantee cleanup during a genuine commit) must not be sent.
    if ((Get-CoworkContext).WhatIfPayload -or $PolicyId -like 'whatif-*') {
        Write-CoworkLog -Level Info -Message "WHATIF rollback: would DELETE spendingPolicies/$PolicyId."
        return 'RolledBack (simulated)'
    }

    Write-CoworkLog -Level Warn -Message "Rolling back: deleting policy '$PolicyName' ($PolicyId)..."
    try {
        # Graph requires If-Match for policy deletion. Use the current ETag when
        # available; wildcard is safe here because this is cleanup of a policy
        # created by this run and avoids leaving an orphan after a later-step failure.
        $etag = Get-CoworkPolicyETag -PolicyId $PolicyId
        $headers = @{ 'If-Match' = if ($etag) { $etag } else { '*' } }
        Invoke-CoworkGraphRequest -Path "spendingPolicies/$PolicyId" -Method DELETE -Headers $headers -SuppressWhatIf | Out-Null
        Write-CoworkLog -Level Success -Message "Rollback succeeded - policy $PolicyId deleted."
        return 'RolledBack'
    }
    catch {
        $m = $_.Exception.Message
        Write-CoworkLog -Level Error -Message "ROLLBACK FAILED for policy $PolicyId. Delete it manually in the admin center. $m"
        return "RollbackFailed: $m"
    }
}

function Test-CoworkCreatedPolicy {
    <#
    .SYNOPSIS
        Re-reads a created policy and diffs it against the CSV intent.
    .OUTPUTS
        An array of human-readable difference messages. Empty means everything matched.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PolicyId,
        [Parameter(Mandatory)]$Row
    )

    $issues = New-Object System.Collections.ArrayList

    # Policy core
    try {
        $p = Invoke-CoworkGraphRequest -Path "spendingPolicies/$PolicyId" -Method GET -SuppressWhatIf

        $name = Get-CoworkFirstStringProperty -Object $p -Names @('displayName', 'name')
        if ($name -and $name -ne $Row.PolicyName) {
            [void]$issues.Add("Verification: policy name is '$name' but the CSV requested '$($Row.PolicyName)'.")
        }

        $actualLimit = Get-CoworkPolicyLimitCredits -Policy $p
        if ($Row.MonthlySpendingLimitType -eq 'Limited') {
            if ($null -eq $actualLimit) {
                [void]$issues.Add("Verification: monthly spending limit of $($Row.MonthlySpendingLimitCredits) credits was requested but the created policy reports no limit. The 'periodLimit' quantity was not accepted as sent - check the policy in the admin center.")
            }
            elseif ($actualLimit -ne $Row.MonthlySpendingLimitCredits) {
                [void]$issues.Add("Verification: monthly spending limit is $actualLimit but the CSV requested $($Row.MonthlySpendingLimitCredits).")
            }
        }
    }
    catch {
        [void]$issues.Add("Verification: could not re-read the policy. $($_.Exception.Message)")
    }

    # Groups
    if ($Row.AssignmentType -eq 'Groups') {
        try {
            $path = "spendingPolicies/$PolicyId/microsoft.graph.selectedGroupsSpendingPolicy/assignedGroups"
            $assigned = @(Invoke-CoworkGraphRequest -Path $path -Method GET -All -SuppressWhatIf)
            $actualIds = @($assigned | ForEach-Object { Get-CoworkObjectId -Object $_ })
            foreach ($g in $Row.ResolvedGroups) {
                if ($actualIds -notcontains $g.Id) {
                    [void]$issues.Add("Verification: group '$($g.DisplayName)' ($($g.Id)) is not present in assignedGroups.")
                }
            }
        }
        catch {
            [void]$issues.Add("Verification: could not read assignedGroups. $($_.Exception.Message)")
        }
    }

    # Services
    try {
        $settings = @(Invoke-CoworkGraphRequest -Path "spendingPolicies/$PolicyId/serviceSettings" -Method GET -All -SuppressWhatIf)
        $actualSvc = @($settings | ForEach-Object { Get-CoworkFirstStringProperty -Object $_ -Names @('serviceId', 'id') })
        foreach ($s in $Row.ResolvedServices) {
            if ($actualSvc -notcontains $s.ServiceId) {
                [void]$issues.Add("Verification: service '$($s.Name)' ($($s.ServiceId)) is not present in serviceSettings.")
            }
        }
    }
    catch {
        [void]$issues.Add("Verification: could not read serviceSettings. $($_.Exception.Message)")
    }

    # Alerts
    $wantsAlerts = ($Row.PolicyAlertThresholdType -or $Row.UserAlertThresholdType)
    if ($wantsAlerts) {
        try {
            Invoke-CoworkGraphRequest -Path "spendingPolicies/$PolicyId/emailThresholdSettings" -Method GET -SuppressWhatIf | Out-Null
            $rcpts = @(Invoke-CoworkGraphRequest -Path "spendingPolicies/$PolicyId/emailThresholdSettings/recipients" -Method GET -All -SuppressWhatIf)
            $actualR = @($rcpts | ForEach-Object { Get-CoworkObjectId -Object $_ })
            foreach ($r in $Row.ResolvedRecipients) {
                if ($actualR -notcontains $r.Id) {
                    [void]$issues.Add("Verification: alert recipient '$($r.UserPrincipalName)' ($($r.Id)) is not present in emailThresholdSettings/recipients.")
                }
            }
        }
        catch {
            [void]$issues.Add("Verification: could not read emailThresholdSettings. $($_.Exception.Message)")
        }
    }

    return , $issues.ToArray()
}
