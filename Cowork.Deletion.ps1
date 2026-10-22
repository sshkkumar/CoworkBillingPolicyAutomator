# Cowork.Deletion.ps1
# Safe, exact-match spending policy deletion workflow.

function Remove-CoworkSpendingPolicy {
    <#
    .SYNOPSIS
        Previews or deletes one spending policy by exact id or exact name.
    .DESCRIPTION
        Reads the target, obtains a fresh ETag immediately before a committed delete,
        and sends If-Match. A single HTTP 412 retry refetches the policy and ETag.
        Preview is the default; no DELETE is sent without -Commit.
    .PARAMETER Id
        Exact spending policy id. Use either Id or Name, not both.
    .PARAMETER Name
        Exact display name. The name must identify one policy.
    .PARAMETER Commit
        Actually delete the matched policy. Without this switch the operation is a preview.
    .PARAMETER Force
        Skip the interactive confirmation required for a committed delete.
    #>
    [CmdletBinding(DefaultParameterSetName = 'ById', ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'ById', Position = 0)]
        [ValidateNotNullOrEmpty()][string]$Id,
        [Parameter(Mandatory, ParameterSetName = 'ByName', Position = 0)]
        [ValidateNotNullOrEmpty()][string]$Name,
        [switch]$Commit,
        [switch]$Force
    )

    $ctx = Initialize-CoworkContext
    Start-CoworkLog | Out-Null
    Assert-CoworkConnected | Out-Null

    $target = $null
    if ($PSCmdlet.ParameterSetName -eq 'ById') {
        Write-CoworkLog -Level Info -Message "Looking up spending policy by exact id '$Id'."
        $target = Get-CoworkSpendingPolicy -Id $Id
    }
    else {
        Write-CoworkLog -Level Info -Message "Looking up spending policy by exact name '$Name'."
        $candidates = @(Get-CoworkSpendingPolicy -Refresh)
        $matches = @($candidates | Where-Object {
            $candidateName = Get-CoworkPolicyDisplayName -Policy $_
            $candidateName -eq $Name
        })
        if ($matches.Count -eq 0) { throw "No spending policy was found with exact name '$Name'." }
        if ($matches.Count -gt 1) { throw "More than one spending policy has exact name '$Name'. Use -Id to select one." }
        $target = $matches[0]
    }

    $policyId = Get-CoworkObjectId -Object $target
    if ([string]::IsNullOrWhiteSpace($policyId)) { throw 'The matched spending policy did not contain an id.' }
    $policyName = Get-CoworkPolicyDisplayName -Policy $target

    $result = [pscustomobject]@{
        Action     = 'Delete'
        Status     = if ($Commit) { 'PendingConfirmation' } else { 'WouldDelete' }
        PolicyId   = $policyId
        PolicyName = $policyName
        ETag       = $null
        Attempts   = 0
        Error      = $null
    }

    if (-not $Commit) {
        Write-CoworkLog -Level Info -Message "Preview: policy '$policyName' ($policyId) would be deleted. Re-run with -Commit to delete it."
        return $result
    }

    if (-not $Force -and -not $PSCmdlet.ShouldContinue("Delete spending policy '$policyName' ($policyId)?", 'Confirm policy deletion')) {
        $result.Status = 'Cancelled'
        Write-CoworkLog -Level Warn -Message "Deletion cancelled for policy '$policyName' ($policyId)."
        return $result
    }

    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $result.Attempts = $attempt
        try {
            # Always refetch immediately before DELETE, including the retry, so the
            # If-Match value cannot come from a stale list response or cache.
            $fresh = Get-CoworkSpendingPolicy -Id $policyId
            $etag = Get-CoworkPolicyETag -Object $fresh
            if ([string]::IsNullOrWhiteSpace($etag)) {
                throw "Graph did not return an ETag for policy $policyId; refusing to delete without If-Match."
            }
            $result.ETag = $etag
            Write-CoworkLog -Level Info -Message "Deleting policy '$policyName' ($policyId), attempt $attempt, with fresh ETag '$etag'."
            Invoke-CoworkGraphRequest -Path "spendingPolicies/$policyId" -Method DELETE -Headers @{ 'If-Match' = $etag } -SuppressWhatIf | Out-Null
            $result.Status = 'Deleted'
            Write-CoworkLog -Level Success -Message "Deleted spending policy '$policyName' ($policyId)."
            Clear-CoworkCache
            return $result
        }
        catch {
            $status = Get-CoworkHttpStatusFromException -Exception $_.Exception
            if ($status -eq 412 -and $attempt -eq 1) {
                Write-CoworkLog -Level Warn -Message "HTTP 412 deleting policy $policyId; refetching the policy and retrying once."
                continue
            }
            $result.Status = 'Failed'
            $result.Error = $_.Exception.Message
            Write-CoworkLog -Level Error -Message "Could not delete spending policy '$policyName' ($policyId): $($result.Error)"
            return $result
        }
    }
}

function Get-CoworkPolicyDisplayName {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Policy)
    return Get-CoworkFirstStringProperty -Object $Policy -Names @('displayName', 'name')
}

function Get-CoworkHttpStatusFromException {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Exception)
    foreach ($e in @($Exception, $Exception.InnerException)) {
        if ($null -eq $e) { continue }
        foreach ($property in @('StatusCode', 'Response')) {
            if ($e.PSObject.Properties.Name -contains $property -and $null -ne $e.$property) {
                if ($property -eq 'StatusCode') { try { return [int]$e.$property } catch {} }
                elseif ($e.$property.PSObject.Properties.Name -contains 'StatusCode') { try { return [int]$e.$property.StatusCode } catch {} }
            }
        }
        if ("$e" -match 'HTTP\s+412\b|\b412\s*\(') { return 412 }
    }
    return 0
}
