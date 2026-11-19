# prober - inspect a second-hand Windows laptop before you buy it.
#
# Read-only: it changes nothing on the machine and sends nothing anywhere.
# The only things it writes are its report folder and a temp battery XML.
# Run as Administrator for the full set (disk wear, BIOS passwords, TPM, temps).
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File probe.ps1
#   irm https://raw.githubusercontent.com/wxsonz/prober/main/probe.ps1 | iex
#
# Keep this file pure ASCII: Windows PowerShell 5.1 reads BOM-less files as ANSI.

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'

$script:ProberVersion = '0.2.0'   # bump on every push: the banner shows which copy ran (raw GitHub caches ~5 min)
$script:Results = New-Object System.Collections.Generic.List[object]
$script:Spec    = [ordered]@{}
$script:CurSec  = ''
$script:OutDir  = $null
$script:Serial  = 'unknown'
$script:Maker   = ''
$script:IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$script:ScriptDir = $PSScriptRoot

# ---------------------------------------------------------------- recording

function Rec {
    param([string]$Item, [string]$Status, [string]$Detail, [string]$Advice = '')
    if ($script:CurSec -eq 'Hands-on tests') {
        for ($i = $script:Results.Count - 1; $i -ge 0; $i--) {
            $r = $script:Results[$i]
            if ($r.Section -eq 'Hands-on tests' -and $r.Item -eq $Item) { $script:Results.RemoveAt($i) }
        }
    }
    $script:Results.Add([pscustomobject]@{ Section = $script:CurSec; Item = $Item; Status = $Status; Detail = $Detail; Advice = $Advice })
    $color = @{ OK = 'Green'; WARN = 'Yellow'; FAIL = 'Red'; INFO = 'Gray'; SKIP = 'DarkGray' }[$Status]
    Write-Host ('  [{0,-4}] ' -f $Status) -ForegroundColor $color -NoNewline
    Write-Host ('{0}: {1}' -f $Item, $Detail)
    if ($Advice -and $Status -ne 'OK') { Write-Host ('         -> ' + $Advice) -ForegroundColor DarkCyan }
}

function Run-Step {
    param([string]$Name, [scriptblock]$Body)
    $script:CurSec = $Name
    Write-Host ''
    Write-Host ('== ' + $Name + ' ==') -ForegroundColor Cyan
    try { & $Body } catch { Rec 'check error' 'SKIP' $_.Exception.Message }
}

function Need-Admin { param([string]$Item) Rec $Item 'SKIP' 'needs Administrator' 'Re-run as admin (run.cmd does this) for this check' }

function Dec { param($a) if (-not $a) { return '' }; -join ($a | Where-Object { $_ -ne 0 } | ForEach-Object { [char]$_ }) }

function GB { param($bytes) [math]::Round([double]$bytes / 1GB, 0) }

# ---------------------------------------------------------------- identity

function Test-Identity {
    $cs   = Get-CimInstance Win32_ComputerSystem
    $prod = Get-CimInstance Win32_ComputerSystemProduct
    $bios = Get-CimInstance Win32_BIOS
    $os   = Get-CimInstance Win32_OperatingSystem

    $script:Maker = ([string]$cs.Manufacturer).Trim()
    $model = ([string]$cs.Model).Trim()
    if ($script:Maker -match 'LENOVO' -and $prod.Version -and $prod.Version -ne $model) { $model = "$model ($($prod.Version.Trim()))" }
    Rec 'Model' 'INFO' "$script:Maker $model" 'Must match the listing and the sticker underneath'
    $script:Spec['Model'] = "$script:Maker $model"

    $serial = ([string]$bios.SerialNumber).Trim()
    if ($serial -match '^(|0+|none|n/?a|default string|to be filled.*|system serial number|123456789|chassis serial number)$') {
        Rec 'Serial' 'WARN' "'$serial' (blank or generic)" 'Motherboard replaced or firmware re-flashed; warranty lookup will not work. Ask why.'
    } else {
        $script:Serial = $serial
        Rec 'Serial' 'INFO' $serial 'Must match the sticker on the bottom and the BIOS screen'
    }
    $script:Spec['Serial'] = $serial

    $url = switch -regex ($script:Maker) {
        'Dell'           { "https://www.dell.com/support/home/product-support/servicetag/$serial"; break }
        'LENOVO'         { 'https://pcsupport.lenovo.com/warrantylookup'; break }
        '^HP|Hewlett'    { 'https://support.hp.com/checkwarranty'; break }
        'ASUS'           { 'https://www.asus.com/support/warranty-status-inquiry/'; break }
        'Acer'           { 'https://www.acer.com/support'; break }
        'Micro-Star|MSI' { 'https://www.msi.com/support'; break }
        default         { '' }
    }
    if ($url) { Rec 'Warranty lookup' 'INFO' $url 'Paste the serial there: shows real model, ship date, warranty left' }

    $bd = ''; if ($bios.ReleaseDate) { $bd = $bios.ReleaseDate.ToString('yyyy-MM-dd') }
    Rec 'BIOS' 'INFO' ("{0} ({1})" -f $bios.SMBIOSBIOSVersion, $bd)

    Rec 'Windows' 'INFO' ("{0} {1}, build {2}" -f $os.Caption, $os.OSArchitecture, $os.BuildNumber)
    if ($os.InstallDate) {
        $days = [int]((Get-Date) - $os.InstallDate).TotalDays
        if ($days -lt 30) { Rec 'Install date' 'INFO' ("{0:yyyy-MM-dd} ({1} days ago)" -f $os.InstallDate, $days) 'Fresh install or big update: crash history below will be short' }
        else { Rec 'Install date' 'INFO' ("{0:yyyy-MM-dd} ({1} days ago)" -f $os.InstallDate, $days) }
    }
    if ($os.LastBootUpTime) {
        $up = (Get-Date) - $os.LastBootUpTime
        Rec 'Uptime' 'INFO' ("{0}d {1}h {2}m" -f $up.Days, $up.Hours, $up.Minutes)
    }
}

# ---------------------------------------------------------------- cpu / ram / gpu

function Get-Temps {
    $z = @(Get-CimInstance -Namespace root\wmi -ClassName MSAcpi_ThermalZoneTemperature | Where-Object { $_.CurrentTemperature -gt 0 })
    if (-not $z) { return $null }
    $c = ($z | ForEach-Object { [double]$_.CurrentTemperature / 10 - 273.15 } | Measure-Object -Maximum).Maximum
    [math]::Round($c, 0)
}

function Test-Cpu {
    $cpu = @(Get-CimInstance Win32_Processor)[0]
    $name = ([string]$cpu.Name).Trim()
    Rec 'CPU' 'INFO' ("{0} - {1} cores / {2} threads, base {3} MHz" -f $name, $cpu.NumberOfCores, $cpu.NumberOfLogicalProcessors, $cpu.MaxClockSpeed)
    $script:Spec['CPU'] = $name
    if ($script:IsAdmin) {
        $t = Get-Temps
        if ($t -ne $null) {
            if ($t -ge 85) { Rec 'Idle temperature' 'WARN' "$t C (ACPI thermal zone)" 'Hot at idle: clogged fans or dried thermal paste' }
            else { Rec 'Idle temperature' 'INFO' "$t C (ACPI thermal zone, often coarse)" }
        }
    }
}

function Test-Memory {
    $mods  = @(Get-CimInstance Win32_PhysicalMemory)
    $slots = (@(Get-CimInstance Win32_PhysicalMemoryArray) | Measure-Object -Property MemoryDevices -Sum).Sum
    $total = (($mods | Measure-Object -Property Capacity -Sum).Sum)
    foreach ($m in $mods) {
        $speed = $m.ConfiguredClockSpeed; if (-not $speed) { $speed = $m.Speed }
        $ff = switch ([int]$m.FormFactor) { 12 { 'SO-DIMM slot' } 8 { 'DIMM slot' } default { 'likely soldered' } }
        $parts = @(("{0} GB" -f (GB $m.Capacity)), ([string]$m.Manufacturer).Trim(), ([string]$m.PartNumber).Trim()) | Where-Object { $_ }
        $txt = $parts -join ' '
        if ($speed) { $txt += " @ $speed MT/s" }
        Rec 'RAM module' 'INFO' ("{0} [{1}, {2}]" -f $txt, $m.DeviceLocator, $ff)
    }
    $detail = "{0} GB in {1} module(s)" -f (GB $total), $mods.Count
    if ($slots) { $detail += ", $slots slot(s) reported" }
    if ($mods.Count -eq 1 -and $slots -ge 2) {
        Rec 'RAM total' 'INFO' $detail 'Single module = single-channel (slower, hurts integrated graphics). Cheap to fix with a second stick.'
    } else { Rec 'RAM total' 'INFO' $detail }
    $script:Spec['RAM'] = "{0} GB ({1} module(s))" -f (GB $total), $mods.Count
}

function Test-Gpu {
    $vram = @{}
    Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}' | ForEach-Object {
        $p = Get-ItemProperty $_.PSPath
        if (-not $p.DriverDesc) { return }
        $q = $p.'HardwareInformation.qwMemorySize'
        if (-not $q) {
            $m = $p.'HardwareInformation.MemorySize'
            if ($m -is [byte[]]) { $q = [BitConverter]::ToUInt32($m, 0) } else { $q = $m }
        }
        if ($q) { $vram[[string]$p.DriverDesc] = [int64]$q }
    }
    $names = @()
    foreach ($g in @(Get-CimInstance Win32_VideoController)) {
        $v = ''
        if ($vram.ContainsKey([string]$g.Name)) { $v = ", {0} GB VRAM" -f [math]::Round($vram[[string]$g.Name] / 1GB, 1) }
        $d = "{0}{1}, driver {2}" -f $g.Name, $v, $g.DriverVersion
        $names += $g.Name
        if ($g.ConfigManagerErrorCode -and $g.ConfigManagerErrorCode -ne 0) {
            Rec 'GPU' 'FAIL' "$d - device error code $($g.ConfigManagerErrorCode)" 'Code 43 on a graphics card is the classic dead/dying GPU. Walk away unless priced as broken.'
        } elseif ($g.Name -match 'Basic Display|Basic Render') {
            Rec 'GPU' 'WARN' $d 'No real graphics driver. Install it (or let Windows Update) and confirm the advertised GPU appears.'
        } else { Rec 'GPU' 'INFO' $d }
    }
    $script:Spec['GPU'] = $names -join ' + '
    $smi = Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'
    if (Test-Path $smi) {
        $o = & $smi --query-gpu=name,memory.total,temperature.gpu,pstate --format=csv,noheader 2>$null
        if ($o) { Rec 'nvidia-smi' 'INFO' (($o | Out-String).Trim()) }
    }
}

# ---------------------------------------------------------------- display

function Test-Display {
    $mfrNames = @{ BOE = 'BOE'; AUO = 'AU Optronics'; LGD = 'LG Display'; SHP = 'Sharp'; CMN = 'Innolux'; SDC = 'Samsung'; IVO = 'InfoVision'; CSO = 'CSOT'; NCP = 'Panda'; LEN = 'Lenovo'; APP = 'Apple'; SAM = 'Samsung'; TMX = 'Tianma' }
    $ids   = @(Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID)
    $cons  = @(Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorConnectionParams)
    $basic = @(Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorBasicDisplayParams)
    $panel = ''
    foreach ($m in $ids) {
        $mfr = Dec $m.ManufacturerName; $code = Dec $m.ProductCodeID; $nm = Dec $m.UserFriendlyName
        $c = $cons  | Where-Object { $_.InstanceName -eq $m.InstanceName } | Select-Object -First 1
        $b = $basic | Where-Object { $_.InstanceName -eq $m.InstanceName } | Select-Object -First 1
        $vot = [int64]$c.VideoOutputTechnology; if ($vot -lt 0) { $vot += 4294967296 }
        $internal = @(2147483648, 6, 11, 13) -contains $vot
        $diag = ''
        if ($b -and $b.MaxHorizontalImageSize) {
            $diag = ' ~{0} in' -f [math]::Round([math]::Sqrt([double]$b.MaxHorizontalImageSize * $b.MaxHorizontalImageSize + [double]$b.MaxVerticalImageSize * $b.MaxVerticalImageSize) / 2.54, 1)
        }
        $full = $mfr; if ($mfrNames.ContainsKey($mfr)) { $full = "$($mfrNames[$mfr]) ($mfr)" }
        $kind = if ($internal) { 'Built-in panel' } else { 'External display' }
        Rec $kind 'INFO' ("{0} {1} {2}{3}" -f $full, $code, $nm, $diag).Trim() "Search '$mfr $code' to see the real panel spec (refresh, brightness, colour)"
        if ($internal -and -not $panel) { $panel = ("{0} {1}{2}" -f $mfr, $code, $diag).Trim() }
    }
    $mode = ''
    foreach ($v in @(Get-CimInstance Win32_VideoController | Where-Object { $_.CurrentHorizontalResolution })) {
        $hz = [int]$v.CurrentRefreshRate
        $d = if ($hz -gt 1) { "{0}x{1} @ {2} Hz" -f $v.CurrentHorizontalResolution, $v.CurrentVerticalResolution, $hz } else { "{0}x{1} @ default refresh" -f $v.CurrentHorizontalResolution, $v.CurrentVerticalResolution }
        if ($hz -gt 1 -and $v.MaxRefreshRate -gt $hz) {
            Rec 'Display mode' 'INFO' "$d (max reported $($v.MaxRefreshRate) Hz)" 'Set to a lower refresh than it supports; check Settings > Display > Advanced display'
        } else { Rec 'Display mode' 'INFO' "$d via $($v.Name)" 'Compare the refresh rate with the listing (60 vs 120/144 Hz)' }
        if (-not $mode) { $mode = $d }
    }
    $script:Spec['Display'] = ("$panel, $mode").Trim(', ')
}

# ---------------------------------------------------------------- storage

function Test-Storage {
    $disks = @(Get-PhysicalDisk)
    if (-not $disks) { Rec 'Disks' 'SKIP' 'Get-PhysicalDisk returned nothing'; return }
    $specs = @()
    foreach ($d in $disks) {
        $label = "{0} - {1} GB {2} {3}" -f $d.FriendlyName, (GB $d.Size), $d.BusType, $d.MediaType
        $specs += "{0} GB {1} {2}" -f (GB $d.Size), $d.BusType, $d.MediaType
        switch ([string]$d.HealthStatus) {
            'Healthy'   { Rec 'Disk' 'OK'   "$label - Windows says Healthy" }
            'Warning'   { Rec 'Disk' 'WARN' "$label - Windows says Warning" 'Drive is reporting problems; back up and budget for a replacement' }
            'Unhealthy' { Rec 'Disk' 'FAIL' "$label - Windows says Unhealthy" 'Drive is failing. Price in a new SSD or walk away.' }
            default     { Rec 'Disk' 'INFO' "$label - health '$($d.HealthStatus)'" }
        }
        if ([string]$d.MediaType -eq 'HDD') { Rec 'Disk type' 'INFO' 'Spinning hard drive' 'Slow by modern standards; an SSD swap transforms it' }

        if (-not $script:IsAdmin) { Need-Admin 'Disk wear / errors'; continue }
        $rc = $d | Get-StorageReliabilityCounter
        if (-not $rc) { Rec 'Disk wear / errors' 'SKIP' 'drive does not report reliability counters'; continue }
        if ($rc.Wear -ne $null) {
            $w = [int]$rc.Wear
            if ($w -ge 80)     { Rec 'Wear' 'FAIL' "$w% of rated write life used" 'SSD near end of life' }
            elseif ($w -ge 40) { Rec 'Wear' 'WARN' "$w% of rated write life used" 'Heavily used SSD; fine for now, worth a discount' }
            else               { Rec 'Wear' 'OK'   "$w% of rated write life used (0 can also mean not reported)" }
        }
        if ($rc.ReadErrorsUncorrected -gt 0) { Rec 'Uncorrected read errors' 'FAIL' $rc.ReadErrorsUncorrected 'Data is being lost: failing drive' }
        if ($rc.WriteErrorsUncorrected -gt 0) { Rec 'Uncorrected write errors' 'FAIL' $rc.WriteErrorsUncorrected 'Failing drive' }
        if ($rc.PowerOnHours) {
            $h = [int]$rc.PowerOnHours
            if ($h -gt 20000) { Rec 'Power-on hours' 'WARN' ("{0} h (~{1} years of 8h days)" -f $h, [math]::Round($h / 2920, 1)) 'Very heavily used machine' }
            else { Rec 'Power-on hours' 'INFO' ("{0} h (~{1} years of 8h days)" -f $h, [math]::Round($h / 2920, 1)) 'Compare with the age the seller claims' }
        }
        if ($rc.Temperature) { Rec 'Disk temperature' 'INFO' "$($rc.Temperature) C" }
    }
    $script:Spec['Storage'] = $specs -join ' + '
    if ($script:IsAdmin) {
        $pf = @(Get-CimInstance -Namespace root\wmi -ClassName MSStorageDriver_FailurePredictStatus | Where-Object { $_.PredictFailure })
        if ($pf.Count -gt 0) { Rec 'SMART prediction' 'FAIL' 'A drive predicts its own failure' 'Failing drive' }
    }
    $c = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
    if ($c) { Rec 'C: free space' 'INFO' ("{0} GB free of {1} GB" -f (GB $c.FreeSpace), (GB $c.Size)) }
}

# ---------------------------------------------------------------- battery

function Test-Battery {
    $xml = Join-Path $env:TEMP 'prober-battery.xml'
    & powercfg.exe /batteryreport /xml /output "$xml" 2>&1 | Out-Null
    $bats = @()
    if (Test-Path $xml) {
        [xml]$bx = Get-Content $xml -Raw
        $bats = @($bx.BatteryReport.Batteries.Battery | Where-Object { $_ })
        Remove-Item $xml -Force
    }
    if ($bats.Count -eq 0) {
        Rec 'Battery' 'FAIL' 'No battery detected' 'Dead or disconnected battery - the laptop only runs on the charger'
        $script:Spec['Battery'] = 'none detected'
        return
    }
    $specs = @()
    foreach ($b in $bats) {
        $design = [double]$b.DesignCapacity; $full = [double]$b.FullChargeCapacity; $cyc = [int]$b.CycleCount
        $who = ("{0} {1}" -f $b.Manufacturer, $b.Id).Trim()
        if ($design -le 0) { Rec 'Battery health' 'SKIP' "$who - design capacity not reported"; continue }
        $pct = [math]::Round($full / $design * 100, 0)
        $d = "{0}% of design ({1:N0} / {2:N0} mWh) - {3}" -f $pct, $full, $design, $who
        if ($pct -lt 60)     { Rec 'Battery health' 'FAIL' $d 'Worn out: budget for a replacement battery' }
        elseif ($pct -lt 80) { Rec 'Battery health' 'WARN' $d 'Noticeably worn; use it to negotiate' }
        else                 { Rec 'Battery health' 'OK'   $d }
        if ($cyc -gt 0) {
            if ($cyc -gt 800) { Rec 'Cycle count' 'WARN' $cyc 'High; most batteries are rated 500-1000 cycles' }
            else { Rec 'Cycle count' 'INFO' $cyc }
        } else { Rec 'Cycle count' 'INFO' '0 / not reported by this battery' }
        $specs += "$pct% health" + $(if ($cyc -gt 0) { ", $cyc cycles" } else { '' })
    }
    $script:Spec['Battery'] = $specs -join ' + '

    Add-Type -AssemblyName System.Windows.Forms
    $ps = [System.Windows.Forms.SystemInformation]::PowerStatus
    $pct = [math]::Round($ps.BatteryLifePercent * 100, 0)
    $charging = ($ps.BatteryChargeStatus -band [System.Windows.Forms.BatteryChargeStatus]::Charging) -ne 0
    if ($ps.PowerLineStatus -eq 'Online') {
        if ($charging) { Rec 'Charging' 'OK' "plugged in, charging, at $pct%" }
        elseif ($pct -ge 95) { Rec 'Charging' 'OK' "plugged in, full ($pct%)" }
        else { Rec 'Charging' 'WARN' "plugged in but NOT charging at $pct%" 'Bad charger/port/battery - or a charge limit (Lenovo Vantage, MyASUS, Dell Power Manager "conservation" mode). Ask.' }
    } else {
        Rec 'Charging' 'INFO' "on battery ($pct%)" 'Plug the charger in and re-run, or watch the tray icon switch to charging'
    }
}

# ---------------------------------------------------------------- ownership & locks

function Test-Ownership {
    # Windows licence
    $lic = @(Get-CimInstance SoftwareLicensingProduct -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL")
    $l = $lic | Select-Object -First 1
    $winSpec = (Get-CimInstance Win32_OperatingSystem).Caption -replace '^Microsoft\s+', ''
    if ($l) {
        $chan = [string]$l.ProductKeyChannel; if (-not $chan) { $chan = [string]$l.Description }
        if ($l.LicenseStatus -ne 1) {
            Rec 'Activation' 'WARN' "Not activated (status $($l.LicenseStatus), $chan)" 'Will nag and limit personalisation; a licence costs money'
            $winSpec += ', NOT activated'
        } elseif ($chan -match 'GVLK|KMS') {
            Rec 'Activation' 'WARN' "Activated via KMS volume licence ($chan)" 'On a personal laptop this almost always means a pirate activator (or a company server). It will lapse.'
            $winSpec += ', KMS-activated'
        } elseif ($chan -match 'MAK|Volume') {
            Rec 'Activation' 'WARN' "Activated with a volume/company key ($chan)" 'Corporate licence: likely an ex-company machine'
            $winSpec += ', volume licence'
        } else {
            Rec 'Activation' 'OK' "Activated ($chan)"
            $winSpec += ', activated'
        }
    } else { Rec 'Activation' 'SKIP' 'could not read licensing status' }
    $sls = Get-CimInstance SoftwareLicensingService
    if ($sls.OA3xOriginalProductKey) {
        Rec 'Firmware licence' 'OK' ("Windows key embedded in firmware ({0})" -f $sls.OA3xOriginalProductKeyDescription) 'A clean reinstall will activate by itself'
    } else { Rec 'Firmware licence' 'INFO' 'No Windows key in firmware' 'Fine if activated with a digital licence; a reinstall may need a key' }
    $script:Spec['Windows'] = $winSpec

    # Organisation join / MDM / Autopilot
    $red = $false
    $ds = (& dsregcmd.exe /status 2>$null) -join "`n"
    function DsVal([string]$k) { if ($ds -match "(?m)^\s*$k\s*:\s*(.+?)\s*$") { return $Matches[1] }; return '' }
    if ((DsVal 'AzureAdJoined') -eq 'YES') {
        $red = $true
        Rec 'Entra/Azure AD join' 'FAIL' ("Joined to organisation '{0}'" -f (DsVal 'TenantName')) 'Company laptop. Unless the company formally released it, it can be locked or stolen. Ask for a release letter/invoice.'
    }
    if ((DsVal 'DomainJoined') -eq 'YES') {
        $red = $true
        Rec 'Domain join' 'FAIL' ("Joined to domain '{0}'" -f (DsVal 'DomainName')) 'Company laptop - same as above'
    }
    $mdm = DsVal 'MdmUrl'
    if ($mdm) { $red = $true; Rec 'MDM' 'FAIL' "Enrolled in device management: $mdm" 'Remotely manageable / wipeable by an organisation' }
    if ((DsVal 'WorkplaceJoined') -eq 'YES') { Rec 'Work account' 'INFO' 'A work/school account is added' 'Not a lock by itself; goes away with a reset' }

    $enr = @()
    Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Enrollments' | Where-Object { $_.PSChildName -match '^[0-9A-Fa-f-]{36}$' } | ForEach-Object {
        $p = Get-ItemProperty $_.PSPath
        if ($p.UPN -or $p.ProviderID -eq 'MS DM Server') { $u = [string]$p.UPN; if ($u -match '@(.+)$') { $u = '@' + $Matches[1] }; $enr += "$($p.ProviderID) $u".Trim() }
    }
    if ($enr) { $red = $true; Rec 'MDM enrollments' 'WARN' (($enr | Select-Object -Unique) -join '; ') 'Device has been enrolled in organisation management' }

    $ap = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Provisioning\Diagnostics\Autopilot'
    if ($ap -and $ap.CloudAssignedTenantDomain) {
        $red = $true
        Rec 'Autopilot' 'FAIL' "Registered to $($ap.CloudAssignedTenantDomain)" 'After any reset it forces that company login. Do not buy unless the company deregisters it.'
    }
    if (-not $red) { Rec 'Organisation locks' 'OK' 'No domain / Entra join, MDM or Autopilot traces' 'Autopilot can still show up after a reset - see checklist' }

    # Absolute / Computrace (theft tracking that survives reinstalls)
    $abs = @()
    foreach ($f in @("$env:SystemRoot\System32\rpcnet.exe", "$env:SystemRoot\System32\rpcnetp.exe", "$env:SystemRoot\SysWOW64\rpcnet.exe", "$env:SystemRoot\SysWOW64\rpcnetp.exe", "$env:ProgramFiles\Absolute Software", "${env:ProgramFiles(x86)}\Absolute Software")) {
        if (Test-Path $f) { $abs += $f }
    }
    $abs += @(Get-Service | Where-Object { $_.Name -match '^rpcnet' -or $_.DisplayName -match 'Absolute|Computrace' } | ForEach-Object { "service $($_.Name)" })
    if ($abs) { Rec 'Absolute/Computrace' 'FAIL' ($abs -join '; ') 'Firmware-level theft tracking is ACTIVE (ex-corporate or reported stolen?). It survives disk wipes. Ask for proof it was released.' }
    else { Rec 'Absolute/Computrace' 'OK' 'Not active in Windows' }

    # BitLocker
    if ($script:IsAdmin -and (Get-Command Get-BitLockerVolume)) {
        $bv = Get-BitLockerVolume -MountPoint 'C:'
        if ($bv) {
            if ([string]$bv.ProtectionStatus -eq 'On' -or [string]$bv.VolumeStatus -ne 'FullyDecrypted') {
                Rec 'BitLocker C:' 'INFO' ("{0}, protection {1}" -f $bv.VolumeStatus, $bv.ProtectionStatus) 'Fine after a full reset in front of you; otherwise the recovery key sits in the seller''s Microsoft account'
            } else { Rec 'BitLocker C:' 'OK' 'Not encrypted' }
        }
    } else {
        $v = (New-Object -ComObject Shell.Application).NameSpace('C:').Self.ExtendedProperty('System.Volume.BitLockerProtection')
        if (@(1, 3, 5, 6) -contains $v) { Rec 'BitLocker C:' 'INFO' "Encrypted (state $v)" 'Fine after a full reset; otherwise the recovery key sits in the seller''s Microsoft account' }
        elseif ($v -eq 2) { Rec 'BitLocker C:' 'OK' 'Not encrypted' }
    }

    # BIOS passwords (vendor WMI)
    if (-not $script:IsAdmin) { Need-Admin 'BIOS password'; return }
    $found = $false
    $len = Get-CimInstance -Namespace root\wmi -ClassName Lenovo_BiosPasswordSettings
    if ($len) {
        $found = $true; $s = [int]$len.PasswordState
        if ($s -band 2)      { Rec 'BIOS password' 'FAIL' 'Supervisor password SET' 'Without it you cannot change BIOS settings; on ThinkPads removing it needs a board swap. Make the seller remove it now.' }
        elseif ($s -band 4)  { Rec 'BIOS password' 'FAIL' 'Hard-disk password SET' 'Seller must remove it in BIOS before sale' }
        elseif ($s -ne 0)    { Rec 'BIOS password' 'WARN' "Password state $s (power-on/system password)" 'Ask the seller to clear it in BIOS' }
        else                 { Rec 'BIOS password' 'OK' 'None set (Lenovo)' }
    }
    $hp = @(Get-CimInstance -Namespace root\HP\InstrumentedBIOS -ClassName HP_BIOSPassword)
    if ($hp) {
        $found = $true
        $set = @($hp | Where-Object { $_.IsSet -eq 1 } | ForEach-Object { $_.Name })
        if ($set -match 'Setup') { Rec 'BIOS password' 'FAIL' ("Set: " + ($set -join ', ')) 'Seller must remove it in BIOS before sale' }
        elseif ($set) { Rec 'BIOS password' 'WARN' ("Set: " + ($set -join ', ')) 'Ask the seller to clear it' }
        else { Rec 'BIOS password' 'OK' 'None set (HP)' }
    }
    $dell = @(Get-CimInstance -Namespace root\dcim\sysman\wmisecurity -ClassName PasswordObject)
    if ($dell) {
        $found = $true
        $set = @($dell | Where-Object { $_.IsPasswordSet -eq 1 } | ForEach-Object { $_.NameId })
        if ($set -match 'Admin') { Rec 'BIOS password' 'FAIL' ("Set: " + ($set -join ', ')) 'Seller must remove it in BIOS before sale' }
        elseif ($set) { Rec 'BIOS password' 'WARN' ("Set: " + ($set -join ', ')) 'Ask the seller to clear it' }
        else { Rec 'BIOS password' 'OK' 'None set (Dell)' }
    }
    if (-not $found) { Rec 'BIOS password' 'SKIP' "No readable vendor interface on $script:Maker" 'Reboot into BIOS setup (F2/F1/Del/Esc) and confirm no password prompt' }
}

function Test-Security {
    $sb = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State'
    if ($sb -and $sb.UEFISecureBootEnabled -eq 1) { Rec 'Secure Boot' 'OK' 'On' }
    elseif ($sb) { Rec 'Secure Boot' 'INFO' 'Off' 'Not a defect, but Windows 11 and some anti-cheat games want it on' }
    else { Rec 'Secure Boot' 'INFO' 'Not available (legacy BIOS mode?)' }
    if (-not $script:IsAdmin) { Need-Admin 'TPM'; return }
    $tpm = Get-CimInstance -Namespace root\cimv2\security\microsofttpm -ClassName Win32_Tpm
    if ($tpm) {
        $ver = ([string]$tpm.SpecVersion).Split(',')[0]
        if ($ver -like '2*') { Rec 'TPM' 'OK' "TPM $ver" } else { Rec 'TPM' 'WARN' "TPM $ver" 'Windows 11 needs TPM 2.0' }
    } else { Rec 'TPM' 'WARN' 'No TPM visible' 'May be disabled in BIOS; Windows 11 needs TPM 2.0' }
}

# ---------------------------------------------------------------- devices

function Find-Dev([string[]]$Classes, [string]$Rx) {
    @($script:Pnp | Where-Object { ($Classes -contains [string]$_.PNPClass) -and ([string]$_.Name -match $Rx) } | ForEach-Object { $_.Name } | Select-Object -Unique)
}

function Test-Devices {
    $script:Pnp = @(Get-CimInstance Win32_PnPEntity)
    $codes = @{ 1 = 'not configured'; 3 = 'driver corrupt'; 10 = 'cannot start'; 12 = 'resource conflict'; 14 = 'needs restart'; 18 = 'reinstall drivers'; 22 = 'DISABLED'; 24 = 'not present / not working'; 28 = 'no driver'; 31 = 'not working properly'; 32 = 'driver disabled'; 37 = 'driver failed'; 39 = 'driver missing'; 43 = 'device reported a problem'; 48 = 'driver blocked'; 52 = 'unsigned driver' }
    $bad = @($script:Pnp | Where-Object { $_.ConfigManagerErrorCode -and $_.ConfigManagerErrorCode -ne 0 -and $_.ConfigManagerErrorCode -ne 45 })
    foreach ($d in $bad) {
        $c = [int]$d.ConfigManagerErrorCode
        $nm = [string]$d.Name; if (-not $nm) { $nm = [string]$d.DeviceID }
        $cls = ''; if ($d.PNPClass) { $cls = " [$($d.PNPClass)]" }
        $txt = "{0}{1} code {2}: {3}" -f $nm, $cls, $c, $codes[$c]
        if ($c -eq 22)                   { Rec 'Device' 'WARN' $txt 'Disabled on purpose - sellers sometimes disable a broken touchscreen, webcam or card. Enable it in Device Manager and test.' }
        elseif (@(10, 31, 43) -contains $c) { Rec 'Device' 'FAIL' $txt 'Hardware or driver failure - test this part specifically' }
        else                             { Rec 'Device' 'WARN' $txt 'Usually a missing driver; confirm the part works after installing it' }
    }
    if (-not $bad) { Rec 'Device Manager' 'OK' 'No devices with errors' }

    $want = @(
        @{ Lbl = 'Webcam';      Cls = @('Camera', 'Image');   Rx = '.';                                          Must = $true;  Hint = 'Check a privacy shutter/F-key kill switch and BIOS, else it is broken' },
        @{ Lbl = 'Wi-Fi';       Cls = @('Net');               Rx = 'Wi-?Fi|Wireless|WLAN|802\.11';              Must = $true;  Hint = 'No wireless card detected' },
        @{ Lbl = 'Bluetooth';   Cls = @('Bluetooth');         Rx = 'Bluetooth|Wireless';                         Must = $true;  Hint = 'No Bluetooth radio detected (may be toggled off by airplane mode or in BIOS)' },
        @{ Lbl = 'Speakers';    Cls = @('AudioEndpoint');     Rx = 'Speaker|Headphone';                          Must = $true;  Hint = 'No speaker output endpoint' },
        @{ Lbl = 'Microphone';  Cls = @('AudioEndpoint');     Rx = 'Microphone|Mic';                             Must = $true;  Hint = 'No microphone endpoint' },
        @{ Lbl = 'Touchpad';    Cls = @('HIDClass', 'Mouse'); Rx = 'touch ?pad|precision|Synaptics|ELAN|ALPS|I2C HID'; Must = $false; Hint = '' },
        @{ Lbl = 'Touchscreen'; Cls = @('HIDClass');          Rx = 'touch ?screen';                              Must = $false; Hint = '' },
        @{ Lbl = 'Fingerprint'; Cls = @('Biometric');         Rx = '.';                                          Must = $false; Hint = '' },
        @{ Lbl = 'Card reader'; Cls = @('SDHost', 'USB', 'DiskDrive', 'MTD'); Rx = 'card reader|SD Host|SDXC|SD/MMC'; Must = $false; Hint = '' }
    )
    foreach ($w in $want) {
        $hits = Find-Dev $w.Cls $w.Rx
        if ($w.Lbl -eq 'Bluetooth') { $hits = @($hits | Where-Object { $_ -notmatch 'Enumerator|RFCOMM|Generic Attribute|Generic Access|Device Identification|Avrcp|Hands-?Free|A2DP' }) }
        if ($hits) { Rec $w.Lbl 'INFO' (($hits | Select-Object -First 3) -join '; ') }
        elseif ($w.Must) { Rec $w.Lbl 'WARN' 'not detected' $w.Hint }
    }
}

# ---------------------------------------------------------------- event history

function Get-Ev([string[]]$Provider, [int[]]$Ids, $Since, [int[]]$Levels) {
    $f = @{ LogName = 'System'; ProviderName = $Provider; StartTime = $Since }
    if ($Ids) { $f.Id = $Ids }
    if ($Levels) { $f.Level = $Levels }   # 1 critical, 2 error, 3 warning
    @(Get-WinEvent -FilterHashtable $f -ErrorAction SilentlyContinue)
}

function Test-Events {
    $since = (Get-Date).AddDays(-365)
    $oldest = Get-WinEvent -LogName System -Oldest -MaxEvents 1
    if ($oldest) {
        $days = [int]((Get-Date) - $oldest.TimeCreated).TotalDays
        $adv = ''; if ($days -lt 14) { $adv = 'Very short history (fresh reset or cleared log): the counts below prove little' }
        Rec 'Log coverage' 'INFO' ("System log goes back {0} days (to {1:yyyy-MM-dd}); counting the last year at most" -f $days, $oldest.TimeCreated) $adv
    }

    $clr = Get-Ev 'Microsoft-Windows-Eventlog' @(104) $since | Select-Object -First 1
    if ($clr -and ((Get-Date) - $clr.TimeCreated).TotalDays -lt 60) {
        Rec 'Log cleared' 'WARN' ("System log was manually cleared on {0:yyyy-MM-dd}" -f $clr.TimeCreated) 'Someone wiped the history - ask why'
    }

    # WHEA: severity comes from the event level (language-independent): Critical/Error = fatal, Warning = corrected
    $whea = @(Get-Ev 'Microsoft-Windows-WHEA-Logger' $null $since)
    $fatal = @($whea | Where-Object { $_.Level -le 2 })
    $corr  = @($whea | Where-Object { $_.Level -ge 3 -and $_.Id -ne 17 })
    $pcie  = @($whea | Where-Object { $_.Level -ge 3 -and $_.Id -eq 17 })
    $bc124 = @(Get-Ev 'Microsoft-Windows-WER-SystemErrorReporting' @(1001) $since | Where-Object { $_.Message -match '0x00000124' })
    if ($fatal) {
        if ($bc124) { Rec 'Fatal hardware errors' 'FAIL' ("{0}, last {1:yyyy-MM-dd}; {2} matching blue screen(s) 0x124" -f $fatal.Count, $fatal[0].TimeCreated, $bc124.Count) 'Confirmed hardware crashes (CPU/RAM/board). Do not buy unless priced as faulty.' }
        else { Rec 'Fatal hardware errors' 'FAIL' ("{0}, last {1:yyyy-MM-dd}; no matching 0x124 blue screen recorded" -f $fatal.Count, $fatal[0].TimeCreated) 'Logged as fatal but no crash record: check the component below, run stress test 6 and look for new ones. On a store demo unit, ask for a sealed box.' }
    }
    if ($corr) { Rec 'Corrected CPU/RAM errors' 'WARN' ("{0}, last {1:yyyy-MM-dd}" -f $corr.Count, $corr[0].TimeCreated) 'A few at boot/wake on an old BIOS = firmware quirk; many, or new ones under stress test 6 = unstable hardware' }
    if ($pcie) { Rec 'PCIe corrected errors' 'INFO' "$($pcie.Count) (WHEA 17)" 'Common and usually benign (power-saving quirks); only worrying with crashes' }
    if (-not $whea) { Rec 'Hardware errors (WHEA)' 'OK' 'none logged' }
    foreach ($e in @($fatal + $corr | Sort-Object TimeCreated -Descending | Select-Object -First 5)) {
        $m = [string]$e.Message
        $comp = if ($m -match '(?m)^\s*(Reported by component|Component)\s*:\s*(.+?)\s*$') { $Matches[2] } else { '' }
        $src  = if ($m -match '(?m)^\s*Error Source\s*:\s*(.+?)\s*$') { $Matches[1] } else { '' }
        $typ  = if ($m -match '(?m)^\s*Error Type\s*:\s*(.+?)\s*$') { $Matches[1] } else { '' }
        if (-not $comp) { $comp = (($m -split "`n") | Where-Object { $_.Trim() } | Select-Object -First 1).Trim() }
        $sev = if ($e.Level -le 2) { 'fatal' } else { 'corrected' }
        $d = "{0:yyyy-MM-dd HH:mm}  id {1}  {2}  {3}" -f $e.TimeCreated, $e.Id, $sev, $comp
        if ($src) { $d += " ($src)" }
        if ($typ) { $d += " - $typ" }
        Rec 'WHEA event' 'INFO' $d
    }

    $bsod = Get-Ev 'Microsoft-Windows-WER-SystemErrorReporting' @(1001) $since
    $dumps = @(Get-ChildItem "$env:SystemRoot\Minidump" -Filter *.dmp)
    if ($bsod -or $dumps) {
        $hint = @{ '00000124' = 'hardware/WHEA'; '00000116' = 'GPU'; '00000117' = 'GPU'; '0000001a' = 'memory'; '00000050' = 'memory/driver'; '0000007a' = 'disk'; '00000077' = 'disk'; '0000009f' = 'driver power'; '000000ef' = 'critical process'; '00000101' = 'CPU'; '0000003b' = 'driver' }
        $codes = @($bsod | ForEach-Object { if ($_.Message -match '0x([0-9a-fA-F]{8})') { $Matches[1].ToLower() } } | Group-Object | Sort-Object Count -Descending | Select-Object -First 4 | ForEach-Object {
            $h = $hint[$_.Name]; if ($h) { "0x$($_.Name) x$($_.Count) ($h)" } else { "0x$($_.Name) x$($_.Count)" } })
        $n = [math]::Max($bsod.Count, $dumps.Count)
        $st = if ($n -gt 3) { 'FAIL' } else { 'WARN' }
        Rec 'Blue screens' $st ("{0} crash(es); {1}" -f $n, ($codes -join ', ')) 'Repeated crashes with the same code point at that part'
    } else { Rec 'Blue screens' 'OK' 'none logged' }

    $kp = Get-Ev 'Microsoft-Windows-Kernel-Power' @(41) $since
    if ($kp.Count -ge 10) { Rec 'Unexpected shutdowns' 'WARN' "$($kp.Count) (Kernel-Power 41)" 'Hard power-offs: crashes, overheating or a bad battery/charger (also counts forced power-button offs)' }
    elseif ($kp.Count -gt 0) { Rec 'Unexpected shutdowns' 'INFO' "$($kp.Count) (Kernel-Power 41)" }
    else { Rec 'Unexpected shutdowns' 'OK' 'none' }

    $bb = Get-Ev 'disk' @(7) $since @(1, 2, 3)
    if ($bb) { Rec 'Disk bad blocks' 'FAIL' "$($bb.Count) (disk event 7)" 'The drive has bad sectors' }
    $lv = @(1, 2, 3)
    $dio = @(Get-Ev 'disk' @(51, 153) $since $lv) + @(Get-Ev @('Ntfs', 'Microsoft-Windows-Ntfs') @(55, 98) $since $lv) + @(Get-Ev 'stornvme' @(11) $since $lv)
    $dio = @($dio | Where-Object { $_ })
    if ($dio.Count -gt 3) { Rec 'Disk/filesystem errors' 'WARN' "$($dio.Count) (disk 51/153, Ntfs 55/98, stornvme 11)" 'I/O retries or file-system corruption; watch the disk health lines above' }
    elseif ($dio) { Rec 'Disk/filesystem errors' 'INFO' "$($dio.Count) (disk 51/153, Ntfs 55/98, stornvme 11)" 'A few retries happen; many are a bad sign' }
    if (-not $bb -and -not $dio) { Rec 'Disk errors' 'OK' 'none logged' }

    $tdr = Get-Ev 'Display' @(4101) $since
    if ($tdr.Count -gt 5) { Rec 'GPU driver resets' 'WARN' "$($tdr.Count) (Display 4101)" 'Graphics driver keeps crashing/recovering - GPU or driver trouble' }
    elseif ($tdr.Count -gt 0) { Rec 'GPU driver resets' 'INFO' "$($tdr.Count) (Display 4101)" }

    $thr = Get-Ev 'Microsoft-Windows-Kernel-Processor-Power' @(37) $since
    if ($thr.Count -gt 0) { Rec 'Firmware CPU limiting' 'INFO' "$($thr.Count) events (Kernel-Processor-Power 37)" 'Normal on battery; many on AC hints at heat - see the stress test' }
}

# ---------------------------------------------------------------- tampering

function Test-Tamper {
    $cpuW = ([string](@(Get-CimInstance Win32_Processor)[0].Name)).Trim()
    $cpuR = ([string](Get-ItemProperty 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0').ProcessorNameString).Trim()
    if ($cpuR -and $cpuW -and $cpuR -ne $cpuW) { Rec 'CPU name' 'FAIL' "Registry says '$cpuR', WMI says '$cpuW'" 'Faked CPU name - a known scam. Check the CPU in the BIOS screen.' }

    $lines = @()
    $runKeys = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce',
                 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
                 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce')
    foreach ($k in $runKeys) {
        $p = Get-ItemProperty $k
        if ($p) { $p.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' } | ForEach-Object { $lines += "Run $($_.Name) = $($_.Value)" } }
    }
    foreach ($dir in @("$env:ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp", "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup")) {
        Get-ChildItem $dir -File | ForEach-Object {
            $t = ''; if ($_.Length -lt 1MB -and $_.Extension -match '\.(bat|cmd|ps1|vbs|js|reg|txt)$') { $t = [IO.File]::ReadAllText($_.FullName) }
            $lines += "Startup $($_.Name) $t"
        }
    }
    foreach ($t in @(Get-ScheduledTask)) {
        $acts = @($t.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -join ' ; '
        $lines += "Task $($t.TaskPath)$($t.TaskName) -> $acts"
    }
    $fake = @($lines | Where-Object { $_ -match 'ProcessorNameString|CentralProcessor' })
    if ($fake) { Rec 'CPU name rewriter' 'FAIL' (($fake | Select-Object -First 2) -join ' | ') 'Something rewrites the CPU name at startup: the advertised CPU is fake' }
    else { Rec 'Spec faking' 'OK' 'No startup item rewrites the CPU name' }

    $kms = @($lines | Where-Object { $_ -match 'KMS|AutoPico|KMSpico|KMSAuto|SECOH|AAct|kms_vl|HWIDGen|Activator' })
    foreach ($f in @("$env:SystemRoot\KMSAutoS", "$env:ProgramData\KMSAutoS", "$env:ProgramData\KMSAuto", "$env:ProgramFiles\KMSpico", "${env:ProgramFiles(x86)}\KMSpico",
                     "$env:SystemRoot\AAct_Tools", "$env:SystemRoot\SECOH-QAD.exe", "$env:SystemRoot\SECOH-QAD.dll", "$env:SystemRoot\System32\SppExtComObjHook.dll", "$env:SystemRoot\System32\SppExtComObjPatcher.exe")) {
        if (Test-Path $f) { $kms += $f }
    }
    if ($kms) { Rec 'Pirate activator' 'WARN' (($kms | Select-Object -First 3) -join ' | ') 'Windows/Office activated with a crack. Do a clean reset; such tools often bundle malware.' }

    $oem = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OEMInformation'
    $fw = ([string](Get-CimInstance Win32_ComputerSystem).Model).Trim()
    $fwFriendly = ([string](Get-CimInstance Win32_ComputerSystemProduct).Version).Trim()
    if ($oem -and $oem.Model) {
        $m = ([string]$oem.Model).Trim()
        $match = ($fw -and ($m -like "*$fw*" -or $fw -like "*$m*")) -or ($fwFriendly -and ($m -like "*$fwFriendly*" -or $fwFriendly -like "*$m*"))
        if (-not $match) { Rec 'OEM branding' 'INFO' "System Properties says '$m', firmware says '$fw'" 'Mismatch can be harmless, or a relabelled cheaper model. Trust the firmware/sticker.' }
    }
}

# ---------------------------------------------------------------- interactive UI (compiled on demand)

$script:ProberCs = @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public class ProberKeys : Form {
    [DllImport("user32.dll")] static extern short GetAsyncKeyState(int vKey);
    static string[] Rows = {
        "1B:Esc 70:F1 71:F2 72:F3 73:F4 74:F5 75:F6 76:F7 77:F8 78:F9 79:F10 7A:F11 7B:F12 2E:Del",
        "C0:` 31:1 32:2 33:3 34:4 35:5 36:6 37:7 38:8 39:9 30:0 BD:- BB:= 08:Bksp:2",
        "09:Tab:1.5 51:Q 57:W 45:E 52:R 54:T 59:Y 55:U 49:I 4F:O 50:P DB:[ DD:] DC:\\:1.5",
        "14:Caps:1.75 41:A 53:S 44:D 46:F 47:G 48:H 4A:J 4B:K 4C:L BA:; DE:' 0D:Enter:2.25",
        "A0:LShift:2.25 5A:Z 58:X 43:C 56:V 42:B 4E:N 4D:M BC:, BE:. BF:/ A1:RShift:2.75",
        "A2:LCtrl:1.5 5B:Win A4:LAlt:1.25 20:Space:5 A5:RAlt:1.25 A3:RCtrl:1.25 25:Left 26:Up 28:Down 27:Right",
        "2C:PrtSc 2D:Ins 24:Home 23:End 21:PgUp 22:PgDn 5D:Menu"
    };
    class K { public int Vk; public string Label; public RectangleF R; }
    List<K> keys = new List<K>();
    HashSet<int> seen = new HashSet<int>();
    List<string> extra = new List<string>();
    string last = "-";

    public ProberKeys() {
        Text = "prober keyboard test - press every key, then close this window (Fn keys are not testable here)";
        BackColor = Color.FromArgb(20, 20, 20);
        DoubleBuffered = true; KeyPreview = true; TopMost = true;
        StartPosition = FormStartPosition.CenterScreen;
        FormBorderStyle = FormBorderStyle.FixedDialog; MaximizeBox = false;
        float u = 62f, y = 20f;
        foreach (string row in Rows) {
            float x = 20f;
            foreach (string tok in row.Split(' ')) {
                string[] p = tok.Split(':');
                float w = p.Length > 2 ? float.Parse(p[2], System.Globalization.CultureInfo.InvariantCulture) : 1f;
                K k = new K();
                k.Vk = Convert.ToInt32(p[0], 16); k.Label = p[1];
                k.R = new RectangleF(x, y, w * u - 6f, u - 8f);
                keys.Add(k);
                x += w * u;
            }
            y += u;
        }
        ClientSize = new Size(1000, (int)y + 50);
    }
    protected override void OnShown(EventArgs e) { base.OnShown(e); Activate(); }
    void Hit(int vk) {
        if (vk == 0x10) vk = GetAsyncKeyState(0xA1) < 0 ? 0xA1 : 0xA0;
        else if (vk == 0x11) { if (GetAsyncKeyState(0xA5) < 0) return; vk = GetAsyncKeyState(0xA3) < 0 ? 0xA3 : 0xA2; }
        else if (vk == 0x12) vk = GetAsyncKeyState(0xA5) < 0 ? 0xA5 : 0xA4;
        else if (vk == 0x5C) vk = 0x5B;
        seen.Add(vk);
        bool known = false;
        foreach (K k in keys) if (k.Vk == vk) { known = true; last = k.Label; }
        if (!known) { string n = ((Keys)vk).ToString(); last = n; if (!extra.Contains(n)) extra.Add(n); }
        Invalidate();
    }
    protected override bool ProcessCmdKey(ref Message msg, Keys keyData) { Hit((int)(keyData & Keys.KeyCode)); return true; }
    protected override void OnKeyDown(KeyEventArgs e) { Hit(e.KeyValue); e.Handled = true; e.SuppressKeyPress = true; }
    protected override void OnKeyUp(KeyEventArgs e) { if (e.KeyCode == Keys.PrintScreen) Hit(0x2C); }
    protected override void WndProc(ref Message m) {
        if (m.Msg == 0x0112 && (m.WParam.ToInt64() & 0xFFF0) == 0xF100) return; // swallow Alt menu activation
        base.WndProc(ref m);
    }
    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics;
        StringFormat sf = new StringFormat(); sf.Alignment = StringAlignment.Center; sf.LineAlignment = StringAlignment.Center;
        using (Font f = new Font("Segoe UI", 11f))
        using (Font small = new Font("Consolas", 10f))
        using (SolidBrush off = new SolidBrush(Color.FromArgb(48, 48, 48)))
        using (SolidBrush on = new SolidBrush(Color.FromArgb(46, 160, 90)))
        using (Pen offP = new Pen(Color.FromArgb(90, 90, 90)))
        using (Pen onP = new Pen(Color.FromArgb(140, 230, 160))) {
            int done = 0;
            foreach (K k in keys) {
                bool s = seen.Contains(k.Vk);
                if (s) done++;
                g.FillRectangle(s ? on : off, k.R);
                g.DrawRectangle(s ? onP : offP, k.R.X, k.R.Y, k.R.Width, k.R.Height);
                g.DrawString(k.Label, f, s ? Brushes.White : Brushes.Gainsboro, k.R, sf);
            }
            string st = done + "/" + keys.Count + " keys   last: " + last;
            if (extra.Count > 0) st += "   other: " + string.Join(", ", extra.ToArray());
            g.DrawString(st, small, Brushes.Gainsboro, 20, ClientSize.Height - 38);
        }
    }
    public string[] Missing() { List<string> m = new List<string>(); foreach (K k in keys) if (!seen.Contains(k.Vk)) m.Add(k.Label); return m.ToArray(); }
    public string[] Extra() { return extra.ToArray(); }
}

public class ProberColors : Form {
    Color[] cols = { Color.Black, Color.White, Color.FromArgb(255, 0, 0), Color.FromArgb(0, 255, 0), Color.FromArgb(0, 0, 255), Color.FromArgb(128, 128, 128) };
    int i = 0;
    public ProberColors() {
        FormBorderStyle = FormBorderStyle.None; WindowState = FormWindowState.Maximized;
        TopMost = true; BackColor = cols[0]; KeyPreview = true;
    }
    protected override void OnShown(EventArgs e) { base.OnShown(e); Activate(); Cursor.Hide(); }
    protected override void OnFormClosed(FormClosedEventArgs e) { Cursor.Show(); base.OnFormClosed(e); }
    protected override void OnKeyDown(KeyEventArgs e) { if (e.KeyCode == Keys.Escape) Close(); else Next(); }
    protected override void OnMouseDown(MouseEventArgs e) { Next(); }
    void Next() { i++; if (i >= cols.Length) { Close(); return; } BackColor = cols[i]; }
}

public static class ProberAudio {
    public static byte[] StereoTone() {
        int rate = 44100, n = rate, gap = rate / 4, frames = n + gap + n, dataLen = frames * 4;
        MemoryStream ms = new MemoryStream(); BinaryWriter w = new BinaryWriter(ms);
        w.Write(new char[] { 'R', 'I', 'F', 'F' }); w.Write(36 + dataLen); w.Write(new char[] { 'W', 'A', 'V', 'E' });
        w.Write(new char[] { 'f', 'm', 't', ' ' }); w.Write(16); w.Write((short)1); w.Write((short)2);
        w.Write(rate); w.Write(rate * 4); w.Write((short)4); w.Write((short)16);
        w.Write(new char[] { 'd', 'a', 't', 'a' }); w.Write(dataLen);
        for (int t = 0; t < frames; t++) {
            short l = 0, r = 0;
            if (t < n) l = S(t, 440, n, rate);
            else if (t >= n + gap) r = S(t - n - gap, 660, n, rate);
            w.Write(l); w.Write(r);
        }
        w.Flush(); return ms.ToArray();
    }
    static short S(int t, double hz, int n, int rate) {
        double env = Math.Min(1.0, Math.Min(t, n - t) / (rate * 0.02));
        return (short)(Math.Sin(2 * Math.PI * hz * t / rate) * 12000 * env);
    }
}
'@

# Benchmark page: same code in Edge (laptop) and Chromium (your PC) = comparable numbers.
# BASE is the reference PC; refresh it with `node tools/ref.ts` on that PC.
$script:BenchHtml = @'
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>prober bench</title>
<style>
:root{--bg:#0e1011;--fg:#d6d8d4;--dim:#8a918d;--line:#2a2f31;--acc:#7fb4ca;--ok:#3fb950;--warn:#d29922;--bad:#f85149}
body{background:var(--bg);color:var(--fg);font:15px/1.5 Consolas,"Cascadia Mono",monospace;margin:0;padding:24px 16px}
main{max-width:760px;margin:0 auto}h1{font-size:20px;margin:0 0 4px}.sub{color:var(--dim)}
table{border-collapse:collapse;width:100%;margin:18px 0}td,th{padding:6px 8px;border-bottom:1px solid var(--line);text-align:right;vertical-align:top}
td:first-child,th:first-child{text-align:left}th{color:var(--dim);font-weight:normal}
.bar{height:6px;background:var(--line);margin-top:4px}.bar i{display:block;height:6px}
textarea{width:100%;box-sizing:border-box;background:#15191a;color:var(--fg);border:1px solid var(--line);font:inherit;padding:8px;height:70px}
button{background:var(--acc);color:#0e1011;border:0;padding:8px 14px;font:inherit;cursor:pointer}
</style></head><body><main>
<h1>prober bench</h1>
<div class="sub" id="status">Keep this tab in front and the charger plugged in. About 30 seconds.</div>
<table><thead><tr><th>test</th><th>this machine</th><th>reference</th><th>vs reference</th></tr></thead><tbody id="rows"></tbody></table>
<div class="sub" id="info"></div>
<p class="sub">Result line - copy it and paste it into the prober window:</p>
<textarea id="line" readonly></textarea>
<p><button id="copy">Copy result line</button></p>
</main>
<script>
const BASE = {"cpu1":389.48,"cpuN":10533.75,"mem":34.28,"gpu":692.93,"name":"my PC","date":"2026-11-19"};
const TESTS = [['cpu1', 'CPU single-core', 'Mops/s'], ['cpuN', 'CPU all cores', 'Mops/s'], ['mem', 'Memory copy', 'GB/s'], ['gpu', 'GPU shader', 'Giter/s']];
const WORK = 'function work(ms){let x=1|0,f=1.0,n=0;const a=new Float64Array(4096);const end=performance.now()+ms;' +
  'while(performance.now()<end){for(let i=0;i<50000;i++){x=(Math.imul(x,1103515245)+12345)|0;f=f*0.999999+(x>>>16)*1e-7;a[i&4095]+=f;}n+=50000;}' +
  'return {ops:n/ms/1000,chk:a[7]+f};}';
const work = new Function(WORK + ';return work;')();
const R = {};
const $ = id => document.getElementById(id);
const tick = () => new Promise(r => setTimeout(r, 60));
const status = s => { $('status').textContent = s; };
const fmt = v => v >= 100 ? v.toFixed(0) : v >= 10 ? v.toFixed(1) : v.toFixed(2);
const pct = k => BASE && BASE[k] && R[k] ? Math.round(R[k] / BASE[k] * 100) : null;
const word = p => p >= 110 ? 'faster' : p >= 90 ? 'on par' : p >= 60 ? 'a bit slower' : p >= 30 ? 'much slower' : 'far slower';

function multi(ms) {
  const n = navigator.hardwareConcurrency || 4;
  const url = URL.createObjectURL(new Blob([WORK + ';onmessage=e=>{work(200);postMessage(work(e.data).ops)}'], { type: 'text/javascript' }));
  return Promise.all(Array.from({ length: n }, () => new Promise(res => {
    let w; try { w = new Worker(url); } catch (e) { res(0); return; }
    w.onmessage = e => { res(e.data); w.terminate(); }; w.onerror = () => res(0); w.postMessage(ms);
  }))).then(v => v.reduce((a, b) => a + b, 0));
}

function mem(ms) {
  const N = 8 * 1024 * 1024; let a, b;
  try { a = new Float64Array(N); b = new Float64Array(N); } catch (e) { return 0; }
  for (let i = 0; i < N; i += 512) a[i] = i;
  b.set(a); let n = 0, t; const t0 = performance.now();
  do { b.set(a); a.set(b); n += 2; t = performance.now() - t0; } while (t < ms);
  return n * N * 8 * 2 / (t / 1000) / 1e9;
}

function gpu(ms) {
  const ITER = 64, c = document.createElement('canvas'); c.width = 1920; c.height = 1080;
  const gl = c.getContext('webgl2', { antialias: false, powerPreference: 'high-performance' });
  if (!gl) return { v: 0, name: 'no WebGL2' };
  const ext = gl.getExtension('WEBGL_debug_renderer_info');
  const name = String(ext ? gl.getParameter(ext.UNMASKED_RENDERER_WEBGL) : gl.getParameter(gl.RENDERER));
  const sh = (type, src) => { const s = gl.createShader(type); gl.shaderSource(s, src); gl.compileShader(s); return s; };
  const pr = gl.createProgram();
  gl.attachShader(pr, sh(gl.VERTEX_SHADER, '#version 300 es\nin vec2 p;void main(){gl_Position=vec4(p,0,1);}'));
  gl.attachShader(pr, sh(gl.FRAGMENT_SHADER, '#version 300 es\nprecision highp float;uniform float k;out vec4 o;void main(){vec2 p=gl_FragCoord.xy*0.0005;float v=0.0;' +
    'for(int i=0;i<' + ITER + ';i++){p=vec2(p.x*p.x-p.y*p.y,2.0*p.x*p.y)+vec2(0.28+k,0.51);p=clamp(p,-2.0,2.0);v+=p.x*p.y;}o=vec4(v,p,1);}'));
  gl.linkProgram(pr);
  if (!gl.getProgramParameter(pr, gl.LINK_STATUS)) return { v: 0, name: name + ' (shader failed)' };
  gl.useProgram(pr);
  gl.bindBuffer(gl.ARRAY_BUFFER, gl.createBuffer());
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
  gl.enableVertexAttribArray(0); gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);
  gl.viewport(0, 0, c.width, c.height);
  const kl = gl.getUniformLocation(pr, 'k'), px = new Uint8Array(4);
  const draw = n => { for (let i = 0; i < n; i++) { gl.uniform1f(kl, Math.random() * 1e-3); gl.drawArrays(gl.TRIANGLES, 0, 3); } gl.readPixels(0, 0, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, px); };
  draw(2);
  let k = 1, t0 = performance.now(); draw(k); let dt = performance.now() - t0;
  while (dt < 100 && k < 4096) { k *= 2; t0 = performance.now(); draw(k); dt = performance.now() - t0; }
  let draws = 0; t0 = performance.now();
  do { draw(k); draws += k; dt = performance.now() - t0; } while (dt < ms);
  return { v: draws * c.width * c.height * ITER / (dt / 1000) / 1e9, name };
}

function show() {
  $('rows').innerHTML = TESTS.map(([k, label, unit]) => {
    const p = pct(k), col = p == null ? 'var(--acc)' : p >= 90 ? 'var(--ok)' : p >= 50 ? 'var(--warn)' : 'var(--bad)';
    const bar = p == null ? '' : '<div class="bar"><i style="width:' + Math.min(p, 100) + '%;background:' + col + '"></i></div>';
    return '<tr><td>' + label + '</td><td>' + (R[k] == null ? '...' : fmt(R[k]) + ' ' + unit) + '</td><td>' +
      (BASE && BASE[k] ? fmt(BASE[k]) : '-') + '</td><td>' + (p == null ? '-' : p + '% <span class="sub">' + word(p) + '</span>' + bar) + '</td></tr>';
  }).join('');
}

async function run() {
  show(); await tick();
  status('CPU single-core...'); await tick(); work(300); R.cpu1 = work(2500).ops; show();
  status('CPU all cores...'); await tick(); R.cpuN = await multi(3000); show();
  status('Memory...'); await tick(); R.mem = mem(2000); show();
  status('GPU...'); await tick(); const g = gpu(3000); R.gpu = g.v; R.gpuName = g.name; show();
  R.threads = navigator.hardwareConcurrency || 0;
  const raw = TESTS.map(([k]) => k + '=' + fmt(R[k] || 0)).join(' ');
  const vs = BASE ? ' | vs ref: ' + TESTS.map(([k]) => k + ' ' + (pct(k) == null ? '-' : pct(k) + '%')).join(' ') : '';
  const line = 'prober-bench ' + raw + vs + ' | ' + R.threads + ' threads | gpu: ' + R.gpuName;
  $('line').value = line;
  $('info').textContent = 'GPU: ' + R.gpuName + ' - threads: ' + R.threads + (BASE ? ' - reference: ' + BASE.name + ' (' + BASE.date + ')' : ' - no reference set');
  if (!/Chrome|Edg/.test(navigator.userAgent)) $('info').textContent += ' - NOTE: not a Chromium browser, compare with care';
  status('Done.');
  if (/^https?:$/.test(location.protocol) && location.hostname === '127.0.0.1') fetch('/result', { method: 'POST', body: JSON.stringify(R) });
}
$('copy').onclick = () => {
  const t = $('line'); t.select();
  (navigator.clipboard ? navigator.clipboard.writeText(t.value) : Promise.reject()).catch(() => document.execCommand('copy'));
  $('copy').textContent = 'Copied';
};
setTimeout(run, 400);
</script></body></html>
'@

function Load-UI {
    if ('ProberKeys' -as [type]) { return $true }
    try {
        Add-Type -AssemblyName System.Windows.Forms, System.Drawing
        Add-Type -TypeDefinition $script:ProberCs -ReferencedAssemblies System.Windows.Forms, System.Drawing -ErrorAction Stop
        [System.Windows.Forms.Application]::EnableVisualStyles()
        return $true
    } catch { Write-Host "  Could not build the test windows: $($_.Exception.Message)" -ForegroundColor Red; return $false }
}

function Ask-Result([string]$Item, [string]$Question, [string]$FailAdvice) {
    $a = Read-Host "  $Question [y = fine / n = problem / Enter = skip]"
    if ($a -match '^y') { Rec $Item 'OK' 'checked by you: fine' }
    elseif ($a -match '^n') { $note = Read-Host '  What was wrong? (short note)'; Rec $Item 'FAIL' ("checked by you: " + $note) $FailAdvice }
    else { Rec $Item 'SKIP' 'not checked' }
}

function Test-Screen {
    if (-not (Load-UI)) { return }
    Write-Host '  Full-screen colours: black, white, red, green, blue, grey. Click or press a key to advance, Esc to quit.'
    Write-Host '  Look for: dead/stuck dots, bright patches at the edges on black (backlight bleed), blotches or lines.'
    [void](Read-Host '  Press Enter to start')
    $f = New-Object ProberColors; [void]$f.ShowDialog(); $f.Dispose()
    Ask-Result 'Screen' 'Was every colour clean and even?' 'Panel defects: price in a replacement panel or walk away'
}

function Test-Keyboard {
    if (-not (Load-UI)) { return }
    Write-Host '  Press every key once (both Shifts, both Ctrls, arrows...). Keys light up green. Close the window when done.'
    $f = New-Object ProberKeys; [void]$f.ShowDialog()
    $miss = @($f.Missing()); $ex = @($f.Extra()); $f.Dispose()
    $exTxt = ''; if ($ex) { $exTxt = '; also seen: ' + ($ex -join ', ') }
    if ($miss.Count -eq 0) { Rec 'Keyboard' 'OK' ("all keys registered" + $exTxt) }
    else { Rec 'Keyboard' 'WARN' ("not registered: {0}{1}" -f ($miss -join ' '), $exTxt) 'Some may not exist on this layout (Ins, Menu, RCtrl). A key you pressed that stayed grey is dead.' }
    Write-Host '  Now test the Fn keys by hand (brightness, volume, mute, keyboard backlight).'
    Ask-Result 'Fn keys / backlight' 'Did the Fn keys and keyboard backlight work?' 'Broken Fn keys usually mean a missing vendor driver - or a bad keyboard'
}

function Test-Speakers {
    if (-not (Load-UI)) { return }
    Write-Host '  Playing a low tone on the LEFT, then a higher tone on the RIGHT. Turn the volume up.'
    $bytes = [ProberAudio]::StereoTone()
    $ms = New-Object System.IO.MemoryStream (, $bytes)
    $sp = New-Object System.Media.SoundPlayer $ms
    $sp.PlaySync(); Start-Sleep -Milliseconds 400; $ms.Position = 0; $sp.PlaySync()
    Ask-Result 'Speakers' 'Heard left then right, clean, no rattle or crackle?' 'Blown/rattling speaker or one channel dead'
}

function Test-Camera {
    Write-Host '  Opening the Camera app. Check the image is sharp and not dark/pink; then close it.'
    Start-Process 'microsoft.windows.camera:'
    Ask-Result 'Webcam' 'Did the camera show a clear image?' 'Check for a privacy shutter or camera kill-switch key first'
}

function Test-Mic {
    Write-Host '  Opening Sound settings. Talk and watch the input level bar move (Input > Microphone).'
    Start-Process 'ms-settings:sound'
    Ask-Result 'Microphone' 'Did the input level react to your voice?' 'Dead mic; a USB/headset mic is the workaround'
}

function Test-Stress {
    param([int]$Seconds = 60)
    $ps0 = $null; Add-Type -AssemblyName System.Windows.Forms; $ps0 = [System.Windows.Forms.SystemInformation]::PowerStatus
    if ($ps0.PowerLineStatus -ne 'Online') { Write-Host '  Note: on battery - plug in the charger for a fair result.' -ForegroundColor Yellow }
    Write-Host "  Loading every CPU thread for $Seconds s. Listen for the fans ramping up. Ctrl+C is safe (workers stop on their own)."
    $base = [double](@(Get-CimInstance Win32_Processor)[0].MaxClockSpeed)
    $work = 'param($s) $end = [DateTime]::UtcNow.AddSeconds($s); $x = 0.0; while ([DateTime]::UtcNow -lt $end) { for ($i = 0; $i -lt 20000; $i++) { $x = [Math]::Sqrt($x + $i) } }'
    $pool = @()
    for ($i = 0; $i -lt [Environment]::ProcessorCount; $i++) {
        $p = [powershell]::Create(); [void]$p.AddScript($work).AddArgument($Seconds)
        $pool += [pscustomobject]@{ P = $p; H = $p.BeginInvoke() }
    }
    $samples = @(); $t0 = Get-Date
    try {
        while (((Get-Date) - $t0).TotalSeconds -lt $Seconds) {
            Start-Sleep -Seconds 2
            $c = Get-CimInstance Win32_PerfFormattedData_Counters_ProcessorInformation -Filter "Name='_Total'"
            $util = $c.PercentProcessorUtility; if ($util -eq $null) { $util = $c.PercentProcessorTime }
            $perf = [double]$c.PercentProcessorPerformance
            $temp = $null; if ($script:IsAdmin) { $temp = Get-Temps }
            $s = [pscustomobject]@{ T = [int]((Get-Date) - $t0).TotalSeconds; Perf = $perf; Util = [double]$util; Temp = $temp }
            $samples += $s
            $tt = ''; if ($temp -ne $null) { $tt = "  $temp C" }
            Write-Host ("`r  {0,3}s  load {1,3}%  clock ~{2,4} MHz ({3,3}% of base){4}     " -f $s.T, [int]$s.Util, [int]($base * $perf / 100), [int]$perf, $tt) -NoNewline
        }
    } finally {
        foreach ($w in $pool) { try { $w.P.Stop(); $w.P.Dispose() } catch {} }
        Write-Host ''
    }
    if ($samples.Count -lt 6) { Rec 'CPU under load' 'SKIP' 'too few samples'; return }
    $peak = ($samples | Select-Object -First 7 | Measure-Object -Property Perf -Maximum).Maximum
    $tail = ($samples | Select-Object -Last 7 | Measure-Object -Property Perf -Average).Average
    $util = ($samples | Measure-Object -Property Util -Average).Average
    $mx = ($samples | Where-Object { $_.Temp -ne $null } | Measure-Object -Property Temp -Maximum).Maximum
    $d = "peak ~{0} MHz, after {1}s ~{2} MHz, avg load {3}%" -f [int]($base * $peak / 100), $Seconds, [int]($base * $tail / 100), [int]$util
    if ($mx) { $d += ", max $mx C" }
    if ($peak -gt 0 -and $tail / $peak -lt 0.65) { Rec 'CPU under load' 'WARN' $d 'Clock collapses under sustained load: dust, dried thermal paste or a weak fan (or on battery). Ask when it was last cleaned.' }
    elseif ($mx -ge 98) { Rec 'CPU under load' 'WARN' $d 'Hitting thermal limit' }
    else { Rec 'CPU under load' 'OK' $d }
    Ask-Result 'Fans' 'Did the fans spin up without grinding or rattling?' 'Worn fan bearing or no fan: overheating risk'
}

function Test-Bench {
    $dir = Get-OutDir
    if (-not $dir) { Rec 'Benchmark' 'SKIP' 'no folder to write the page to'; return }
    $f = Join-Path $dir 'bench.html'
    [IO.File]::WriteAllText($f, $script:BenchHtml, (New-Object System.Text.UTF8Encoding $false))
    Write-Host '  Opening the benchmark in Edge (about 30 s): CPU, memory, GPU vs your reference PC.'
    Write-Host '  Keep its tab in front and the charger plugged in.'
    try { Start-Process 'msedge.exe' -ArgumentList ('"' + $f + '"') -ErrorAction Stop } catch { Start-Process $f }
    $line = Read-Host '  When it says Done: click "Copy result line", paste it here (right-click or Ctrl+V), Enter'
    if ($line -match 'prober-bench') {
        Rec 'Benchmark' 'INFO' $line.Trim() 'Percentages compare against the reference PC baked into the page'
        if ($line -match 'vs ref: ([^|]+)') { $script:Spec['vs my PC'] = $Matches[1].Trim() }
    } else { Rec 'Benchmark' 'SKIP' 'no result pasted' }
}

# ---------------------------------------------------------------- report

$script:Checklist = @(
    'Serial on the bottom sticker matches the serial in this report',
    'BIOS/UEFI setup (F2 / F1 / Del / Esc at power-on): no password prompt; the CPU and RAM shown there match',
    'Hinges: lid holds any angle, no creaking or cracks at the hinge mounts, lid closes evenly',
    'Chassis: no cracks, bulges or gaps (a swollen battery lifts the touchpad or bottom panel); screws present and not chewed',
    'Liquid damage: sticky keys, stains or corrosion around ports and keyboard',
    'Touchpad: left/right click, two-finger scroll, no cursor jumping',
    'Every USB port with a stick or mouse; USB-C charging/display if advertised; HDMI; headphone jack; card reader',
    'Charger: original or correct wattage, cable not frayed or taped; laptop keeps running when unplugged',
    'Wi-Fi connects (use your phone hotspot); Bluetooth finds your phone',
    'Screen at low brightness: no flicker; at full brightness: no yellow patches or pressure marks',
    'Ask: receipt/invoice, why selling, repairs done, warranty left',
    'Before paying: watch a full reset (Settings > System > Recovery > Reset this PC > Remove everything). At first setup connect to Wi-Fi - a company sign-in page means Autopilot-locked: do not buy',
    'Delete the prober report folder from their machine after you copy it'
)

function Get-OutDir {
    if ($script:OutDir) { return $script:OutDir }
    $name = ('prober-{0}-{1}' -f $script:Serial, (Get-Date -Format 'yyyyMMdd-HHmm')) -replace '[^\w\-\.]', '_'
    foreach ($b in @($script:ScriptDir, [Environment]::GetFolderPath('Desktop'), $env:TEMP)) {
        if (-not $b) { continue }
        $d = Join-Path $b $name
        try { New-Item -ItemType Directory -Path $d -Force -ErrorAction Stop | Out-Null; $script:OutDir = $d; return $d } catch {}
    }
    return $null
}

function HtmlEnc([string]$s) { [System.Net.WebUtility]::HtmlEncode($s) }  # not 'H': h is an alias for Get-History

function Save-Report {
    $dir = Get-OutDir
    if (-not $dir) { Write-Host '  Could not create a report folder.' -ForegroundColor Red; return }
    $bat = Join-Path $dir 'battery-report.html'
    if (-not (Test-Path $bat)) { & powercfg.exe /batteryreport /output "$bat" 2>&1 | Out-Null }

    $fails = @($script:Results | Where-Object { $_.Status -eq 'FAIL' })
    $warns = @($script:Results | Where-Object { $_.Status -eq 'WARN' })
    $verdict = if ($fails) { 'RED FLAGS FOUND' } elseif ($warns) { 'MOSTLY OK - check the warnings' } else { 'LOOKS CLEAN' }
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm'

    # text
    $t = New-Object System.Text.StringBuilder
    [void]$t.AppendLine("prober $script:ProberVersion - $stamp - admin: $script:IsAdmin")
    [void]$t.AppendLine("VERDICT: $verdict ($($fails.Count) fail, $($warns.Count) warn)")
    [void]$t.AppendLine('')
    foreach ($k in $script:Spec.Keys) { [void]$t.AppendLine(('{0,-9} {1}' -f $k, $script:Spec[$k])) }
    $sec = ''
    foreach ($r in $script:Results) {
        if ($r.Section -ne $sec) { $sec = $r.Section; [void]$t.AppendLine(''); [void]$t.AppendLine("== $sec ==") }
        [void]$t.AppendLine(('[{0,-4}] {1}: {2}' -f $r.Status, $r.Item, $r.Detail))
        if ($r.Advice) { [void]$t.AppendLine("       -> $($r.Advice)") }
    }
    [void]$t.AppendLine(''); [void]$t.AppendLine('== Check by hand ==')
    foreach ($c in $script:Checklist) { [void]$t.AppendLine("[ ] $c") }
    [IO.File]::WriteAllText((Join-Path $dir 'report.txt'), $t.ToString(), (New-Object System.Text.UTF8Encoding $false))

    # html
    $css = 'body{background:#0e1011;color:#d6d8d4;font:14px/1.5 Consolas,"Cascadia Mono",monospace;margin:0;padding:24px 16px}main{max-width:960px;margin:0 auto}' +
           'h1{font-size:20px;margin:0 0 4px}h2{font-size:15px;color:#7fb4ca;border-bottom:1px solid #2a2f31;padding-bottom:4px;margin:28px 0 8px}' +
           '.sub{color:#8a918d}.verdict{margin:16px 0;padding:12px 14px;border:1px solid #2a2f31;font-weight:bold}.v-FAIL{border-color:#f85149;color:#f85149}.v-WARN{border-color:#d29922;color:#d29922}.v-OK{border-color:#3fb950;color:#3fb950}' +
           'table{border-collapse:collapse;width:100%}td{padding:4px 8px;vertical-align:top;border-bottom:1px solid #1d2123}td.k{color:#8a918d;white-space:nowrap;width:1%}' +
           '.s{display:inline-block;min-width:40px;text-align:center;font-weight:bold}.OK{color:#3fb950}.WARN{color:#d29922}.FAIL{color:#f85149}.INFO{color:#8a918d}.SKIP{color:#5c6360}' +
           '.adv{color:#7fb4ca;font-size:13px}label{display:block;padding:3px 0}a{color:#7fb4ca}'
    $vclass = if ($fails) { 'v-FAIL' } elseif ($warns) { 'v-WARN' } else { 'v-OK' }
    $h = New-Object System.Text.StringBuilder
    [void]$h.Append("<!doctype html><html lang=""en""><head><meta charset=""utf-8""><meta name=""viewport"" content=""width=device-width,initial-scale=1""><title>prober $(HtmlEnc $script:Serial)</title><style>$css</style></head><body><main>")
    [void]$h.Append("<h1>prober &mdash; $(HtmlEnc $script:Spec['Model'])</h1><div class=""sub"">$stamp &middot; serial $(HtmlEnc $script:Serial) &middot; admin: $script:IsAdmin &middot; v$script:ProberVersion</div>")
    [void]$h.Append("<div class=""verdict $vclass"">$(HtmlEnc $verdict) &mdash; $($fails.Count) fail, $($warns.Count) warn</div>")
    [void]$h.Append('<h2>Spec sheet (compare with the listing)</h2><table>')
    foreach ($k in $script:Spec.Keys) { [void]$h.Append("<tr><td class=""k"">$(HtmlEnc $k)</td><td>$(HtmlEnc $script:Spec[$k])</td></tr>") }
    [void]$h.Append('</table>')
    foreach ($grp in @(@{ N = 'Red flags'; L = $fails }, @{ N = 'Warnings'; L = $warns })) {
        if (-not $grp.L) { continue }
        [void]$h.Append("<h2>$($grp.N)</h2><table>")
        foreach ($r in $grp.L) { [void]$h.Append("<tr><td class=""k"">$(HtmlEnc $r.Item)</td><td>$(HtmlEnc $r.Detail)<div class=""adv"">$(HtmlEnc $r.Advice)</div></td></tr>") }
        [void]$h.Append('</table>')
    }
    $sec = ''
    foreach ($r in $script:Results) {
        if ($r.Section -ne $sec) { if ($sec) { [void]$h.Append('</table>') }; $sec = $r.Section; [void]$h.Append("<h2>$(HtmlEnc $sec)</h2><table>") }
        $adv = ''; if ($r.Advice) { $adv = "<div class=""adv"">$(HtmlEnc $r.Advice)</div>" }
        [void]$h.Append("<tr><td class=""k""><span class=""s $($r.Status)"">$($r.Status)</span></td><td class=""k"">$(HtmlEnc $r.Item)</td><td>$(HtmlEnc $r.Detail)$adv</td></tr>")
    }
    if ($sec) { [void]$h.Append('</table>') }
    [void]$h.Append('<h2>Check by hand</h2>')
    foreach ($c in $script:Checklist) { [void]$h.Append("<label><input type=""checkbox""> $(HtmlEnc $c)</label>") }
    [void]$h.Append('<p class="sub">Battery history: <a href="battery-report.html">battery-report.html</a></p></main></body></html>')
    [IO.File]::WriteAllText((Join-Path $dir 'report.html'), $h.ToString(), (New-Object System.Text.UTF8Encoding $false))
}

function Show-Summary {
    Write-Host ''
    Write-Host '================ SPEC SHEET (compare with the listing) ================' -ForegroundColor Cyan
    foreach ($k in $script:Spec.Keys) { Write-Host ('  {0,-9} {1}' -f $k, $script:Spec[$k]) }
    $fails = @($script:Results | Where-Object { $_.Status -eq 'FAIL' })
    $warns = @($script:Results | Where-Object { $_.Status -eq 'WARN' })
    Write-Host ''
    if ($fails) { Write-Host "  RED FLAGS ($($fails.Count)):" -ForegroundColor Red; $fails | ForEach-Object { Write-Host "   - $($_.Item): $($_.Detail)" -ForegroundColor Red } }
    if ($warns) { Write-Host "  WARNINGS ($($warns.Count)):" -ForegroundColor Yellow; $warns | ForEach-Object { Write-Host "   - $($_.Item): $($_.Detail)" -ForegroundColor Yellow } }
    if (-not $fails -and -not $warns) { Write-Host '  No red flags or warnings from the automatic checks.' -ForegroundColor Green }
    if ($script:OutDir) { Write-Host ''; Write-Host "  Report: $script:OutDir" -ForegroundColor Cyan }
}

# ---------------------------------------------------------------- main

function Invoke-Prober {
    Write-Host ''
    Write-Host "  prober $script:ProberVersion - second-hand laptop inspection (read-only)" -ForegroundColor Cyan
    if (-not $script:IsAdmin) {
        Write-Host '  Not running as Administrator: disk wear, BIOS password, TPM and temperature checks will be skipped.' -ForegroundColor Yellow
        Write-Host '  For the full scan: right-click PowerShell/Terminal > Run as administrator (or use run.cmd).' -ForegroundColor Yellow
        $c = Read-Host '  Continue anyway? (y/n)'
        if ($c -notmatch '^y') { return }
    }
    Write-Host '  Scanning - takes about a minute.'

    Run-Step 'Identity'          { Test-Identity }
    Run-Step 'CPU'               { Test-Cpu }
    Run-Step 'Memory'            { Test-Memory }
    Run-Step 'Graphics'          { Test-Gpu }
    Run-Step 'Display'           { Test-Display }
    Run-Step 'Storage'           { Test-Storage }
    Run-Step 'Battery & power'   { Test-Battery }
    Run-Step 'Ownership & locks' { Test-Ownership }
    Run-Step 'Security'          { Test-Security }
    Run-Step 'Devices'           { Test-Devices }
    Run-Step 'Crash & error history' { Test-Events }
    Run-Step 'Tampering'         { Test-Tamper }

    Save-Report
    Show-Summary

    while ($true) {
        Write-Host ''
        Write-Host '  Hands-on tests:' -ForegroundColor Cyan
        Write-Host '   1  Screen      (dead pixels, backlight bleed)'
        Write-Host '   2  Keyboard    (every key + Fn keys)'
        Write-Host '   3  Speakers    (left / right)'
        Write-Host '   4  Webcam'
        Write-Host '   5  Microphone'
        Write-Host '   6  CPU stress  (60 s: fans, thermal throttling)'
        Write-Host '   7  Benchmark   (CPU / memory / GPU vs your PC, in the browser)'
        Write-Host '   a  All of the above'
        Write-Host '   q  Save report, open it and quit'
        $choice = (Read-Host '  Choose').Trim().ToLower()
        if ($choice -eq 'q') { break }
        if (-not $choice) { continue }
        $todo = if ($choice -eq 'a') { @('1', '2', '3', '4', '5', '6', '7') } else { @($choice) }
        $script:CurSec = 'Hands-on tests'
        foreach ($c in $todo) {
            Write-Host ''
            try {
                switch ($c) {
                    '1' { Test-Screen }
                    '2' { Test-Keyboard }
                    '3' { Test-Speakers }
                    '4' { Test-Camera }
                    '5' { Test-Mic }
                    '6' { Test-Stress }
                    '7' { Test-Bench }
                    default { Write-Host '  ?' }
                }
            } catch { Rec "test $c" 'SKIP' $_.Exception.Message }
        }
        Save-Report
    }
    Save-Report
    Write-Host ''
    Write-Host "  Report: $script:OutDir" -ForegroundColor Cyan
    $html = Join-Path $script:OutDir 'report.html'
    if (Test-Path $html) { Start-Process $html }
    Write-Host ''
    Write-Host '  Copy the report folder to your USB/phone, then delete it from this machine.' -ForegroundColor Cyan
}

Invoke-Prober
