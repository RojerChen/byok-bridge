import readline from 'node:readline';

export class InputCancelledError extends Error {
  constructor() {
    super('Input cancelled.');
    this.name = 'InputCancelledError';
    this.exitCode = 130;
  }
}

export class NonInteractiveInputError extends Error {
  constructor() {
    super('Interactive input is unavailable because stdin or stdout is not a TTY.');
    this.name = 'NonInteractiveInputError';
    this.exitCode = 1;
  }
}

/**
 * Reads user input securely without echoing (masked prompt for secrets/API keys).
 */
export async function readMaskedPrompt(promptText = 'API key: ') {
  if (!process.stdin.isTTY || !process.stdout.isTTY) throw new NonInteractiveInputError();

  return new Promise((resolve, reject) => {
    process.stdout.write(promptText);

    const isRaw = process.stdin.isRaw;
    const rejectWithCode = (message, exitCode) => {
      const error = new Error(message);
      error.exitCode = exitCode;
      cleanup();
      reject(error);
    };

    const onSigint = () => {
      cleanup();
      reject(new InputCancelledError());
    };
    const onSigterm = () => rejectWithCode('Input terminated.', 143);
    const onSighup = () => rejectWithCode('Input terminated.', 129);
    const onError = (error) => {
      cleanup();
      reject(error);
    };
    const onEnd = () => rejectWithCode('Input stream ended before a value was entered.', 1);

    const cleanup = () => {
      process.stdin.removeListener('data', onData);
      process.stdin.removeListener('error', onError);
      process.stdin.removeListener('end', onEnd);
      process.removeListener('SIGINT', onSigint);
      process.removeListener('SIGTERM', onSigterm);
      process.removeListener('SIGHUP', onSighup);
      try { process.stdin.setRawMode(isRaw); } catch {}
      process.stdin.pause();
    };

    process.stdin.setRawMode(true);
    process.stdin.resume();
    process.stdin.setEncoding('utf8');

    let input = '';

    const onData = (char) => {
      // Handle Ctrl+C
      if (char === '\u0003') {
        process.stdout.write('\n');
        onSigint();
        return;
      }

      // Handle Enter (CR/LF)
      if (char === '\r' || char === '\n') {
        cleanup();
        process.stdout.write('\n');
        resolve(input.trim());
        return;
      }

      // Handle Backspace (0x08, 0x7f)
      if (char === '\u0008' || char === '\x7f') {
        if (input.length > 0) {
          input = input.slice(0, -1);
        }
        return;
      }

      // Accumulate readable characters
      input += char;
    };

    process.stdin.on('data', onData);
    process.stdin.once('error', onError);
    process.stdin.once('end', onEnd);
    process.once('SIGINT', onSigint);
    process.once('SIGTERM', onSigterm);
    process.once('SIGHUP', onSighup);
  });
}

/**
 * Reads standard text line input from user.
 */
export async function readInput(promptText = '', defaultValue = '') {
  if (!process.stdin.isTTY || !process.stdout.isTTY) throw new NonInteractiveInputError();

  const rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout
  });

  return new Promise((resolve, reject) => {
    const fullPrompt = defaultValue ? `${promptText} (default: ${defaultValue}): ` : `${promptText}: `;
    const cleanup = () => {
      rl.close();
      process.removeListener('SIGINT', onSigint);
    };
    const onSigint = () => {
      cleanup();
      reject(new InputCancelledError());
    };
    process.once('SIGINT', onSigint);
    rl.on('SIGINT', onSigint);
    rl.question(fullPrompt, (answer) => {
      cleanup();
      const trimmed = (answer || '').trim();
      resolve(trimmed ? trimmed : defaultValue);
    });
  });
}

/**
 * Reads a numeric menu option.  The menu body is rendered by the caller so an
 * invalid entry can repeat only the prompt, as required by the UI contract.
 */
export async function readNumberSelection(promptText, min, max, defaultValue, { onInvalid } = {}) {
  while (true) {
    const answer = await readInput(promptText, String(defaultValue));
    if (/^\d+$/.test(answer) && Number.isSafeInteger(Number(answer))) {
      const value = Number(answer);
      if (value >= min && value <= max) return value;
    }
    onInvalid?.();
  }
}
