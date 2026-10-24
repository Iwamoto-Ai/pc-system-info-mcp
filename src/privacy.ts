/**
 * Privacy handling for identifiers in collector output.
 *
 * PRIVACY_MODE (environment variable)
 *   unset / anything else  -> "partial" (default): keep only the last 4
 *                              alphanumeric characters, e.g. "****DB96"
 *   "full" | "1" | "on"    -> "full": replace with "[REDACTED]"
 *   "off"  | "0"           -> "off":  no masking
 *
 * "1" and "0" keep their v1.x meaning ("1" = hide, "0" = show) so that
 * existing configurations never silently lose their protection.
 */

export type PrivacyMode = "partial" | "full" | "off";

export type JsonValue =
  | string | number | boolean | null
  | JsonValue[]
  | { [key: string]: JsonValue };

/** Keys whose values are treated as identifiers (compared case-insensitively). */
export const IDENTIFIER_KEYS = new Set([
  "serialnumber", "macaddress", "ipaddress", "ipaddresses",
  "dns", "gateway", "defaultipgateway",
]);

export function parsePrivacyMode(raw: string | undefined): PrivacyMode {
  const v = (raw ?? "").trim().toLowerCase();
  if (["1", "full", "on", "true", "redact"].includes(v)) return "full";
  if (["0", "off", "false", "none"].includes(v)) return "off";
  return "partial";
}

const isAlnum = (c: string): boolean => /[0-9A-Za-z]/.test(c);

/**
 * Mask every alphanumeric character except the last `keep` ones.
 * Separators (":", ".", "-", "_" ...) are preserved so the format stays
 * recognizable. Values with `keep` or fewer alphanumerics are fully masked.
 *   "C8:A3:62:18:8D:2D"   -> "**:**:**:**:8D:2D"
 *   "WD-WX42D55E12DY"     -> "**-*******12DY"
 *   "192.168.1.13"        -> "***.**8.1.13"
 */
export function maskTail(value: string, keep = 4): string {
  const chars = Array.from(value);
  const total = chars.filter(isAlnum).length;
  const showFrom = total <= keep ? Number.POSITIVE_INFINITY : total - keep;
  let seen = 0;
  return chars
    .map((c) => {
      if (!isAlnum(c)) return c;
      const idx = seen++;
      return idx >= showFrom ? c : "*";
    })
    .join("");
}

function maskLeaf(value: JsonValue): JsonValue {
  if (value === null || typeof value === "boolean") return value;
  if (typeof value === "string") return maskTail(value);
  if (typeof value === "number") return maskTail(String(value));
  if (Array.isArray(value)) return value.map(maskLeaf);
  return applyPrivacy(value, "partial");
}

/** Return a copy of `value` with identifier fields masked according to `mode`. */
export function applyPrivacy(value: JsonValue, mode: PrivacyMode): JsonValue {
  if (mode === "off") return value;
  if (Array.isArray(value)) return value.map((v) => applyPrivacy(v, mode));
  if (value !== null && typeof value === "object") {
    const out: { [key: string]: JsonValue } = {};
    for (const [k, v] of Object.entries(value)) {
      if (IDENTIFIER_KEYS.has(k.toLowerCase())) {
        out[k] = mode === "full" ? "[REDACTED]" : maskLeaf(v);
      } else {
        out[k] = applyPrivacy(v, mode);
      }
    }
    return out;
  }
  return value;
}
