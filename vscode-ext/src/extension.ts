/**
 * NotifyMe Bridge -- the VS Code half of the "teleport me to that terminal" trick.
 *
 * VS Code exposes no AppleScript interface, so the Swift menu-bar app cannot focus a
 * specific terminal tab on its own. It resolves a claude process's parent shell pid and
 * POSTs it here; we find the matching `vscode.Terminal` and reveal it.
 *
 * One extension host per VS Code window means one server (and one registration file) per
 * window. The Swift app broadcasts to all of them; the window that owns the terminal
 * answers 200, everyone else answers 404.
 */

import * as vscode from 'vscode';
import {
  type BridgeHost,
  type BridgeServer,
  type FocusOutcome,
  type FocusState,
  startBridgeServer,
} from './server';
import { deleteRegistration, pruneStaleRegistrations, writeRegistration } from './registry';
import type { TerminalCandidate } from './terminals';

const IDE_NAME = 'Visual Studio Code';

let output: vscode.OutputChannel | undefined;
let server: BridgeServer | undefined;
let registeredPort: number | undefined;

function log(message: string): void {
  output?.appendLine(`[${new Date().toISOString()}] ${message}`);
}

export async function activate(context: vscode.ExtensionContext): Promise<void> {
  output = vscode.window.createOutputChannel('NotifyMe Bridge');
  context.subscriptions.push(output);

  const host: BridgeHost<vscode.Terminal> = {
    ideName: IDE_NAME,
    getWorkspace,
    listTerminals,
    focusTerminal,
    getFocusState,
    log,
  };

  context.subscriptions.push(
    vscode.commands.registerCommand('notifyMe.showBridgeStatus', () => void showStatus()),
  );

  try {
    // Sweep registrations left behind by windows that were killed before deactivate() ran.
    for (const file of pruneStaleRegistrations()) {
      log(`pruned stale registration ${file}`);
    }

    server = await startBridgeServer(host);
    registeredPort = server.port;

    const file = writeRegistration({
      port: server.port,
      pid: process.pid,
      workspace: getWorkspace(),
      ideName: IDE_NAME,
      startedAt: Date.now(),
    });

    log(`listening on 127.0.0.1:${server.port}, registered at ${file}`);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    log(`failed to start bridge: ${message}`);
    void vscode.window.showErrorMessage(`NotifyMe Bridge failed to start: ${message}`);
  }
}

export async function deactivate(): Promise<void> {
  if (registeredPort !== undefined) {
    try {
      deleteRegistration(registeredPort);
    } catch (error) {
      log(`failed to delete registration: ${error instanceof Error ? error.message : String(error)}`);
    }
    registeredPort = undefined;
  }
  if (server !== undefined) {
    await server.close();
    server = undefined;
  }
}

function getWorkspace(): string | null {
  return vscode.workspace.workspaceFolders?.[0]?.uri.fsPath ?? null;
}

/**
 * Whether the user is looking at *this* window, and at which terminal inside it.
 *
 * This is the only place the answer exists. From outside, every VS Code window shares one OS process
 * (pid 1334 on this machine), so the menu-bar app can see that "VS Code is frontmost" and nothing
 * more — not which project, and certainly not which terminal tab. It was suppressing every
 * notification on that basis, which meant that while you were working in VS Code — i.e. always — you
 * were told about nothing.
 *
 * `vscode.window.state.focused` is per-window and true only for the one the user is actually in.
 */
async function getFocusState(): Promise<FocusState> {
  const active = vscode.window.activeTerminal;
  const pid = active ? await Promise.resolve(active.processId).catch(() => undefined) : undefined;
  return {
    focused: vscode.window.state.focused,
    activeTerminalShellPid: pid ?? null,
  };
}

async function listTerminals(): Promise<TerminalCandidate<vscode.Terminal>[]> {
  const terminals = vscode.window.terminals;
  // `processId` is a Thenable that settles once the shell is spawned. Resolve them in
  // parallel; a terminal still starting up simply has no pid yet and cannot match.
  const pids = await Promise.all(
    terminals.map((terminal) => Promise.resolve(terminal.processId).catch(() => undefined)),
  );
  return terminals.map((terminal, index) => ({
    shellPid: pids[index],
    name: terminal.name,
    index,
    terminal,
  }));
}

async function focusTerminal(terminal: vscode.Terminal): Promise<FocusOutcome> {
  // `false` = do NOT preserve focus, i.e. actually put the cursor in this terminal.
  terminal.show(false);

  // ...but that only moves focus *within* this window. It cannot bring VS Code's OS window
  // to the foreground, and a background app cannot raise itself on macOS. This command can:
  // workbench.action.focusWindow -> hostService.focus(activeWindow, { mode: Force })
  //   -> isMacintosh && Electron app.focus({ steal: true }), then raises THIS window.
  // Ordering matters: show the terminal first so it is the focused element when the window
  // comes forward. Best-effort -- a missing command must never fail an otherwise good match.
  let windowRaised = false;
  try {
    await vscode.commands.executeCommand('workbench.action.focusWindow');
    windowRaised = true;
  } catch (error) {
    log(`could not raise window: ${error instanceof Error ? error.message : String(error)}`);
  }

  return { windowRaised };
}

async function showStatus(): Promise<void> {
  if (server === undefined) {
    void vscode.window.showWarningMessage('NotifyMe Bridge is not running. See the output channel.');
    return;
  }
  const terminals = await listTerminals();
  const summary = terminals.map((t) => `${t.name} (shellPid ${t.shellPid ?? '?'})`).join(', ') || 'none';
  void vscode.window.showInformationMessage(
    `NotifyMe Bridge on 127.0.0.1:${server.port} | workspace: ${getWorkspace() ?? 'none'} | terminals: ${summary}`,
  );
  output?.show(true);
}
