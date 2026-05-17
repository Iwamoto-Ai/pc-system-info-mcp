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
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { CallToolRequestSchema, ListToolsRequestSchema, } from "@modelcontextprotocol/sdk/types.js";
import { exec } from "node:child_process";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { readFileSync, existsSync } from "node:fs";
const execAsync = promisify(exec);
// ── Resolve __dirname in ESM ──────────────────────────────
const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
// ── Platform detection (synchronous at startup) ───────────
const PLATFORM = process.platform; // "win32" | "darwin" | "linux"
const IS_WSL = (() => {
    if (PLATFORM !== "linux")
        return false;
    try {
        const v = readFileSync("/proc/version", "utf8").toLowerCase();
        return v.includes("microsoft") || v.includes("wsl");
    }
    catch {
        return false;
    }
})();
const IS_WINDOWS = PLATFORM === "win32" || IS_WSL;
const IS_MACOS = PLATFORM === "darwin";
// ── Script paths ──────────────────────────────────────────
const SCRIPTS_DIR = join(__dirname, "..", "scripts");
const WIN_PS1 = join(SCRIPTS_DIR, "windows", "get-system-info.ps1");
const MACOS_SH = join(SCRIPTS_DIR, "macos", "get-system-info.sh");
// ── WSL path conversion ───────────────────────────────────
async function toWinPath(linuxPath) {
    const { stdout } = await execAsync(`wslpath -w "${linuxPath}"`);
    return stdout.trim();
}
// ── Build OS-specific command ─────────────────────────────
async function buildCommand(category) {
    if (IS_WINDOWS) {
        const scriptPath = IS_WSL ? await toWinPath(WIN_PS1) : WIN_PS1;
        const safe = scriptPath.replace(/"/g, '\\"');
        return `powershell.exe -NonInteractive -NoProfile -ExecutionPolicy Bypass -File "${safe}" -Category "${category}"`;
    }
    // macOS
    return `bash "${MACOS_SH}" "${category}"`;
}
async function fetchSystemInfo(category) {
    if (!IS_WINDOWS && !IS_MACOS) {
        return {
            error: "Unsupported platform. Supported: Windows 10/11, macOS 12+.",
            platform: PLATFORM,
            isWSL: IS_WSL,
        };
    }
    const scriptFile = IS_WINDOWS ? WIN_PS1 : MACOS_SH;
    if (!existsSync(scriptFile)) {
        return {
            error: `Script not found: ${scriptFile}`,
            hint: "Ensure the 'scripts/' directory is present next to the compiled output.",
        };
    }
    let command;
    try {
        command = await buildCommand(category);
    }
    catch (e) {
        return { error: `Failed to build command: ${String(e)}` };
    }
    try {
        const { stdout, stderr } = await execAsync(command, {
            timeout: 30_000,
            maxBuffer: 10 * 1024 * 1024,
            shell: IS_WSL ? "/bin/bash" : undefined,
        });
        const raw = stdout.trim();
        if (!raw) {
            return {
                error: "Script returned no output.",
                stderr: stderr.trim() || null,
            };
        }
        try {
            return JSON.parse(raw);
        }
        catch {
            return {
                rawOutput: raw.slice(0, 2000),
                parseError: "Could not parse JSON from script output.",
                stderr: stderr.trim() || null,
            };
        }
    }
    catch (execErr) {
        const e = execErr;
        return {
            error: e.message ?? "Unknown error",
            code: e.code ?? null,
            killed: e.killed ?? false,
            stderr: e.stderr?.trim() ?? null,
            hint: IS_WINDOWS
                ? "PowerShell execution policy may be blocking the script. Run as Admin: Set-ExecutionPolicy -Scope CurrentUser RemoteSigned"
                : "Ensure the script is executable: chmod +x scripts/macos/get-system-info.sh",
        };
    }
}
// ── Tool definitions ──────────────────────────────────────
const TOOLS = [
    {
        name: "get_system_overview",
        description: "Get system overview: OS name/version, hostname, uptime, hardware manufacturer, model, BIOS version, and motherboard info.",
        inputSchema: { type: "object", properties: {} },
    },
    {
        name: "get_cpu_info",
        description: "Get CPU details: name, physical/logical core count, max clock speed (MHz), current load (%), and temperature (°C). " +
            "Windows temperature requires LibreHardwareMonitor or OpenHardwareMonitor running. " +
            "macOS temperature requires 'osx-cpu-temp' (brew install osx-cpu-temp).",
        inputSchema: { type: "object", properties: {} },
    },
    {
        name: "get_gpu_info",
        description: "Get GPU details for all GPUs. NVIDIA: full telemetry via nvidia-smi " +
            "(temperature °C, utilization %, VRAM used/total MB, fan speed %, power draw W, core/mem clock MHz). " +
            "AMD/Intel: basic info via Get-CimInstance (Windows) or system_profiler (macOS).",
        inputSchema: { type: "object", properties: {} },
    },
    {
        name: "get_ram_info",
        description: "Get RAM usage: total/used/available (GB), usage (%), and DIMM slot details (capacity GB, speed MHz, manufacturer, type DDR4/DDR5). " +
            "Apple Silicon Macs report unified memory.",
        inputSchema: { type: "object", properties: {} },
    },
    {
        name: "get_fan_info",
        description: "Get fan speeds (RPM) for all system fans. " +
            "Windows: requires LibreHardwareMonitor or OpenHardwareMonitor running. " +
            "macOS: uses powermetrics (may require sudo) or smcutil.",
        inputSchema: { type: "object", properties: {} },
    },
    {
        name: "get_disk_info",
        description: "Get storage info: drive model, total size (GB), media type, interface (NVMe/SATA/USB), " +
            "per-volume usage (total/free GB, used %), and real-time I/O throughput (read/write bytes/sec).",
        inputSchema: { type: "object", properties: {} },
    },
    {
        name: "get_network_info",
        description: "Get network adapter info (IP addresses, MAC, DHCP, DNS, gateway) and real-time per-interface throughput (bytes sent/received per second).",
        inputSchema: { type: "object", properties: {} },
    },
    {
        name: "get_all_system_info",
        description: "Get ALL system metrics in one call: overview + CPU + GPU + RAM + fans + disks + network. Best for a complete health snapshot.",
        inputSchema: { type: "object", properties: {} },
    },
    {
        name: "get_server_info",
        description: "Get MCP server information: detected platform, WSL status, feature support, and setup guidance.",
        inputSchema: { type: "object", properties: {} },
    },
];
const TOOL_CATEGORY = {
    get_system_overview: "overview",
    get_cpu_info: "cpu",
    get_gpu_info: "gpu",
    get_ram_info: "ram",
    get_fan_info: "fan",
    get_disk_info: "disk",
    get_network_info: "network",
    get_all_system_info: "all",
};
// ── MCP Server ────────────────────────────────────────────
const server = new Server({ name: "pc-system-info-mcp", version: "1.0.0" }, { capabilities: { tools: {} } });
server.setRequestHandler(ListToolsRequestSchema, async () => ({ tools: TOOLS }));
server.setRequestHandler(CallToolRequestSchema, async (request) => {
    const { name } = request.params;
    // Static info tool
    if (name === "get_server_info") {
        return {
            content: [{
                    type: "text",
                    text: JSON.stringify({
                        serverName: "pc-system-info-mcp",
                        serverVersion: "1.0.0",
                        platform: PLATFORM,
                        isWSL: IS_WSL,
                        isWindows: IS_WINDOWS,
                        isMacos: IS_MACOS,
                        nodeVersion: process.version,
                        supportedOS: ["Windows 10 21H1+", "Windows 11", "macOS 12 Monterey+"],
                        features: {
                            cpuTemperature: {
                                windows: "Requires LibreHardwareMonitor or OpenHardwareMonitor running",
                                macos: "brew install osx-cpu-temp  OR  sudo powermetrics (Apple Silicon)",
                            },
                            gpuNvidia: "Full telemetry via nvidia-smi (must be in system PATH)",
                            gpuAmdIntel: {
                                windows: "Basic info via Get-CimInstance Win32_VideoController",
                                macos: "Basic info via system_profiler SPDisplaysDataType",
                            },
                            fanSpeeds: {
                                windows: "Requires LibreHardwareMonitor or OpenHardwareMonitor running",
                                macos: "sudo powermetrics or smcutil",
                            },
                        },
                        wslNote: "When running inside WSL, the server automatically calls Windows powershell.exe to collect Windows-native metrics.",
                    }, null, 2),
                }],
        };
    }
    const category = TOOL_CATEGORY[name];
    if (!category) {
        return {
            content: [{ type: "text", text: `Unknown tool: "${name}"` }],
            isError: true,
        };
    }
    const data = await fetchSystemInfo(category);
    return {
        content: [{ type: "text", text: JSON.stringify(data, null, 2) }],
    };
});
// ── Entry point ───────────────────────────────────────────
async function main() {
    const transport = new StdioServerTransport();
    await server.connect(transport);
    process.stderr.write(`[pc-system-info-mcp] Ready | platform=${PLATFORM} wsl=${IS_WSL}\n`);
}
main().catch((err) => {
    process.stderr.write(`[pc-system-info-mcp] Fatal: ${String(err)}\n`);
    process.exit(1);
});
//# sourceMappingURL=index.js.map