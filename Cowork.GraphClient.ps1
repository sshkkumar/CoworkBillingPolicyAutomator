# Cowork.GraphClient.ps1
# Authentication and the single Graph request wrapper used by every other function.

function Connect-CoworkPolicy {
    <#
    .SYNOPSIS
        Signs in to Microsoft Graph interactively (delegated) for the Cowork billing tool.
    .DESCRIPTION
        Wraps Connect-MgGraph using the scopes, TenantId, and ClientId from config.json.
        If an existing Graph session already has the required scopes, it is reused.
    .PARAMETER Scopes
        Override the scopes from config.json.
    .PARAMETER Force
        Force a fresh sign-in even if an existing session is present.
    .EXAMPLE
        Connect-CoworkPolicy
    #>
    [CmdletBinding()]
    param(
        [string[]]$Scopes,
        [switch]$Force
    )

    $ctx = Get-CoworkContext

    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
        throw "The Microsoft.Graph.Authentication module is required. Install it with: Install-Module Microsoft.Graph.Authentication -Scope CurrentUser"
    }
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop

    if (-not $Scopes) { $Scopes = @($ctx.Config.Scopes) }

    $existing = $null
    try { $existing = Get-MgContext } catch { $existing = $null }

    if ($existing -and -not $Force) {
        $missing = @($Scopes | Where-Object { $_ -and ($existing.Scopes -notcontains $_) })
        if ($missing.Count -eq 0) {
            Write-CoworkLog -Level Success -Message "Reusing existing Graph session for $($existing.Account) (tenant $($existing.TenantId))."
            return $existing
        }
        Write-CoworkLog -Level Info -Message "Existing session is missing scopes: $($missing -join ', '). Re-authenticating."
    }

    $connectArgs = @{ Scopes = $Scopes; ErrorAction = 'Stop' }
    if (-not [string]::IsNullOrWhiteSpace($ctx.Config.TenantId)) { $connectArgs.TenantId = $ctx.Config.TenantId }
    if (-not [string]::IsNullOrWhiteSpace($ctx.Config.ClientId)) { $connectArgs.ClientId = $ctx.Config.ClientId }

    Write-CoworkLog -Level Info -Message "Signing in to Microsoft Graph with scopes: $($Scopes -join ', ')"
    Connect-MgGraph @connectArgs | Out-Null

    $now = Get-MgContext
    Write-CoworkLog -Level Success -Message "Connected as $($now.Account) (tenant $($now.TenantId))."
    Clear-CoworkCache
    return $now
}

function Disconnect-CoworkPolicy {
    <#
    .SYNOPSIS
        Signs out of Microsoft Graph and clears cached lookups.
    #>
    [CmdletBinding()]
    param()
    try { Disconnect-MgGraph -ErrorAction Stop | Out-Null } catch { }
    Clear-CoworkCache
    Write-CoworkLog -Level Info -Message "Disconnected from Microsoft Graph."
}

function Assert-CoworkConnected {
    [CmdletBinding()]
    param()
    $c = $null
    try { $c = Get-MgContext } catch { $c = $null }
    if (-not $c -or -not $c.Account) {
        throw "Not connected to Microsoft Graph. Run Connect-CoworkPolicy first."
    }
    return $c
}

function Resolve-CoworkUri {
    <#
    .SYNOPSIS
        Turns a relative endpoint path into an absolute URI.
    .DESCRIPTION
        Paths beginning with http(s) are returned unchanged.
        Paths beginning with 'directory:' are resolved against DirectoryBaseUri (Graph v1.0).
        Everything else is resolved against the billing root.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$BillingRootOverride
    )

    if ($Path -match '^https?://') { return $Path }

    $ctx = Get-CoworkContext

    if ($Path -like 'directory:*') {
        $rel = $Path.Substring('directory:'.Length).TrimStart('/')
        return "$($ctx.DirectoryRoot)/$rel"
    }

    $root = if ($BillingRootOverride) { $BillingRootOverride.TrimEnd('/') } else { $ctx.BillingRoot.TrimEnd('/') }
    return "$root/$($Path.TrimStart('/'))"
}

function Invoke-CoworkGraphRequest {
    <#
    .SYNOPSIS
        The single Graph request wrapper. Handles retry, throttling, paging, and -WhatIfPayload.
    .DESCRIPTION
        All Cowork functions route through this one function, which is also the single
        mock point for the Pester tests.
    .PARAMETER Path
        Relative endpoint path (resolved against the billing root), a 'directory:' prefixed
        path (resolved against Graph v1.0), or an absolute URI.
    .PARAMETER Method
        HTTP method.
    .PARAMETER Body
        Request body as a hashtable / PSObject. Serialized to JSON.
    .PARAMETER All
        Follow @odata.nextLink and return the concatenated 'value' collection.
    .PARAMETER IsWrite
        Marks the call as a write. Write calls are suppressed and recorded when
        -WhatIfPayload mode is active.
    .PARAMETER SuppressWhatIf
        Perform the call even in WhatIfPayload mode (used by read-only verification).
    #>
    [CmdletBinding()]
    param(
        [hashtable]$Headers,
        [Parameter(Mandatory)][string]$Path,
        [ValidateSet('GET', 'POST', 'PATCH', 'PUT', 'DELETE')][string]$Method = 'GET',
        $Body,
        [switch]$All,
        [switch]$IsWrite,
        [switch]$SuppressWhatIf,
        [string]$BillingRootOverride
    )

    # Caller-supplied request headers (for example If-Match on $ref writes).
    $__coworkHeaders = @{}
    if ($Headers) {
        foreach ($__k in @($Headers.Keys)) { $__coworkHeaders[$__k] = $Headers[$__k] }
    }

    $ctx = Get-CoworkContext
    $uri = Resolve-CoworkUri -Path $Path -BillingRootOverride $BillingRootOverride

    $json = $null
    if ($null -ne $Body) {
        $json = $Body | ConvertTo-Json -Depth 12 -Compress:$false
    }

    $isMutation = $IsWrite -or ($Method -in @('POST', 'PATCH', 'PUT', 'DELETE'))

    if ($ctx.WhatIfPayload -and $isMutation -and -not $SuppressWhatIf) {
        $record = [pscustomobject]@{
            Method = $Method
            Uri    = $uri
            Body   = $json
        }
        [void]$ctx.PayloadLog.Add($record)
        Write-CoworkLog -Level Info -Message "WHATIF $Method $uri"
        if ($json) {
            foreach ($l in ($json -split "`n")) { Write-CoworkLog -Level Info -Message "WHATIF   $l" }
        }
        # Return a believable synthetic result so downstream orchestration can continue.
        if ($Method -eq 'POST' -and $Path -match '(^|/)spendingPolicies/?$') {
            return [pscustomobject]@{ id = "whatif-$([guid]::NewGuid().ToString())" }
        }
        return $null
    }

    $maxAttempts = [int]$ctx.Config.Behaviour.MaxRetryAttempts
    if ($maxAttempts -lt 1) { $maxAttempts = 1 }
    $baseDelay = [int]$ctx.Config.Behaviour.RetryBaseDelaySeconds
    if ($baseDelay -lt 1) { $baseDelay = 1 }

    $aggregate = New-Object System.Collections.ArrayList
    $next = $uri

    while ($true) {
        $attempt = 0
        $response = $null

        while ($true) {
            $attempt++
            try {
                $params = @{
                    Method      = $Method
                    Uri         = $next
                    ErrorAction = 'Stop'
                }
                if ($json) {
                    $params.Body = $json
                    $params.ContentType = 'application/json'
                }
                Write-CoworkLog -Level Debug -Message "$Method $next"
                $response = Invoke-MgGraphRequest -Headers $__coworkHeaders @params -OutputType PSObject
                break
            }
            catch {
                $status = Get-CoworkHttpStatus -ErrorRecord $_

                $retryable = ($status -in @(429, 500, 502, 503, 504)) -or ($status -eq 0 -and $_.Exception -is [System.Net.WebException])
                if ($retryable -and $attempt -lt $maxAttempts) {
                    $delay = $baseDelay * [math]::Pow(2, $attempt - 1)
                    $retryAfter = Get-CoworkRetryAfter -ErrorRecord $_
                    if ($retryAfter -gt 0) { $delay = $retryAfter }
                    Write-CoworkLog -Level Warn -Message "HTTP $status on $Method $next. Retry $attempt/$maxAttempts in $delay s."
                    Start-Sleep -Seconds $delay
                    continue
                }

                throw (New-CoworkGraphException -ErrorRecord $_ -Method $Method -Uri $next -Status $status)
            }
        }

        if (-not $All) { return $response }

        $pageItems = $null
        if ($null -ne $response -and $response.PSObject.Properties.Name -contains 'value') {
            $pageItems = $response.value
        }
        elseif ($null -ne $response -and $response.PSObject.Properties.Name -contains 'AdditionalProperties' -and
                $response.AdditionalProperties -is [System.Collections.IDictionary] -and
                $response.AdditionalProperties.Contains('value')) {
            # Graph PowerShell may deserialize collection fields into AdditionalProperties.
            $pageItems = $response.AdditionalProperties['value']
        }

        if ($null -ne $pageItems) {
            foreach ($item in @($pageItems)) { [void]$aggregate.Add($item) }
        }
        elseif ($null -ne $response) {
            [void]$aggregate.Add($response)
        }

        $nextLink = $null
        if ($null -ne $response -and $response.PSObject.Properties.Name -contains '@odata.nextLink') {
            $nextLink = $response.'@odata.nextLink'
        }
        elseif ($null -ne $response -and $response.PSObject.Properties.Name -contains 'AdditionalProperties' -and
                $response.AdditionalProperties -is [System.Collections.IDictionary] -and
                $response.AdditionalProperties.Contains('@odata.nextLink')) {
            $nextLink = $response.AdditionalProperties['@odata.nextLink']
        }
        if (-not $nextLink) { break }
        $next = $nextLink
        $json = $null
        $Method = 'GET'
    }

    return , $aggregate.ToArray()
}

function Get-CoworkHttpStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$ErrorRecord)

    $ex = $ErrorRecord.Exception
    # Microsoft.Graph throws HttpResponseException / RestException variants across versions.
    foreach ($prop in @('StatusCode', 'Response')) {
        if ($ex.PSObject.Properties.Name -contains $prop) {
            $v = $ex.$prop
            if ($null -eq $v) { continue }
            if ($prop -eq 'StatusCode') {
                try { return [int]$v } catch { }
            }
            else {
                if ($v.PSObject.Properties.Name -contains 'StatusCode') {
                    try { return [int]$v.StatusCode } catch { }
                }
            }
        }
    }
    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message -match '"status"\s*:\s*(\d+)') {
        return [int]$Matches[1]
    }
    if ("$ex" -match '\b(\d{3})\b\s*\(') { return [int]$Matches[1] }
    return 0
}

function Get-CoworkRetryAfter {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$ErrorRecord)
    try {
        $resp = $ErrorRecord.Exception.Response
        if ($null -ne $resp -and $resp.Headers) {
            $h = $resp.Headers
            if ($h.RetryAfter -and $h.RetryAfter.Delta) { return [int]$h.RetryAfter.Delta.TotalSeconds }
        }
    }
    catch { }
    return 0
}

function New-CoworkGraphException {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$ErrorRecord,
        [string]$Method,
        [string]$Uri,
        [int]$Status
    )

    $detail = $null
    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
        $detail = $ErrorRecord.ErrorDetails.Message
        try {
            $parsed = $detail | ConvertFrom-Json
            if ($parsed.error -and $parsed.error.message) {
                $detail = "$($parsed.error.code): $($parsed.error.message)"
            }
        }
        catch { }
    }
    if (-not $detail) { $detail = $ErrorRecord.Exception.Message }

    $msg = "Graph request failed. $Method $Uri -> HTTP $Status. $detail"

    if ($Status -eq 404) {
        $ctx = Get-CoworkContext
        $msg += "`n`nHTTP 404 usually means the billing root path in config.json is wrong." +
                "`n  Current BillingRootPath : '$($ctx.Config.BillingRootPath)'" +
                "`n  Effective billing root  : $($ctx.BillingRoot)" +
                "`n  Fix: edit the 'BillingRootPath' value in $($ctx.ConfigPath)" +
                "`n  Or run: Test-CoworkPolicyConnection -AutoDiscover    (probes every BillingRootPathCandidates entry and reports which one works)"
    }
    elseif ($Status -eq 403) {
        $msg += "`n`nHTTP 403 means the signed-in account lacks permission, or the required Graph scope was not consented." +
                "`n  Fix: run Connect-CoworkPolicy -Force, or add the missing scope to 'Scopes' in config.json."
    }

    return (New-Object System.Exception($msg, $ErrorRecord.Exception))
}

function Test-CoworkPolicyConnection {
    <#
    .SYNOPSIS
        Verifies that the configured billing root actually resolves.
    .DESCRIPTION
        Probes GET {billingRoot}/spendingPolicies. On 404 it reports the exact config.json
        key to change. With -AutoDiscover it probes every entry in BillingRootPathCandidates
        and reports which one responds.
    .PARAMETER AutoDiscover
        Probe all candidate billing root paths.
    .PARAMETER Apply
        With -AutoDiscover, write the first working candidate back to config.json.
    .EXAMPLE
        Test-CoworkPolicyConnection
    .EXAMPLE
        Test-CoworkPolicyConnection -AutoDiscover -Apply
    #>
    [CmdletBinding()]
    param(
        [switch]$AutoDiscover,
        [switch]$Apply
    )

    Assert-CoworkConnected | Out-Null
    $ctx = Get-CoworkContext

    $candidates = @()
    if ($AutoDiscover) {
        $candidates = @($ctx.Config.BillingRootPath) + @($ctx.Config.BillingRootPathCandidates)
        $candidates = $candidates | Where-Object { $null -ne $_ } | Select-Object -Unique
    }
    else {
        $candidates = @($ctx.Config.BillingRootPath)
    }

    $results = New-Object System.Collections.ArrayList
    $working = $null

    foreach ($cand in $candidates) {
        $root = Get-CoworkBillingRoot -Config $ctx.Config -OverrideBillingRootPath $cand
        $status = 0
        $ok = $false
        $message = ''
        try {
            Invoke-CoworkGraphRequest -Path 'spendingPolicies' -Method GET -BillingRootOverride $root -SuppressWhatIf | Out-Null
            $ok = $true
            $status = 200
            $message = 'OK'
        }
        catch {
            $message = $_.Exception.Message
            if ($message -match 'HTTP (\d+)') { $status = [int]$Matches[1] }
        }

        [void]$results.Add([pscustomobject]@{
            BillingRootPath = $cand
            Uri             = "$root/spendingPolicies"
            Success         = $ok
            Status          = $status
        })

        if ($ok) {
            Write-CoworkLog -Level Success -Message "Billing root OK: $root"
            if (-not $working) { $working = $cand }
            if (-not $AutoDiscover) { break }
        }
        else {
            $level = if ($AutoDiscover) { 'Info' } else { 'Error' }
            Write-CoworkLog -Level $level -Message "Billing root failed (HTTP $status): $root/spendingPolicies"
        }
    }

    if (-not $working) {
        Write-CoworkLog -Level Error -Message "No working billing root found."
        Write-CoworkLog -Level Error -Message "Edit 'BillingRootPath' in $($ctx.ConfigPath) to the correct value from your internal API document."
        if (-not $AutoDiscover) {
            Write-CoworkLog -Level Error -Message "Tip: run 'Test-CoworkPolicyConnection -AutoDiscover' to probe all known candidates."
        }
        return , $results.ToArray()
    }

    if ($Apply -and $working -ne $ctx.Config.BillingRootPath) {
        Set-CoworkBillingRootPath -BillingRootPath $working
        Write-CoworkLog -Level Success -Message "config.json updated: BillingRootPath = '$working'"
    }

    return , $results.ToArray()
}

function Set-CoworkBillingRootPath {
    <#
    .SYNOPSIS
        Persists a new BillingRootPath into config.json and refreshes module state.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BillingRootPath)

    $ctx = Get-CoworkContext
    $raw = Get-Content -LiteralPath $ctx.ConfigPath -Raw -Encoding UTF8
    $obj = $raw | ConvertFrom-Json
    $obj.BillingRootPath = $BillingRootPath
    ($obj | ConvertTo-Json -Depth 20) | Set-Content -LiteralPath $ctx.ConfigPath -Encoding UTF8

    $ctx.Config.BillingRootPath = $BillingRootPath
    $ctx.BillingRoot = Get-CoworkBillingRoot -Config $ctx.Config
    Clear-CoworkCache
}

function Enable-CoworkWhatIfPayload {
    [CmdletBinding()]
    param()
    $ctx = Get-CoworkContext
    $ctx.WhatIfPayload = $true
    $ctx.PayloadLog.Clear()
}

function Disable-CoworkWhatIfPayload {
    [CmdletBinding()]
    param()
    (Get-CoworkContext).WhatIfPayload = $false
}

function Get-CoworkPayloadLog {
    <#
    .SYNOPSIS
        Returns the method/uri/body of every write call captured in -WhatIfPayload mode.
    #>
    [CmdletBinding()]
    param()
    return , (Get-CoworkContext).PayloadLog.ToArray()
}
