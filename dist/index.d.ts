#!/usr/bin/env node
/**
 * PC System Info MCP Server v1.2.0
 * - Supports Windows (PowerShell/CIM), macOS, and WSL (calls Windows-side PowerShell)
 * - Tool name aliases for local LLMs (Ollama etc.); extra arguments are ignored
 * - execFile-based invocation (no shell, no quoting pitfalls)
 * - Short-TTL result cache + in-flight request coalescing
 * - PRIVACY_MODE=1 redacts serial numbers / MAC / IP / DNS / gateway
 * - Unknown tools return an MCP error by default (MCP_LENIENT_MODE=1 restores
 *   the old "fall back to get_all_system_info" behavior for weak local LLMs)
 */
export {};
//# sourceMappingURL=index.d.ts.map