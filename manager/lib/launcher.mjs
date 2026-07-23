import { spawn } from 'node:child_process';
import path from 'node:path';
import fs from 'node:fs';

/**
 * Checks if an executable command exists in system PATH or at an absolute path.
 */
export function isExecutableInPath(command) {
  if (!command) return false;
  if (path.isAbsolute(command)) {
    try { return fs.existsSync(command); } catch { return false; }
  }

  const PATH = process.env.PATH || '';
  const pathDirs = PATH.split(path.delimiter);
  const extensions = process.platform === 'win32' ? ['.exe', '.cmd', '.bat', ''] : [''];

  for (const dir of pathDirs) {
    for (const ext of extensions) {
      const fullPath = path.join(dir, command + ext);
      try {
        if (fs.existsSync(fullPath)) {
          return true;
        }
      } catch {}
    }
  }
  return false;
}

/**
 * Launches the selected CLI executable with resolved arguments and environment map.
 */
export async function launchCli(command, args = [], envMap = {}, options = {}) {
  const { dryRun = false, refresh = false } = options;

  if (dryRun || refresh) {
    console.log('[DRY-RUN] Resolved CLI Command:', command);
    console.log('[DRY-RUN] Resolved Arguments:', args);
    console.log('[DRY-RUN] Environment Map (Redacted):');
    for (const [k, v] of Object.entries(envMap)) {
      if (k.includes('KEY') || k.includes('TOKEN') || k.includes('SECRET')) {
        console.log(`  ${k}: [SET (length: ${v ? String(v).length : 0}) redacting value]`);
      } else {
        console.log(`  ${k}: ${v}`);
      }
    }
    if (dryRun) {
      console.log('Dry run complete.');
      return 0;
    }
  }

  if (!isExecutableInPath(command)) {
    console.error(`Error: The command '${command}' was not found in PATH.`);
    console.error(`Please ensure '${command}' is installed and accessible in your environment.`);
    return 5;
  }

  const childEnv = { ...process.env, ...envMap };

  return new Promise((resolve) => {
    const child = spawn(command, args, {
      shell: false,
      stdio: 'inherit',
      env: childEnv
    });

    const sigHandler = (sig) => {
      if (child && !child.killed) {
        child.kill(sig);
      }
    };

    process.on('SIGINT', () => sigHandler('SIGINT'));
    process.on('SIGTERM', () => sigHandler('SIGTERM'));
    process.on('SIGHUP', () => sigHandler('SIGHUP'));

    child.on('error', (err) => {
      console.error(`Failed to launch child process '${command}':`, err.message);
      resolve(1);
    });

    child.on('close', (code, signal) => {
      if (signal) {
        resolve(128 + (signal === 'SIGINT' ? 2 : 15));
      } else {
        resolve(code ?? 0);
      }
    });
  });
}
