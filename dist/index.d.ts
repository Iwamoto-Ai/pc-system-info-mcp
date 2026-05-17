#!/usr/bin/env node
/**
 * PC System Info MCP Server v1.0.0
 *
 * Provides system monitoring tools for:
 *   - CPU  (load %, temperature °C, clock speed)
 *   - GPU  (NVIDIA via nvidia-smi, AMD/Intel via CIM/system_profiler)
 *   - RAM  (usage GB/%, DIMM slots)
 *   - Fans (RPM via LibreHardwareMonitor on Windows / powermetrics on macOS)
 *   - Disk (usage, read/write throughput)
 *   - Network (adapters, throughput)
 *
 * Supported OS:  Windows 10 21H1+ / Windows 11, macOS 12+
 * Supported MCP: Claude Desktop, OpenClaw
 * NOTE: WMIC is NOT used (deprecated). Uses Get-CimInstance instead.
 */
export {};
//# sourceMappingURL=index.d.ts.map