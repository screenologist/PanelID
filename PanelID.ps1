<#
    PanelID - laptop and screen identification (short version)

    Shows: laptop make / model / serial, the screen's PnP ID, part number
    (only when the screen itself stores one) and highest refresh rate, and
    whether a touchscreen is connected, with its controller ID.
    Prints on screen and saves a text file to the Desktop.

    READ-ONLY. Nothing is installed or changed. No administrator rights needed.

    Usage:
      .\PanelID.ps1
      .\PanelID.ps1 -Label "RMA-4471"


    MIT Licensed. Provided as is, without warranty of any kind.
#>

[CmdletBinding()]
param(
    [string]$Label,
    [string]$OutputPath,
    [switch]$NoPause
)

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'

# =====================================================================
#  SHARED WITH LaptopCheck.ps1 - copied unchanged, keep the two in step
# =====================================================================
function Test-DevicePresent {
    # Get-PnpDevice reports Present on Windows 10/11. If it is ever missing,
    # fall back to Status (devices that are not plugged in report 'Unknown').
    param($Device)
    if ($null -ne $Device.Present) { return [bool]$Device.Present }
    return ("$($Device.Status)" -ne 'Unknown')
}

function Get-DeviceDate {
    param([string]$InstanceId, [string]$Key)
    try {
        $d = (Get-PnpDeviceProperty -InstanceId $InstanceId -KeyName $Key -ErrorAction Stop).Data
        if ($d -is [datetime] -and $d.Year -ge 2000) { return $d }
    } catch { }
    return $null
}

function Get-FriendlyModel {
    # Lenovo keeps the friendly model name in Version (Model is the machine type, e.g. 83DL)
    param($ComputerSystem, $Product)
    $friendly = $ComputerSystem.Model
    if ($ComputerSystem.Manufacturer -match '^LENOVO' -and $Product.Version -and
        $Product.Version -notmatch '^(None|Not|System|To Be|Default)') { $friendly = $Product.Version }
    return $friendly
}

function Find-TouchDevices {
    # Touchscreen = HID collection with usage page 0x0D (digitizer), usage 0x04 (touch screen).
    # This works on any Windows language; the English name is only a fallback.
    # Includes devices that are remembered but not connected: check Present on each.
    param($Devices)
    $touchId = 'HID_DEVICE_UP:000D_U:0004'
    $found = @($Devices | Where-Object {
        $_.Class -eq 'HIDClass' -and (
            (@($_.CompatibleID) -contains $touchId) -or ("$($_.FriendlyName)" -match 'touch ?screen')
        )
    })
    foreach ($d in @($Devices | Where-Object { $_.Class -eq 'HIDClass' -and -not $_.CompatibleID })) {
        try {
            $ids = (Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName 'DEVPKEY_Device_CompatibleIds' -ErrorAction Stop).Data
            if (@($ids) -contains $touchId -and @($found | Where-Object { $_.InstanceId -eq $d.InstanceId }).Count -eq 0) {
                $found += $d
            }
        } catch { }
    }
    return @($found)
}

function Get-EdidTiming {
    param([byte[]]$Bytes, [int]$Offset)
    $e = $Bytes; $o = $Offset
    $px = [int]$e[$o] -bor ([int]$e[$o + 1] -shl 8)
    # 0 = this slot is a text descriptor. A tiny value such as 1 is a placeholder that newer panels
    # use to say "the real timings are in the DisplayID block". Anything under 10 MHz (stored value
    # under 1000) is not a real laptop timing either: edid-decode also treats it as invalid data.
    if ($px -lt 1000) { return $null }
    $hAct = [int]$e[$o + 2] -bor ((([int]$e[$o + 4] -shr 4) -band 0x0F) -shl 8)
    $hBlk = [int]$e[$o + 3] -bor ((( [int]$e[$o + 4])        -band 0x0F) -shl 8)
    $vAct = [int]$e[$o + 5] -bor ((([int]$e[$o + 7] -shr 4) -band 0x0F) -shl 8)
    $vBlk = [int]$e[$o + 6] -bor ((( [int]$e[$o + 7])        -band 0x0F) -shl 8)
    $hTot = $hAct + $hBlk
    $vTot = $vAct + $vBlk
    if ($hTot -le 0 -or $vTot -le 0) { return $null }
    # Pixel clock is stored in units of 10 kHz
    $hz = [math]::Round(($px * 10000.0) / ($hTot * $vTot), 0)
    # Physical image size in millimetres (bytes 12-14 of the descriptor). Only meaningful in a
    # base-block timing; extension-block timings may leave it empty.
    $wMm = [int]$e[$o + 12] -bor ((([int]$e[$o + 14] -shr 4) -band 0x0F) -shl 8)
    $hMm = [int]$e[$o + 13] -bor ((( [int]$e[$o + 14])        -band 0x0F) -shl 8)
    [pscustomobject]@{ Width = $hAct; Height = $vAct; Refresh = $hz; WidthMm = $wMm; HeightMm = $hMm }
}

function Get-DisplayIdTimings {
    # DisplayID extension block (tag 0x70). Many newer laptop panels list their high-refresh modes
    # ONLY here: Type I detailed timings (DisplayID 1.x) or Type VII (DisplayID 2.0).
    # Without this a 165 Hz panel would be reported as 60 Hz.
    param([byte[]]$Bytes, [int]$Base)
    $e = $Bytes
    $list = New-Object System.Collections.Generic.List[object]
    $isV2 = ([int]$e[$Base + 1] -ge 0x20)            # 0x13 = DisplayID 1.3, 0x20 = DisplayID 2.0
    $end  = $Base + 5 + [int]$e[$Base + 2]           # first byte after the data blocks
    if ($end -gt $Base + 126) { $end = $Base + 126 }
    $p = $Base + 5
    while ($p + 3 -le $end) {
        $tag = [int]$e[$p]; $rev = [int]$e[$p + 1]; $len = [int]$e[$p + 2]
        if ($p + 3 + $len -gt $end) { break }        # damaged block
        $size = 0
        if (-not $isV2 -and $tag -eq 0x03) { $size = 20 }
        if ($isV2 -and $tag -eq 0x22)      { $size = 20 + (($rev -shr 4) -band 0x07) }
        if ($size -gt 0) {
            for ($q = $p + 3; $q + $size -le $p + 3 + $len; $q += $size) {
                $clk  = [int]$e[$q] -bor ([int]$e[$q + 1] -shl 8) -bor ([int]$e[$q + 2] -shl 16)
                $hAct = 1 + ([int]$e[$q + 4]  -bor ([int]$e[$q + 5]  -shl 8))
                $hBlk = 1 + ([int]$e[$q + 6]  -bor ([int]$e[$q + 7]  -shl 8))
                $vAct = 1 + ([int]$e[$q + 12] -bor ([int]$e[$q + 13] -shl 8))
                $vBlk = 1 + ([int]$e[$q + 14] -bor ([int]$e[$q + 15] -shl 8))
                # Type I counts the pixel clock in 10 kHz steps, Type VII in 1 kHz steps (both stored minus 1)
                $kHz  = if ($isV2) { $clk + 1 } else { 10 * ($clk + 1) }
                $hz   = [math]::Round(($kHz * 1000.0) / (($hAct + $hBlk) * ($vAct + $vBlk)), 0)
                $list.Add([pscustomobject]@{ Width = $hAct; Height = $vAct; Refresh = $hz; WidthMm = 0; HeightMm = 0 })
            }
        }
        $p += 3 + $len
    }
    $list.ToArray()
}

function ConvertFrom-EdidBytes {
    param([byte[]]$Bytes)
    $e = $Bytes
    if (-not $e -or $e.Length -lt 128) { return $null }
    if ($e[0] -ne 0 -or $e[1] -ne 255 -or $e[7] -ne 0) { return $null }

    # Manufacturer ID: three 5-bit letters, big endian ('A' = 1)
    $v = ([int]$e[8] -shl 8) -bor [int]$e[9]
    $letters = [char[]]@(
        ((($v -shr 10) -band 0x1F) + 64),
        ((($v -shr 5)  -band 0x1F) + 64),
        (( $v          -band 0x1F) + 64)
    )
    $vendor  = -join $letters
    $product = [int]$e[10] -bor ([int]$e[11] -shl 8)
    $pnpId   = '{0}{1:X4}' -f $vendor, $product

    $timings = New-Object System.Collections.Generic.List[object]
    $strings = New-Object System.Collections.Generic.List[string]

    foreach ($o in 54, 72, 90, 108) {
        $t = Get-EdidTiming -Bytes $e -Offset $o
        if ($t) { $timings.Add($t); continue }
        if ([int]$e[$o] -ne 0 -or [int]$e[$o + 1] -ne 0) { continue }    # starts with a pixel clock: placeholder or damaged slot, not text
        # 0xFE = text (where laptop panels keep the part number), 0xFC = name.
        # 0xFF is the serial number and must not be mistaken for a part number.
        $tag = [int]$e[$o + 3]
        if ($tag -eq 0xFC -or $tag -eq 0xFE) {
            $sb = New-Object System.Text.StringBuilder
            for ($i = 5; $i -le 17; $i++) {
                $c = [int]$e[$o + $i]
                if ($c -eq 0x0A -or $c -eq 0) { break }
                [void]$sb.Append([char]$c)
            }
            $s = $sb.ToString().Trim()
            if ($s) { $strings.Add($s) }
        }
    }

    # Extra timings in extension blocks: CTA-861 (tag 0x02) and DisplayID (tag 0x70) - high refresh modes often live here
    $extCount = [int]$e[126]
    for ($x = 1; $x -le $extCount; $x++) {
        $base = $x * 128
        if ($e.Length -lt $base + 128) { break }
        if ([int]$e[$base] -eq 0x70) {
            foreach ($t in @(Get-DisplayIdTimings -Bytes $e -Base $base)) { $timings.Add($t) }
            continue
        }
        if ([int]$e[$base] -ne 0x02) { continue }
        $dtd = [int]$e[$base + 2]
        if ($dtd -lt 4) { continue }
        $p = $base + $dtd
        while ($p + 18 -le $base + 127) {
            $t = Get-EdidTiming -Bytes $e -Offset $p
            if (-not $t) { break }
            $timings.Add($t)
            $p += 18
        }
    }

    # Part number, when the panel stores one in a text descriptor.
    # Real panel part numbers always contain a digit; plain words (SAMSUNG, DISPLAY) are not part numbers.
    $part = ''
    foreach ($s in $strings) {
        $u = $s.ToUpperInvariant()      # not ToUpper(): in a Turkish locale i becomes a different letter
        if ($u -match '^[A-Z0-9][A-Z0-9\.\-]{5,}$' -and
            $u -match '[0-9]' -and
            $u -notmatch '^(LCD|LED|MONITOR|DISPLAY|GENERIC|COLOR)') { $part = $s; break }
    }

    $native = $null
    if ($timings.Count -gt 0) { $native = $timings[0] }
    $maxHz = 0
    foreach ($t in $timings) { if ($t.Refresh -gt $maxHz) { $maxHz = $t.Refresh } }

    # Size: the first timing carries the image size in mm (exact). The header only has whole cm.
    $wCm = [int]$e[21]; $hCm = [int]$e[22]
    $wMm = 0; $hMm = 0
    if ($native -and $native.WidthMm -gt 0 -and $native.HeightMm -gt 0) { $wMm = $native.WidthMm; $hMm = $native.HeightMm }
    $diag = 0
    if ($wMm -gt 0) {
        $diag = [math]::Round([math]::Sqrt(($wMm * $wMm) + ($hMm * $hMm)) / 25.4, 1)
    }
    elseif ($wCm -gt 0 -and $hCm -gt 0) {
        $diag = [math]::Round([math]::Sqrt(($wCm * $wCm) + ($hCm * $hCm)) / 2.54, 1)
    }

    $aspect = ''
    if ($native -and $native.Height -gt 0) {
        $r = $native.Width / $native.Height
        if     ($r -gt 1.76 -and $r -lt 1.79) { $aspect = '16:9' }
        elseif ($r -gt 1.59 -and $r -lt 1.61) { $aspect = '16:10' }
        elseif ($r -gt 1.49 -and $r -lt 1.51) { $aspect = '3:2' }
    }

    [pscustomobject]@{
        PnpId    = $pnpId
        Part     = $part
        Strings  = @($strings)
        Width    = if ($native) { $native.Width }  else { 0 }
        Height   = if ($native) { $native.Height } else { 0 }
        Aspect   = $aspect
        MaxHz    = $maxHz
        WidthCm  = $wCm
        WidthMm  = $wMm
        HeightMm = $hMm
        Diagonal = $diag
        Built    = "week $([int]$e[16]), $(1990 + [int]$e[17])"
    }
}

function Select-Screens {
    # Splits recorded screens into the one in use now and earlier ones.
    param($Screens)
    $all = @($Screens | Where-Object { $_.Edid })
    $laptopSize = { param($s) $s.Edid.WidthCm -ge 20 -and $s.Edid.WidthCm -le 42 }

    $now = @($all | Where-Object { $_.Present -and (& $laptopSize $_) } |
             Sort-Object { $_.Edid.WidthCm }) | Select-Object -First 1
    if (-not $now) {
        # Some built-in panels report no physical size; external monitors always do
        $now = @($all | Where-Object { $_.Present -and $_.Edid.WidthCm -eq 0 }) | Select-Object -First 1
    }

    $earlier = @()
    $seen = @{}
    if ($now) { $seen[$now.Edid.PnpId] = $true }
    foreach ($s in @($all | Where-Object { -not $_.Present -and (& $laptopSize $_) } |
                     Sort-Object { if ($_.LastArrival) { [datetime]$_.LastArrival } else { [datetime]::MinValue } } -Descending)) {
        if ($seen.ContainsKey($s.Edid.PnpId)) { continue }
        $seen[$s.Edid.PnpId] = $true
        $earlier += $s
    }
    [pscustomobject]@{ Now = $now; Earlier = $earlier }
}

function Get-ScreenList {
    # Every screen Windows has a stored EDID for: the one connected now and ones seen before.
    param($Devices)
    $present = @{}
    foreach ($m in @($Devices | Where-Object { $_.Class -eq 'Monitor' })) {
        $present[([string]$m.InstanceId).ToUpper()] = (Test-DevicePresent $m)
    }
    $screens = @()
    foreach ($pnp in @(Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Enum\DISPLAY' -ErrorAction SilentlyContinue)) {
        foreach ($inst in @(Get-ChildItem -LiteralPath $pnp.PSPath -ErrorAction SilentlyContinue)) {
            $raw = (Get-ItemProperty -LiteralPath (Join-Path $inst.PSPath 'Device Parameters') -ErrorAction SilentlyContinue).EDID
            if (-not $raw) { continue }
            $info = ConvertFrom-EdidBytes -Bytes ([byte[]]$raw)
            if (-not $info) { continue }
            $id = ('DISPLAY\{0}\{1}' -f $pnp.PSChildName, $inst.PSChildName).ToUpper()
            $isPresent = $false
            if ($present.ContainsKey($id)) { $isPresent = $present[$id] }
            $screens += [pscustomobject]@{
                InstanceId  = $id
                Present     = $isPresent
                LastArrival = Get-DeviceDate $id 'DEVPKEY_Device_LastArrivalDate'
                Edid        = $info
            }
        }
    }
    return @($screens)
}

# =====================================================================
#  PANELID
# =====================================================================
function Get-TouchControllerId {
    # I2C touch controllers show up as HID\ELAN2514&COL01\...
    # USB touch controllers show up as HID\VID_04F3&PID_2B22&COL01\...
    param([string]$InstanceId)
    if ($InstanceId -match '^HID\\(VID_[0-9A-F]{4}&PID_[0-9A-F]{4})') { return $Matches[1].ToUpperInvariant() }
    if ($InstanceId -match '^(?:HID|ACPI)\\([A-Z]{3,4}[0-9A-F]{3,4})') { return $Matches[1].ToUpperInvariant() }
    return ''
}

function Get-PanelFacts {
    $cs   = Get-CimInstance Win32_ComputerSystem
    $csp  = Get-CimInstance Win32_ComputerSystemProduct
    $bios = Get-CimInstance Win32_BIOS
    $all  = @(Get-PnpDevice -ErrorAction SilentlyContinue)

    $sel = Select-Screens -Screens @(Get-ScreenList -Devices $all)

    $touch = @(Find-TouchDevices -Devices $all | ForEach-Object {
        [pscustomobject]@{
            Present    = (Test-DevicePresent $_)
            Controller = (Get-TouchControllerId ([string]$_.InstanceId))
        }
    })

    [pscustomobject]@{
        Today       = Get-Date
        Make        = [string]$cs.Manufacturer
        Model       = [string](Get-FriendlyModel -ComputerSystem $cs -Product $csp)
        SystemModel = [string]$cs.Model
        Sku         = [string]$cs.SystemSKUNumber
        Serial      = [string]$bios.SerialNumber
        Screen      = $sel.Now
        Touch       = $touch
    }
}

function Get-FieldLine {
    param([string]$Name, $Value)
    if ("$Value".Trim() -eq '') { $Value = '(not reported)' }
    return ('  {0,-16}: {1}' -f $Name, $Value)
}

function Build-PanelReport {
    param($Facts, [string]$Label)
    $r = New-Object System.Collections.Generic.List[string]
    $r.Add('')
    $r.Add('===============================================================')
    $r.Add('   LAPTOP AND SCREEN INFORMATION')
    $r.Add('===============================================================')
    $r.Add('')
    $r.Add('Generated: ' + $Facts.Today.ToString('yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture))
    if ($Label) { $r.Add("Reference: $Label") }

    $r.Add('')
    $r.Add('LAPTOP')
    $r.Add((Get-FieldLine 'Make'          $Facts.Make))
    $r.Add((Get-FieldLine 'Model'         $Facts.Model))
    $r.Add((Get-FieldLine 'System model'  $Facts.SystemModel))
    $r.Add((Get-FieldLine 'SKU'           $Facts.Sku))
    $r.Add((Get-FieldLine 'Serial number' $Facts.Serial))

    $r.Add('')
    $r.Add('SCREEN')
    $scr = $Facts.Screen
    if (-not $scr) {
        $r.Add('  No screen information could be read.')
    }
    else {
        $e = $scr.Edid
        $part = 'not stored in screen'
        if ($e.Part) { $part = $e.Part }
        $hz = ''
        if ($e.MaxHz -gt 0) { $hz = "$($e.MaxHz) Hz" }
        $r.Add((Get-FieldLine 'PnP ID'      $e.PnpId))
        $r.Add((Get-FieldLine 'Part number' $part))
        $r.Add((Get-FieldLine 'Max refresh' $hz))
    }

    $r.Add('')
    $r.Add('TOUCH')
    $here = @($Facts.Touch | Where-Object { $_.Present })
    if ($here.Count -gt 0) {
        $withId = @($here | Where-Object { $_.Controller } | Select-Object -First 1)
        $id = ''
        if ($withId.Count -gt 0) { $id = $withId[0].Controller }
        $r.Add((Get-FieldLine 'Touchscreen' 'YES'))
        $r.Add((Get-FieldLine 'Controller'  $id))
    }
    else {
        $r.Add((Get-FieldLine 'Touchscreen' 'NO'))
        # A touchscreen Windows remembers but that is not connected now: typical after a screen swap
        $old = @($Facts.Touch | Where-Object { $_.Controller } | Select-Object -First 1)
        if ($old.Count -gt 0) {
            $r.Add((Get-FieldLine 'Seen earlier' ($old[0].Controller + ' (not connected now)')))
        }
    }

    $r.Add('')
    $r.Add('===============================================================')
    return $r.ToArray()
}

function Save-PanelReport {
    param([string[]]$Lines)
    $dir = $OutputPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        try { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null } catch { }
    }
    if (-not $dir) { $dir = [Environment]::GetFolderPath('Desktop') }
    if (-not $dir -or -not (Test-Path -LiteralPath $dir)) { $dir = $env:USERPROFILE }
    if (-not $dir -or -not (Test-Path -LiteralPath $dir)) { $dir = $env:TEMP }

    $stamp = (Get-Date).ToString('yyyy-MM-dd_HHmm', [Globalization.CultureInfo]::InvariantCulture)
    $name  = "PanelID_$stamp.txt"
    $file  = Join-Path $dir $name
    $text  = $Lines -join "`r`n"
    try {
        Set-Content -LiteralPath $file -Value $text -Encoding UTF8 -ErrorAction Stop
    } catch {
        $file = Join-Path $env:TEMP $name
        Set-Content -LiteralPath $file -Value $text -Encoding UTF8
    }
    return $file
}

function Invoke-PanelId {
    Write-Host ''
    Write-Host '  Reading laptop and screen details...' -ForegroundColor Gray
    $facts = Get-PanelFacts
    $lines = Build-PanelReport -Facts $facts -Label $Label

    Clear-Host
    foreach ($l in $lines) { Write-Host "  $l" }
    $file = Save-PanelReport -Lines $lines

    Write-Host ''
    Write-Host "  Saved to: $file" -ForegroundColor Green
    Write-Host '  Please email this file to support.' -ForegroundColor Gray
    Write-Host ''

    Start-Process -FilePath 'notepad.exe' -ArgumentList "`"$file`"" -ErrorAction SilentlyContinue
    if (-not $NoPause) { Read-Host '  Press Enter to close' | Out-Null }
}

# Run only when started as a script (not when loaded for testing)
if ($MyInvocation.InvocationName -ne '.') { Invoke-PanelId }
