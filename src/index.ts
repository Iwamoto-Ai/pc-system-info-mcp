#!/usr/bin/env node
/**
 * PC System Info MCP Server v2
 * - Supports Windows (PowerShell/CIM), macOS, and WSL (calls Windows-side PowerShell)
 * - Windows: hybrid CPU topology, RAPL power, iGPU / NPU utilization
 *   (user-mode APIs and performance counters only; no kernel drivers)
 * - Tool name aliases for local LLMs (Ollama etc.); extra arguments are ignored
 * - execFile-based invocation (no shell, no quoting pitfalls)
 * - Short-TTL result cache + in-flight request coalescing
 * - PRIVACY_MODE: identifiers (serial / MAC / IP / DNS / gateway) are partially
 *   masked by default; "full" (or "1") redacts them, "off" (or "0") shows them
 * - Unknown tools return an MCP error by default (MCP_LENIENT_MODE=1 restores
 *   the old "fall back to get_all_system_info" behavior for weak local LLMs)
 */

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
  Tool,
} from "@modelcontextprotocol/sdk/types.js";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { readFileSync, existsSync } from "node:fs";
import { applyPrivacy, parsePrivacyMode, type JsonValue } from "./privacy.js";

const execFileAsync = promisify(execFile);
const __filename = fileURLToPath(import.meta.url);
const __dirname  = dirname(__filename);

// ── Version: single source of truth = package.json ────────
const SERVER_VERSION: string = (() => {
  try {
    const pkg = JSON.parse(
      readFileSync(join(__dirname, "..", "package.json"), "utf8")
    ) as { version?: string };
    return pkg.version ?? "0.0.0";
  } catch {
    return "0.0.0";
  }
})();

// ── Feature flags ─────────────────────────────────────────
const PRIVACY_MODE = parsePrivacyMode(process.env.PRIVACY_MODE);
const LENIENT_MODE = process.env.MCP_LENIENT_MODE === "1";
const CACHE_TTL_MS = Number(process.env.CACHE_TTL_MS ?? 3000);

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
  const { stdout } = await execFileAsync("wslpath", ["-w", linuxPath]);
  return stdout.trim();
}

interface Invocation { file: string; args: string[]; }

async function buildInvocation(category: string): Promise<Invocation> {
  if (IS_WINDOWS) {
    const scriptPath = IS_WSL ? await toWinPath(WIN_PS1) : WIN_PS1;
    return {
      file: "powershell.exe",
      args: [
        "-NonInteractive", "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", scriptPath, "-Category", category,
      ],
    };
  }
  return { file: "bash", args: [MACOS_SH, category] };
}

// ── Fetch with TTL cache + in-flight coalescing ───────────
const cache = new Map<string, { at: number; data: JsonValue }>();
const inFlight = new Map<string, Promise<JsonValue>>();

async function fetchSystemInfo(category: string): Promise<JsonValue> {
  const cached = cache.get(category);
  if (cached && Date.now() - cached.at < CACHE_TTL_MS) return cached.data;

  const pending = inFlight.get(category);
  if (pending) return pending;

  const p = fetchSystemInfoUncached(category)
    .then((data) => {
      cache.set(category, { at: Date.now(), data });
      return data;
    })
    .finally(() => inFlight.delete(category));
  inFlight.set(category, p);
  return p;
}

async function fetchSystemInfoUncached(category: string): Promise<JsonValue> {
  if (!IS_WINDOWS && !IS_MACOS) {
    return {
      error: "Unsupported platform. (Native Linux support is planned; WSL is supported.)",
      platform: PLATFORM, isWSL: IS_WSL,
    };
  }
  if (IS_MACOS && category === "power") {
    return {
      power: {
        available: false,
        note: "Power telemetry (RAPL via Windows Energy Meter) is Windows-only. On macOS, use `sudo powermetrics`.",
      },
    };
  }
  const scriptFile = IS_WINDOWS ? WIN_PS1 : MACOS_SH;
  if (!existsSync(scriptFile)) {
    return { error: `Script not found: ${scriptFile}. Run "npm run build" first.` };
  }
  let inv: Invocation;
  try { inv = await buildInvocation(category); }
  catch (e) { return { error: `Failed to build command: ${String(e)}` }; }

  try {
    const { stdout, stderr } = await execFileAsync(inv.file, inv.args, {
      timeout: 60_000,
      maxBuffer: 10 * 1024 * 1024,
    });
    const raw = stdout.trim();
    if (!raw) return { error: "No output from script.", stderr: stderr.trim() || null };
    let parsed: JsonValue;
    try { parsed = JSON.parse(raw) as JsonValue; }
    catch { return { rawOutput: raw.slice(0, 2000), parseError: "JSON parse failed." }; }
    return applyPrivacy(parsed, PRIVACY_MODE);
  } catch (execErr) {
    const e = execErr as { message?: string; code?: string | number; killed?: boolean; stderr?: string };
    return { error: e.message ?? "Unknown error", code: e.code ?? null, killed: e.killed ?? false };
  }
}

// ── inputSchema: additionalProperties:true ignores stray args ──
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
    description: "Get CPU info: name, cores/threads, hybrid topology (P-core / E-core / LP E-core) with load per core type, L2/L3 cache, microcode, instruction sets (AVX2 etc.), load %, package power W, and temperature °C when the hardware exposes it (often null on Intel Core Ultra; see tempNote and use power as the load/heat indicator). No arguments needed.",
    inputSchema: NO_PARAM_SCHEMA,
  },
  {
    name: "get_gpu_info",
    description: "List GPUs and NPUs; each entry has type discrete / integrated / virtual / npu. NVIDIA: temperature, utilization %, VRAM MB, fan %, power W, clocks via nvidia-smi. Intel/AMD integrated GPU: utilization %, busiest engine, shared memory MB, power W (Intel, RAPL); temperature is usually unavailable. NPU: utilization %. No arguments needed.",
    inputSchema: NO_PARAM_SCHEMA,
  },
  {
    name: "get_power_info",
    description: "Get power draw in watts from RAPL (Windows Energy Meter counters): CPU package, CPU cores, integrated GPU, DRAM. Best available load/heat indicator when temperatures are not exposed. Windows only. No arguments needed.",
    inputSchema: NO_PARAM_SCHEMA,
  },
  {
    name: "get_ram_info",
    description: "Get RAM: total/used/available GB, usage %, DIMM slots (capacity, speed MHz, DDR/LPDDR type). No arguments needed.",
    inputSchema: NO_PARAM_SCHEMA,
  },
  {
    name: "get_fan_info",
    description: "Get fan info. RPM is rarely exposed by standard Windows WMI; a note explains when unavailable. No arguments needed.",
    inputSchema: NO_PARAM_SCHEMA,
  },
  {
    name: "get_disk_info",
    description: "Get disk info: model, size GB, media type, interface, serial number (partially masked by default), volume usage, read/write bytes/sec. No arguments needed.",
    inputSchema: NO_PARAM_SCHEMA,
  },
  {
    name: "get_network_info",
    description: "Get network adapters: IP, MAC, DHCP, DNS, gateway (identifiers partially masked by default), throughput bytes/sec. No arguments needed.",
    inputSchema: NO_PARAM_SCHEMA,
  },
  {
    name: "get_all_system_info",
    description: "Get ALL PC metrics at once: overview + CPU + GPU/NPU + power + RAM + fans + disks + network. Use for a full health check. No arguments needed.",
    inputSchema: NO_PARAM_SCHEMA,
  },
  {
    name: "get_server_info",
    description: "Get MCP server info: platform, WSL status, feature flags (privacy mode etc.). No arguments needed.",
    inputSchema: NO_PARAM_SCHEMA,
  },
];

// ── Aliases: absorb alternate names used by local LLMs ────
// Note: these are NOT advertised via ListTools; they exist only as a
// safety net for local models that hallucinate tool names.
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
  "power_info":       "get_power_info",
  "get_power":        "get_power_info",
  "pc_power_info":    "get_power_info",
  "energy_info":      "get_power_info",
  "npu_info":         "get_gpu_info",
  "get_npu_info":     "get_gpu_info",
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
  get_power_info:      "power",
  get_ram_info:        "ram",
  get_fan_info:        "fan",
  get_disk_info:       "disk",
  get_network_info:    "network",
  get_all_system_info: "all",
};

// ── MCP Server ────────────────────────────────────────────
const server = new Server(
  { name: "pc-system-info-mcp", version: SERVER_VERSION },
  { capabilities: { tools: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({ tools: TOOLS }));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  // Alias resolution (handles local LLMs calling by alternate names)
  const rawName = request.params.name;
  const name = TOOL_ALIASES[rawName] ?? rawName;

  if (name === "get_server_info") {
    return {
      content: [{
        type: "text",
        text: JSON.stringify({
          serverName: "pc-system-info-mcp", serverVersion: SERVER_VERSION,
          platform: PLATFORM, isWSL: IS_WSL, isWindows: IS_WINDOWS, isMacos: IS_MACOS,
          nodeVersion: process.version,
          privacyMode: PRIVACY_MODE, lenientMode: LENIENT_MODE, cacheTtlMs: CACHE_TTL_MS,
          calledAs: rawName !== name ? `${rawName} → ${name}` : name,
          privacyModeHelp: "partial (default) = last 4 chars visible, full = [REDACTED], off = no masking",
          supportedOS: ["Windows 10 21H1+", "Windows 11", "macOS 12+", "WSL2"],
        }, null, 2),
      }],
    };
  }

  const category = TOOL_CATEGORY[name];
  if (!category) {
    if (LENIENT_MODE) {
      // Opt-in legacy behavior: unknown tool → return everything
      process.stderr.write(`[pc-system-info-mcp] Unknown tool "${rawName}", lenient fallback to get_all_system_info\n`);
      const data = await fetchSystemInfo("all");
      return { content: [{ type: "text", text: JSON.stringify(data, null, 2) }] };
    }
    return {
      isError: true,
      content: [{
        type: "text",
        text: `Unknown tool: "${rawName}". Available tools: ${TOOLS.map(t => t.name).join(", ")}`,
      }],
    };
  }

  const data = await fetchSystemInfo(category);
  return { content: [{ type: "text", text: JSON.stringify(data, null, 2) }] };
});

// ── Entry point ───────────────────────────────────────────
async function main(): Promise<void> {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  process.stderr.write(
    `[pc-system-info-mcp] Ready v${SERVER_VERSION} | platform=${PLATFORM} wsl=${IS_WSL} privacy=${PRIVACY_MODE} lenient=${LENIENT_MODE}\n`
  );
}

main().catch((err) => {
  process.stderr.write(`[pc-system-info-mcp] Fatal: ${String(err)}\n`);
  process.exit(1);
});
