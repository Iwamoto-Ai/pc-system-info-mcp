# Windows System Info Collector (PowerShell) - pc-system-info-mcp v2.0.0
# Uses Get-CimInstance (WMIC is deprecated and not used)
# Compatible with Windows 10 21H1+ and Windows 11 (Windows PowerShell 5.1+)
#
# Data sources (all user-mode, no third-party drivers, no admin rights):
#   - CIM/WMI (Win32_Processor etc.): CPU, RAM, Disk, Network, GPU names
#   - GetLogicalProcessorInformationEx (inline C#): P-core / E-core / LP E-core topology
#   - IsProcessorFeaturePresent (inline C#): instruction set support
#   - Performance counters:
#       Energy Meter       -> RAPL power (CPU package / cores / iGPU / DRAM)
#       GPU Engine         -> iGPU / NPU utilization
#       GPU Adapter Memory -> iGPU shared / dedicated memory usage
#       Processor Information -> per-core-type load
#   - DirectX adapter registry: maps adapter LUIDs to adapter names
#   - nvidia-smi: NVIDIA GPU telemetry (bundled with NVIDIA drivers)
#   - MSAcpi_ThermalZoneTemperature: CPU temperature (limited hardware support)
#
# Not used:
#   - OpenHardwareMonitor / LibreHardwareMonitor (WinRing0.sys, CVE-2020-14979)
#   - HWMonitor automation (SendKeys interferes with other work)
#   - Intel IGCL (verified: exposes no iGPU temperature on Meteor Lake)
#
# This file must stay ASCII-only (Windows PowerShell 5.1 reads BOM-less files as ANSI).

param(
    [Parameter(Mandatory=$false)]
    [string]$Category = "all"
)

$ErrorActionPreference = "SilentlyContinue"

# ---------------------------------------------------------------------------
# Native helpers (inline C#, kept C# 5 compatible for Windows PowerShell 5.1)
# Compiled lazily: only the cpu / gpu categories need it.
# ---------------------------------------------------------------------------
$script:NativeOk = $null

function Initialize-Native {
    if ($null -ne $script:NativeOk) { return $script:NativeOk }
    $script:NativeOk = $false
    try {
        if (-not ("PcsiNative" -as [type])) {
            Add-Type -ErrorAction Stop -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Collections.Generic;

public class PcsiTopology {
    public bool Hybrid;
    public int PerformanceCores;
    public int EfficiencyCores;
    public int LowPowerEfficiencyCores;
    public int PerformanceThreads;
    public int EfficiencyThreads;
    public int LowPowerEfficiencyThreads;
    // index = group * 64 + bit; value: 2 = P-core, 1 = E-core, 0 = LP E-core, -1 = unknown
    public int[] LogicalClass;
}

public static class PcsiNative {
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetLogicalProcessorInformationEx(int relationship, IntPtr buffer, ref uint returnedLength);

    [DllImport("kernel32.dll")]
    private static extern bool IsProcessorFeaturePresent(uint feature);

    public static bool Feature(uint feature) { return IsProcessorFeaturePresent(feature); }

    // Formats a 64-bit adapter LUID the same way performance counters do:
    // 0xHHHHHHHH_0xLLLLLLLL
    public static string LuidKey(long value) {
        ulong v = (ulong)value;
        uint hi = (uint)(v >> 32);
        uint lo = (uint)(v & 0xFFFFFFFFUL);
        return string.Format("0x{0:x8}_0x{1:x8}", hi, lo);
    }

    private static int PopCount(ulong v) {
        int c = 0;
        while (v != 0) { c += (int)(v & 1UL); v >>= 1; }
        return c;
    }

    // relationship 0 = RelationProcessorCore -> { efficiencyClass, flags, mask, group }
    // relationship 2 = RelationCache         -> { level, type, sizeBytes, mask, group }
    private static List<ulong[]> Query(int relationship) {
        List<ulong[]> list = new List<ulong[]>();
        uint len = 0;
        GetLogicalProcessorInformationEx(relationship, IntPtr.Zero, ref len);
        if (len == 0) return list;
        IntPtr buf = Marshal.AllocHGlobal((int)len);
        try {
            if (!GetLogicalProcessorInformationEx(relationship, buf, ref len)) return list;
            int off = 0;
            while (off < (int)len) {
                IntPtr p = IntPtr.Add(buf, off);
                int size = Marshal.ReadInt32(p, 4);
                if (size <= 0) break;
                if (relationship == 0) {
                    ulong flags = Marshal.ReadByte(p, 8);
                    ulong eff   = Marshal.ReadByte(p, 9);
                    ulong mask  = (ulong)Marshal.ReadInt64(p, 32);
                    ulong group = (ushort)Marshal.ReadInt16(p, 40);
                    list.Add(new ulong[] { eff, flags, mask, group });
                } else {
                    ulong level = Marshal.ReadByte(p, 8);
                    ulong csize = (uint)Marshal.ReadInt32(p, 12);
                    ulong ctype = (uint)Marshal.ReadInt32(p, 16);
                    ulong mask  = (ulong)Marshal.ReadInt64(p, 40);
                    ulong group = (ushort)Marshal.ReadInt16(p, 48);
                    list.Add(new ulong[] { level, ctype, csize, mask, group });
                }
                off += size;
            }
        } finally {
            Marshal.FreeHGlobal(buf);
        }
        return list;
    }

    public static PcsiTopology Topology() {
        List<ulong[]> cores  = Query(0);
        List<ulong[]> caches = Query(2);
        PcsiTopology t = new PcsiTopology();
        t.LogicalClass = new int[64 * 4];
        for (int i = 0; i < t.LogicalClass.Length; i++) t.LogicalClass[i] = -1;
        if (cores.Count == 0) return t;

        ulong minEff = 255, maxEff = 0;
        foreach (ulong[] c in cores) {
            if (c[0] < minEff) minEff = c[0];
            if (c[0] > maxEff) maxEff = c[0];
        }
        t.Hybrid = maxEff != minEff;

        // L3 coverage per processor group. LP E-cores (e.g. Meteor Lake SoC tile)
        // do not share the L3 cache, which is how they are told apart from E-cores:
        // Windows reports E-cores and LP E-cores with the same EfficiencyClass.
        ulong[] l3 = new ulong[4];
        bool haveL3 = false;
        foreach (ulong[] c in caches) {
            if (c[0] == 3 && c[4] < 4) { l3[c[4]] |= c[3]; haveL3 = true; }
        }

        foreach (ulong[] c in cores) {
            int group = (int)c[3];
            ulong mask = c[2];
            int threads = PopCount(mask);
            int cls;
            if (!t.Hybrid || c[0] == maxEff) cls = 2;
            else if (haveL3 && group < 4 && (mask & l3[group]) == 0) cls = 0;
            else cls = 1;

            if (cls == 2)      { t.PerformanceCores++;        t.PerformanceThreads += threads; }
            else if (cls == 1) { t.EfficiencyCores++;         t.EfficiencyThreads += threads; }
            else               { t.LowPowerEfficiencyCores++; t.LowPowerEfficiencyThreads += threads; }

            if (group < 4) {
                for (int b = 0; b < 64; b++) {
                    if (((mask >> b) & 1UL) != 0) t.LogicalClass[group * 64 + b] = cls;
                }
            }
        }
        return t;
    }
}
"@
        }
        $script:NativeOk = $true
    } catch {}
    return $script:NativeOk
}

# ---------------------------------------------------------------------------
# Performance counters: sampled ONCE per invocation (~1 s) for all categories.
# English counter paths are accepted on localized Windows, but the returned
# sample paths may be localized; Get-Perf falls back to querying a single
# counter when the English path match finds nothing.
# ---------------------------------------------------------------------------
$script:Perf          = @()
$script:PerfRequested = @{}   # "Set|Counter" -> requested path
$script:PerfFallback  = @{}   # "Set|Counter" -> samples from an individual query

function Add-PerfPath($List, [string]$Set, [string]$Instance, [string]$Counter) {
    $path = "\$Set($Instance)\$Counter"
    $script:PerfRequested["$Set|$Counter"] = $path
    $List.Add($path)
}

function Initialize-Perf([string]$Cat) {
    $all   = ($Cat -eq "all")
    $paths = New-Object System.Collections.Generic.List[string]

    if ($all -or $Cat -eq "cpu") {
        Add-PerfPath $paths "Processor Information" "*" "% Processor Utility"
    }
    if ($all -or $Cat -eq "gpu") {
        Add-PerfPath $paths "GPU Engine" "*" "Utilization Percentage"
        Add-PerfPath $paths "GPU Adapter Memory" "*" "Shared Usage"
        Add-PerfPath $paths "GPU Adapter Memory" "*" "Dedicated Usage"
    }
    if ($all -or $Cat -eq "cpu" -or $Cat -eq "gpu" -or $Cat -eq "power") {
        Add-PerfPath $paths "Energy Meter" "*" "Power"
    }
    if ($all -or $Cat -eq "disk") {
        Add-PerfPath $paths "PhysicalDisk" "_Total" "Disk Read Bytes/sec"
        Add-PerfPath $paths "PhysicalDisk" "_Total" "Disk Write Bytes/sec"
    }
    if ($all -or $Cat -eq "network") {
        Add-PerfPath $paths "Network Interface" "*" "Bytes Received/sec"
        Add-PerfPath $paths "Network Interface" "*" "Bytes Sent/sec"
    }
    if ($paths.Count -eq 0) { return }

    # Counter sets that do not exist on this machine (e.g. Energy Meter on
    # some AMD desktops) produce non-terminating errors and are skipped.
    try {
        $script:Perf = @((Get-Counter -Counter $paths.ToArray() -ErrorAction SilentlyContinue).CounterSamples)
    } catch {
        $script:Perf = @()
    }
}

function Get-Perf([string]$Set, [string]$Counter) {
    $key     = "$Set|$Counter"
    $pattern = "*\$Set(*)\$Counter"
    $hits = @($script:Perf | Where-Object { $_.Path -like $pattern })
    if ($hits.Count -gt 0) { return $hits }

    if (-not $script:PerfRequested.ContainsKey($key)) { return @() }
    if (-not $script:PerfFallback.ContainsKey($key)) {
        $script:PerfFallback[$key] = @()
        try {
            $script:PerfFallback[$key] = @((Get-Counter -Counter $script:PerfRequested[$key] -ErrorAction Stop).CounterSamples)
        } catch {}
    }
    return @($script:PerfFallback[$key])
}

# ---------------------------------------------------------------------------
# RAPL power (Windows "Energy Meter" counters, values in milliwatts)
# ---------------------------------------------------------------------------
$script:Rapl = $null

function Get-RaplPower {
    if ($null -ne $script:Rapl) { return $script:Rapl }
    $r = [ordered]@{ available = $false; packageW = $null; coresW = $null; igpuW = $null; dramW = $null }
    $samples = Get-Perf "Energy Meter" "Power"
    foreach ($s in $samples) {
        $inst = $s.InstanceName.ToLower()
        $w = [math]::Round($s.CookedValue / 1000.0, 2)
        $key = $null
        if     ($inst -like "*_pkg")  { $key = "packageW" }
        elseif ($inst -like "*_pp0")  { $key = "coresW" }
        elseif ($inst -like "*_pp1")  { $key = "igpuW" }
        elseif ($inst -like "*_dram") { $key = "dramW" }
        if ($key) {
            # Sum across packages (multi-socket systems)
            $r[$key] = if ($null -eq $r[$key]) { $w } else { [math]::Round($r[$key] + $w, 2) }
            $r.available = $true
        }
    }
    $script:Rapl = $r
    return $r
}

# ---------------------------------------------------------------------------
# GPU adapter helpers: LUID -> name (DirectX registry) and per-LUID usage
# ---------------------------------------------------------------------------
function Get-DxAdapterMap {
    $map = @{}
    if (-not (Initialize-Native)) { return $map }
    Get-ChildItem "HKLM:\SOFTWARE\Microsoft\DirectX" -ErrorAction SilentlyContinue | ForEach-Object {
        $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
        if ($null -ne $p -and $null -ne $p.AdapterLuid -and $p.Description) {
            $key = $null
            try { $key = [PcsiNative]::LuidKey([long]$p.AdapterLuid) } catch { return }
            $map[$key] = [ordered]@{
                description  = [string]$p.Description
                vendorId     = $p.VendorId
                dedicatedMB  = if ($p.DedicatedVideoMemory) { [math]::Round([double]$p.DedicatedVideoMemory / 1MB) } else { $null }
            }
        }
    }
    return $map
}

function Get-LuidUsage {
    # Task Manager style: sum per engine across processes, then busiest engine per adapter
    $engineSums = @{}
    foreach ($s in (Get-Perf "GPU Engine" "Utilization Percentage")) {
        if ($s.InstanceName -match 'luid_(0x[0-9a-f]{8}_0x[0-9a-f]{8})_phys_(\d+)_eng_(\d+)_engtype_(.+)$') {
            $k = "$($matches[1])|$($matches[2])|$($matches[3])|$($matches[4])"
            if ($engineSums.ContainsKey($k)) { $engineSums[$k] += $s.CookedValue } else { $engineSums[$k] = $s.CookedValue }
        }
    }
    $usage = @{}
    foreach ($k in $engineSums.Keys) {
        $parts = $k -split '\|'
        $luid = $parts[0]; $type = $parts[3]
        $v = [math]::Min(100.0, $engineSums[$k])
        if (-not $usage.ContainsKey($luid)) {
            $usage[$luid] = @{ utilizationPct = 0.0; busiestEngine = $null; engineTypes = @{}; sharedMB = $null; dedicatedMB = $null }
        }
        $usage[$luid].engineTypes[$type] = $true
        if ($v -ge $usage[$luid].utilizationPct) {
            $usage[$luid].utilizationPct = $v
            $usage[$luid].busiestEngine  = $type
        }
    }
    foreach ($pair in @(@("Shared Usage", "sharedMB"), @("Dedicated Usage", "dedicatedMB"))) {
        foreach ($s in (Get-Perf "GPU Adapter Memory" $pair[0])) {
            if ($s.InstanceName -match 'luid_(0x[0-9a-f]{8}_0x[0-9a-f]{8})') {
                $luid = $matches[1]
                if (-not $usage.ContainsKey($luid)) {
                    $usage[$luid] = @{ utilizationPct = 0.0; busiestEngine = $null; engineTypes = @{}; sharedMB = $null; dedicatedMB = $null }
                }
                $mb = [math]::Round($s.CookedValue / 1MB)
                $usage[$luid][$pair[1]] = if ($null -eq $usage[$luid][$pair[1]]) { $mb } else { $usage[$luid][$pair[1]] + $mb }
            }
        }
    }
    return $usage
}

function Get-Vendor([string]$Name) {
    if ($Name -match "NVIDIA")           { return "NVIDIA" }
    if ($Name -match "AMD|Radeon")       { return "AMD" }
    if ($Name -match "Intel")            { return "Intel" }
    if ($Name -match "Qualcomm|Adreno|Hexagon") { return "Qualcomm" }
    return "Unknown"
}

# ---------------------------------------------------------------------------
# Categories
# ---------------------------------------------------------------------------
function Get-CPUInfo {
    # Single CIM query; average load across sockets (LoadPercentage is an
    # array on multi-socket systems)
    $cpus    = @(Get-CimInstance -ClassName Win32_Processor)
    $cpu     = $cpus[0]
    $loads   = @($cpus | ForEach-Object { $_.LoadPercentage } | Where-Object { $null -ne $_ })
    $loadPct = if ($loads.Count -gt 0) {
        [math]::Round(($loads | Measure-Object -Average).Average, 1)
    } else { $null }

    # --- Topology (P / E / LP E-cores) and per-core-type load ---
    $topology   = $null
    $loadByType = $null
    if (Initialize-Native) {
        try {
            $t = [PcsiNative]::Topology()
            if ($t.PerformanceCores + $t.EfficiencyCores + $t.LowPowerEfficiencyCores -gt 0) {
                $topology = [ordered]@{
                    hybrid                    = $t.Hybrid
                    performanceCores          = $t.PerformanceCores
                    efficiencyCores           = $t.EfficiencyCores
                    lowPowerEfficiencyCores   = $t.LowPowerEfficiencyCores
                    performanceThreads        = $t.PerformanceThreads
                    efficiencyThreads         = $t.EfficiencyThreads
                    lowPowerEfficiencyThreads = $t.LowPowerEfficiencyThreads
                }
                $buckets = @{ 2 = @(); 1 = @(); 0 = @() }
                foreach ($s in (Get-Perf "Processor Information" "% Processor Utility")) {
                    if ($s.InstanceName -match '^(\d+),(\d+)$') {
                        $idx = [int]$matches[1] * 64 + [int]$matches[2]
                        if ($idx -lt $t.LogicalClass.Length) {
                            $cls = $t.LogicalClass[$idx]
                            if ($cls -ge 0) { $buckets[$cls] += [math]::Min(100.0, $s.CookedValue) }
                        }
                    }
                }
                $avg = {
                    param($a)
                    if ($a.Count -eq 0) { return $null }
                    return [math]::Round(($a | Measure-Object -Average).Average, 1)
                }
                $loadByType = [ordered]@{
                    performance        = & $avg $buckets[2]
                    efficiency         = & $avg $buckets[1]
                    lowPowerEfficiency = & $avg $buckets[0]
                }
            }
        } catch {}
    }

    # --- Overall load fallback ---
    # Win32_Processor.LoadPercentage is sometimes null on Windows 11. Fall back
    # to the same counter that loadByCoreType uses (Task Manager's "Utility"):
    # the _Total instance first, then the average of all logical processors.
    $loadSource = if ($null -ne $loadPct) { "Win32_Processor" } else { $null }
    if ($null -eq $loadPct) {
        $util  = @(Get-Perf "Processor Information" "% Processor Utility")
        $total = $util | Where-Object { $_.InstanceName -eq "_total" } | Select-Object -First 1
        if ($total) {
            $loadPct    = [math]::Round([math]::Min(100.0, $total.CookedValue), 1)
            $loadSource = "Processor Information counter (_Total)"
        } else {
            $perCpu = @($util | Where-Object { $_.InstanceName -match '^\d+,\d+$' } |
                        ForEach-Object { [math]::Min(100.0, $_.CookedValue) })
            if ($perCpu.Count -gt 0) {
                $loadPct    = [math]::Round(($perCpu | Measure-Object -Average).Average, 1)
                $loadSource = "Processor Information counter (average of logical processors)"
            }
        }
    }

    # --- Instruction sets (IsProcessorFeaturePresent) ---
    $isa = $null
    if (Initialize-Native) {
        try {
            $isa = [ordered]@{
                sse3    = [PcsiNative]::Feature(13)
                ssse3   = [PcsiNative]::Feature(36)
                sse4_1  = [PcsiNative]::Feature(37)
                sse4_2  = [PcsiNative]::Feature(38)
                avx     = [PcsiNative]::Feature(39)
                avx2    = [PcsiNative]::Feature(40)
                avx512f = [PcsiNative]::Feature(41)
            }
        } catch {}
    }
    # Virtualization. While a hypervisor is running (Hyper-V, which WSL2 / Docker
    # Desktop / VBS use), Windows itself runs as a guest and the firmware flag
    # reads as false even though VT-x/AMD-V is enabled - so a running
    # hypervisor counts as "enabled".
    $virtFw = $null
    if (Initialize-Native) { try { $virtFw = [PcsiNative]::Feature(21) } catch {} }
    $hvPresent = $null
    try { $hvPresent = [bool](Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).HypervisorPresent } catch {}
    $virtEnabled = if ($hvPresent -eq $true -or $virtFw -eq $true) { $true }
                   elseif ($null -eq $hvPresent -and $null -eq $virtFw) { $null }
                   else { $false }

    # --- Microcode revision (registry "Update Revision", REG_BINARY) ---
    $microcode = $null
    try {
        $rev = (Get-ItemProperty "HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0" -ErrorAction Stop)."Update Revision"
        if ($rev -is [byte[]] -and $rev.Length -ge 4) {
            $lo = [BitConverter]::ToUInt32($rev, 0)
            $hi = if ($rev.Length -ge 8) { [BitConverter]::ToUInt32($rev, 4) } else { [uint32]0 }
            $mc = if ($lo -ne 0) { $lo } else { $hi }
            # 0xFFFFFFFF is reported by some hypervisors and means "unknown"
            if ($mc -ne 0 -and $mc -ne [uint32]::MaxValue) { $microcode = "0x{0:X}" -f $mc }
        }
    } catch {}

    # --- Temperature (MSAcpi; works on some hardware only) ---
    $tempC       = $null
    $tempSrcName = $null
    $tempNote    = $null
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

    $rapl = Get-RaplPower
    if ($null -eq $tempC) {
        $hint = if ($rapl.available) { " Use power.packageW as the load/heat indicator." } else { "" }
        if ($cpu.Name -match "Ultra") {
            $tempNote = "Intel Core Ultra does not expose CPU temperature through standard Windows APIs (kernel drivers are intentionally not used).$hint"
        } else {
            $tempNote = "CPU temperature is not exposed through standard Windows APIs on this hardware.$hint"
        }
    }

    return [ordered]@{
        name            = $cpu.Name.Trim()
        manufacturer    = $cpu.Manufacturer
        socket          = $cpu.SocketDesignation
        cores           = $cpu.NumberOfCores
        logicalCores    = $cpu.NumberOfLogicalProcessors
        topology        = $topology
        maxClockMHz     = $cpu.MaxClockSpeed
        cache           = [ordered]@{ l2KB = $cpu.L2CacheSize; l3KB = $cpu.L3CacheSize }
        microcode       = $microcode
        instructionSets = $isa
        virtualization  = [ordered]@{ enabled = $virtEnabled; hypervisorPresent = $hvPresent }
        load            = $loadPct
        loadSource      = $loadSource
        loadByCoreType  = $loadByType
        power           = [ordered]@{ packageW = $rapl.packageW; coresW = $rapl.coresW }
        temperatureC    = $tempC
        tempSource      = $tempSrcName
        tempNote        = $tempNote
    }
}

function Get-GPUInfo {
    $gpus = @()

    # --- NVIDIA via nvidia-smi ---
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
                    $gpus += [ordered]@{
                        type           = "discrete"
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

    $dx    = Get-DxAdapterMap
    $usage = Get-LuidUsage
    $rapl  = Get-RaplPower
    $claimed = @{}

    # --- Other GPUs via CIM (Intel / AMD), enriched with counters ---
    $cimGpus = @(Get-CimInstance -ClassName Win32_VideoController |
                 Where-Object { $_.Name -notmatch "Microsoft Basic" })
    foreach ($g in $cimGpus) {
        if ($g.Name -match "NVIDIA" -and ($gpus | Where-Object { $_.vendor -eq "NVIDIA" })) { continue }

        $vendor = Get-Vendor $g.Name

        # Find this adapter's current LUID (registry entries can be stale, so
        # only accept LUIDs that are present in the live counters)
        $luid = $null
        foreach ($k in $dx.Keys) {
            if ($dx[$k].description -eq $g.Name -and $usage.ContainsKey($k) -and -not $claimed.ContainsKey($k)) {
                $luid = $k; break
            }
        }
        if ($luid) { $claimed[$luid] = $true }

        $dedicatedMB = $null
        if ($luid -and $null -ne $dx[$luid].dedicatedMB) { $dedicatedMB = $dx[$luid].dedicatedMB }
        $type = "integrated"
        if ($g.Name -match "Hyper-V|VMware|VirtualBox|Parallels|Remote Display|Citrix|Virtual Display") { $type = "virtual" }
        elseif ($vendor -eq "NVIDIA") { $type = "discrete" }
        elseif ($null -ne $dedicatedMB -and $dedicatedMB -ge 1024) { $type = "discrete" }
        elseif ($null -eq $dedicatedMB -and $g.Name -match "Arc\(TM\) [AB]\d|Radeon RX") { $type = "discrete" }

        $u = if ($luid) { $usage[$luid] } else { $null }
        $gpuTempNote = if ($type -eq "virtual") {
            "Virtual display adapter; no hardware telemetry is available."
        } elseif ($type -eq "integrated") {
            "Integrated GPU temperature is not exposed by the graphics driver (verified with Intel IGCL on Meteor Lake)."
        } elseif ($vendor -eq "NVIDIA") {
            "nvidia-smi was not found; install or update the NVIDIA driver for temperature and full telemetry."
        } else {
            "GPU temperature is not exposed through standard Windows APIs for this adapter."
        }
        $gpus += [ordered]@{
            type                  = $type
            vendor                = $vendor
            name                  = $g.Name
            temperatureC          = $null
            utilizationPct        = if ($u) { [math]::Round($u.utilizationPct, 1) } else { $null }
            busiestEngine         = if ($u) { $u.busiestEngine } else { $null }
            sharedMemoryUsedMB    = if ($u) { $u.sharedMB } else { $null }
            dedicatedMemoryUsedMB = if ($u) { $u.dedicatedMB } else { $null }
            vramTotalMB           = if ($g.AdapterRAM) { [math]::Round($g.AdapterRAM / 1MB) } else { $null }
            powerW                = if ($vendor -eq "Intel" -and $type -eq "integrated") { $rapl.igpuW } else { $null }
            driverVersion         = $g.DriverVersion
            source                = if ($luid) { "CIM + performance counters" } else { "CIM" }
            tempNote              = $gpuTempNote
        }
    }

    # --- NPU (Windows device class "ComputeAccelerator") ---
    $npus = @(Get-CimInstance -ClassName Win32_PnPEntity -Filter "PNPClass='ComputeAccelerator'" -ErrorAction SilentlyContinue)
    foreach ($n in $npus) {
        $luid = $null
        foreach ($k in $dx.Keys) {
            if ($dx[$k].description -eq $n.Name -and -not $claimed.ContainsKey($k)) { $luid = $k; break }
        }
        if (-not $luid -and $npus.Count -eq 1) {
            # Fallback: an unclaimed adapter whose engines are all compute engines
            foreach ($k in $usage.Keys) {
                if ($claimed.ContainsKey($k)) { continue }
                $types = @($usage[$k].engineTypes.Keys)
                if ($types.Count -gt 0 -and -not ($types | Where-Object { $_ -notmatch "compute" })) { $luid = $k; break }
            }
        }
        if ($luid) { $claimed[$luid] = $true }

        $util = $null
        if ($luid -and $usage.ContainsKey($luid)) { $util = [math]::Round($usage[$luid].utilizationPct, 1) }
        elseif ($luid) { $util = 0.0 }

        $gpus += [ordered]@{
            type           = "npu"
            vendor         = Get-Vendor $n.Name
            name           = $n.Name
            status         = $n.Status
            utilizationPct = $util
            source         = "PnP (ComputeAccelerator) + GPU Engine counters"
            note           = if ($null -eq $util) { "NPU utilization unavailable (idle, or adapter not found in counters)." } else { $null }
        }
    }

    return $gpus
}

function Get-PowerInfo {
    $r = Get-RaplPower
    $note = if ($r.available) {
        "RAPL energy counters via Windows 'Energy Meter' (no driver needed). 0 W for igpuW/dramW can mean idle or an unsupported domain on this platform."
    } else {
        "RAPL energy counters (Windows 'Energy Meter') are not available on this system."
    }
    return [ordered]@{
        source    = "Windows Energy Meter (RAPL)"
        available = $r.available
        packageW  = $r.packageW
        coresW    = $r.coresW
        igpuW     = $r.igpuW
        dramW     = $r.dramW
        note      = $note
    }
}

function Get-RAMInfo {
    $os    = Get-CimInstance -ClassName Win32_OperatingSystem
    $cs    = Get-CimInstance -ClassName Win32_ComputerSystem
    $dimms = Get-CimInstance -ClassName Win32_PhysicalMemory

    $slots = $dimms | ForEach-Object {
        # SMBIOSMemoryType is reliable on modern systems (MemoryType is often 0)
        $t = if ($_.SMBIOSMemoryType) { [int]$_.SMBIOSMemoryType } else { [int]$_.MemoryType }
        @{
            slot         = $_.DeviceLocator
            capacityGB   = [math]::Round($_.Capacity / 1GB, 2)
            speedMHz     = $_.Speed
            manufacturer = $_.Manufacturer
            type         = switch ($t) {
                24 {"DDR3"} 26 {"DDR4"} 29 {"LPDDR3"} 30 {"LPDDR4"} 34 {"DDR5"} 35 {"LPDDR5"} default {"Unknown"}
            }
        }
    }

    return @{
        totalGB     = [math]::Round($cs.TotalPhysicalMemory / 1GB, 2)
        availableGB = [math]::Round($os.FreePhysicalMemory / 1MB, 2)
        usedGB      = [math]::Round(($cs.TotalPhysicalMemory - $os.FreePhysicalMemory * 1KB) / 1GB, 2)
        usedPct     = [math]::Round((1 - $os.FreePhysicalMemory * 1KB / $cs.TotalPhysicalMemory) * 100, 1)
        slots       = @($slots)
    }
}

function Get-FanInfo {
    # Win32_Fan lives in root/cimv2 (NOT root/WMI). Even so, most consumer
    # motherboards do not expose fan RPM through standard WMI, so rpm may be
    # null. A note field explains the situation to the caller/LLM.
    $fans = @()
    try {
        $cimFans = @(Get-CimInstance -ClassName Win32_Fan -ErrorAction Stop)
        $fans = $cimFans | ForEach-Object {
            @{
                name   = $_.Name
                rpm    = if ($_.DesiredSpeed) { [int64]$_.DesiredSpeed } else { $null }
                status = $_.Status
                source = "CIM (Win32_Fan)"
            }
        }
    } catch {}

    if ($fans.Count -eq 0) {
        return @{
            fans = @()
            note = "Fan RPM is not exposed via standard Windows WMI on this hardware. Third-party sensor tools are intentionally not used (WinRing0 vulnerability, CVE-2020-14979). NVIDIA GPU fan speed is reported in the gpu category."
        }
    }
    return @{ fans = @($fans); note = $null }
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
            serialNumber = if ($disk.SerialNumber) { $disk.SerialNumber.Trim() } else { $null }
            volumes      = @($volInfo)
        }
    }

    $diskIO = $null
    $read  = Get-Perf "PhysicalDisk" "Disk Read Bytes/sec"  | Select-Object -First 1
    $write = Get-Perf "PhysicalDisk" "Disk Write Bytes/sec" | Select-Object -First 1
    if ($read -or $write) {
        $diskIO = @{
            readBytesPerSec  = if ($read)  { [math]::Round($read.CookedValue) }  else { $null }
            writeBytesPerSec = if ($write) { [math]::Round($write.CookedValue) } else { $null }
        }
    }

    return @{ drives = @($disks); io = $diskIO }
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

    # Receive / send are fetched as separate counters and joined by interface
    # name, so this works even when sample paths are localized
    $netIO = @()
    $recvBy = @{}
    foreach ($s in (Get-Perf "Network Interface" "Bytes Received/sec")) { $recvBy[$s.InstanceName] = $s.CookedValue }
    $sentBy = @{}
    foreach ($s in (Get-Perf "Network Interface" "Bytes Sent/sec"))     { $sentBy[$s.InstanceName] = $s.CookedValue }
    $names = @($recvBy.Keys) + @($sentBy.Keys) | Where-Object { $_ -ne "_total" } | Sort-Object -Unique
    foreach ($n in $names) {
        $netIO += @{
            interface       = $n
            recvBytesPerSec = if ($recvBy.ContainsKey($n)) { [math]::Round($recvBy[$n]) } else { $null }
            sentBytesPerSec = if ($sentBy.ContainsKey($n)) { [math]::Round($sentBy[$n]) } else { $null }
        }
    }

    return @{ adapters = @($adapters); throughput = @($netIO) }
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
        # OSArchitecture is localized (e.g. Japanese "64 bit"); use the invariant value
        architecture = $env:PROCESSOR_ARCHITECTURE
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

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
$cat = $Category.ToLower()
$known = @("cpu", "gpu", "ram", "fan", "disk", "network", "overview", "power")
if ($known -notcontains $cat) { $cat = "all" }

Initialize-Perf $cat

$result = [ordered]@{}
switch ($cat) {
    "cpu"      { $result.cpu      = Get-CPUInfo }
    "gpu"      { $result.gpu      = @(Get-GPUInfo) }
    "ram"      { $result.ram      = Get-RAMInfo }
    "fan"      { $result.fan      = Get-FanInfo }
    "disk"     { $result.disk     = Get-DiskInfo }
    "network"  { $result.network  = Get-NetworkInfo }
    "overview" { $result.overview = Get-SystemOverview }
    "power"    { $result.power    = Get-PowerInfo }
    default {
        $result.overview = Get-SystemOverview
        $result.cpu      = Get-CPUInfo
        $result.gpu      = @(Get-GPUInfo)
        $result.power    = Get-PowerInfo
        $result.ram      = Get-RAMInfo
        $result.fan      = Get-FanInfo
        $result.disk     = Get-DiskInfo
        $result.network  = Get-NetworkInfo
    }
}

$result | ConvertTo-Json -Depth 10 -Compress
