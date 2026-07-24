import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { withFileLock } from "./file-lock.mjs";

export function getDataDir() {
  let override = process.env.BYOK_CLI_HUB_DATA_DIR?.trim() || process.env.BYOK_MODEL_V3_DATA_DIR?.trim();
  if (override && process.platform !== "win32" && (/^[A-Za-z]:\\/.test(override) || override.includes("\\"))) {
    override = null;
  }
  if (override) return path.resolve(override);
  const current = path.join(os.homedir(), ".byok-cli-hub");
  const legacy = path.join(os.homedir(), ".copilot", "byok-model-v3");
  return fs.existsSync(current) || !fs.existsSync(legacy) ? current : legacy;
}

function readJsonStrict(filePath, fallback) {
  if (!fs.existsSync(filePath)) return fallback;
  try {
    return JSON.parse(fs.readFileSync(filePath, "utf8"));
  } catch (error) {
    throw new Error(`Invalid or unreadable BYOK data file '${filePath}': ${error.message}`);
  }
}

function syncDirectory(dir) {
  let descriptor;
  try {
    descriptor = fs.openSync(dir, "r");
    fs.fsyncSync(descriptor);
  } catch {
  } finally {
    if (descriptor !== undefined) fs.closeSync(descriptor);
  }
}

function writeJsonUnlocked(filePath, value) {
  const dir = path.dirname(filePath);
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  const tmp = `${filePath}.${process.pid}.${Date.now()}.${Math.random().toString(36).slice(2)}.tmp`;
  let descriptor;
  try {
    descriptor = fs.openSync(tmp, "wx", 0o600);
    fs.writeFileSync(descriptor, `${JSON.stringify(value, null, 2)}\n`, "utf8");
    fs.fsyncSync(descriptor);
    fs.closeSync(descriptor);
    descriptor = undefined;
    fs.renameSync(tmp, filePath);
    if (process.platform !== "win32") fs.chmodSync(filePath, 0o600);
    syncDirectory(dir);
  } catch (error) {
    if (descriptor !== undefined) try { fs.closeSync(descriptor); } catch {}
    try { fs.unlinkSync(tmp); } catch {}
    throw error;
  }
}

export function readState(dataDir = getDataDir()) {
  return readJsonStrict(path.join(dataDir, "state.json"), null);
}

export function writeState(state, dataDir = getDataDir()) {
  const filePath = path.join(dataDir, "state.json");
  withFileLock(filePath, () => writeJsonUnlocked(filePath, state));
}

export function updateState(updater, dataDir = getDataDir()) {
  const filePath = path.join(dataDir, "state.json");
  return withFileLock(filePath, () => {
    const updated = updater(readJsonStrict(filePath, null));
    writeJsonUnlocked(filePath, updated);
    return updated;
  });
}

export function readCache(dataDir = getDataDir()) {
  return readJsonStrict(path.join(dataDir, "models-cache.json"), { version: 1, caches: {} });
}
