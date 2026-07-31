/**
 * Windows PATH management helpers.
 *
 * Reads and writes the user PATH from/to the Windows registry via reg.exe.
 * After writing, broadcasts WM_SETTINGCHANGE via a minimal PowerShell call so
 * existing terminals pick up the new value.
 *
 * For testability, all functions accept an optional `testPathFile` parameter.
 * When set, the file is used as the PATH store instead of the registry.
 */

import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

const HKCU_ENV = 'HKCU\\Environment';

function normalizePathEntry(entry) {
  if (!entry || !entry.trim()) return null;
  const trimmed = entry.trim().replace(/^"+|"+$/g, '');
  try {
    return path.normalize(trimmed).replace(/[/\\]+$/, '');
  } catch {
    return trimmed.replace(/[/\\]+$/, '');
  }
}

/**
 * Read the current user PATH. Returns the raw string value.
 */
export function getUserPath(testPathFile = null) {
  if (testPathFile) {
    if (!fs.existsSync(testPathFile)) return '';
    return fs.readFileSync(testPathFile, 'utf8');
  }
  const result = spawnSync('reg', ['query', HKCU_ENV, '/v', 'Path'], { encoding: 'utf8' });
  if (result.status !== 0) return '';
  // Output looks like:
  //   HKEY_CURRENT_USER\Environment
  //       Path    REG_EXPAND_SZ    C:\some\path;C:\other
  const match = result.stdout.match(/Path\s+REG_(?:EXPAND_)?SZ\s+(.*)/i);
  return match ? match[1].trim() : '';
}

/**
 * Write the user PATH. Broadcasts WM_SETTINGCHANGE after writing.
 */
export function setUserPath(newValue, testPathFile = null) {
  if (testPathFile) {
    const dir = path.dirname(testPathFile);
    if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(testPathFile, newValue, 'utf8');
    return;
  }
  const result = spawnSync('reg', [
    'add', HKCU_ENV, '/v', 'Path', '/t', 'REG_EXPAND_SZ', '/d', newValue, '/f'
  ], { encoding: 'utf8' });
  if (result.status !== 0) {
    throw new Error(`Failed to update user PATH in registry: ${result.stderr || result.stdout}`);
  }
  broadcastPathChange();
}

/**
 * Broadcast WM_SETTINGCHANGE so running programs can see the new PATH.
 * Uses a minimal PowerShell call — the only PS usage permitted in Phase 4.
 */
function broadcastPathChange() {
  try {
    const psScript = `
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace ByokBridge {
  public static class NativeMethods {
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern IntPtr SendMessageTimeout(IntPtr hWnd,uint msg,UIntPtr wParam,string lParam,uint flags,uint timeout,out UIntPtr result);
  }
}
'@
$r = [UIntPtr]::Zero
[void][ByokBridge.NativeMethods]::SendMessageTimeout([IntPtr]0xffff,0x001a,[UIntPtr]::Zero,'Environment',2,5000,[ref]$r)`;
    spawnSync('powershell', ['-NonInteractive', '-NoProfile', '-Command', psScript], { timeout: 8000 });
  } catch {
    // Non-fatal: users just need to open a new terminal.
  }
}

/**
 * Add `dir` to the user PATH if it is not already present.
 * Returns true if the PATH was modified, false if `dir` was already present.
 */
export function addToUserPath(dir, testPathFile = null) {
  const target = normalizePathEntry(dir);
  if (!target) throw new Error('A non-empty directory is required.');
  const current = getUserPath(testPathFile);
  const entries = current.split(';').filter(e => e.trim());
  const alreadyPresent = entries.some(e => {
    const norm = normalizePathEntry(e);
    return norm && norm.toLowerCase() === target.toLowerCase();
  });
  if (alreadyPresent) {
    console.log(`User PATH already contains: ${target}`);
    return false;
  }
  const newPath = [...entries, target].join(';');
  setUserPath(newPath, testPathFile);
  console.log(`Added to user PATH: ${target}`);
  return true;
}

/**
 * Remove `dir` from the user PATH.
 * Returns true if the PATH was modified, false if `dir` was not present.
 */
export function removeFromUserPath(dir, testPathFile = null) {
  const target = normalizePathEntry(dir);
  if (!target) throw new Error('A non-empty directory is required.');
  const current = getUserPath(testPathFile);
  const entries = current.split(';').filter(e => e.trim());
  const matching = entries.filter(e => {
    const norm = normalizePathEntry(e);
    return norm && norm.toLowerCase() === target.toLowerCase();
  });
  if (matching.length === 0) {
    console.log(`User PATH does not contain: ${target}`);
    return false;
  }
  const newEntries = entries.filter(e => {
    const norm = normalizePathEntry(e);
    return !(norm && norm.toLowerCase() === target.toLowerCase());
  });
  setUserPath(newEntries.join(';'), testPathFile);
  console.log(`Removed from user PATH: ${target}`);
  return true;
}
