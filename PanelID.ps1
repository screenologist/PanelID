<#
    PanelID - laptop and LCD panel identification

    Prints to the console and saves a text file to the Desktop.
    Read-only. No admin rights needed. Changes nothing.

    Usage:  .\PanelID.ps1
            .\PanelID.ps1 -Label "RMA-4471"
#>

param([string]$Label)

$ErrorActionPreference = 'SilentlyContinue'

$out = New-Object System.Collections.Generic.List[string]
function W($t = '') { $out.Add($t); Write-Host "  $t" }
function F($n, $v) {
    if ("$v".Trim() -eq '') { $v = '(not reported)' }
    W ("  {0,-16}: {1}" -f $n, $v)
}

# ---------- laptop ----------------------------------------------------
$cs   = Get-CimInstance Win32_ComputerSystem
$csp  = Get-CimInstance Win32_ComputerSystemProduct
$bios = Get-CimInstance Win32_BIOS

# ---------- panel EDID ------------------------------------------------
$panel = $null

foreach ($pnp in Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Enum\DISPLAY') {
    foreach ($inst in Get-ChildItem $pnp.PSPath) {
        $e = (Get-ItemProperty "$($inst.PSPath)\Device Parameters").EDID
        if (-not $e -or $e.Length -lt 128) { continue }

        # PnP ID: 3-letter vendor code + product code
        $v    = ($e[8] -shl 8) -bor $e[9]
        $vend = [char](((($v -shr 10) -band 0x1F)) + 64) +
                [char](((($v -shr 5)  -band 0x1F)) + 64) +
                [char]((($v -band 0x1F)) + 64)
        $pnpId = '{0}{1:X4}' -f $vend, ($e[10] -bor ($e[11] -shl 8))

        # Text descriptors (0xFC / 0xFE / 0xFF) and detailed timings
        $strings = @()
        $maxHz   = 0
        $widthCm = $e[21]

        foreach ($o in 54, 72, 90, 108) {
            $px = $e[$o] -bor ($e[$o + 1] -shl 8)
            if ($px -ne 0) {
                $hT = ($e[$o+2] -bor ((($e[$o+4] -shr 4) -band 0x0F) -shl 8)) +
                      ($e[$o+3] -bor ((  $e[$o+4]        -band 0x0F) -shl 8))
                $vT = ($e[$o+5] -bor ((($e[$o+7] -shr 4) -band 0x0F) -shl 8)) +
                      ($e[$o+6] -bor ((  $e[$o+7]        -band 0x0F) -shl 8))
                if ($hT -gt 0 -and $vT -gt 0) {
                    $hz = [math]::Round((($px / 100.0) * 1e6) / ($hT * $vT), 0)
                    if ($hz -gt $maxHz) { $maxHz = $hz }
                }
            }
            elseif ($e[$o + 3] -in 0xFC, 0xFE, 0xFF) {
                $s = ((5..17 | ForEach-Object { [char]$e[$o + $_] }) -join '')
                $s = (($s -split "`n")[0]).Trim()
                if ($s) { $strings += $s }
            }
        }

        # Detailed timings in CTA-861 extension blocks too
        if ($e[126] -gt 0 -and $e.Length -ge 256) {
            for ($x = 1; $x -le $e[126]; $x++) {
                $b = $x * 128
                if ($e.Length -lt $b + 128 -or $e[$b] -ne 0x02 -or $e[$b + 2] -lt 4) { continue }
                $p = $b + $e[$b + 2]
                while ($p + 18 -le $b + 127) {
                    $px = $e[$p] -bor ($e[$p + 1] -shl 8)
                    if ($px -eq 0) { break }
                    $hT = ($e[$p+2] -bor ((($e[$p+4] -shr 4) -band 0x0F) -shl 8)) +
                          ($e[$p+3] -bor ((  $e[$p+4]        -band 0x0F) -shl 8))
                    $vT = ($e[$p+5] -bor ((($e[$p+7] -shr 4) -band 0x0F) -shl 8)) +
                          ($e[$p+6] -bor ((  $e[$p+7]        -band 0x0F) -shl 8))
                    if ($hT -gt 0 -and $vT -gt 0) {
                        $hz = [math]::Round((($px / 100.0) * 1e6) / ($hT * $vT), 0)
                        if ($hz -gt $maxHz) { $maxHz = $hz }
                    }
                    $p += 18
                }
            }
        }

        # Part number, if the panel stores one
        $part = $strings |
            Where-Object { $_.ToUpper() -match '^[A-Z0-9][A-Z0-9\.\-]{5,}$' } |
            Where-Object { $_.ToUpper() -notmatch '^(LCD|LED|MONITOR|DISPLAY|GENERIC|COLOR)' } |
            Select-Object -First 1

        $rec = [pscustomobject]@{
            PnpId = $pnpId; Part = $part; MaxHz = $maxHz; WidthCm = $widthCm
        }

        # Internal panel = smallest physical width
        if (-not $panel -or $widthCm -lt $panel.WidthCm) { $panel = $rec }
    }
}

# ---------- touch -----------------------------------------------------
$touch = Get-PnpDevice | Where-Object {
    $_.FriendlyName -like '*touch screen*' -or
    $_.FriendlyName -like '*touchscreen*'  -or
    $_.FriendlyName -like '*digitizer*'
} | Select-Object -First 1

$ctrl = ''
if ($touch -and $touch.InstanceId -match '(?:HID|ACPI)\\([A-Z]{3,4}[0-9A-F]{3,4})') {
    $ctrl = $Matches[1]
}

# ---------- report ----------------------------------------------------
Clear-Host
W ''
W '==============================================================='
W '   LAPTOP AND SCREEN INFORMATION'
W '==============================================================='
W ''
W "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
if ($Label) { W "Reference: $Label" }

W ''
W 'LAPTOP'
F 'Make'          $cs.Manufacturer
F 'Model'         $csp.Version
F 'System model'  $cs.Model
F 'SKU'           $cs.SystemSKUNumber
F 'Serial number' $bios.SerialNumber

W ''
W 'SCREEN'
if (-not $panel) {
    W '  No screen information could be read.'
} else {
    F 'PnP ID'      $panel.PnpId
    F 'Part number' $(if ($panel.Part) { $panel.Part } else { 'not stored in screen' })
    F 'Max refresh' $(if ($panel.MaxHz -gt 0) { "$($panel.MaxHz) Hz" } else { '' })
}

W ''
W 'TOUCH'
if ($touch) {
    F 'Touchscreen' 'YES'
    F 'Controller'  $ctrl
} else {
    F 'Touchscreen' 'NO'
}

W ''
W '==============================================================='

# ---------- save ------------------------------------------------------
$dir = [Environment]::GetFolderPath('Desktop')
if (-not $dir -or -not (Test-Path $dir)) { $dir = $env:USERPROFILE }
if (-not (Test-Path $dir)) { $dir = $env:TEMP }

$name = "PanelID_$(Get-Date -Format 'yyyy-MM-dd_HHmm').txt"
$file = Join-Path $dir $name

try   { $out -join "`r`n" | Out-File $file -Encoding UTF8 -ErrorAction Stop }
catch { $file = Join-Path $env:TEMP $name; $out -join "`r`n" | Out-File $file -Encoding UTF8 }

Write-Host ''
Write-Host "  Saved to: $file" -ForegroundColor Green
Write-Host '  Please email this file to support.' -ForegroundColor Gray
Write-Host ''

Start-Process notepad.exe $file
Read-Host '  Press Enter to close'
