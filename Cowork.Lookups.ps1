# Cowork.Lookups.ps1
# Tenant balance, existing policies, group/user resolution, and the service catalog.

function Get-CoworkTenantCreditBalance {
    <#
    .SYNOPSIS
        Reads the tenant credit balance.
    .DESCRIPTION
        GET {billingRoot}/getTenantCreditBalance()
        The response shape is not published, so the function probes a list of plausible
        property names and returns a normalized object. Raw is always included.
    .PARAMETER Refresh
        Bypass the cache.
    #>
    [CmdletBinding()]
    param([switch]$Refresh)

    $ctx = Get-CoworkContext
    if ($ctx.Cache.TenantBalance -and -not $Refresh) { return $ctx.Cache.TenantBalance }

    $raw = Invoke-CoworkGraphRequest -Path 'getTenantCreditBalance()' -Method GET -SuppressWhatIf

    $total = Get-CoworkFirstNumericProperty -Object $raw -Names @(
        'totalCredits', 'totalCreditBalance', 'creditBalance', 'balance',
        'totalBalance', 'availableCredits', 'remainingCredits', 'credits', 'value'
    )
    $consumed = Get-CoworkFirstNumericProperty -Object $raw -Names @(
        'consumedCredits', 'usedCredits', 'spentCredits', 'consumed', 'used'
    )

    $result = [pscustomobject]@{
        TotalCredits    = $total
        ConsumedCredits = $consumed
        Raw             = $raw
    }

    $ctx.Cache.TenantBalance = $result

    if ($null -eq $total) {
        Write-CoworkLog -Level Warn -Message "Tenant credit balance returned no recognizable credit total. Tenant-ceiling validation will be skipped. Inspect (Get-CoworkTenantCreditBalance).Raw and add the correct property name to Get-CoworkTenantCreditBalance."
    }
    else {
        Write-CoworkLog -Level Info -Message "Tenant credit balance: $total credits."
    }

    return $result
}

function Get-CoworkFirstNumericProperty {
    [CmdletBinding()]
    param($Object, [string[]]$Names)

    if ($null -eq $Object) { return $null }

    if ($Object -is [int] -or $Object -is [long] -or $Object -is [double] -or $Object -is [decimal]) {
        return [double]$Object
    }

    foreach ($n in $Names) {
        if ($Object.PSObject.Properties.Name -contains $n) {
            $v = $Object.$n
            if ($null -eq $v) { continue }
            $d = 0.0
            if ([double]::TryParse([string]$v, [ref]$d)) { return $d }
        }
    }
    return $null
}

function Get-CoworkSpendingPolicy {
    <#
    .SYNOPSIS
        Lists spending policies, or gets one by id.
    .DESCRIPTION
        GET {billingRoot}/spendingPolicies
        GET {billingRoot}/spendingPolicies/{id}
    #>
    [CmdletBinding()]
    param(
        [string]$Id,
        [switch]$Refresh
    )

    if ($Id) {
        return Invoke-CoworkGraphRequest -Path "spendingPolicies/$Id" -Method GET -SuppressWhatIf
    }

    $ctx = Get-CoworkContext
    if ($null -ne $ctx.Cache.Policies -and -not $Refresh) { return , $ctx.Cache.Policies }

    $all = Invoke-CoworkGraphRequest -Path 'spendingPolicies' -Method GET -All -SuppressWhatIf
    if ($null -eq $all) { $all = @() }
    $ctx.Cache.Policies = @($all)
    Write-CoworkLog -Level Info -Message "Found $($ctx.Cache.Policies.Count) existing spending policies."
    return , $ctx.Cache.Policies
}

function Get-CoworkPolicyLimitCredits {
    <#
    .SYNOPSIS
        Reads the monthly credit limit off a spending policy returned by Graph.
    .OUTPUTS
        The credit value, or $null when the policy is unlimited or the limit
        cannot be determined.
    #>
    [CmdletBinding()]
    param($Policy)

    if (-not $Policy) { return $null }

    $read = {
        param($o, $n)
        if ($null -eq $o) { return $null }
        if ($o -is [System.Collections.IDictionary]) {
            if ($o.Contains($n)) { return $o[$n] }
            return $null
        }
        if ($o.PSObject.Properties.Name -contains $n) { return $o.$n }
        return $null
    }

    # periodLimit is the current contract; the others are legacy/defensive.
    foreach ($n in @('periodLimit', 'monthlyCreditLimit', 'limit')) {
        $v = & $read $Policy $n
        if ($null -eq $v) { continue }

        if ($v -is [string] -or $v -is [int] -or $v -is [long] -or $v -is [double] -or $v -is [decimal]) {
            $d = 0.0
            if ([double]::TryParse([string]$v, [ref]$d)) { return $d }
            continue
        }

        $type = [string](& $read $v '@odata.type')
        if ($type -and $type -match 'unlimited') { return $null }

        $val = & $read $v 'value'
        if ($null -ne $val) {
            $d = 0.0
            if ([double]::TryParse([string]$val, [ref]$d)) { return $d }
        }
        return $null
    }

    return $null
}

# ---------------------------------------------------------------------------
# Service catalog
# ---------------------------------------------------------------------------

function Get-CoworkServiceCatalog {
    <#
    .SYNOPSIS
        Returns the service catalog from services.json.
    .PARAMETER FromExistingPolicies
        Instead of returning the file, read serviceSettings from every existing policy in
        the tenant and print a ready-to-paste services.json block of the real serviceIds.
    .EXAMPLE
        Get-CoworkServiceCatalog -FromExistingPolicies
    #>
    [CmdletBinding()]
    param([switch]$FromExistingPolicies)

    $ctx = Get-CoworkContext

    if (-not $FromExistingPolicies) {
        return , @($ctx.ServiceCatalog.Services)
    }

    Assert-CoworkConnected | Out-Null
    $found = @{}

    foreach ($p in (Get-CoworkSpendingPolicy)) {
        $pid = Get-CoworkObjectId -Object $p
        if (-not $pid) { continue }
        try {
            $settings = Invoke-CoworkGraphRequest -Path "spendingPolicies/$pid/serviceSettings" -Method GET -All -SuppressWhatIf
        }
        catch {
            Write-CoworkLog -Level Warn -Message "Could not read serviceSettings for policy $pid : $($_.Exception.Message)"
            continue
        }
        foreach ($s in @($settings)) {
            $sid = Get-CoworkFirstStringProperty -Object $s -Names @('serviceId', 'id', 'service')
            if ($sid) {
                $name = Get-CoworkFirstStringProperty -Object $s -Names @('displayName', 'serviceName', 'name')
                if (-not $name) { $name = $sid }
                $found[$sid] = $name
            }
        }
    }

    if ($found.Count -eq 0) {
        Write-CoworkLog -Level Warn -Message "No serviceIds discovered. Either there are no existing policies, or none have serviceSettings configured."
        return @()
    }

    Write-CoworkLog -Level Success -Message "Discovered $($found.Count) serviceId value(s) in use. Paste into services.json:"
    $block = ($found.GetEnumerator() | ForEach-Object {
        '    { "Name": "' + $_.Value + '", "Aliases": [], "ServiceId": "' + $_.Key + '", "Verified": true }'
    }) -join ",`n"
    Write-Host "`n  `"Services`": [`n$block`n  ]`n"

    return , ($found.GetEnumerator() | ForEach-Object {
        [pscustomobject]@{ Name = $_.Value; ServiceId = $_.Key; Verified = $true }
    })
}

function Resolve-CoworkService {
    <#
    .SYNOPSIS
        Resolves a friendly service name (or raw id/GUID) to a serviceId.
    .OUTPUTS
        PSCustomObject with Input, Name, ServiceId, Resolved, Error.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    $ctx = Get-CoworkContext
    $needle = $Name.Trim()

    foreach ($svc in @($ctx.ServiceCatalog.Services)) {
        $names = @($svc.Name) + @($svc.Aliases)
        foreach ($n in $names) {
            if ($n -and ($n.Trim() -ieq $needle)) {
                return [pscustomobject]@{
                    Input = $Name; Name = $svc.Name; ServiceId = $svc.ServiceId
                    Resolved = $true; Error = $null
                }
            }
        }
        if ($svc.ServiceId -and ($svc.ServiceId.Trim() -ieq $needle)) {
            return [pscustomobject]@{
                Input = $Name; Name = $svc.Name; ServiceId = $svc.ServiceId
                Resolved = $true; Error = $null
            }
        }
    }

    # A raw GUID is always accepted and passed through unmapped.
    $g = [guid]::Empty
    if ([guid]::TryParse($needle, [ref]$g)) {
        return [pscustomobject]@{
            Input = $Name; Name = $needle; ServiceId = $needle
            Resolved = $true; Error = $null
        }
    }

    $known = (@($ctx.ServiceCatalog.Services) | ForEach-Object { $_.Name }) -join ', '
    return [pscustomobject]@{
        Input = $Name; Name = $needle; ServiceId = $null; Resolved = $false
        Error = "Unknown service '$needle'. Known services: $known. Add it to services.json or supply a raw serviceId GUID."
    }
}

# ---------------------------------------------------------------------------
# Directory lookups (Graph v1.0)
# ---------------------------------------------------------------------------

function Get-CoworkObjectId {
    [CmdletBinding()]
    param($Object)
    if ($null -eq $Object) { return $null }

    foreach ($n in @('id', 'Id', 'policyId', 'objectId')) {
        if ($Object -is [System.Collections.IDictionary] -and $Object.Contains($n) -and $Object[$n]) {
            return [string]$Object[$n]
        }
        if ($Object.PSObject.Properties.Name -contains $n -and $Object.$n) {
            return [string]$Object.$n
        }
        # Invoke-MgGraphRequest -OutputType PSObject can place undeclared Graph
        # fields in AdditionalProperties instead of exposing them as properties.
        $additional = $null
        if ($Object.PSObject.Properties.Name -contains 'AdditionalProperties') {
            $additional = $Object.AdditionalProperties
        }
        if ($additional -is [System.Collections.IDictionary] -and $additional.Contains($n) -and $additional[$n]) {
            return [string]$additional[$n]
        }
    }

    # Some Graph wrappers expose only @odata.id on directory references.
    $odataId = $null
    if ($Object -is [System.Collections.IDictionary] -and $Object.Contains('@odata.id')) {
        $odataId = $Object['@odata.id']
    }
    elseif ($Object.PSObject.Properties.Name -contains '@odata.id') {
        $odataId = $Object.'@odata.id'
    }
    elseif ($Object.PSObject.Properties.Name -contains 'AdditionalProperties' -and
            $Object.AdditionalProperties -is [System.Collections.IDictionary] -and
            $Object.AdditionalProperties.Contains('@odata.id')) {
        $odataId = $Object.AdditionalProperties['@odata.id']
    }
    if ($odataId -and [string]$odataId -match '/([^/]+)$') {
        return $Matches[1]
    }

    return $null
}

function Get-CoworkFirstStringProperty {
    [CmdletBinding()]
    param($Object, [string[]]$Names)
    if ($null -eq $Object) { return $null }
    foreach ($n in $Names) {
        if ($Object.PSObject.Properties.Name -contains $n) {
            $v = $Object.$n
            if ($null -ne $v -and -not [string]::IsNullOrWhiteSpace([string]$v)) { return [string]$v }
        }
        if ($Object.PSObject.Properties.Name -contains 'AdditionalProperties' -and
            $Object.AdditionalProperties -is [System.Collections.IDictionary] -and
            $Object.AdditionalProperties.Contains($n)) {
            $v = $Object.AdditionalProperties[$n]
            if ($null -ne $v -and -not [string]::IsNullOrWhiteSpace([string]$v)) { return [string]$v }
        }
    }
    return $null
}

function ConvertTo-CoworkODataFilterLiteral {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Value)
    return $Value.Replace("'", "''")
}

function Resolve-CoworkGroup {
    <#
    .SYNOPSIS
        Resolves a group by object id or display name.
    .DESCRIPTION
        GET {v1.0}/groups/{id}                       when the input is a GUID
        GET {v1.0}/groups?$filter=displayName eq 'â€¦'  otherwise
        Ambiguous display names (more than one match) are reported as an error.
    .OUTPUTS
        PSCustomObject with Input, Id, DisplayName, Resolved, Error.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Group)

    $ctx = Get-CoworkContext
    $key = $Group.Trim().ToLowerInvariant()
    if ($ctx.Cache.Groups.ContainsKey($key)) { return $ctx.Cache.Groups[$key] }

    $result = $null
    $g = [guid]::Empty

    if ([guid]::TryParse($Group.Trim(), [ref]$g)) {
        try {
            $obj = Invoke-CoworkGraphRequest -Path "directory:groups/$($g.ToString())" -Method GET -SuppressWhatIf
            $resolvedId = Get-CoworkObjectId -Object $obj
            if ([string]::IsNullOrWhiteSpace($resolvedId)) {
                throw "Group id '$Group' lookup returned no object id."
            }
            $result = [pscustomobject]@{
                Input = $Group; Id = $resolvedId
                DisplayName = (Get-CoworkFirstStringProperty -Object $obj -Names @('displayName'))
                Resolved = $true; Error = $null
            }
        }
        catch {
            $result = [pscustomobject]@{
                Input = $Group; Id = $null; DisplayName = $null; Resolved = $false
                Error = "Group id '$Group' was not found in the tenant."
            }
        }
    }
    else {
        $literal = ConvertTo-CoworkODataFilterLiteral -Value $Group.Trim()
        $filter = [uri]::EscapeDataString("displayName eq '$literal'")
        $path = "directory:groups?`$filter=$filter&`$select=id,displayName&`$top=5"
        try {
            $matches = @(Invoke-CoworkGraphRequest -Path $path -Method GET -All -SuppressWhatIf)
        }
        catch {
            $matches = @()
            Write-CoworkLog -Level Warn -Message "Group lookup failed for '$Group': $($_.Exception.Message)"
        }

        if ($matches.Count -eq 0) {
            $result = [pscustomobject]@{
                Input = $Group; Id = $null; DisplayName = $null; Resolved = $false
                Error = "Group '$Group' was not found in the tenant."
            }
        }
        elseif ($matches.Count -gt 1) {
            $ids = (@($matches) | ForEach-Object { Get-CoworkObjectId -Object $_ }) -join ', '
            $result = [pscustomobject]@{
                Input = $Group; Id = $null; DisplayName = $Group; Resolved = $false
                Error = "Group name '$Group' is ambiguous - $($matches.Count) groups share this display name ($ids). Use the group object id instead."
            }
        }
        else {
            $resolvedId = Get-CoworkObjectId -Object $matches[0]
            $resolvedName = Get-CoworkFirstStringProperty -Object $matches[0] -Names @('displayName')

            # Fallback for Graph PowerShell response shapes that hide selected
            # fields from the generic request wrapper. Request raw JSON so the
            # id field cannot be lost during SDK object deserialization.
            if ([string]::IsNullOrWhiteSpace($resolvedId) -and (Get-Command Invoke-MgGraphRequest -ErrorAction SilentlyContinue)) {
                try {
                    $rawUri = "$($ctx.DirectoryRoot)/groups?`$filter=$filter&`$select=id,displayName&`$top=5"
                    $rawJson = Invoke-MgGraphRequest -Method GET -Uri $rawUri -OutputType Json -ErrorAction Stop
                    $rawPage = if ($rawJson -is [string]) { $rawJson | ConvertFrom-Json } else { $rawJson }
                    $rawMatches = @($rawPage.value)
                    if ($rawMatches.Count -eq 1) {
                        $resolvedId = [string]$rawMatches[0].id
                        $resolvedName = [string]$rawMatches[0].displayName
                    }
                }
                catch {
                    Write-CoworkLog -Level Debug -Message "Raw JSON group lookup fallback failed for '$Group': $($_.Exception.Message)"
                }
            }

            # Final fallback for installations that include the typed Groups SDK.
            if ([string]::IsNullOrWhiteSpace($resolvedId) -and (Get-Command Get-MgGroup -ErrorAction SilentlyContinue)) {
                try {
                    $typedMatches = @(Get-MgGroup -Filter "displayName eq '$literal'" -Property Id,DisplayName -ErrorAction Stop)
                    if ($typedMatches.Count -eq 1) {
                        $resolvedId = [string]$typedMatches[0].Id
                        $resolvedName = [string]$typedMatches[0].DisplayName
                    }
                }
                catch {
                    Write-CoworkLog -Level Debug -Message "Typed group lookup fallback failed for '$Group': $($_.Exception.Message)"
                }
            }

            if ([string]::IsNullOrWhiteSpace($resolvedId)) {
                $result = [pscustomobject]@{
                    Input = $Group; Id = $null; DisplayName = $Group; Resolved = $false
                    Error = "Group '$Group' was found by name but Graph returned no object id. Supply the group's object ID in the Groups column."
                }
            }
            else {
                $result = [pscustomobject]@{
                    Input = $Group; Id = $resolvedId
                    DisplayName = $resolvedName
                    Resolved = $true; Error = $null
                }
            }
        }
    }

    $ctx.Cache.Groups[$key] = $result
    return $result
}

function Resolve-CoworkRecipient {
    <#
    .SYNOPSIS
        Resolves an alert recipient (UPN / email / object id) to a user object id.
    .DESCRIPTION
        GET {v1.0}/users/{upn-or-id}
        Falls back to a mail / userPrincipalName filter when direct lookup fails, which
        covers recipients whose mail address differs from their UPN.
    .OUTPUTS
        PSCustomObject with Input, Id, UserPrincipalName, Resolved, Error.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Recipient)

    $ctx = Get-CoworkContext
    $needle = $Recipient.Trim()
    $key = $needle.ToLowerInvariant()
    if ($ctx.Cache.Users.ContainsKey($key)) { return $ctx.Cache.Users[$key] }

    $result = $null

    try {
        $obj = Invoke-CoworkGraphRequest -Path "directory:users/$([uri]::EscapeDataString($needle))?`$select=id,userPrincipalName,mail" -Method GET -SuppressWhatIf
        $result = [pscustomobject]@{
            Input = $Recipient; Id = (Get-CoworkObjectId -Object $obj)
            UserPrincipalName = (Get-CoworkFirstStringProperty -Object $obj -Names @('userPrincipalName', 'mail'))
            Resolved = $true; Error = $null
        }
    }
    catch {
        $literal = ConvertTo-CoworkODataFilterLiteral -Value $needle
        $filter = [uri]::EscapeDataString("mail eq '$literal' or userPrincipalName eq '$literal'")
        $path = "directory:users?`$filter=$filter&`$select=id,userPrincipalName,mail&`$top=5"
        $matches = @()
        try { $matches = @(Invoke-CoworkGraphRequest -Path $path -Method GET -All -SuppressWhatIf) } catch { $matches = @() }

        if ($matches.Count -eq 1) {
            $result = [pscustomobject]@{
                Input = $Recipient; Id = (Get-CoworkObjectId -Object $matches[0])
                UserPrincipalName = (Get-CoworkFirstStringProperty -Object $matches[0] -Names @('userPrincipalName', 'mail'))
                Resolved = $true; Error = $null
            }
        }
        elseif ($matches.Count -gt 1) {
            $result = [pscustomobject]@{
                Input = $Recipient; Id = $null; UserPrincipalName = $null; Resolved = $false
                Error = "Alert recipient '$Recipient' matches $($matches.Count) users. Use the user object id instead."
            }
        }
        else {
            $result = [pscustomobject]@{
                Input = $Recipient; Id = $null; UserPrincipalName = $null; Resolved = $false
                Error = "Alert recipient '$Recipient' was not found in the tenant. Alert emails must be mailboxes of tenant users (POST emailThresholdSettings/recipients/`$ref requires a user id)."
            }
        }
    }

    $ctx.Cache.Users[$key] = $result
    return $result
}

function Get-CoworkUserBalance {
    <#
    .SYNOPSIS
        Reads a user's credit balance, optionally per service.
    .DESCRIPTION
        GET {billingRoot}/userBalances/{userId}
        GET {billingRoot}/userBalances/{userId}/serviceBalances
        GET {billingRoot}/userBalances/{userId}/serviceBalances/{serviceId}
    .PARAMETER UserId
        User object id or UPN. A UPN is resolved to an object id first.
    .PARAMETER ServiceBalances
        Return the per-service balance collection.
    .PARAMETER ServiceId
        Return a single service balance. Accepts a friendly name from services.json.
    .EXAMPLE
        Get-CoworkUserBalance -UserId alice@contoso.com
    .EXAMPLE
        Get-CoworkUserBalance -UserId alice@contoso.com -ServiceId 'Copilot Cowork'
    #>
    [CmdletBinding(DefaultParameterSetName = 'Summary')]
    param(
        [Parameter(Mandatory, ValueFromPipeline)][string]$UserId,
        [Parameter(ParameterSetName = 'All')][switch]$ServiceBalances,
        [Parameter(ParameterSetName = 'One')][string]$ServiceId
    )

    process {
        Assert-CoworkConnected | Out-Null

        $uid = $UserId.Trim()
        $g = [guid]::Empty
        if (-not [guid]::TryParse($uid, [ref]$g)) {
            $r = Resolve-CoworkRecipient -Recipient $uid
            if (-not $r.Resolved) { throw $r.Error }
            $uid = $r.Id
        }

        if ($PSCmdlet.ParameterSetName -eq 'One') {
            $svc = Resolve-CoworkService -Name $ServiceId
            if (-not $svc.Resolved) { throw $svc.Error }
            return Invoke-CoworkGraphRequest -Path "userBalances/$uid/serviceBalances/$($svc.ServiceId)" -Method GET -SuppressWhatIf
        }

        if ($PSCmdlet.ParameterSetName -eq 'All') {
            return , @(Invoke-CoworkGraphRequest -Path "userBalances/$uid/serviceBalances" -Method GET -All -SuppressWhatIf)
        }

        return Invoke-CoworkGraphRequest -Path "userBalances/$uid" -Method GET -SuppressWhatIf
    }
}
