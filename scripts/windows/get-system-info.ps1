# Windows System Info Collector (PowerShell)
# WMIC is deprecated - uses Get-CimInstance and nvidia-smi instead
# Compatible with Windows 10 21H1+ and Windows 11

param(
    [Parameter(Mandatory=$false)]
    [string]$Category = "all"
)

$ErrorActionPreference = "SilentlyContinue"

function Get-CPUInfo {
    $cpu     = Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1
    $loadPct = (Get-CimInstance -ClassName Win32_Processor).LoadPercentage

    # Per-core load via OpenHardwareMonitor (more accurate than WMI LoadPercentage)
    $coreLoads = $null
    try {
        $ohmSensors = Get-CimInstance -Namespace "root/OpenHardwareMonitor" -ClassName Sensor -ErrorAction Stop
        $coreSensors = $ohmSensors | Where-Object {
            $_.SensorType -eq "Load" -and $_.Name -match "Core #"
        } | Sort-Object { [int]($_.Name -replace "[^0-9]","") }
        if ($coreSensors) {
            $coreLoads = $coreSensors | ForEach-Object {
                @{ core = $_.Name; loadPct = [math]::Round($_.Value, 1) }
            }
            # Use OHM CPU Total as overall load if available
            $ohmTotal = $ohmSensors | Where-Object {
                $_.SensorType -eq "Load" -and $_.Name -eq "CPU Total"
            } | Select-Object -First 1
            if ($ohmTotal) { $loadPct = [math]::Round($ohmTotal.Value, 1) }
        }
    } catch {}

    $tempC       = $null
    $tempSrcName = $null
    $tempNote    = $null

    # 1) MSAcpi_ThermalZoneTemperature
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

    # 2) LibreHardwareMonitor / OpenHardwareMonitor WMI
    # Priority 1: CPU Package / Core temps (true CPU temp)
    foreach ($ns in @("root/LibreHardwareMonitor", "root/OpenHardwareMonitor")) {
        if ($null -ne $tempC) { break }
        try {
            $allSensors = Get-CimInstance -Namespace $ns -ClassName Sensor -ErrorAction Stop
            if (-not $allSensors) { continue }

            $cpuPkg = $allSensors | Where-Object {
                $_.SensorType -eq "Temperature" -and
                ($_.Name -match "CPU Package|CPU \(Tctl|CPU Die|Core #|Package")
            } | Select-Object -First 1

            if ($cpuPkg -and $null -ne $cpuPkg.Value) {
                $tempC       = [math]::Round([double]$cpuPkg.Value, 1)
                $tempSrcName = "$ns ($($cpuPkg.Name))"
            }
        } catch {}
    }

    # Priority 2: iGPU temp as CPU approximation (Intel Core Ultra / integrated graphics)
    # Intel Core Ultra (Meteor Lake/Arrow Lake) does not expose CPU Package temp
    # iGPU temperature is on the same die and is the best available approximation
    if ($null -eq $tempC) {
        foreach ($ns in @("root/LibreHardwareMonitor", "root/OpenHardwareMonitor")) {
            if ($null -ne $tempC) { break }
            try {
                $allSensors = Get-CimInstance -Namespace $ns -ClassName Sensor -ErrorAction Stop
                if (-not $allSensors) { continue }

                $igpuTemp = $allSensors | Where-Object {
                    $_.SensorType -eq "Temperature" -and
                    ($_.Name -match "Intel.*Graphics|Intel.*GPU|iGPU|Intel Arc") -and
                    ($_.Identifier -notmatch "nvidiagpu|amdgpu")
                } | Select-Object -First 1

                if ($igpuTemp -and $null -ne $igpuTemp.Value) {
                    $tempC       = [math]::Round([double]$igpuTemp.Value, 1)
                    $tempSrcName = "$ns ($($igpuTemp.Name))"
                    $tempNote    = "CPU temp unavailable - iGPU temp used as approximation (Intel Core Ultra)"
                }
            } catch {}
        }
    }

    # Note for Intel Core Ultra where CPU temp is unavailable
    if ($null -eq $tempC -and $cpu.Name -match "Ultra|Core Ultra") {
        $tempNote = "Intel Core Ultra CPU temperature not supported by current monitoring tools"
    }

    return @{
        name         = $cpu.Name.Trim()
        cores        = $cpu.NumberOfCores
        logicalCores = $cpu.NumberOfLogicalProcessors
        maxClockMHz  = $cpu.MaxClockSpeed
        load         = $loadPct
        coreLoads    = $coreLoads
        temperatureC = $tempC
        tempSource   = $tempSrcName
        tempNote     = $tempNote
        socket       = $cpu.SocketDesignation
    }
}

function Get-GPUInfo {
    $gpus = @()

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
                    $gpus += @{
                        vendor         = "NVIDIA"
                        name           = $f[0]
                        temperatureC   = if ($f[1] -match '^\d') { [int]$f[1] } else { $null }
                        utilizationPct = if ($f[2] -match '^\d') { [int]$f[2] } else { $null }
                        vramUsedMB     = if ($f[3] -match '^\d') { [int]$f[3] } else { $null }
                        vramTotalMB    = if ($f[4] -match '^\d') { [int]$f[4] } else { $null }
                        fanSpeedPct    = if ($f[5] -match '^\d') { [int]$f[5] } else { $null }
                        powerDrawW     = if ($f[6] -match '^\d') { [double]$f[6] } else { $null }
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

    # Other GPUs via CIM (AMD / Intel)
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

        # GPU temp via LHM/OHM
        $gpuTemp    = $null
        $gpuTempSrc = $null
        foreach ($ns in @("root/LibreHardwareMonitor", "root/OpenHardwareMonitor")) {
            if ($null -ne $gpuTemp) { break }
            try {
                $allSensors = Get-CimInstance -Namespace $ns -ClassName Sensor -ErrorAction Stop
                $gpuSensor  = $allSensors | Where-Object {
                    $_.SensorType -eq "Temperature" -and $_.Name -match "GPU Core|GPU"
                } | Where-Object {
                    $_.Identifier -notmatch "nvidiagpu"
                } | Select-Object -First 1
                if ($gpuSensor -and $null -ne $gpuSensor.Value) {
                    $gpuTemp    = [math]::Round([double]$gpuSensor.Value, 1)
                    $gpuTempSrc = "$ns ($($gpuSensor.Name))"
                }
            } catch {}
        }

        $gpus += @{
            vendor        = $vendor
            name          = $g.Name
            temperatureC  = $gpuTemp
            tempSource    = $gpuTempSrc
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
    $fans = @()

    # LHM / OHM
    foreach ($ns in @("root/OpenHardwareMonitor","root/LibreHardwareMonitor")) {
        try {
            $allSensors = Get-CimInstance -Namespace $ns -ClassName Sensor -ErrorAction Stop
            $f = $allSensors | Where-Object { $_.SensorType -eq "Fan" }
            if ($f) {
                $fans = $f | ForEach-Object {
                    @{ name = $_.Name; rpm = [int]$_.Value; source = $ns }
                }
                break
            }
        } catch {}
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
