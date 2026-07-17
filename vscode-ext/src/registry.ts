/**
 * Ownership of `~/.notifyme/ide/<port>.json`.
 *
 * Every VS Code window runs its own extension host, so every window writes its own file.
 * That is by design: the Swift app broadcasts `POST /focus` to all of them and the window
 * that actually owns the terminal claims it (everyone else answers 404).
 */

import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';

export const REGISTRY_DIR = path.join(os.homedir(), '.notifyme', 'ide');

export interface Registration {
  readonly port: number;
  /**
   * The EXTENSION HOST pid (`process.pid`), which is unique per window and dies with it.
   * Deliberately not the VS Code main-process pid -- that is shared by every window and so
   * cannot tell you whether a given registration is stale.
   */
  readonly pid: number;
  /** First `vscode.workspace.workspaceFolders` entry, or null for a window with no folder open. */
  readonly workspace: string | null;
  readonly ideName: string;
  readonly startedAt: number;
}

export function registrationPath(port: number): string {
  return path.join(REGISTRY_DIR, `${port}.json`);
}

export function writeRegistration(registration: Registration): string {
  fs.mkdirSync(REGISTRY_DIR, { recursive: true });
  const file = registrationPath(registration.port);
  // 0o600: this file advertises a port that will focus the user's editor on demand.
  // Owner-only, same posture as Claude Code's own ~/.claude/ide/*.lock files.
  fs.writeFileSync(file, `${JSON.stringify(registration, null, 2)}\n`, { encoding: 'utf8', mode: 0o600 });
  return file;
}

export function deleteRegistration(port: number): void {
  try {
    fs.unlinkSync(registrationPath(port));
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== 'ENOENT') {
      throw error;
    }
  }
}

/** True if a pid is still alive. EPERM means the process exists but is not ours -- still alive. */
export function isProcessAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return (error as NodeJS.ErrnoException).code === 'EPERM';
  }
}

/**
 * Drop registrations whose extension host is gone (VS Code crashed, or was SIGKILLed, so
 * `deactivate()` never ran). Without this the Swift app would keep dialing dead ports.
 *
 * Best-effort: a malformed or unreadable file is left alone rather than risking deleting
 * something another window is actively using.
 */
export function pruneStaleRegistrations(): string[] {
  let entries: string[];
  try {
    entries = fs.readdirSync(REGISTRY_DIR);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') {
      return [];
    }
    throw error;
  }

  const pruned: string[] = [];
  for (const entry of entries) {
    if (!entry.endsWith('.json')) {
      continue;
    }
    const file = path.join(REGISTRY_DIR, entry);
    try {
      const parsed = JSON.parse(fs.readFileSync(file, 'utf8')) as Partial<Registration>;
      if (typeof parsed.pid !== 'number' || isProcessAlive(parsed.pid)) {
        continue;
      }
      fs.unlinkSync(file);
      pruned.push(file);
    } catch {
      // Unparseable or racing with another window's write. Leave it.
    }
  }
  return pruned;
}
