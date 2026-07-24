import fs from "node:fs";
import path from "node:path";

const LOCK_TIMEOUT_MS = 3000;
const STALE_LOCK_MS = 30000;
const sleepCell = new Int32Array(new SharedArrayBuffer(4));
const BUSY_OR_UNKNOWN_CODES = new Set(["EBUSY", "EACCES", "EPERM"]);

function sleep(milliseconds) {
  Atomics.wait(sleepCell, 0, 0, milliseconds);
}

function getLockOwnerStatus(lockPath) {
  let ownerText;
  try {
    ownerText = fs.readFileSync(lockPath, "utf8").trim();
  } catch (error) {
    if (error?.code === "ENOENT") return "missing";
    return "unknown";
  }

  const ownerPid = Number.parseInt(ownerText.split(/\s+/)[0], 10);
  if (!Number.isInteger(ownerPid) || ownerPid <= 0) return "dead";

  try {
    process.kill(ownerPid, 0);
    return "alive";
  } catch (error) {
    if (error?.code === "ESRCH") return "dead";
    if (error?.code === "EPERM") return "alive";
    return "unknown";
  }
}

function removeAbandonedLock(lockPath) {
  try {
    fs.unlinkSync(lockPath);
    return true;
  } catch (error) {
    if (error?.code === "ENOENT") return true;
    if (BUSY_OR_UNKNOWN_CODES.has(error?.code)) return false;
    throw error;
  }
}

/**
 * Runs a synchronous operation while holding the cross-runtime BYOK data lock.
 * A stale lock is removed only when its recorded owner can be proven dead.
 */
export function withFileLock(
  filePath,
  operation,
  timeoutMs = LOCK_TIMEOUT_MS,
  staleLockMs = STALE_LOCK_MS
) {
  const lockPath = `${filePath}.lock`;
  const deadline = Date.now() + timeoutMs;
  const directory = path.dirname(filePath);
  fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
  if (process.platform !== "win32") fs.chmodSync(directory, 0o700);

  while (true) {
    let descriptor;
    let created = false;
    try {
      descriptor = fs.openSync(lockPath, "wx", 0o600);
      created = true;
      fs.writeFileSync(descriptor, `${process.pid} ${new Date().toISOString()}\n`, "utf8");
      fs.fsyncSync(descriptor);
      fs.closeSync(descriptor);
      descriptor = undefined;
      break;
    } catch (error) {
      if (descriptor !== undefined) {
        try { fs.closeSync(descriptor); } catch {}
      }
      if (created) {
        try { fs.unlinkSync(lockPath); } catch {}
        throw error;
      }
      if (error?.code !== "EEXIST") throw error;

      try {
        const age = Date.now() - fs.statSync(lockPath).mtimeMs;
        if (age > staleLockMs) {
          const ownerStatus = getLockOwnerStatus(lockPath);
          if (ownerStatus === "missing") continue;
          if (ownerStatus === "dead" && removeAbandonedLock(lockPath)) continue;
        }
      } catch (statError) {
        if (statError?.code === "ENOENT") continue;
        if (!BUSY_OR_UNKNOWN_CODES.has(statError?.code)) throw statError;
      }

      if (Date.now() >= deadline) {
        throw new Error(`Timed out waiting for data lock '${lockPath}'.`);
      }
      sleep(25);
    }
  }

  try {
    return operation();
  } finally {
    try { fs.unlinkSync(lockPath); } catch {}
  }
}
