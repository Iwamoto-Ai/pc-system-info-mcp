# Windows System Info Collector (PowerShell)
# WMIC is deprecated - uses Get-CimInstance and nvidia-smi instead
# Compatible with Windows 10 21H1+ and Windows 11

param(
    [Parameter(Mandatory=$false)]
    [string]$Category = "all"
)

$ErrorActionPreference = "SilentlyContinue"

function Get-CPUInfo {
    $cpu = Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1
    $loadPct = (Get-CimInstance -ClassName Win32_Processor).LoadPercentage
    
    # CPU temperature via MSAcpi_ThermalZoneTemperature (requires admin)
    $tempK = $null
    $tempC = $null
    try {
        $thermal = Get-CimInstance -Namespace "root/WMI" -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop
        if ($thermal) {
            $tempK = ($thermal | Select-Object -First 1).CurrentTemperature
            $tempC = [math]::Round(($tempK / 10) - 273.15, 1)
        }
    } catch {}

    # Fallback: LibreHardwareMonitor / OpenHardwareMonitor WMI namespace
    # NOTE: WQL Filter on SensorType is unreliable in LHM - fetch all sensors and filter in PowerShell
    foreach ($ns in @("root/LibreHardwareMonitor", "root/OpenHardwareMonitor")) {
        if ($null -ne $tempC) { break }
        try {
            $allSensors = Get-CimInstance -Namespace $ns -ClassName Sensor -ErrorAction Stop
            if (-not $allSensors) { continue }

            # Priority 1: "CPU Package" or "CPU (Tctl/Tdie)" — whole-CPU temp
            $cpuPkg = $allSensors | Where-Object {
                $_.SensorType -eq "Temperature" -and
                ($_.Name -match "Package|Tctl|Tdie|CPU$")
            } | Select-Object -First 1

            # Priority 2: Any sensor with "CPU" or "Core" in the name
            $cpuAny = $allSensors | Where-Object {
                $_.SensorType -eq "Temperature" -and
                ($_.Name -match "CPU|Core")
            } | Select-Object -First 1

            $chosen = if ($cpuPkg) { $cpuPkg } elseif ($cpuAny) { $cpuAny } else { $null }

            if ($chosen -and $null -ne $chosen.Value) {
                $tempC = [math]::Round([double]$chosen.Value, 1)
                $tempSrcName = "$ns ($($chosen.Name))"
            }
        } catch {}
    }

    return @{
        name         = $cpu.Name.Trim()
        cores        = $cpu.NumberOfCores
        logicalCores = $cpu.NumberOfLogicalProcessors
        maxClockMHz  = $cpu.MaxClockSpeed
        load         = $loadPct
        temperatureC = $tempC
        tempSource   = if ($null -ne $tempC) { $tempSrcName } else { $null }
        socket       = $cpu.SocketDesignation
    }
}

function Get-GPUInfo {
    $gpus = @()

    # --- NVIDIA via nvidia-smi ---
    $nvidiaSmi = $null
    $nvidiaPaths = @(
        "nvidia-smi",
        "C:\Windows\System32\nvidia-smi.exe",
        "C:\Program Files\NVIDIA Corporation\NVSMI\nvidia-smi.exe"
    )
    foreach ($p in $nvidiaPaths) {
        try {
            $out = & $p --query-gpu=name,temperature.gpu,utilization.gpu,memory.used,memory.total,fan.speed,power.draw,power.limit,clocks.current.graphics,clocks.current.memory --format=csv,noheader,nounits 2>$null
            if ($LASTEXITCODE -eq 0 -and $out) {
                $nvidiaSmi = $out
                break
            }
        } catch {}
    }

    if ($nvidiaSmi) {
        $lines = $nvidiaSmi -split "`n" | Where-Object { $_.Trim() -ne "" }
        foreach ($line in $lines) {
            $f = $line -split "," | ForEach-Object { $_.Trim() }
            $gpus += @{
                vendor          = "NVIDIA"
                name            = $f[0]
                temperatureC    = if ($f[1] -match '^\d') { [int]$f[1] } else { $null }
                utilizationPct  = if ($f[2] -match '^\d') { [int]$f[2] } else { $null }
                vramUsedMB      = if ($f[3] -match '^\d') { [int]$f[3] } else { $null }
                vramTotalMB     = if ($f[4] -match '^\d') { [int]$f[4] } else { $null }
                fanSpeedPct     = if ($f[5] -match '^\d') { [int]$f[5] } else { $null }
                powerDrawW      = if ($f[6] -match '^\d') { [double]$f[6] } else { $null }
                powerLimitW     = if ($f[7] -match '^\d') { [double]$f[7] } else { $null }
                coreClockMHz    = if ($f[8] -match '^\d') { [int]$f[8] } else { $null }
                memClockMHz     = if ($f[9] -match '^\d') { [int]$f[9] } else { $null }
                source          = "nvidia-smi"
            }
        }
    }

    # --- Other GPUs via CIM (AMD / Intel) ---
    $cimGpus = Get-CimInstance -ClassName Win32_VideoController | Where-Object { $_.Name -notmatch "Microsoft Basic" }
    foreach ($g in $cimGpus) {
        # Skip if already captured by nvidia-smi
        $alreadyCaptured = $gpus | Where-Object { $_.name -and $g.Name -and $_.name.ToLower().Contains("nvidia") -and $g.Name.ToLower().Contains("nvidia") }
        if ($alreadyCaptured) { continue }

        $vendor = "Unknown"
        if ($g.Name -match "AMD|Radeon")  { $vendor = "AMD" }
        if ($g.Name -match "Intel")       { $vendor = "Intel" }
        if ($g.Name -match "NVIDIA")      { $vendor = "NVIDIA" }

        # OHM / LHM temperature for non-NVIDIA (same fetch-all-then-filter approach)
        $gpuTemp = $null
        foreach ($ns in @("root/LibreHardwareMonitor", "root/OpenHardwareMonitor")) {
            if ($null -ne $gpuTemp) { break }
            try {
                $allSensors = Get-CimInstance -Namespace $ns -ClassName Sensor -ErrorAction Stop
                $gpuSensor  = $allSensors | Where-Object {
                    $_.SensorType -eq "Temperature" -and $_.Name -match "GPU"
                } | Select-Object -First 1
                if ($gpuSensor -and $null -ne $gpuSensor.Value) {
                    $gpuTemp = [math]::Round([double]$gpuSensor.Value, 1)
                }
            } catch {}
        }

        $gpus += @{
            vendor         = $vendor
            name           = $g.Name
            temperatureC   = $gpuTemp
            vramTotalMB    = if ($g.AdapterRAM) { [math]::Round($g.AdapterRAM / 1MB) } else { $null }
            driverVersion  = $g.DriverVersion
            source         = "CIM"
        }
    }

    return $gpus
}

function Get-RAMInfo {
    $os  = Get-CimInstance -ClassName Win32_OperatingSystem
    $cs  = Get-CimInstance -ClassName Win32_ComputerSystem
    $dimms = Get-CimInstance -ClassName Win32_PhysicalMemory

    $slots = $dimms | ForEach-Object {
        @{
            slot         = $_.DeviceLocator
            capacityGB   = [math]::Round($_.Capacity / 1GB, 2)
            speedMHz     = $_.Speed
            manufacturer = $_.Manufacturer
            type         = switch ($_.MemoryType) { 24 {"DDR3"} 26 {"DDR4"} 34 {"DDR5"} default {"Unknown"} }
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

    # OHM / LHM
    foreach ($ns in @("root/OpenHardwareMonitor","root/LibreHardwareMonitor")) {
        try {
            $f = Get-CimInstance -Namespace $ns -ClassName Sensor -Filter "SensorType='Fan'" -ErrorAction Stop
            if ($f) {
                $fans = $f | ForEach-Object { @{ name = $_.Name; rpm = [int]$_.Value; source = $ns } }
                break
            }
        } catch {}
    }

    # Fallback: CIM fan (limited info)
    if ($fans.Count -eq 0) {
        try {
            $cimFans = Get-CimInstance -Namespace "root/WMI" -ClassName Win32_Fan -ErrorAction Stop
            $fans = $cimFans | ForEach-Object { @{ name = $_.Name; rpm = $null; source = "CIM" } }
        } catch {}
    }

    return $fans
}

function Get-DiskInfo {
    $disks = Get-CimInstance -ClassName Win32_DiskDrive | ForEach-Object {
        $disk = $_
        $partitions = Get-CimInstance -Query "ASSOCIATORS OF {Win32_DiskDrive.DeviceID='$($disk.DeviceID)'} WHERE AssocClass=Win32_DiskDriveToDiskPartition"
        $volumes = $partitions | ForEach-Object {
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
            model       = $disk.Model
            sizeGB      = [math]::Round($disk.Size / 1GB, 2)
            mediaType   = $disk.MediaType
            interface   = $disk.InterfaceType
            serialNumber= $disk.SerialNumber
            volumes     = $volInfo
        }
    }

    # Disk IO via perf counters
    $diskIO = $null
    try {
        $counters = Get-Counter '\PhysicalDisk(_Total)\Disk Read Bytes/sec','\PhysicalDisk(_Total)\Disk Write Bytes/sec' -ErrorAction Stop
        $samples  = $counters.CounterSamples
        $diskIO   = @{
            readBytesPerSec  = [math]::Round($samples[0].CookedValue)
            writeBytesPerSec = [math]::Round($samples[1].CookedValue)
        }
    } catch {}

    return @{
        drives = $disks
        io     = $diskIO
    }
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

    # Network throughput via perf counters
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

    return @{
        adapters   = $adapters
        throughput = $netIO
    }
}

function Get-SystemOverview {
    $os  = Get-CimInstance -ClassName Win32_OperatingSystem
    $cs  = Get-CimInstance -ClassName Win32_ComputerSystem
    $bios= Get-CimInstance -ClassName Win32_BIOS
    $mb  = Get-CimInstance -ClassName Win32_BaseBoard

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

# --- Main execution ---
$result = @{}

switch ($Category.ToLower()) {
    "cpu"       { $result.cpu     = Get-CPUInfo }
    "gpu"       { $result.gpu     = Get-GPUInfo }
    "ram"       { $result.ram     = Get-RAMInfo }
    "fan"       { $result.fan     = Get-FanInfo }
    "disk"      { $result.disk    = Get-DiskInfo }
    "network"   { $result.network = Get-NetworkInfo }
    "overview"  { $result.overview= Get-SystemOverview }
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
