// Unit tests for PRIVACY_MODE masking. Run: npm run build && npm test
import { applyPrivacy, parsePrivacyMode, maskTail } from "../dist/privacy.js";
import assert from "node:assert/strict";
const sample = {
  disk: { drives: [
    { model: "WD PC SN740", serialNumber: "E823_8FA6_BF53_0001_001B_448B_4CDF_DB96." },
    { model: "ASMT", serialNumber: "00000000000000000000" },
    { model: "x", serialNumber: null },
  ]},
  network: { adapters: [{ description: "ASIX", macAddress: "C8:A3:62:18:8D:2D",
    ipAddresses: ["192.168.1.13", "2400:2650:2203:5b00:39e3:f901:c5ef:92bb"], gateway: ["192.168.1.1"], dns: ["192.168.1.1"], dhcp: true }]},
};
for (const [raw, exp] of [[undefined,"partial"],["","partial"],["full","full"],["1","full"],["ON","full"],["off","off"],["0","off"],["weird","partial"]])
  assert.equal(parsePrivacyMode(raw), exp, `parse ${raw}`);
assert.equal(maskTail("C8:A3:62:18:8D:2D"), "**:**:**:**:8D:2D");
assert.equal(maskTail("E823_8FA6_BF53_0001_001B_448B_4CDF_DB96."), "****_****_****_****_****_****_****_DB96.");
assert.equal(maskTail("192.168.1.13"), "***.**8.1.13");
assert.equal(maskTail("1234"), "****");
assert.equal(maskTail(""), "");
const p = applyPrivacy(sample, "partial");

assert.equal(p.disk.drives[0].model, "WD PC SN740");
assert.equal(p.disk.drives[2].serialNumber, null);
assert.equal(p.network.adapters[0].dhcp, true);
assert.equal(applyPrivacy(sample, "full").network.adapters[0].macAddress, "[REDACTED]");
assert.deepEqual(applyPrivacy(sample, "off"), sample);
assert.equal(sample.network.adapters[0].macAddress, "C8:A3:62:18:8D:2D", "input not mutated");
console.log("ALL PRIVACY TESTS PASSED");
