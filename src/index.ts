#!/usr/bin/env node
/**
 * PC System Info MCP Server v1.1.0
 * - ローカルLLM（Ollama等）向けにツール名エイリアス対応
 * - 余分な引数（language等）を無視
 * - Supports Windows (PowerShell/CIM) and macOS
 */

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
  Tool,
} from "@modelcontextprotocol/sdk/types.js";
import { exec } from "node:child_process";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { readFileSync, existsSync } from "node:fs";

const execAsync = promisify(exec);
const __filename = fileURLToPath(import.meta.url);
const __dirname  = dirname(__filename);

// ── Platform detection ────────────────────────────────────
const PLATFORM = process.platform;

const IS_WSL = (() => {
  if (PLATFORM !== "linux") return false;
  try {
    const v = readFileSync("/proc/version", "utf8").toLowerCase();
    return v.includes("microsoft") || v.includes("wsl");
  } catch { return false; }
})();

const IS_WINDOWS = PLATFORM === "win32" || IS_WSL;
const IS_MACOS   = PLATFORM === "darwin";

// ── Script paths ──────────────────────────────────────────
const SCRIPTS_DIR = join(__dirname, "..", "scripts");
const WIN_PS1     = join(SCRIPTS_DIR, "windows", "get-system-info.ps1");
const MACOS_SH    = join(SCRIPTS_DIR, "macos",   "get-system-info.sh");

async function toWinPath(linuxPath: string): Promise<string> {
  const { stdout } = await execAsync(`wslpath -w "${linuxPath}"`);
  return stdout.trim();
}

async function buildCommand(category: string): Promise<string> {
  if (IS_WINDOWS) {
    const scriptPath = IS_WSL ? await toWinPath(WIN_PS1) : WIN_PS1;
    const safe = scriptPath.replace(/"/g, '\\"');
    return `powershell.exe -NonInteractive -NoProfile -ExecutionPolicy Bypass -File "${safe}" -Category "${category}"`;
  }
  return `bash "${MACOS_SH}" "${category}"`;
}

type JsonValue =
  | string | number | boolean | null
  | JsonValue[]
  | { [key: string]: JsonValue };

async function fetchSystemInfo(category: string): Promise<JsonValue> {
  if (!IS_WINDOWS && !IS_MACOS) {
    return { error: "Unsupported platform.", platform: PLATFORM, isWSL: IS_WSL };
  }
  const scriptFile = IS_WINDOWS ? WIN_PS1 : MACOS_SH;
  if (!existsSync(scriptFile)) {
    return { error: `Script not found: ${scriptFile}` };
  }
  let command: string;
  try { command = await buildCommand(category); }
  catch (e) { return { error: `Failed to build command: ${String(e)}` }; }

  try {
    const { stdout, stderr } = await execAsync(command, {
      timeout: 30_000,
      maxBuffer: 10 * 1024 * 1024,
      shell: IS_WSL ? "/bin/bash" : undefined,
    });
    const raw = stdout.trim();
    if (!raw) return { error: "No output from script.", stderr: stderr.trim() || null };
    try { return JSON.parse(raw) as JsonValue; }
    catch { return { rawOutput: raw.slice(0, 2000), parseError: "JSON parse failed." }; }
  } catch (execErr) {
    const e = execErr as { message?: string; code?: string | number; killed?: boolean; stderr?: string };
    return { error: e.message ?? "Unknown error", code: e.code ?? null, killed: e.killed ?? false };
  }
}

// ── inputSchema: additionalProperties:true で余分な引数を無視 ──
const NO_PARAM_SCHEMA = {
  type: "object" as const,
  properties: {},
  additionalProperties: true,
};

// ── Tool definitions ──────────────────────────────────────
const TOOLS: Tool[] = [
  {
    name: "get_system_overview",
    description: "Get PC system overview: OS, hostname, uptime, manufacturer, model, BIOS, motherboard. No arguments needed.",
    inputSchema: NO_PARAM_SCHEMA,
  },
  {
    name: "get_cpu_info",
    description: "Get CPU info: name, cores, clock speed MHz, load %, temperature °C. No arguments needed. Windows needs LibreHardwareMonitor for temperature.",
    inputSchema: NO_PARAM_SCHEMA,
  },
  {
    name: "get_gpu_info",
    description: "Get GPU info. NVIDIA: temperature, utilization %, VRAM MB, fan %, power W, clocks MHz via nvidia-smi. No arguments needed.",
    inputSchema: NO_PARAM_SCHEMA,
  },
  {
    name: "get_ram_info",
    description: "Get RAM: total/used/available GB, usage %, DIMM slots (capacity, speed MHz, DDR type). No arguments needed.",
    inputSchema: NO_PARAM_SCHEMA,
  },
  {
    name: "get_fan_info",
    description: "Get fan speeds RPM. Windows needs LibreHardwareMonitor. No arguments needed.",
    inputSchema: NO_PARAM_SCHEMA,
  },
  {
    name: "get_disk_info",
    description: "Get disk info: model, size GB, interface, volume usage, read/write bytes/sec. No arguments needed.",
    inputSchema: NO_PARAM_SCHEMA,
  },
  {
    name: "get_network_info",
    description: "Get network adapters: IP, MAC, DHCP, DNS, gateway, throughput bytes/sec. No arguments needed.",
    inputSchema: NO_PARAM_SCHEMA,
  },
  {
    name: "get_all_system_info",
    description: "Get ALL PC metrics at once: overview+CPU+GPU+RAM+fans+disks+network. Use for full health check. No arguments needed.",
    inputSchema: NO_PARAM_SCHEMA,
  },
  {
    name: "get_server_info",
    description: "Get MCP server info: platform, WSL status, features. No arguments needed.",
    inputSchema: NO_PARAM_SCHEMA,
  },
];

// ── エイリアス: ローカルLLMが別名で呼んだ場合も吸収 ─────────────
const TOOL_ALIASES: Record<string, string> = {
  "pc_cpu_info":      "get_cpu_info",
  "cpu_info":         "get_cpu_info",
  "get_cpu":          "get_cpu_info",
  "pc_gpu_info":      "get_gpu_info",
  "gpu_info":         "get_gpu_info",
  "get_gpu":          "get_gpu_info",
  "pc_ram_info":      "get_ram_info",
  "ram_info":         "get_ram_info",
  "memory_info":      "get_ram_info",
  "get_memory":       "get_ram_info",
  "pc_fan_info":      "get_fan_info",
  "fan_info":         "get_fan_info",
  "pc_disk_info":     "get_disk_info",
  "disk_info":        "get_disk_info",
  "storage_info":     "get_disk_info",
  "pc_network_info":  "get_network_info",
  "network_info":     "get_network_info",
  "system_overview":  "get_system_overview",
  "system_info":      "get_all_system_info",
  "all_system_info":  "get_all_system_info",
  "pc_system_info":   "get_all_system_info",
  "get_system_info":  "get_all_system_info",
  "server_info":      "get_server_info",
};

const TOOL_CATEGORY: Record<string, string> = {
  get_system_overview: "overview",
  get_cpu_info:        "cpu",
  get_gpu_info:        "gpu",
  get_ram_info:        "ram",
  get_fan_info:        "fan",
  get_disk_info:       "disk",
  get_network_info:    "network",
  get_all_system_info: "all",
};

// ── MCP Server ────────────────────────────────────────────
const server = new Server(
  { name: "pc-system-info-mcp", version: "1.1.0" },
  { capabilities: { tools: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({ tools: TOOLS }));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  // エイリアス解決（ローカルLLMが別名で呼んだ場合も対応）
  const rawName = request.params.name;
  const name = TOOL_ALIASES[rawName] ?? rawName;

  if (name === "get_server_info") {
    return {
      content: [{
        type: "text",
        text: JSON.stringify({
          serverName: "pc-system-info-mcp", serverVersion: "1.1.0",
          platform: PLATFORM, isWSL: IS_WSL, isWindows: IS_WINDOWS, isMacos: IS_MACOS,
          nodeVersion: process.version,
          calledAs: rawName !== name ? `${rawName} → ${name}` : name,
          supportedOS: ["Windows 10 21H1+", "Windows 11", "macOS 12+"],
        }, null, 2),
      }],
    };
  }

  const category = TOOL_CATEGORY[name];
  if (!category) {
    // 未知のツール名でも全情報を返してフォールバック
    process.stderr.write(`[pc-system-info-mcp] Unknown tool "${rawName}", falling back to get_all_system_info\n`);
    const data = await fetchSystemInfo("all");
    return { content: [{ type: "text", text: JSON.stringify(data, null, 2) }] };
  }

  const data = await fetchSystemInfo(category);
  return { content: [{ type: "text", text: JSON.stringify(data, null, 2) }] };
});

// ── Entry point ───────────────────────────────────────────
async function main(): Promise<void> {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  process.stderr.write(`[pc-system-info-mcp] Ready v1.1.0 | platform=${PLATFORM} wsl=${IS_WSL}\n`);
}

main().catch((err) => {
  process.stderr.write(`[pc-system-info-mcp] Fatal: ${String(err)}\n`);
  process.exit(1);
});
