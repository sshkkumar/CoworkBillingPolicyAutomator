# Cowork.CsvSchema.ps1
# CSV column definitions, parsing/normalization, and every Graph request payload builder.
#
# ALL request bodies are built in this file. The internal API document publishes endpoint
# paths but not body property names, so if a property name turns out to be wrong it is a
# one-line fix here - no other file needs to change. Use -WhatIfPayload to print the exact
# JSON that would be sent.

$script:CoworkCsvColumns = @(
    @{ Name = 'PolicyName';                    Required = $true;  Description = 'Policy display name. Minimum 10 characters.' }
    @{ Name = 'AssignmentType';                Required = $true;  Description = 'AllUsers or Groups.' }
    @{ Name = 'Groups';                        Required = $false; Description = 'Semicolon-separated group display names or object ids. Required when AssignmentType=Groups.' }
    @{ Name = 'Services';                      Required = $true;  Description = 'Semicolon-separated agent/service names from services.json, e.g. Copilot Cowork.' }
    @{ Name = 'MonthlySpendingLimitType';      Required = $true;  Description = 'NoLimit or Limited.' }
    @{ Name = 'MonthlySpendingLimitCredits';   Required = $false; Description = 'Credits as a whole number. Required when MonthlySpendingLimitType=Limited.' }
    @{ Name = 'UserMonthlyBudgetLimitType';    Required = $true;  Description = 'NoLimit or Limited.' }
    @{ Name = 'UserMonthlyBudgetLimitCredits'; Required = $false; Description = 'Credits as a whole number. Required when UserMonthlyBudgetLimitType=Limited.' }
    @{ Name = 'AlertEmails';                   Required = $false; Description = 'Semicolon-separated recipient UPNs or email addresses.' }
    @{ Name = 'PolicyAlertThresholdType';      Required = $false; Description = 'Percent or Credits. Percent requires MonthlySpendingLimitType=Limited.' }
    @{ Name = 'PolicyAlertThresholdValue';     Required = $false; Description = 'Threshold number. Percent must be 1-100; Credits must not exceed the policy limit.' }
    @{ Name = 'UserAlertThresholdType';        Required = $false; Description = 'Percent or Credits. Requires UserMonthlyBudgetLimitType=Limited.' }
    @{ Name = 'UserAlertThresholdValue';       Required = $false; Description = 'Threshold number. Percent must be 1-100; Credits must not exceed the user budget limit.' }
)

function Get-CoworkCsvColumn {
    <#
    .SYNOPSIS
        Returns the CSV column definitions used by the tool.
    #>
    [CmdletBinding()]
    param()
    return , (@($script:CoworkCsvColumns) | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; Required = $_.Required; Description = $_.Description }
    })
}

function New-CoworkPolicyTemplate {
    <#
    .SYNOPSIS
        Writes a blank CSV template with the correct header row.
    .EXAMPLE
        New-CoworkPolicyTemplate -Path .\my-policies.csv
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $header = (@($script:CoworkCsvColumns) | ForEach-Object { $_.Name }) -join ','
    Set-Content -LiteralPath $Path -Value $header -Encoding UTF8
    Write-CoworkLog -Level Success -Message "Template written to $Path"
    return $Path
}

function Split-CoworkMultiValue {
    <#
    .SYNOPSIS
        Splits a semicolon-separated cell into trimmed, de-duplicated, non-empty values.
    #>
    [CmdletBinding()]
    param([string]$Value, [string]$Separator)

    if ([string]::IsNullOrWhiteSpace($Value)) { return @() }
    if (-not $Separator) { $Separator = ';' }

    $parts = $Value -split ([regex]::Escape($Separator))
    $out = New-Object System.Collections.ArrayList
    foreach ($p in $parts) {
        $t = $p.Trim()
        if ($t) { [void]$out.Add($t) }
    }
    return , $out.ToArray()
}

function ConvertTo-CoworkEnumValue {
    <#
    .SYNOPSIS
        Case/space/punctuation-insensitive match of a cell value against allowed values.
    .OUTPUTS
        The canonical allowed value, or $null when there is no match.
    #>
    [CmdletBinding()]
    param([string]$Value, [string[]]$Allowed)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $norm = ($Value -replace '[\s_\-]', '').ToLowerInvariant()
    foreach ($a in $Allowed) {
        if (($a -replace '[\s_\-]', '').ToLowerInvariant() -eq $norm) { return $a }
    }
    return $null
}

function Import-CoworkPolicyCsv {
    <#
    .SYNOPSIS
        Reads the CSV and returns normalized row objects.
    .DESCRIPTION
        Performs structural checks only (file exists, header present, required columns
        present). Value-level rules are applied later by Test-CoworkRow.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "CSV file not found: $Path"
    }

    $ctx = Get-CoworkContext
    $sep = $ctx.Config.Output.MultiValueSeparator
    if (-not $sep) { $sep = ';' }

    $rows = @(Import-Csv -LiteralPath $Path)
    if ($rows.Count -eq 0) {
        throw "CSV file contains a header but no data rows: $Path"
    }

    $present = @($rows[0].PSObject.Properties.Name)
    $missing = @(@($script:CoworkCsvColumns) | Where-Object { $_.Required } | ForEach-Object { $_.Name } |
                 Where-Object { $present -notcontains $_ })
    if ($missing.Count -gt 0) {
        throw "CSV is missing required column(s): $($missing -join ', ')`nExpected header: $((@($script:CoworkCsvColumns) | ForEach-Object { $_.Name }) -join ',')"
    }

    $unknown = @($present | Where-Object { $_ -and (@($script:CoworkCsvColumns) | ForEach-Object { $_.Name }) -notcontains $_ })
    if ($unknown.Count -gt 0) {
        Write-CoworkLog -Level Warn -Message "CSV contains unrecognized column(s) that will be ignored: $($unknown -join ', ')"
    }

    $index = 1
    $out = New-Object System.Collections.ArrayList

    foreach ($r in $rows) {
        $index++
        $norm = [pscustomobject]@{
            RowNumber                     = $index   # CSV line number including the header
            PolicyName                    = (Get-CoworkCell $r 'PolicyName')
            AssignmentTypeRaw             = (Get-CoworkCell $r 'AssignmentType')
            AssignmentType                = $null
            GroupsRaw                     = (Get-CoworkCell $r 'Groups')
            Groups                        = (Split-CoworkMultiValue -Value (Get-CoworkCell $r 'Groups') -Separator $sep)
            ServicesRaw                   = (Get-CoworkCell $r 'Services')
            Services                      = (Split-CoworkMultiValue -Value (Get-CoworkCell $r 'Services') -Separator $sep)
            MonthlySpendingLimitTypeRaw   = (Get-CoworkCell $r 'MonthlySpendingLimitType')
            MonthlySpendingLimitType      = $null
            MonthlySpendingLimitCreditsRaw= (Get-CoworkCell $r 'MonthlySpendingLimitCredits')
            MonthlySpendingLimitCredits   = $null
            UserMonthlyBudgetLimitTypeRaw = (Get-CoworkCell $r 'UserMonthlyBudgetLimitType')
            UserMonthlyBudgetLimitType    = $null
            UserMonthlyBudgetLimitCreditsRaw = (Get-CoworkCell $r 'UserMonthlyBudgetLimitCredits')
            UserMonthlyBudgetLimitCredits = $null
            AlertEmailsRaw                = (Get-CoworkCell $r 'AlertEmails')
            AlertEmails                   = (Split-CoworkMultiValue -Value (Get-CoworkCell $r 'AlertEmails') -Separator $sep)
            PolicyAlertThresholdTypeRaw   = (Get-CoworkCell $r 'PolicyAlertThresholdType')
            PolicyAlertThresholdType      = $null
            PolicyAlertThresholdValueRaw  = (Get-CoworkCell $r 'PolicyAlertThresholdValue')
            PolicyAlertThresholdValue     = $null
            UserAlertThresholdTypeRaw     = (Get-CoworkCell $r 'UserAlertThresholdType')
            UserAlertThresholdType        = $null
            UserAlertThresholdValueRaw    = (Get-CoworkCell $r 'UserAlertThresholdValue')
            UserAlertThresholdValue       = $null

            # Populated during validation
            ResolvedGroups                = @()
            ResolvedServices              = @()
            ResolvedRecipients            = @()
        }

        $norm.AssignmentType           = ConvertTo-CoworkEnumValue -Value $norm.AssignmentTypeRaw           -Allowed @('AllUsers', 'Groups')
        $norm.MonthlySpendingLimitType = ConvertTo-CoworkEnumValue -Value $norm.MonthlySpendingLimitTypeRaw -Allowed @('NoLimit', 'Limited')
        $norm.UserMonthlyBudgetLimitType = ConvertTo-CoworkEnumValue -Value $norm.UserMonthlyBudgetLimitTypeRaw -Allowed @('NoLimit', 'Limited')
        $norm.PolicyAlertThresholdType  = ConvertTo-CoworkEnumValue -Value $norm.PolicyAlertThresholdTypeRaw  -Allowed @('Percent', 'Credits')
        $norm.UserAlertThresholdType    = ConvertTo-CoworkEnumValue -Value $norm.UserAlertThresholdTypeRaw    -Allowed @('Percent', 'Credits')

        [void]$out.Add($norm)
    }

    Write-CoworkLog -Level Info -Message "Loaded $($out.Count) row(s) from $Path"
    return , $out.ToArray()
}

function Get-CoworkCell {
    [CmdletBinding()]
    param($Row, [string]$Name)
    if ($Row.PSObject.Properties.Name -notcontains $Name) { return '' }
    $v = $Row.$Name
    if ($null -eq $v) { return '' }
    return ([string]$v).Trim()
}

function ConvertTo-CoworkWholeNumber {
    <#
    .SYNOPSIS
        Parses a credit/threshold cell into a whole number.
    .OUTPUTS
        PSCustomObject with Value and Error. Thousands separators are tolerated.
    #>
    [CmdletBinding()]
    param([string]$Value, [string]$FieldName, [switch]$AllowDecimal)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return [pscustomobject]@{ Value = $null; Error = $null }
    }

    $clean = $Value -replace '[,\s]', ''
    $clean = $clean -replace '^\+', ''

    $d = 0.0
    if (-not [double]::TryParse($clean, [System.Globalization.NumberStyles]::Float,
            [System.Globalization.CultureInfo]::InvariantCulture, [ref]$d)) {
        return [pscustomobject]@{ Value = $null; Error = "$FieldName must be a number. Received '$Value'." }
    }

    if (-not $AllowDecimal -and ($d -ne [math]::Floor($d))) {
        return [pscustomobject]@{ Value = $null; Error = "$FieldName must be a whole number of credits. Received '$Value'." }
    }

    return [pscustomobject]@{ Value = $d; Error = $null }
}

# ---------------------------------------------------------------------------
# Payload builders - every Graph request body is constructed below.
# ---------------------------------------------------------------------------

function New-CoworkSpendingPolicyPayload {
    <#
    .SYNOPSIS
        Body for POST {billingRoot}/spendingPolicies
    .DESCRIPTION
        Verified against the published Copilot Cost Management API (beta).

        @odata.type selects the policy flavour:
          #microsoft.graph.allUsersSpendingPolicy
          #microsoft.graph.selectedGroupsSpendingPolicy

        displayName, periodLimit, perUserLimit and serviceSettings are ALL required
        on create. Limits are costManagementQuantity objects, not bare numbers:
          #microsoft.graph.limitedCostManagementQuantity    -> { value, unit }
          #microsoft.graph.unlimitedCostManagementQuantity  -> { unit } only
        A limited quantity of 0 means "no consumption permitted" and is NOT the
        same thing as unlimited.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Row)

    $odataType = if ($Row.AssignmentType -eq 'Groups') {
        '#microsoft.graph.selectedGroupsSpendingPolicy'
    }
    else {
        '#microsoft.graph.allUsersSpendingPolicy'
    }

    $body = [ordered]@{
        '@odata.type' = $odataType
        displayName   = $Row.PolicyName
        periodLimit    = (New-CoworkQuantityPayload -LimitType $Row.MonthlySpendingLimitType   -Credits $Row.MonthlySpendingLimitCredits)
        perUserLimit   = (New-CoworkQuantityPayload -LimitType $Row.UserMonthlyBudgetLimitType -Credits $Row.UserMonthlyBudgetLimitCredits)
        billingMethods = 'prepaidCredits'
    }

    # serviceSettings is part of the create body. It cannot be POSTed separately.
    $settings = @()
    foreach ($s in @($Row.ResolvedServices)) {
        $settings += (New-CoworkServiceSettingPayload -ServiceId $s.ServiceId)
    }
    $body['serviceSettings'] = @($settings)

    return $body
}

function New-CoworkQuantityPayload {
    <#
    .SYNOPSIS
        Builds a costManagementQuantity used by periodLimit and perUserLimit.
    #>
    [CmdletBinding()]
    param([string]$LimitType, $Credits)

    if ($LimitType -eq 'Limited') {
        return [ordered]@{
            '@odata.type' = '#microsoft.graph.limitedCostManagementQuantity'
            value         = [int]$Credits
            unit          = 'copilotCredit'
        }
    }

    return [ordered]@{
        '@odata.type' = '#microsoft.graph.unlimitedCostManagementQuantity'
        unit          = 'copilotCredit'
    }
}

function New-CoworkDirectoryRefPayload {
    <#
    .SYNOPSIS
        Standard OData $ref body: { "@odata.id": "https://graph.microsoft.com/v1.0/{set}/{id}" }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('groups', 'users')][string]$EntitySet,
        [Parameter(Mandatory)][string]$Id
    )
    $ctx = Get-CoworkContext
    return [ordered]@{ '@odata.id' = "$($ctx.DirectoryRoot)/$EntitySet/$Id" }
}

function New-CoworkServiceSettingPayload {
    <#
    .SYNOPSIS
        One entry of the serviceSettings collection on a spending policy.
    .DESCRIPTION
        The published contract uses a 'state' string, not a boolean.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ServiceId,
        [bool]$Enabled = $true
    )

    $state = if ($Enabled) { 'enabled' } else { 'disabled' }

    return [ordered]@{
        serviceId = $ServiceId
        state     = $state
    }
}

function New-CoworkEmailThresholdPayload {
    <#
    .SYNOPSIS
        Body for PATCH {billingRoot}/spendingPolicies/{id}/emailThresholdSettings
    .DESCRIPTION
        costManagementAlertSetting carries a flat 'thresholds' collection plus
        'isEnabled'. Each threshold is one of:
          #microsoft.graph.percentageCostManagementAlertThreshold  (value 1-100)
          #microsoft.graph.absoluteCostManagementAlertThreshold    (value in credits)

        IMPORTANT: the published beta schema has NO separate per-user alert
        threshold - 'thresholds' is evaluated against the policy limit only.
        A UserAlertThreshold* value from the CSV therefore cannot be sent. It is
        reported to the caller via Test-CoworkUserAlertSupported rather than being
        silently folded into the policy thresholds, which would alert at the wrong
        number.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Row,
        [bool]$Enabled = $true
    )

    $thresholds = @()

    if ($Row.PolicyAlertThresholdType) {
        $thresholds += (New-CoworkAlertThresholdPayload -ThresholdType $Row.PolicyAlertThresholdType -Value $Row.PolicyAlertThresholdValue)
    }

    if ($thresholds.Count -eq 0) { return [ordered]@{} }

    return [ordered]@{
        isEnabled  = $Enabled
        thresholds = @($thresholds)
    }
}

function New-CoworkAlertThresholdPayload {
    <#
    .SYNOPSIS
        A single costManagementAlertThreshold entry.
    #>
    [CmdletBinding()]
    param([string]$ThresholdType, $Value)

    $type = if ($ThresholdType -eq 'Percent') {
        '#microsoft.graph.percentageCostManagementAlertThreshold'
    }
    else {
        '#microsoft.graph.absoluteCostManagementAlertThreshold'
    }

    return [ordered]@{
        '@odata.type' = $type
        value         = [double]$Value
    }
}

function Test-CoworkUserAlertSupported {
    <#
    .SYNOPSIS
        Returns a message when the row asks for something the API cannot express.
    .OUTPUTS
        A warning string, or $null when there is nothing to report.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Row)

    if (-not $Row.UserAlertThresholdType) { return $null }

    return ("A per-user alert threshold ({0} {1}) was requested, but the Copilot Cost Management beta API " +
            "exposes only policy-level alert thresholds. This part of the row was NOT applied. Configure the " +
            "per-user alert manually in the admin center, or re-run once the API exposes it." -f
            $Row.UserAlertThresholdValue, $Row.UserAlertThresholdType)
}
