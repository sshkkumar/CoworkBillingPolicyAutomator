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

$__FORM__.Add_Shown({
    Initialize-CwLog
    $best = $null
    foreach ($c in $__FORM__.Controls) {
        if ($c -is [System.Windows.Forms.TextBox] -and $c.Multiline) {
            if ($null -eq $best) { $best = $c }
            elseif (($c.Width * $c.Height) -gt ($best.Width * $best.Height)) { $best = $c }
        }
    }
    $script:CwLogBox = $best

    Write-CwLayout '--- layout v8 start ---'
    if ($script:CwLayoutLog) { Write-CwLayout ("log file: {0}" -f $script:CwLayoutLog) }
    else { Write-CwLayout 'log file: NONE - all write targets refused' }

    Invoke-CwPhase 'scale'  { Set-CwGeometryScale     -Form $__FORM__ }
    Invoke-CwPhase 'dock'   { Set-CoworkGuiDockLayout -Form $__FORM__ }
    Invoke-CwPhase 'repair' { Repair-CoworkGuiLayout  -Form $__FORM__ }
    Write-CwLayout '--- layout v8 end ---'

    try { $__FORM__.Text = "$($__FORM__.Text)   [layout v8 - dpi $($script:CwDpi)]" } catch { }
})
