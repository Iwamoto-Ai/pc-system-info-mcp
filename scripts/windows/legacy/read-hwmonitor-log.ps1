# HWMonitor Log Reader
# HWMonitor (File -> Save Monitoring Data) で保存したログを読み取る
# ログファイルパスを引数で指定、デフォルトは C:\hwmonitor_log.txt

param(
    [string]$LogPath = "C:\hwmonitor_log.txt"
)

$ErrorActionPreference = "SilentlyContinue"

function Read-HWMonitorLog {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        return @{ error = "HWMonitor log not found: $Path"; hint = "Open HWMonitor -> File -> Save Monitoring Data -> Save to $Path" }
    }

    $lines   = Get-Content $Path -Encoding UTF8
    $result  = @{}
    $section = ""

    # CPU temperatures
    $cpuTemps  = @{}
    $cpuVolts  = @{}
    $inCpuInfo = $false

    foreach ($line in $lines) {
        # セクション検出
        if ($line -match "Processors Information") { $inCpuInfo = $true }
        if ($inCpuInfo -and $line -match "^\s+Temperature (\d+)\s+(\d+) degC.*\((.+)\)") {
            $idx   = $matches[1]
            $val   = [int]$matches[2]
            $label = $matches[3].Trim()
            $cpuTemps[$label] = $val
        }
        if ($inCpuInfo -and $line -match "^\s+Voltage (\d+)\s+([\d.]+) Volts.*\((.+)\)") {
            $label = $matches[3].Trim()
            $cpuVolts[$label] = [double]$matches[2]
        }
        # 次のセクションに入ったらCPU情報終了
        if ($inCpuInfo -and $line -match "^(Graphic APIs|Display Adapters|Register Spaces)") {
            $inCpuInfo = $false
        }
    }

    # CPU Package温度（最重要）
    $packageTemp = if ($cpuTemps.ContainsKey("Package")) { $cpuTemps["Package"] } else { $null }

    # コア温度一覧
    $coreTemps = @()
    foreach ($key in ($cpuTemps.Keys | Sort-Object)) {
        if ($key -match "P-Core|E-Core|LP-Core") {
            $coreTemps += @{ core = $key; temperatureC = $cpuTemps[$key] }
        }
    }

    # NVIDIA GPU情報
    $nvGpuTemp  = $null
    $nvHotSpot  = $null
    $nvPower    = $null
    $nvFan0     = $null
    $nvFan1     = $null
    $nvCoreClock= $null
    $nvMemClock = $null
    $inNvNvapi  = $false
    $inNvNvml   = $false

    foreach ($line in $lines) {
        if ($line -match "Hardware monitor\s+NVIDIA NVAPI") { $inNvNvapi = $true; $inNvNvml = $false }
        if ($line -match "Hardware monitor\s+NVIDIA NVML")  { $inNvNvml  = $true; $inNvNvapi = $false }
        if ($line -match "Hardware monitor\s+(?!NVIDIA)" -and ($inNvNvapi -or $inNvNvml)) {
            $inNvNvapi = $false; $inNvNvml = $false
        }
        if ($inNvNvapi) {
            if ($line -match "Temperature 1\s+(\d+) degC.*\(GPU\)")     { $nvGpuTemp  = [int]$matches[1] }
            if ($line -match "Temperature 2\s+(\d+) degC.*\(Hot Spot\)") { $nvHotSpot  = [int]$matches[1] }
            if ($line -match "Power 01\s+([\d.]+) W.*\(GPU\)")           { $nvPower    = [double]$matches[1] }
            if ($line -match "Fan 0\s+(\d+) RPM")                        { $nvFan0     = [int]$matches[1] }
            if ($line -match "Fan 1\s+(\d+) RPM")                        { $nvFan1     = [int]$matches[1] }
            if ($line -match "Clock Speed 0\s+([\d.]+) MHz.*\(Graphics\)") { $nvCoreClock = [double]$matches[1] }
            if ($line -match "Clock Speed 1\s+([\d.]+) MHz.*\(Memory\)")   { $nvMemClock  = [double]$matches[1] }
        }
    }

    # iGPU情報 (Intel IGCL)
    $igpuPower     = $null
    $igpuCoreClock = $null
    $inIgcl        = $false

    foreach ($line in $lines) {
        if ($line -match "Hardware monitor\s+Intel IGCL") { $inIgcl = $true }
        if ($line -match "Hardware monitor\s+(?!Intel IGCL)" -and $inIgcl) { $inIgcl = $false }
        if ($inIgcl) {
            if ($line -match "Power 01\s+([\d.]+) W.*\(GPU\)")              { $igpuPower     = [double]$matches[1] }
            if ($line -match "Clock Speed 0\s+([\d.]+) MHz.*\(Graphics\)")  { $igpuCoreClock = [double]$matches[1] }
        }
    }

    # バッテリー情報
    $battLevel   = $null
    $battVoltage = $null
    $inBattery   = $false

    foreach ($line in $lines) {
        if ($line -match "Hardware monitor\s+Battery") { $inBattery = $true }
        if ($line -match "Hardware monitor\s+(?!Battery)" -and $inBattery) { $inBattery = $false }
        if ($inBattery) {
            if ($line -match "Level 1\s+(\d+) pc.*\(Charge Level\)") { $battLevel   = [int]$matches[1] }
            if ($line -match "Voltage 0\s+([\d.]+) Volts.*\(Current Voltage\)") { $battVoltage = [double]$matches[1] }
        }
    }

    # ログファイルのタイムスタンプ
    $logTime = (Get-Item $Path).LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")

    return @{
        source    = "HWMonitor log"
        logTime   = $logTime
        cpu = @{
            packageTempC  = $packageTemp
            coreTemps     = $coreTemps
            voltages      = $cpuVolts
            tempSource    = if ($packageTemp) { "HWMonitor (Intel SVID)" } else { $null }
        }
        nvidiaGpu = @{
            temperatureC  = $nvGpuTemp
            hotSpotC      = $nvHotSpot
            powerW        = $nvPower
            fan0RPM       = $nvFan0
            fan1RPM       = $nvFan1
            coreClockMHz  = $nvCoreClock
            memClockMHz   = $nvMemClock
        }
        iGpu = @{
            name          = "Intel Arc Graphics"
            powerW        = $igpuPower
            coreClockMHz  = $igpuCoreClock
        }
        battery = @{
            chargePct     = $battLevel
            voltageV      = $battVoltage
        }
    }
}

Read-HWMonitorLog -Path $LogPath | ConvertTo-Json -Depth 10 -Compress
