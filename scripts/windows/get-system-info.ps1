# Windows System Info Collector (PowerShell)
# WMIC is deprecated - uses Get-CimInstance and nvidia-smi instead
# Compatible with Windows 10 21H1+ and Windows 11
#
# Required tools:
#   - HWMonitor (CPUID): For CPU temperature (Intel Core Ultra / Meteor Lake)
#     Run HWMonitor, press F5 to save log to C:\HWMonitor.txt
#     See hwmonitor-autosave.ps1 for automatic saving via Task Scheduler
#   - nvidia-smi: For NVIDIA GPU telemetry (bundled with NVIDIA drivers)
#
# Note: OpenHardwareMonitor and LibreHardwareMonitor are NOT used
#   due to WinRing0.sys security vulnerability (CVE-2020-14979)

param(
    [Parameter(Mandatory=$false)]
    [string]$Category = "all"
)

$ErrorActionPreference = "SilentlyContinue"

# HWMonitor log path - searches multiple locations automatically
$HWMONITOR_LOG = @(
    "C:\HWMonitor.txt",
    "C:\hwmonitor_log.txt",
    "C:\Software\hwmonitor\HWMonitor.txt",
    "$env:USERPROFILE\Documents\HWMonitor.txt",
    "$env:USERPROFILE\Desktop\HWMonitor.txt"
) | Where-Object { Test-Path $_ } | Select-Object -First 1

# Read HWMonitor log file for CPU/GPU temperatures
function Get-HWMonitorData {
    if (-not $HWMONITOR_LOG) { return $null }
    try {
        $lines   = Get-Content $HWMONITOR_LOG -Encoding UTF8
        $data    = @{
            cpuPackageC  = $null
            coreTemps    = @()
            nvGpuTempC   = $null
            nvFan0       = $null
            nvFan1       = $null
            nvPowerW     = $null
            igpuPowerW   = $null
            igpuClockMHz = $null
            logTime      = (Get-Item $HWMONITOR_LOG).LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")
        }
        $inCpu   = $false
        $inNvApi = $false
        $inIgcl  = $false

        foreach ($line in $lines) {
            if ($line -match "Processors Information")        { $inCpu   = $true  }
            if ($line -match "Graphic APIs|Display Adapters") { $inCpu   = $false }
            if ($line -match "Hardware monitor\s+NVIDIA NVAPI") { $inNvApi = $true  }
            if ($line -match "Hardware monitor\s+NVIDIA NVML")  { $inNvApi = $false }
            if ($line -match "Hardware monitor\s+Intel IGCL")   { $inIgcl  = $true  }
            if ($line -match "Hardware monitor\s+(?!Intel IGCL)(NVIDIA|PDH|D3D|Battery|ASIX|Intel I)" -and $inIgcl) {
                $inIgcl = $false
            }

            if ($inCpu) {
                if ($line -match "Temperature \d+\s+(\d+) degC.*\(Package\)") {
                    $data.cpuPackageC = [int]$matches[1]
                }
                if ($line -match "Temperature \d+\s+(\d+) degC.*\(([PC].*Core.+)\)") {
                    $data.coreTemps += @{ core = $matches[2].Trim(); temperatureC = [int]$matches[1] }
                }
            }
            if ($inNvApi) {
                if ($line -match "Temperature 1\s+(\d+) degC.*\(GPU\)")  { $data.nvGpuTempC = [int]$matches[1] }
                if ($line -match "Fan 0\s+(\d+) RPM")                    { $data.nvFan0     = [int]$matches[1] }
                if ($line -match "Fan 1\s+(\d+) RPM")                    { $data.nvFan1     = [int]$matches[1] }
                if ($line -match "Power 01\s+([\d.]+) W.*\(GPU\)")       { $data.nvPowerW   = [double]$matches[1] }
            }
            if ($inIgcl) {
                if ($line -match "Power 01\s+([\d.]+) W.*\(GPU\)")             { $data.igpuPowerW   = [double]$matches[1] }
                if ($line -match "Clock Speed 0\s+([\d.]+) MHz.*\(Graphics\)") { $data.igpuClockMHz = [double]$matches[1] }
            }
        }
        return $data
    } catch { return $null }
}

function Get-CPUInfo {
    $cpu     = Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1
    $loadPct = (Get-CimInstance -ClassName Win32_Processor).LoadPercentage

    $tempC       = $null
    $tempSrcName = $null
    $tempNote    = $null
    $coreTemps   = $null

    # HWMonitor log (supports Intel Core Ultra / Meteor Lake)
    $hwData = Get-HWMonitorData
    if ($hwData -and $null -ne $hwData.cpuPackageC) {
        $tempC       = $hwData.cpuPackageC
        $tempSrcName = "HWMonitor (Intel SVID - Package)"
        if ($hwData.coreTemps.Count -gt 0) { $coreTemps = $hwData.coreTemps }
    }

    # MSAcpi_ThermalZoneTemperature fallback
    if ($null -eq $tempC) {
        try {
            $thermal = Get-CimInstance -Namespace "root/WMI" -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop
            if ($thermal) {
                $calc = [math]::Round(($thermal[0].CurrentTemperature / 10) - 273.15, 1)
                if ($calc -gt -10 -and $calc -lt 125) {
                    $tempC       = $calc
                    $tempSrcName = "MSAcpi"
                }
            }
        } catch {}
    }

    if ($null -eq $tempC) {
        if ($cpu.Name -match "Ultra|Core Ultra") {
            $tempNote = "Intel Core Ultra CPU temperature requires HWMonitor. Run HWMonitor and press F5 to save log."
        } else {
            $tempNote = "CPU temperature unavailable. Install HWMonitor or LibreHardwareMonitor."
        }
    }

    return @{
        name         = $cpu.Name.Trim()
        cores        = $cpu.NumberOfCores
        logicalCores = $cpu.NumberOfLogicalProcessors
        maxClockMHz  = $cpu.MaxClockSpeed
        load         = $loadPct
        temperatureC = $tempC
        coreTemps    = $coreTemps
        tempSource   = $tempSrcName
        tempNote     = $tempNote
        socket       = $cpu.SocketDesignation
    }
}

function Get-GPUInfo {
    $gpus   = @()
    $hwData = Get-HWMonitorData

    # NVIDIA via nvidia-smi
    $nvidiaPaths = @(
        "nvidia-smi",
        "C:\Windows\System32\nvidia-smi.exe",
        "C:\Program Files\NVIDIA Corporation\NVSMI\nvidia-smi.exe"
    )
    foreach ($p in $nvidiaPaths) {
        try {
            $out = & $p --query-gpu=name,temperature.gpu,utilization.gpu,memory.used,memory.total,fan.speed,power.draw,power.limit,clocks.current.graphics,clocks.current.memory --format=csv,noheader,nounits 2>$null
            if ($LASTEXITCODE -eq 0 -and $out) {
                $lines = $out -split "`n" | Where-Object { $_.Trim() -ne "" }
                foreach ($line in $lines) {
                    $f = $line -split "," | ForEach-Object { $_.Trim() }
                    # Supplement with HWMonitor data if nvidia-smi values are missing
                    $fanSpeed = if ($f[5] -match '^\d') { [int]$f[5] } elseif ($hwData -and $hwData.nvFan0) { $hwData.nvFan0 } else { $null }
                    $powerDraw= if ($f[6] -match '^\d') { [double]$f[6] } elseif ($hwData -and $hwData.nvPowerW) { $hwData.nvPowerW } else { $null }
                    $gpus += @{
                        vendor         = "NVIDIA"
                        name           = $f[0]
                        temperatureC   = if ($f[1] -match '^\d') { [int]$f[1] } else { $hwData.nvGpuTempC }
                        utilizationPct = if ($f[2] -match '^\d') { [int]$f[2] } else { $null }
                        vramUsedMB     = if ($f[3] -match '^\d') { [int]$f[3] } else { $null }
                        vramTotalMB    = if ($f[4] -match '^\d') { [int]$f[4] } else { $null }
                        fanSpeedPct    = $fanSpeed
                        powerDrawW     = $powerDraw
                        powerLimitW    = if ($f[7] -match '^\d') { [double]$f[7] } else { $null }
                        coreClockMHz   = if ($f[8] -match '^\d') { [int]$f[8] } else { $null }
                        memClockMHz    = if ($f[9] -match '^\d') { [int]$f[9] } else { $null }
                        source         = "nvidia-smi"
                    }
                }
                break
            }
        } catch {}
    }

    # Other GPUs via CIM (AMD / Intel iGPU)
    $cimGpus = Get-CimInstance -ClassName Win32_VideoController |
               Where-Object { $_.Name -notmatch "Microsoft Basic" }
    foreach ($g in $cimGpus) {
        $alreadyCaptured = $gpus | Where-Object {
            $_.name -and $g.Name -and
            $_.name.ToLower().Contains("nvidia") -and
            $g.Name.ToLower().Contains("nvidia")
        }
        if ($alreadyCaptured) { continue }

        $vendor = "Unknown"
        if ($g.Name -match "AMD|Radeon") { $vendor = "AMD" }
        if ($g.Name -match "Intel")      { $vendor = "Intel" }
        if ($g.Name -match "NVIDIA")     { $vendor = "NVIDIA" }

        $gpus += @{
            vendor        = $vendor
            name          = $g.Name
            temperatureC  = $null
            powerW        = if ($vendor -eq "Intel" -and $hwData -and $hwData.igpuPowerW) { $hwData.igpuPowerW } else { $null }
            coreClockMHz  = if ($vendor -eq "Intel" -and $hwData -and $hwData.igpuClockMHz) { $hwData.igpuClockMHz } else { $null }
            vramTotalMB   = if ($g.AdapterRAM) { [math]::Round($g.AdapterRAM / 1MB) } else { $null }
            driverVersion = $g.DriverVersion
            source        = "CIM"
        }
    }

    return $gpus
}

function Get-RAMInfo {
    $os    = Get-CimInstance -ClassName Win32_OperatingSystem
    $cs    = Get-CimInstance -ClassName Win32_ComputerSystem
    $dimms = Get-CimInstance -ClassName Win32_PhysicalMemory

    $slots = $dimms | ForEach-Object {
        @{
            slot         = $_.DeviceLocator
            capacityGB   = [math]::Round($_.Capacity / 1GB, 2)
            speedMHz     = $_.Speed
            manufacturer = $_.Manufacturer
            type         = switch ($_.MemoryType) {
                24 {"DDR3"} 26 {"DDR4"} 34 {"DDR5"} default {"Unknown"}
            }
        }
    }

    return @{
        totalGB     = [math]::Round($cs.TotalPhysicalMemory / 1GB, 2)
        availableGB = [math]::Round($os.FreePhysicalMemory / 1MB, 2)
        usedGB      = [math]::Round(($cs.TotalPhysicalMemory - $os.FreePhysicalMemory * 1KB) / 1GB, 2)
        usedPct     = [math]::Round((1 - $os.FreePhysicalMemory * 1KB / $cs.TotalPhysicalMemory) * 100, 1)
        slots       = $slots
    }
}

function Get-FanInfo {
    $fans   = @()
    $hwData = Get-HWMonitorData

    # HWMonitor fan data
    if ($hwData) {
        if ($hwData.nvFan0) { $fans += @{ name = "GPU Fan 0"; rpm = $hwData.nvFan0; source = "HWMonitor" } }
        if ($hwData.nvFan1) { $fans += @{ name = "GPU Fan 1"; rpm = $hwData.nvFan1; source = "HWMonitor" } }
    }

    # CIM fallback
    if ($fans.Count -eq 0) {
        try {
            $cimFans = Get-CimInstance -Namespace "root/WMI" -ClassName Win32_Fan -ErrorAction Stop
            $fans = $cimFans | ForEach-Object {
                @{ name = $_.Name; rpm = $null; source = "CIM" }
            }
        } catch {}
    }

    return $fans
}

function Get-DiskInfo {
    $disks = Get-CimInstance -ClassName Win32_DiskDrive | ForEach-Object {
        $disk       = $_
        $partitions = Get-CimInstance -Query "ASSOCIATORS OF {Win32_DiskDrive.DeviceID='$($disk.DeviceID)'} WHERE AssocClass=Win32_DiskDriveToDiskPartition"
        $volumes    = $partitions | ForEach-Object {
            Get-CimInstance -Query "ASSOCIATORS OF {Win32_DiskPartition.DeviceID='$($_.DeviceID)'} WHERE AssocClass=Win32_LogicalDiskToPartition"
        }
        $volInfo = $volumes | ForEach-Object {
            @{
                letter     = $_.DeviceID
                totalGB    = [math]::Round($_.Size / 1GB, 2)
                freeGB     = [math]::Round($_.FreeSpace / 1GB, 2)
                usedPct    = if ($_.Size) { [math]::Round((1 - $_.FreeSpace / $_.Size) * 100, 1) } else { $null }
                filesystem = $_.FileSystem
            }
        }
        @{
            model        = $disk.Model
            sizeGB       = [math]::Round($disk.Size / 1GB, 2)
            mediaType    = $disk.MediaType
            interface    = $disk.InterfaceType
            serialNumber = $disk.SerialNumber
            volumes      = $volInfo
        }
    }

    $diskIO = $null
    try {
        $counters = Get-Counter '\PhysicalDisk(_Total)\Disk Read Bytes/sec','\PhysicalDisk(_Total)\Disk Write Bytes/sec' -ErrorAction Stop
        $samples  = $counters.CounterSamples
        $diskIO   = @{
            readBytesPerSec  = [math]::Round($samples[0].CookedValue)
            writeBytesPerSec = [math]::Round($samples[1].CookedValue)
        }
    } catch {}

    return @{ drives = $disks; io = $diskIO }
}

function Get-NetworkInfo {
    $adapters = Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter "IPEnabled=True" | ForEach-Object {
        @{
            description = $_.Description
            ipAddresses = $_.IPAddress
            macAddress  = $_.MACAddress
            dhcp        = $_.DHCPEnabled
            gateway     = $_.DefaultIPGateway
            dns         = $_.DNSServerSearchOrder
        }
    }

    $netIO = @()
    try {
        $instances = (Get-Counter "\Network Interface(*)\Bytes Received/sec" -ErrorAction Stop).CounterSamples |
                     Where-Object { $_.InstanceName -ne "_total" }
        foreach ($s in $instances) {
            $sname = $s.InstanceName
            $sent  = (Get-Counter "\Network Interface($sname)\Bytes Sent/sec" -ErrorAction Stop).CounterSamples[0].CookedValue
            $netIO += @{
                interface       = $sname
                recvBytesPerSec = [math]::Round($s.CookedValue)
                sentBytesPerSec = [math]::Round($sent)
            }
        }
    } catch {}

    return @{ adapters = $adapters; throughput = $netIO }
}

function Get-SystemOverview {
    $os     = Get-CimInstance -ClassName Win32_OperatingSystem
    $cs     = Get-CimInstance -ClassName Win32_ComputerSystem
    $bios   = Get-CimInstance -ClassName Win32_BIOS
    $mb     = Get-CimInstance -ClassName Win32_BaseBoard
    $uptime = (Get-Date) - $os.LastBootUpTime

    return @{
        hostname     = $env:COMPUTERNAME
        os           = $os.Caption
        osVersion    = $os.Version
        buildNumber  = $os.BuildNumber
        architecture = $os.OSArchitecture
        manufacturer = $cs.Manufacturer
        model        = $cs.Model
        biosVersion  = $bios.SMBIOSBIOSVersion
        motherboard  = "$($mb.Manufacturer) $($mb.Product)"
        uptimeHours  = [math]::Round($uptime.TotalHours, 2)
        lastBoot     = $os.LastBootUpTime.ToString("yyyy-MM-dd HH:mm:ss")
        timezone     = (Get-TimeZone).Id
        timestamp    = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        hwmonitorLog = if ($HWMONITOR_LOG) { $HWMONITOR_LOG } else { "not found" }
    }
}

# Main
$result = @{}

switch ($Category.ToLower()) {
    "cpu"      { $result.cpu      = Get-CPUInfo }
    "gpu"      { $result.gpu      = Get-GPUInfo }
    "ram"      { $result.ram      = Get-RAMInfo }
    "fan"      { $result.fan      = Get-FanInfo }
    "disk"     { $result.disk     = Get-DiskInfo }
    "network"  { $result.network  = Get-NetworkInfo }
    "overview" { $result.overview = Get-SystemOverview }
    default {
        $result.overview = Get-SystemOverview
        $result.cpu      = Get-CPUInfo
        $result.gpu      = Get-GPUInfo
        $result.ram      = Get-RAMInfo
        $result.fan      = Get-FanInfo
        $result.disk     = Get-DiskInfo
        $result.network  = Get-NetworkInfo
    }
}

$result | ConvertTo-Json -Depth 10 -Compress
