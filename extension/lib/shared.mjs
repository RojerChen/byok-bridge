import fs from "node:fs";
import os from "node:os";
import path from "node:path";

// Extension-side shared helpers. The manager side (PowerShell) owns fetch /
// cache merge / env templating; the extension only needs to read the JSON
// files the manager wrote and write back state on model switch.

export function getDataDir() {
  const override = process.env.BYOK_CLI_HUB_DATA_DIR?.trim() || process.env.BYOK_MODEL_V3_DATA_DIR?.trim();
  if (override) return path.resolve(override);
  const current = path.join(os.homedir(), ".byok-cli-hub");
  const legacy = path.join(os.homedir(), ".copilot", "byok-model-v3");
  return fs.existsSync(current) || !fs.existsSync(legacy) ? current : legacy;
}

function readJson(filePath, fallback) {
  if (!fs.existsSync(filePath)) return fallback;
  try {
    return JSON.parse(fs.readFileSync(filePath, "utf8"));
  } catch {
    return fallback;
  }
}

function writeJsonAtomic(filePath, value) {
  const dir = path.dirname(filePath);
  fs.mkdirSync(dir, { recursive: true });
  const tmp = `${filePath}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, `${JSON.stringify(value, null, 2)}\n`, { encoding: "utf8", mode: 0o600 });
  if (fs.existsSync(filePath)) fs.rmSync(filePath, { force: true });
  fs.renameSync(tmp, filePath);
}

export function readState() {
  return readJson(path.join(getDataDir(), "state.json"), null);
}

export function writeState(state) {
  writeJsonAtomic(path.join(getDataDir(), "state.json"), state);
}

export function readCache() {
  return readJson(path.join(getDataDir(), "models-cache.json"), { version: 1, caches: {} });
}
