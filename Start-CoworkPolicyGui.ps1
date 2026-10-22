<#
.SYNOPSIS
    WinForms front end for the Cowork Billing Policy Automator.
.DESCRIPTION
    Connect to Graph, pick a CSV, validate it, review the per-row results, then commit.
    The Commit button stays disabled until a validation pass has produced at least one
    valid row, and it always asks for confirmation first.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -STA -File .\Start-CoworkPolicyGui.ps1
#>
[CmdletBinding()]
param(
    [string]$CsvPath
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$modulePath = Join-Path $PSScriptRoot 'CoworkBillingPolicy.psd1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    [System.Windows.Forms.MessageBox]::Show(
        "CoworkBillingPolicy.psd1 was not found next to this script.`n`nExpected at:`n$modulePath",
        'Cowork Billing Policy Automator', 'OK', 'Error') | Out-Null
    return
}

try {
    Import-Module $modulePath -Force -ErrorAction Stop
}
catch {
    [System.Windows.Forms.MessageBox]::Show(
        "Failed to load the CoworkBillingPolicy module.`n`n$($_.Exception.Message)",
        'Cowork Billing Policy Automator', 'OK', 'Error') | Out-Null
    return
}

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
$script:Results = @()
$script:ValidCount = 0
$script:LastValidatedPath = $null
$script:Policies = @()

# ---------------------------------------------------------------------------
# Form
# ---------------------------------------------------------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Cowork Billing Policy Automator'
$form.Size = New-Object System.Drawing.Size(1180, 760)
$form.StartPosition = 'CenterScreen'
$form.MinimumSize = New-Object System.Drawing.Size(980, 620)

$font = New-Object System.Drawing.Font('Segoe UI', 9)
$form.Font = $font

# --- Top: connection -------------------------------------------------------
$grpConn = New-Object System.Windows.Forms.GroupBox
$grpConn.Text = '1. Connect'
$grpConn.Location = New-Object System.Drawing.Point(12, 10)
$grpConn.Size = New-Object System.Drawing.Size(1140, 70)
$grpConn.Anchor = 'Top,Left,Right'
$form.Controls.Add($grpConn)

$btnConnect = New-Object System.Windows.Forms.Button
$btnConnect.Text = 'Sign in to Microsoft Graph'
$btnConnect.Location = New-Object System.Drawing.Point(14, 26)
$btnConnect.Size = New-Object System.Drawing.Size(210, 30)
$grpConn.Controls.Add($btnConnect)

$lblAccount = New-Object System.Windows.Forms.Label
$lblAccount.Text = 'Not connected.'
$lblAccount.Location = New-Object System.Drawing.Point(238, 33)
$lblAccount.Size = New-Object System.Drawing.Size(560, 20)
$lblAccount.ForeColor = [System.Drawing.Color]::DimGray
$grpConn.Controls.Add($lblAccount)

$btnTestEndpoint = New-Object System.Windows.Forms.Button
$btnTestEndpoint.Text = 'Test API endpoint'
$btnTestEndpoint.Location = New-Object System.Drawing.Point(810, 26)
$btnTestEndpoint.Size = New-Object System.Drawing.Size(150, 30)
$btnTestEndpoint.Anchor = 'Top,Right'
$btnTestEndpoint.Enabled = $false
$grpConn.Controls.Add($btnTestEndpoint)

$btnDisconnect = New-Object System.Windows.Forms.Button
$btnDisconnect.Text = 'Sign out'
$btnDisconnect.Location = New-Object System.Drawing.Point(970, 26)
$btnDisconnect.Size = New-Object System.Drawing.Size(150, 30)
$btnDisconnect.Anchor = 'Top,Right'
$btnDisconnect.Enabled = $false
$grpConn.Controls.Add($btnDisconnect)

# --- File + actions --------------------------------------------------------
$grpFile = New-Object System.Windows.Forms.GroupBox
$grpFile.Text = '2. Choose a policy CSV and validate'
$grpFile.Location = New-Object System.Drawing.Point(12, 86)
$grpFile.Size = New-Object System.Drawing.Size(1140, 76)
$grpFile.Anchor = 'Top,Left,Right'
$form.Controls.Add($grpFile)

$txtPath = New-Object System.Windows.Forms.TextBox
$txtPath.Location = New-Object System.Drawing.Point(14, 30)
$txtPath.Size = New-Object System.Drawing.Size(690, 24)
$txtPath.Anchor = 'Top,Left,Right'
$grpFile.Controls.Add($txtPath)

$btnBrowse = New-Object System.Windows.Forms.Button
$btnBrowse.Text = 'Browse...'
$btnBrowse.Location = New-Object System.Drawing.Point(712, 28)
$btnBrowse.Size = New-Object System.Drawing.Size(90, 28)
$btnBrowse.Anchor = 'Top,Right'
$grpFile.Controls.Add($btnBrowse)

$btnTemplate = New-Object System.Windows.Forms.Button
$btnTemplate.Text = 'New template'
$btnTemplate.Location = New-Object System.Drawing.Point(808, 28)
$btnTemplate.Size = New-Object System.Drawing.Size(110, 28)
$btnTemplate.Anchor = 'Top,Right'
$grpFile.Controls.Add($btnTemplate)

$btnValidate = New-Object System.Windows.Forms.Button
$btnValidate.Text = 'Validate'
$btnValidate.Location = New-Object System.Drawing.Point(924, 28)
$btnValidate.Size = New-Object System.Drawing.Size(95, 28)
$btnValidate.Anchor = 'Top,Right'
$btnValidate.Enabled = $false
$grpFile.Controls.Add($btnValidate)

$btnPreview = New-Object System.Windows.Forms.Button
$btnPreview.Text = 'Preview calls'
$btnPreview.Location = New-Object System.Drawing.Point(1025, 28)
$btnPreview.Size = New-Object System.Drawing.Size(100, 28)
$btnPreview.Anchor = 'Top,Right'
$btnPreview.Enabled = $false
$grpFile.Controls.Add($btnPreview)

# --- Policy management -----------------------------------------------------
$grpPolicies = New-Object System.Windows.Forms.GroupBox
$grpPolicies.Text = '3. Manage existing policies (refresh, preview, delete)'
$grpPolicies.Location = New-Object System.Drawing.Point(12, 172)
$grpPolicies.Size = New-Object System.Drawing.Size(1140, 150)
$grpPolicies.Anchor = 'Top,Left,Right'
$form.Controls.Add($grpPolicies)

$policyList = New-Object System.Windows.Forms.ListView
$policyList.Location = New-Object System.Drawing.Point(14, 27)
$policyList.Size = New-Object System.Drawing.Size(730, 108)
$policyList.View = [System.Windows.Forms.View]::Details
$policyList.FullRowSelect = $true
$policyList.GridLines = $true
$policyList.MultiSelect = $false
$policyList.HideSelection = $false
$policyList.Anchor = 'Top,Left,Right'
foreach ($c in @(
    @{ N = 'Id'; H = 'Policy id'; W = 260 },
    @{ N = 'Name'; H = 'Policy name'; W = 300 },
    @{ N = 'Type'; H = 'Assignment'; W = 130 }
)) {
    [void]$policyList.Columns.Add($c.H, $c.W)
}
$grpPolicies.Controls.Add($policyList)

$btnRefreshPolicies = New-Object System.Windows.Forms.Button
$btnRefreshPolicies.Text = 'Refresh list'
$btnRefreshPolicies.Location = New-Object System.Drawing.Point(756, 32)
$btnRefreshPolicies.Size = New-Object System.Drawing.Size(110, 30)
$btnRefreshPolicies.Anchor = 'Top,Right'
$btnRefreshPolicies.Enabled = $false
$grpPolicies.Controls.Add($btnRefreshPolicies)

$btnPreviewDelete = New-Object System.Windows.Forms.Button
$btnPreviewDelete.Text = 'Preview delete'
$btnPreviewDelete.Location = New-Object System.Drawing.Point(874, 32)
$btnPreviewDelete.Size = New-Object System.Drawing.Size(115, 30)
$btnPreviewDelete.Anchor = 'Top,Right'
$btnPreviewDelete.Enabled = $false
$grpPolicies.Controls.Add($btnPreviewDelete)

$btnDeletePolicy = New-Object System.Windows.Forms.Button
$btnDeletePolicy.Text = 'Delete selected'
$btnDeletePolicy.Location = New-Object System.Drawing.Point(997, 32)
$btnDeletePolicy.Size = New-Object System.Drawing.Size(125, 30)
$btnDeletePolicy.Anchor = 'Top,Right'
$btnDeletePolicy.Enabled = $false
$btnDeletePolicy.BackColor = [System.Drawing.Color]::FromArgb(253, 231, 233)
$grpPolicies.Controls.Add($btnDeletePolicy)

# --- Results grid ----------------------------------------------------------
$grid = New-Object System.Windows.Forms.DataGridView
$grid.Location = New-Object System.Drawing.Point(12, 332)
$grid.Size = New-Object System.Drawing.Size(1140, 220)
$grid.Anchor = 'Top,Bottom,Left,Right'
$grid.ReadOnly = $true
$grid.AllowUserToAddRows = $false
$grid.AllowUserToDeleteRows = $false
$grid.SelectionMode = 'FullRowSelect'
$grid.MultiSelect = $false
$grid.AutoSizeColumnsMode = 'Fill'
$grid.RowHeadersVisible = $false
$grid.BackgroundColor = [System.Drawing.Color]::White
$form.Controls.Add($grid)

foreach ($c in @(
    @{ N = 'Row';      H = 'Row';      W = 6 },
    @{ N = 'Policy';   H = 'Policy name'; W = 22 },
    @{ N = 'Status';   H = 'Status';   W = 12 },
    @{ N = 'Assign';   H = 'Assigned to'; W = 14 },
    @{ N = 'Limits';   H = 'Limits (policy / user)'; W = 18 },
    @{ N = 'Alerts';   H = 'Alerts'; W = 14 },
    @{ N = 'Issues';   H = 'Errors and warnings'; W = 44 }
)) {
    $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $col.Name = $c.N
    $col.HeaderText = $c.H
    $col.FillWeight = $c.W
    [void]$grid.Columns.Add($col)
}

# --- Commit + progress -----------------------------------------------------
$grpCommit = New-Object System.Windows.Forms.GroupBox
$grpCommit.Text = '3. Create the policies'
$grpCommit.Location = New-Object System.Drawing.Point(12, 560)
$grpCommit.Size = New-Object System.Drawing.Size(1140, 72)
$grpCommit.Anchor = 'Top,Left,Right'
$form.Controls.Add($grpCommit)

$btnCommit = New-Object System.Windows.Forms.Button
$btnCommit.Text = 'Commit valid rows'
$btnCommit.Location = New-Object System.Drawing.Point(14, 26)
$btnCommit.Size = New-Object System.Drawing.Size(170, 32)
$btnCommit.Enabled = $false
$btnCommit.BackColor = [System.Drawing.Color]::FromArgb(230, 244, 234)
$grpCommit.Controls.Add($btnCommit)

$progress = New-Object System.Windows.Forms.ProgressBar
$progress.Location = New-Object System.Drawing.Point(198, 30)
$progress.Size = New-Object System.Drawing.Size(770, 24)
$progress.Anchor = 'Top,Left,Right'
$grpCommit.Controls.Add($progress)

$btnExport = New-Object System.Windows.Forms.Button
$btnExport.Text = 'Export report'
$btnExport.Location = New-Object System.Drawing.Point(980, 26)
$btnExport.Size = New-Object System.Drawing.Size(140, 32)
$btnExport.Anchor = 'Top,Right'
$btnExport.Enabled = $false
$grpCommit.Controls.Add($btnExport)

# --- Log -------------------------------------------------------------------
$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Location = New-Object System.Drawing.Point(12, 638)
$txtLog.Size = New-Object System.Drawing.Size(1140, 60)
$txtLog.Anchor = 'Bottom,Left,Right'
$txtLog.Multiline = $true
$txtLog.ScrollBars = 'Vertical'
$txtLog.ReadOnly = $true
$txtLog.BackColor = [System.Drawing.Color]::FromArgb(250, 250, 250)
$txtLog.Font = New-Object System.Drawing.Font('Consolas', 8.5)
$form.Controls.Add($txtLog)

$status = New-Object System.Windows.Forms.StatusStrip
$statusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
$statusLabel.Text = 'Ready.'
[void]$status.Items.Add($statusLabel)
$form.Controls.Add($status)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Write-GuiLog {
    param([string]$Text)
    $txtLog.AppendText($Text + [Environment]::NewLine)
    $txtLog.SelectionStart = $txtLog.TextLength
    $txtLog.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()
}

function Set-GuiStatus {
    param([string]$Text)
    $statusLabel.Text = $Text
    [System.Windows.Forms.Application]::DoEvents()
}

function Show-GuiError {
    param([string]$Message, [string]$Title = 'Cowork Billing Policy Automator')
    [System.Windows.Forms.MessageBox]::Show($Message, $Title, 'OK', 'Error') | Out-Null
}

function Format-GuiLimits {
    param($Row)
    $p = if ($Row.MonthlySpendingLimitType -eq 'Limited') { "$($Row.MonthlySpendingLimitCredits)" } else { 'No limit' }
    $u = if ($Row.UserMonthlyBudgetLimitType -eq 'Limited') { "$($Row.UserMonthlyBudgetLimitCredits)" } else { 'No limit' }
    return "$p / $u"
}

function Format-GuiAlerts {
    param($Row)
    $parts = @()
    if ($Row.PolicyAlertThresholdType) {
        $parts += if ($Row.PolicyAlertThresholdType -eq 'Percent') { "Policy $($Row.PolicyAlertThresholdValue)%" } else { "Policy $($Row.PolicyAlertThresholdValue)cr" }
    }
    if ($Row.UserAlertThresholdType) {
        $parts += if ($Row.UserAlertThresholdType -eq 'Percent') { "User $($Row.UserAlertThresholdValue)%" } else { "User $($Row.UserAlertThresholdValue)cr" }
    }
    if ($parts.Count -eq 0) { return 'None' }
    return ($parts -join ', ')
}

function Get-GuiPolicyProperty {
    param($Policy, [string[]]$Names)
    foreach ($name in $Names) {
        if ($null -eq $Policy) { continue }
        if ($Policy.PSObject.Properties.Name -contains $name -and $null -ne $Policy.$name) {
            return [string]$Policy.$name
        }
        if ($Policy.PSObject.Properties.Name -contains 'AdditionalProperties' -and
            $Policy.AdditionalProperties -is [System.Collections.IDictionary] -and
            $Policy.AdditionalProperties.Contains($name) -and
            $null -ne $Policy.AdditionalProperties[$name]) {
            return [string]$Policy.AdditionalProperties[$name]
        }
    }
    return ''
}

function Refresh-GuiPolicies {
    try {
        Set-GuiStatus 'Refreshing spending policies...'
        $btnRefreshPolicies.Enabled = $false
        # Get-CoworkSpendingPolicy returns the collection as one pipeline object;
        # assign it first, then enumerate its elements for the ListView.
        $fetchedPolicies = Get-CoworkSpendingPolicy -Refresh
        $script:Policies = if ($fetchedPolicies -is [System.Array]) { @($fetchedPolicies) } else { @($fetchedPolicies) }
        $policyList.Items.Clear()
        foreach ($policy in $script:Policies) {
            $id = Get-GuiPolicyProperty -Policy $policy -Names @('id', 'Id')
            $name = Get-GuiPolicyProperty -Policy $policy -Names @('displayName', 'name')
            $type = Get-GuiPolicyProperty -Policy $policy -Names @('assignmentType', '@odata.type', 'type')
            if ($type -match 'selectedGroups') { $type = 'Groups' }
            elseif ($type -match 'allUsers') { $type = 'All users' }
            $item = New-Object System.Windows.Forms.ListViewItem($id)
            [void]$item.SubItems.Add($name)
            [void]$item.SubItems.Add($type)
            $item.Tag = $policy
            [void]$policyList.Items.Add($item)
        }
        Set-GuiStatus "Policy list refreshed: $($script:Policies.Count) found."
    }
    catch {
        Show-GuiError "Could not refresh spending policies.`n`n$($_.Exception.Message)"
        Set-GuiStatus 'Policy refresh failed.'
    }
    finally {
        $btnRefreshPolicies.Enabled = $true
        Update-GuiButtons
    }
}

function Get-GuiSelectedPolicy {
    if ($policyList.SelectedItems.Count -eq 0) {
        Show-GuiError 'Select a spending policy first.'
        return $null
    }
    return $policyList.SelectedItems[0]
}

function Update-GuiGrid {
    param($Results)

    $grid.Rows.Clear()
    foreach ($r in $Results) {
        $issues = @()
        foreach ($e in $r.Errors) { $issues += "ERROR: $e" }
        foreach ($w in $r.Warnings) { $issues += "WARN: $w" }

        $assign = if ($r.Row.AssignmentType -eq 'Groups') { "Groups: $($r.Row.Groups -join ', ')" } else { 'All users' }

        $idx = $grid.Rows.Add(@(
            $r.RowNumber,
            $r.PolicyName,
            $r.Status,
            $assign,
            (Format-GuiLimits -Row $r.Row),
            (Format-GuiAlerts -Row $r.Row),
            ($issues -join '  |  ')
        ))

        $cells = $grid.Rows[$idx]
        switch ($r.Status) {
            'Invalid'     { $cells.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(253, 231, 233) }
            'Failed'      { $cells.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(253, 231, 233) }
            'Created'     { $cells.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(223, 246, 221) }
            'WouldCreate' {
                if ($r.Warnings.Count -gt 0) { $cells.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(255, 248, 219) }
                else { $cells.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(233, 243, 253) }
            }
            default { }
        }
    }
}

function Update-GuiButtons {
    $connected = $false
    try { $connected = [bool](Get-MgContext) } catch { $connected = $false }

    $hasPath = -not [string]::IsNullOrWhiteSpace($txtPath.Text)
    $btnValidate.Enabled = ($connected -and $hasPath)
    $btnPreview.Enabled = ($connected -and $hasPath)
    $btnTestEndpoint.Enabled = $connected
    $btnDisconnect.Enabled = $connected
    $hasPolicy = ($connected -and $policyList.SelectedItems.Count -gt 0)
    $btnRefreshPolicies.Enabled = $connected
    $btnPreviewDelete.Enabled = $hasPolicy
    $btnDeletePolicy.Enabled = $hasPolicy
    $btnCommit.Enabled = ($connected -and $script:ValidCount -gt 0 -and $script:LastValidatedPath -eq $txtPath.Text)
    $btnExport.Enabled = (@($script:Results).Count -gt 0)
}

# Route all module logging into the GUI log pane.
Register-CoworkLogSink -Sink {
    param($Line, $Level)
    Write-GuiLog $Line
}

# ---------------------------------------------------------------------------
# Events
# ---------------------------------------------------------------------------
$btnConnect.Add_Click({
    try {
        Set-GuiStatus 'Signing in...'
        $btnConnect.Enabled = $false
        $ctx = Connect-CoworkPolicy
        $lblAccount.Text = "Connected as $($ctx.Account)  |  Tenant $($ctx.TenantId)"
        $lblAccount.ForeColor = [System.Drawing.Color]::DarkGreen
        Set-GuiStatus 'Connected.'
        Refresh-GuiPolicies
    }
    catch {
        $lblAccount.Text = 'Not connected.'
        $lblAccount.ForeColor = [System.Drawing.Color]::Firebrick
        Show-GuiError "Sign-in failed.`n`n$($_.Exception.Message)"
        Set-GuiStatus 'Sign-in failed.'
    }
    finally {
        $btnConnect.Enabled = $true
        Update-GuiButtons
    }
})

$btnDisconnect.Add_Click({
    try { Disconnect-CoworkPolicy } catch { }
    $lblAccount.Text = 'Not connected.'
    $lblAccount.ForeColor = [System.Drawing.Color]::DimGray
    $script:ValidCount = 0
    $script:Policies = @()
    $policyList.Items.Clear()
    Set-GuiStatus 'Signed out.'
    Update-GuiButtons
})

$btnRefreshPolicies.Add_Click({ Refresh-GuiPolicies })

$policyList.Add_SelectedIndexChanged({ Update-GuiButtons })

$btnPreviewDelete.Add_Click({
    $item = Get-GuiSelectedPolicy
    if ($null -eq $item) { return }
    try {
        Set-GuiStatus 'Previewing policy deletion...'
        $preview = Remove-CoworkSpendingPolicy -Id $item.Text
        [System.Windows.Forms.MessageBox]::Show(
            "No changes were made.`n`nPolicy: $($preview.PolicyName)`nId: $($preview.PolicyId)`nAction: $($preview.Status)",
            'Delete preview', 'OK', 'Information') | Out-Null
        Set-GuiStatus 'Delete preview complete. Nothing was deleted.'
    }
    catch {
        Show-GuiError "Could not preview deletion.`n`n$($_.Exception.Message)"
        Set-GuiStatus 'Delete preview failed.'
    }
})

$btnDeletePolicy.Add_Click({
    $item = Get-GuiSelectedPolicy
    if ($null -eq $item) { return }
    try {
        Set-GuiStatus 'Checking selected policy before deletion...'
        $preview = Remove-CoworkSpendingPolicy -Id $item.Text
        $answer = [System.Windows.Forms.MessageBox]::Show(
            "Preview: this will permanently delete the following policy:`n`n$($preview.PolicyName)`nId: $($preview.PolicyId)`n`nContinue?",
            'Confirm policy deletion', 'YesNo', 'Warning')
        if ($answer -ne 'Yes') {
            Set-GuiStatus 'Deletion cancelled.'
            return
        }
        $result = Remove-CoworkSpendingPolicy -Id $preview.PolicyId -Commit -Force
        if ($result.Status -eq 'Deleted') {
            [System.Windows.Forms.MessageBox]::Show("Deleted policy:`n$($result.PolicyName)", 'Policy deleted', 'OK', 'Information') | Out-Null
            Refresh-GuiPolicies
        }
        else {
            Show-GuiError "The policy was not deleted.`n`nStatus: $($result.Status)`n$($result.Error)"
            Set-GuiStatus 'Policy deletion failed.'
        }
    }
    catch {
        Show-GuiError "Could not delete the selected policy.`n`n$($_.Exception.Message)"
        Set-GuiStatus 'Policy deletion failed.'
    }
    finally { Update-GuiButtons }
})

$btnTestEndpoint.Add_Click({
    try {
        Set-GuiStatus 'Probing billing API endpoints...'
        $btnTestEndpoint.Enabled = $false
        $res = Test-CoworkPolicyConnection -AutoDiscover
        $ok = @($res | Where-Object { $_.Success })
        if ($ok.Count -gt 0) {
            $msg = "Working billing root path: '$($ok[0].BillingRootPath)'`n`n$($ok[0].Uri)"
            if ($ok[0].BillingRootPath -ne (Get-CoworkContext).Config.BillingRootPath) {
                $msg += "`n`nUpdate config.json to use this path?"
                $r = [System.Windows.Forms.MessageBox]::Show($msg, 'Endpoint found', 'YesNo', 'Question')
                if ($r -eq 'Yes') {
                    Set-CoworkBillingRootPath -BillingRootPath $ok[0].BillingRootPath
                    [System.Windows.Forms.MessageBox]::Show('config.json updated.', 'Saved', 'OK', 'Information') | Out-Null
                }
            }
            else {
                [System.Windows.Forms.MessageBox]::Show($msg, 'Endpoint OK', 'OK', 'Information') | Out-Null
            }
            Set-GuiStatus 'Endpoint OK.'
        }
        else {
            $tried = ($res | ForEach-Object { "  $($_.BillingRootPath)  ->  HTTP $($_.Status)" }) -join "`n"
            Show-GuiError ("No working billing root path was found.`n`nTried:`n$tried`n`n" +
                "Edit the 'BillingRootPath' value in config.json to the path from your internal API document.")
            Set-GuiStatus 'Endpoint probe failed.'
        }
    }
    catch {
        Show-GuiError "Endpoint probe failed.`n`n$($_.Exception.Message)"
        Set-GuiStatus 'Endpoint probe failed.'
    }
    finally {
        $btnTestEndpoint.Enabled = $true
        Update-GuiButtons
    }
})

$btnBrowse.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = 'CSV files (*.csv)|*.csv|All files (*.*)|*.*'
    $dlg.Title = 'Select a policy CSV'
    if ($dlg.ShowDialog() -eq 'OK') {
        $txtPath.Text = $dlg.FileName
        $script:ValidCount = 0
        $script:LastValidatedPath = $null
        $grid.Rows.Clear()
        Update-GuiButtons
    }
})

$btnTemplate.Add_Click({
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter = 'CSV files (*.csv)|*.csv'
    $dlg.FileName = 'policies.csv'
    $dlg.Title = 'Save a blank policy template'
    if ($dlg.ShowDialog() -eq 'OK') {
        try {
            New-CoworkPolicyTemplate -Path $dlg.FileName | Out-Null
            $txtPath.Text = $dlg.FileName
            Update-GuiButtons
            [System.Windows.Forms.MessageBox]::Show("Template written to:`n$($dlg.FileName)", 'Template created', 'OK', 'Information') | Out-Null
        }
        catch {
            Show-GuiError "Could not write the template.`n`n$($_.Exception.Message)"
        }
    }
})

$btnValidate.Add_Click({
    try {
        Set-GuiStatus 'Validating...'
        $btnValidate.Enabled = $false
        $btnCommit.Enabled = $false
        $progress.Style = 'Marquee'

        $script:Results = @(Invoke-CoworkPolicyImport -Path $txtPath.Text)
        $script:ValidCount = @($script:Results | Where-Object { $_.Status -eq 'WouldCreate' }).Count
        $script:LastValidatedPath = $txtPath.Text

        Update-GuiGrid -Results $script:Results

        $invalid = @($script:Results | Where-Object { $_.Status -eq 'Invalid' }).Count
        Set-GuiStatus "Validation complete: $($script:ValidCount) ready to create, $invalid invalid."
    }
    catch {
        Show-GuiError "Validation failed.`n`n$($_.Exception.Message)"
        Set-GuiStatus 'Validation failed.'
    }
    finally {
        $progress.Style = 'Blocks'
        $progress.Value = 0
        $btnValidate.Enabled = $true
        Update-GuiButtons
    }
})

$btnPreview.Add_Click({
    try {
        Set-GuiStatus 'Building request preview...'
        $btnPreview.Enabled = $false
        $progress.Style = 'Marquee'

        $script:Results = @(Invoke-CoworkPolicyImport -Path $txtPath.Text -Commit -WhatIfPayload)
        Update-GuiGrid -Results $script:Results

        $log = Get-CoworkPayloadLog
        if (@($log).Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show('No write calls would be made (no rows passed validation).', 'Preview', 'OK', 'Information') | Out-Null
        }
        else {
            $text = (@($log) | ForEach-Object { "$($_.Method) $($_.Uri)`n$($_.Body)`n" }) -join "`n"
            Show-GuiTextWindow -Title "Request preview - $(@($log).Count) call(s)" -Text $text
        }
        Set-GuiStatus 'Preview complete. Nothing was sent.'
    }
    catch {
        Show-GuiError "Preview failed.`n`n$($_.Exception.Message)"
        Set-GuiStatus 'Preview failed.'
    }
    finally {
        $progress.Style = 'Blocks'
        $btnPreview.Enabled = $true
        Update-GuiButtons
    }
})

function Show-GuiTextWindow {
    param([string]$Title, [string]$Text)

    $w = New-Object System.Windows.Forms.Form
    $w.Text = $Title
    $w.Size = New-Object System.Drawing.Size(900, 600)
    $w.StartPosition = 'CenterParent'

    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Multiline = $true
    $tb.ScrollBars = 'Both'
    $tb.ReadOnly = $true
    $tb.WordWrap = $false
    $tb.Dock = 'Fill'
    $tb.Font = New-Object System.Drawing.Font('Consolas', 9)
    $tb.Text = $Text
    $w.Controls.Add($tb)

$script:CwLayoutLog = $null
$script:CwLogBox    = $null
$script:CwDpi       = 96

function Initialize-CwLog {
    $candidates = @()
    if ($PSScriptRoot) { $candidates += (Join-Path $PSScriptRoot 'gui-layout.log') }
    $candidates += (Join-Path $env:TEMP 'cowork-gui-layout.log')
    foreach ($p in $candidates) {
        try {
            Set-Content -LiteralPath $p -Value "[layout] log start" -Encoding UTF8 -ErrorAction Stop
            $script:CwLayoutLog = $p
            return
        } catch { }
    }
}

function Write-CwLayout {
    param([string]$Message)
    $line = "[layout] $Message"
    try { Write-Host $line } catch { }
    if ($script:CwLayoutLog) {
        try { Add-Content -LiteralPath $script:CwLayoutLog -Value $line -Encoding UTF8 } catch { }
    }
    if ($script:CwLogBox) {
        try { $script:CwLogBox.AppendText($line + [Environment]::NewLine) } catch { }
    }
}

function Invoke-CwPhase {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
        Write-CwLayout "phase '$Name' ok"
    } catch {
        Write-CwLayout "phase '$Name' FAILED: $($_.Exception.Message)"
        $n = $_.InvocationInfo.ScriptLineNumber
        $s = $_.InvocationInfo.Line
        if ($s) { $s = $s.Trim() }
        Write-CwLayout "   line $n : $s"
    }
}

function Get-CwDpi {
    param([System.Windows.Forms.Control]$Control)
    $dpi = 0
    try { $dpi = [int]$Control.DeviceDpi } catch { }
    if ($dpi -lt 48) {
        try { $gr = $Control.CreateGraphics(); $dpi = [int]$gr.DpiX; $gr.Dispose() } catch { $dpi = 96 }
    }
    if ($dpi -lt 48) { $dpi = 96 }
    return $dpi
}

function Invoke-CwScaleChildren {
    param($Parent, [double]$S)
    foreach ($c in @($Parent.Controls)) {
        $nl = [int][math]::Round($c.Left   * $S)
        $nt = [int][math]::Round($c.Top    * $S)
        $nw = [int][math]::Round($c.Width  * $S)
        $nh = [int][math]::Round($c.Height * $S)
        try { $c.SetBounds($nl, $nt, $nw, $nh) } catch { }
        if ($c.Controls.Count -gt 0) { Invoke-CwScaleChildren -Parent $c -S $S }
    }
}

function Set-CwGeometryScale {
    param([System.Windows.Forms.Form]$Form)
    $dpi = Get-CwDpi -Control $Form
    $script:CwDpi = $dpi
    $s = $dpi / 96.0
    Write-CwLayout ("host dpi {0}  geometry scale {1}" -f $dpi, [math]::Round($s, 3))
    if ($s -le 1.01) { Write-CwLayout 'dpi-unaware host or 100% - no geometry scaling needed'; return }

    $cw = [int][math]::Round($Form.ClientSize.Width  * $s)
    $ch = [int][math]::Round($Form.ClientSize.Height * $s)
    Invoke-CwScaleChildren -Parent $Form -S $s
    $Form.ClientSize = New-Object System.Drawing.Size($cw, $ch)

    if ($Form.MinimumSize.Width -gt 0) {
        $mw = [int][math]::Round($Form.MinimumSize.Width  * $s)
        $mh = [int][math]::Round($Form.MinimumSize.Height * $s)
        $Form.MinimumSize = New-Object System.Drawing.Size($mw, $mh)
    }

    $wa = [System.Windows.Forms.Screen]::FromControl($Form).WorkingArea
    if ($Form.Width  -gt $wa.Width)  { $Form.Width  = $wa.Width  - 20 }
    if ($Form.Height -gt $wa.Height) { $Form.Height = $wa.Height - 40 }
    $px = $wa.X + [int](($wa.Width  - $Form.Width)  / 2)
    $py = $wa.Y + [int](($wa.Height - $Form.Height) / 2)
    $Form.Location = New-Object System.Drawing.Point($px, $py)
    Write-CwLayout ("scaled client {0}x{1}, window {2}x{3}" -f $cw, $ch, $Form.Width, $Form.Height)
}

function Get-CwContainers {
    param([System.Windows.Forms.Control]$Root)
    $list = New-Object System.Collections.ArrayList
    $null = $list.Add($Root)
    for ($i = 0; $i -lt $list.Count; $i++) {
        foreach ($c in $list[$i].Controls) { if ($c.Controls.Count -gt 0) { $null = $list.Add($c) } }
    }
    return $list
}

function Set-CoworkGuiDockLayout {
    param([System.Windows.Forms.Form]$Form)

    $kids   = @($Form.Controls)
    $grid   = $kids | Where-Object { $_ -is [System.Windows.Forms.DataGridView] } | Select-Object -First 1
    $status = $kids | Where-Object { $_ -is [System.Windows.Forms.StatusStrip]  } | Select-Object -First 1
    $log    = $script:CwLogBox

    if (-not $grid) { Write-CwLayout 'dock skipped - no DataGridView'; return }
    if (-not $log)  { Write-CwLayout 'dock skipped - no multiline TextBox'; return }

    $commit = $kids | Where-Object {
                  $_ -ne $grid -and $_ -ne $log -and $_ -ne $status -and $_.Top -gt $grid.Top
              } | Sort-Object Top | Select-Object -First 1

    $header = @($kids | Where-Object {
                  $_ -ne $grid -and $_ -ne $log -and $_ -ne $status -and $_ -ne $commit -and $_.Top -lt $grid.Top
              } | Sort-Object Top)

    $hdr = $null
    if ($header.Count -gt 0) {
        $bottom = 0
        foreach ($h in $header) { $hb = $h.Top + $h.Height; if ($hb -gt $bottom) { $bottom = $hb } }
        $hdr = New-Object System.Windows.Forms.Panel
        $hdr.Height = $bottom + 8
        $hdr.Dock   = [System.Windows.Forms.DockStyle]::Top
        $wide = $Form.ClientSize.Width * 0.8
        foreach ($h in $header) {
            $Form.Controls.Remove($h)
            $hdr.Controls.Add($h)
            if ($h.Width -gt $wide) {
                $h.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor
                            [System.Windows.Forms.AnchorStyles]::Left -bor
                            [System.Windows.Forms.AnchorStyles]::Right
            }
        }
        $Form.Controls.Add($hdr)
    }

    if ($commit) { $commit.Height = [int]($commit.Height * 1.35) }

    $logH = [int]($Form.ClientSize.Height * 0.32)
    if ($logH -lt 220) { $logH = 220 }
    $log.Height     = $logH
    $log.ScrollBars = [System.Windows.Forms.ScrollBars]::Both
    $log.WordWrap   = $false

    $sp           = New-Object System.Windows.Forms.Splitter
    $sp.Dock      = [System.Windows.Forms.DockStyle]::Bottom
    $sp.Height    = 6
    $sp.BackColor = [System.Drawing.SystemColors]::ControlDark
    $sp.MinSize   = 90
    $sp.MinExtra  = 150
    $Form.Controls.Add($sp)

    $grid.Dock = [System.Windows.Forms.DockStyle]::Fill
    $log.Dock  = [System.Windows.Forms.DockStyle]::Bottom
    if ($commit) { $commit.Dock = [System.Windows.Forms.DockStyle]::Bottom }
    if ($status) { $status.Dock = [System.Windows.Forms.DockStyle]::Bottom }

    foreach ($c in @($status, $log, $sp, $commit, $hdr, $grid)) { if ($c) { $c.BringToFront() } }

    $hh = 0; if ($hdr) { $hh = $hdr.Height }
    $cc = 0; if ($commit) { $cc = $commit.Height }
    Write-CwLayout ("docked: header {0}px commit {1}px log {2}px" -f $hh, $cc, $log.Height)
}

function Repair-CwRow {
    param($Parent, $Row)

    $anchorTR  = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
    $anchorTLR = [System.Windows.Forms.AnchorStyles]::Top -bor
                 [System.Windows.Forms.AnchorStyles]::Left -bor
                 [System.Windows.Forms.AnchorStyles]::Right

    $oL = @($Row | ForEach-Object { $_.Left })
    $oR = @($Row | ForEach-Object { $_.Left + $_.Width })
    $gaps = @()
    for ($i = 1; $i -lt $Row.Count; $i++) { $gaps += ($oL[$i] - $oR[$i - 1]) }

    $clientW = $Parent.ClientSize.Width
    $rightMargin = $clientW - $oR[$Row.Count - 1]
    if ($rightMargin -lt 12) { $rightMargin = 12 }

    $grown = 0
    foreach ($b in $Row) {
        $need = 0
        try { $need = $b.PreferredSize.Width + 12 } catch { }
        $meas = 0
        try { $meas = [System.Windows.Forms.TextRenderer]::MeasureText($b.Text, $b.Font).Width + 26 } catch { }
        if ($meas -gt $need) { $need = $meas }
        if ($need -gt $b.Width) {
            Write-CwLayout ("  '{0}' {1} -> {2}" -f $b.Text, $b.Width, $need)
            $b.Width = $need
            $grown++
        }
    }

    $sp = $Row.Count
    $half = $clientW / 2
    for ($i = 0; $i -lt $Row.Count; $i++) {
        $big = $false
        if ($i -eq 0) { $big = $true } elseif ($gaps[$i - 1] -gt 30) { $big = $true }
        if ($big -and ($oL[$i] -gt $half)) { $sp = $i; break }
    }

    if ($sp -gt 0) {
        $x = $oL[0]
        for ($i = 0; $i -lt $sp; $i++) {
            $Row[$i].Left = $x
            $gp = 8; if ($i -lt $gaps.Count) { $gp = $gaps[$i] }
            $x = $Row[$i].Left + $Row[$i].Width + $gp
        }
    }

    if ($sp -lt $Row.Count) {
        $x = $clientW - $rightMargin
        for ($i = $Row.Count - 1; $i -ge $sp; $i--) {
            $Row[$i].Left = $x - $Row[$i].Width
            $Row[$i].Anchor = $anchorTR
            $gp = 8; if ($i -ge 1) { $gp = $gaps[$i - 1] }
            $x = $Row[$i].Left - $gp
        }

        $blockLeft = $Row[$sp].Left
        $rowTop = $Row[0].Top
        $rowH   = $Row[0].Height

        foreach ($f in $Parent.Controls) {
            if ($f -is [System.Windows.Forms.Button]) { continue }
            $isText  = $f -is [System.Windows.Forms.TextBox]
            $isLabel = $f -is [System.Windows.Forms.Label]
            $isBar   = $f -is [System.Windows.Forms.ProgressBar]
            if (-not ($isText -or $isLabel -or $isBar)) { continue }
            if ([math]::Abs($f.Top - $rowTop) -gt 16) { continue }
            if ($f.Left -ge $blockLeft) { continue }
            $w = $blockLeft - 10 - $f.Left
            if ($w -lt 40) { continue }

            if ($isText -and (-not $f.Multiline)) {
                $f.Font = New-Object System.Drawing.Font($f.Font.FontFamily, ($f.Font.SizeInPoints + 1.5))
            }
            if ($isLabel) { $f.AutoSize = $false }

            $f.Width  = $w
            $f.Top    = $rowTop + [int](($rowH - $f.Height) / 2)
            $f.Anchor = $anchorTLR
            Write-CwLayout ("  stretched '{0}' to {1}x{2}" -f $f.Name, $f.Width, $f.Height)
        }
    }

    return $grown
}

function Repair-CoworkGuiLayout {
    param([System.Windows.Forms.Form]$Form)

    $containers = Get-CwContainers -Root $Form

    Invoke-CwPhase 'report' {
        Write-CwLayout ("font '{0}' {1}pt  autoscale {2}  containers {3}" -f
            $Form.Font.Name, $Form.Font.SizeInPoints, $Form.AutoScaleMode, $containers.Count)
    }

    Invoke-CwPhase 'buttons' {
        $grown = 0; $total = 0
        foreach ($parent in $containers) {
            $buttons = @($parent.Controls | Where-Object { $_ -is [System.Windows.Forms.Button] })
            if ($buttons.Count -eq 0) { continue }
            $rows = @{}
            foreach ($b in $buttons) {
                $k = [string][int][math]::Round($b.Top / 8)
                if (-not $rows.ContainsKey($k)) { $rows[$k] = New-Object System.Collections.ArrayList }
                $null = $rows[$k].Add($b)
            }
            foreach ($k in @($rows.Keys)) {
                $row = @($rows[$k] | Sort-Object Left)
                $total = $total + $row.Count
                try { $grown = $grown + (Repair-CwRow -Parent $parent -Row $row) }
                catch { Write-CwLayout ("  row top {0} FAILED: {1}" -f $row[0].Top, $_.Exception.Message) }
            }
        }
        Write-CwLayout ("{0} of {1} buttons widened" -f $grown, $total)
    }

    Invoke-CwPhase 'grid' {
        foreach ($parent in $containers) {
            foreach ($c in $parent.Controls) {
                if ($c -is [System.Windows.Forms.DataGridView]) {
                    $c.ColumnHeadersHeightSizeMode =
                        [System.Windows.Forms.DataGridViewColumnHeadersHeightSizeMode]::AutoSize
                    $c.AutoSizeColumnsMode =
                        [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::Fill
                    $c.ColumnHeadersDefaultCellStyle.WrapMode =
                        [System.Windows.Forms.DataGridViewTriState]::True
                    Write-CwLayout 'grid set to Fill + auto header'
                }
            }
        }
    }

    Invoke-CwPhase 'finish' { $Form.PerformLayout(); $Form.Refresh() }
}

$w.Add_Shown({
    Initialize-CwLog
    $best = $null
    foreach ($c in $w.Controls) {
        if ($c -is [System.Windows.Forms.TextBox] -and $c.Multiline) {
            if ($null -eq $best) { $best = $c }
            elseif (($c.Width * $c.Height) -gt ($best.Width * $best.Height)) { $best = $c }
        }
    }
    $script:CwLogBox = $best

    Write-CwLayout '--- layout v10 start ---'
    if ($script:CwLayoutLog) { Write-CwLayout ("log file: {0}" -f $script:CwLayoutLog) }
    else { Write-CwLayout 'log file: NONE - all write targets refused' }

    Invoke-CwPhase 'scale'  { Set-CwGeometryScale     -Form $w }
    Invoke-CwPhase 'dock'   { Set-CoworkGuiDockLayout -Form $w }
    Invoke-CwPhase 'repair' { Repair-CoworkGuiLayout  -Form $w }
    Write-CwLayout '--- layout v10 end ---'

    try { $w.Text = "$($w.Text)   [layout v10 - dpi $($script:CwDpi)]" } catch { }
})

    $w.ShowDialog() | Out-Null
}

$btnCommit.Add_Click({
    $msg = "This will create $($script:ValidCount) spending policy/policies in your tenant.`n`n" +
           "Rows that fail partway through are rolled back automatically.`n`nContinue?"
    $answer = [System.Windows.Forms.MessageBox]::Show($msg, 'Confirm creation', 'YesNo', 'Warning')
    if ($answer -ne 'Yes') { return }

    try {
        Set-GuiStatus 'Creating policies...'
        $btnCommit.Enabled = $false
        $btnValidate.Enabled = $false
        $progress.Style = 'Marquee'

        $script:Results = @(Invoke-CoworkPolicyImport -Path $txtPath.Text -Commit)
        Update-GuiGrid -Results $script:Results

        $created = @($script:Results | Where-Object { $_.Status -eq 'Created' }).Count
        $failed = @($script:Results | Where-Object { $_.Status -eq 'Failed' }).Count
        $script:ValidCount = 0

        Set-GuiStatus "Done: $created created, $failed failed."
        [System.Windows.Forms.MessageBox]::Show(
            "Created : $created`nFailed  : $failed`n`nSee the results grid and log for details.",
            'Creation complete', 'OK', $(if ($failed -gt 0) { 'Warning' } else { 'Information' })) | Out-Null
    }
    catch {
        Show-GuiError "Creation run failed.`n`n$($_.Exception.Message)"
        Set-GuiStatus 'Creation failed.'
    }
    finally {
        $progress.Style = 'Blocks'
        $progress.Value = 0
        $btnValidate.Enabled = $true
        Update-GuiButtons
    }
})

$btnExport.Add_Click({
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter = 'CSV files (*.csv)|*.csv'
    $dlg.FileName = "cowork-policy-results-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
    if ($dlg.ShowDialog() -eq 'OK') {
        try {
            Write-CoworkReport -Results $script:Results -ReportPath $dlg.FileName | Out-Null
            [System.Windows.Forms.MessageBox]::Show("Report saved to:`n$($dlg.FileName)", 'Saved', 'OK', 'Information') | Out-Null
        }
        catch {
            Show-GuiError "Could not save the report.`n`n$($_.Exception.Message)"
        }
    }
})

$txtPath.Add_TextChanged({
    $script:ValidCount = 0
    $script:LastValidatedPath = $null
    Update-GuiButtons
})

$grid.Add_CellDoubleClick({
    param($sender, $e)
    if ($e.RowIndex -lt 0) { return }
    $r = $script:Results[$e.RowIndex]
    $detail = "Row $($r.RowNumber): $($r.PolicyName)`r`nStatus: $($r.Status)`r`n"
    if ($r.PolicyId) { $detail += "Policy id: $($r.PolicyId)`r`n" }
    if ($r.StepsDone.Count) { $detail += "Steps completed: $($r.StepsDone -join ' > ')`r`n" }
    if ($r.FailedStep) { $detail += "Failed at: $($r.FailedStep)`r`n" }
    if ($r.RollbackResult) { $detail += "Rollback: $($r.RollbackResult)`r`n" }
    if ($r.Errors.Count) { $detail += "`r`nERRORS`r`n" + (($r.Errors | ForEach-Object { " - $_" }) -join "`r`n") + "`r`n" }
    if ($r.Warnings.Count) { $detail += "`r`nWARNINGS`r`n" + (($r.Warnings | ForEach-Object { " - $_" }) -join "`r`n") + "`r`n" }
    Show-GuiTextWindow -Title "Row $($r.RowNumber) details" -Text $detail
})

$form.Add_FormClosed({
    try { Unregister-CoworkLogSink } catch { }
})

# ---------------------------------------------------------------------------
# Start
# ---------------------------------------------------------------------------
if ($CsvPath) { $txtPath.Text = $CsvPath }
else {
    $defaultSample = Join-Path $PSScriptRoot 'policies-sample.csv'
    if (Test-Path -LiteralPath $defaultSample) { $txtPath.Text = $defaultSample }
}

Write-GuiLog "Cowork Billing Policy Automator"
try {
    $c = Get-CoworkContext
    Write-GuiLog "Billing root : $($c.BillingRoot)"
    Write-GuiLog "Config       : $($c.ConfigPath)"
}
catch {
    Write-GuiLog "Could not load configuration: $($_.Exception.Message)"
}
Write-GuiLog "Sign in, pick a CSV, then Validate. Commit stays disabled until validation passes."
Write-GuiLog "Existing policies can be refreshed and safely previewed/deleted from the policy management section."
Write-GuiLog ""

Update-GuiButtons
[void]$form.ShowDialog()
