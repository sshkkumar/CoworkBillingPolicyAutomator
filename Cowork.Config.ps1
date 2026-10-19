# Cowork.Config.ps1
# Configuration loading, service catalog loading, logging, and shared module state.

$script:CoworkContext = $null

function Get-CoworkToolRoot {
    [CmdletBinding()]
    param()
    if ($script:CoworkModuleRoot) { return $script:CoworkModuleRoot }
    return $PSScriptRoot
}

function ConvertFrom-CoworkJsonFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Required file not found: $Path"
    }
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "File is empty: $Path"
    }
    try {
        return $raw | ConvertFrom-Json
    }
    catch {
        throw "File is not valid JSON: $Path`n$($_.Exception.Message)"
    }
}

function Get-CoworkBillingRoot {
    <#
    .SYNOPSIS
        Composes the effective billing API root from configuration.
    .DESCRIPTION
        Effective root = {GraphBaseUri}/{ApiVersion}/{BillingRootPath}
        With shipped defaults this is https://graph.microsoft.com/beta/copilot/billing
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [string]$OverrideBillingRootPath
    )

    $path = if ($OverrideBillingRootPath) { $OverrideBillingRootPath } else { $Config.BillingRootPath }

    $base = ($Config.GraphBaseUri).TrimEnd('/')
    $ver = ($Config.ApiVersion).Trim('/')
    $path = ($path).Trim('/')

    if ([string]::IsNullOrWhiteSpace($path)) {
        return "$base/$ver"
    }
    return "$base/$ver/$path"
}

function Initialize-CoworkContext {
    <#
    .SYNOPSIS
        Loads config.json and services.json into module state.
    .DESCRIPTION
        Safe to call repeatedly. Use -Force to reload from disk.
    #>
    [CmdletBinding()]
    param(
        [string]$ConfigPath,
        [string]$ServiceCatalogPath,
        [switch]$Force
    )

    if ($script:CoworkContext -and -not $Force) { return $script:CoworkContext }

    $root = Get-CoworkToolRoot
    if (-not $ConfigPath) { $ConfigPath = Join-Path $root 'config.json' }
    if (-not $ServiceCatalogPath) { $ServiceCatalogPath = Join-Path $root 'services.json' }

    $config = ConvertFrom-CoworkJsonFile -Path $ConfigPath
    $catalog = ConvertFrom-CoworkJsonFile -Path $ServiceCatalogPath

    foreach ($required in @('GraphBaseUri', 'ApiVersion', 'DirectoryBaseUri')) {
        if ([string]::IsNullOrWhiteSpace($config.$required)) {
            throw "config.json is missing required value '$required'. Path: $ConfigPath"
        }
    }

    $script:CoworkContext = [pscustomobject]@{
        ToolRoot           = $root
        ConfigPath         = $ConfigPath
        ServiceCatalogPath = $ServiceCatalogPath
        Config             = $config
        ServiceCatalog     = $catalog
        BillingRoot        = (Get-CoworkBillingRoot -Config $config)
        DirectoryRoot      = ($config.DirectoryBaseUri).TrimEnd('/')
        WhatIfPayload      = $false
        PayloadLog         = (New-Object System.Collections.ArrayList)
        Cache              = @{
            Groups         = @{}
            Users          = @{}
            Policies       = $null
            TenantBalance  = $null
        }
        LogPath            = $null
        LogSink            = $null
    }

    return $script:CoworkContext
}

function Get-CoworkContext {
    [CmdletBinding()]
    param()
    if (-not $script:CoworkContext) { return Initialize-CoworkContext }
    return $script:CoworkContext
}

function Clear-CoworkCache {
    <#
    .SYNOPSIS
        Drops cached groups, users, policies, and tenant balance.
    #>
    [CmdletBinding()]
    param()
    $ctx = Get-CoworkContext
    $ctx.Cache.Groups = @{}
    $ctx.Cache.Users = @{}
    $ctx.Cache.Policies = $null
    $ctx.Cache.TenantBalance = $null
}

function Resolve-CoworkOutputDirectory {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('Report', 'Log')][string]$Kind)

    $ctx = Get-CoworkContext
    $configured = if ($Kind -eq 'Report') { $ctx.Config.Output.ReportDirectory } else { $ctx.Config.Output.LogDirectory }
    if ([string]::IsNullOrWhiteSpace($configured)) { $configured = if ($Kind -eq 'Report') { 'reports' } else { 'logs' } }

    if ([System.IO.Path]::IsPathRooted($configured)) {
        $dir = $configured
    }
    else {
        $dir = Join-Path $ctx.ToolRoot $configured
    }

    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    return (Resolve-Path -LiteralPath $dir).Path
}

function Start-CoworkLog {
    [CmdletBinding()]
    param([string]$Path)

    $ctx = Get-CoworkContext
    if (-not $Path) {
        $dir = Resolve-CoworkOutputDirectory -Kind Log
        $Path = Join-Path $dir ("cowork-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
    }
    $ctx.LogPath = $Path
    Write-CoworkLog -Level Info -Message "Log started. Tool root: $($ctx.ToolRoot)"
    Write-CoworkLog -Level Info -Message "Billing root: $($ctx.BillingRoot)"
    return $Path
}

function Write-CoworkLog {
    <#
    .SYNOPSIS
        Writes a timestamped line to the console, the log file, and any registered GUI sink.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('Info', 'Warn', 'Error', 'Success', 'Debug')][string]$Level = 'Info'
    )

    $ctx = $script:CoworkContext
    $line = "[{0:HH:mm:ss}] [{1}] {2}" -f (Get-Date), $Level.ToUpper(), $Message

    switch ($Level) {
        'Warn'    { Write-Warning $Message }
        'Error'   { Write-Host $line -ForegroundColor Red }
        'Success' { Write-Host $line -ForegroundColor Green }
        'Debug'   { Write-Verbose $line }
        default   { Write-Host $line }
    }

    if ($ctx) {
        if ($ctx.LogPath) {
            try { Add-Content -LiteralPath $ctx.LogPath -Value $line -Encoding UTF8 -ErrorAction Stop } catch { }
        }
        if ($ctx.LogSink) {
            try { $ctx.LogSink.Invoke($line, $Level) } catch { }
        }
    }
}

function Register-CoworkLogSink {
    <#
    .SYNOPSIS
        Registers a scriptblock that receives every log line. Used by the GUI.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][scriptblock]$Sink)
    (Get-CoworkContext).LogSink = $Sink
}

function Unregister-CoworkLogSink {
    [CmdletBinding()]
    param()
    (Get-CoworkContext).LogSink = $null
}
