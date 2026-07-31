#!/usr/bin/env node
/**
 * Windows uninstaller CLI entry point.
 *
 * Usage: node windows-uninstaller-cli.mjs [--purge-data] [--yes]
 */

import process from 'node:process';
import { uninstallWindows, InstallerError } from './lib/windows-installer.mjs';

const args = process.argv.slice(2);
const options = {
  purgeData: args.includes('--purge-data'),
  yes: args.includes('--yes')
};

uninstallWindows(options).then(() => {
  process.exitCode = 0;
}).catch(err => {
  if (err instanceof InstallerError) {
    console.error(`Uninstaller error: ${err.message}`);
  } else {
    console.error(`Unexpected error: ${err.message}`);
    if (process.env.BYOK_BRIDGE_DEBUG) console.error(err.stack);
  }
  process.exitCode = 1;
});
