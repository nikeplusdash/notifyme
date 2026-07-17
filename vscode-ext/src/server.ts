/**
 * The local IPC channel the NotifyMe menu-bar app talks to.
 *
 * Plain `node:http`, bound to 127.0.0.1 on an ephemeral port. This is IPC, not a network
 * service -- nothing here should ever be reachable off-box.
 *
 * The server takes a `BridgeHost` rather than importing `vscode` directly, so it can be
 * booted in plain node against a mock terminal list (see README > Verifying without VS Code).
 */

import * as http from 'node:http';
import { type FocusRequest, type TerminalCandidate, isValidPid, pickTerminal } from './terminals';

/** Bodies are tiny (a pid and a short ancestry array). Anything larger is a bug or an attack. */
export const MAX_BODY_BYTES = 64 * 1024;

export interface FocusOutcome {
  /**
   * Whether we also managed to bring the VS Code OS window to the foreground.
   * `terminal.show()` alone only moves focus *within* a window.
   */
  readonly windowRaised: boolean;
}

/** Everything the server needs from its host. The VS Code wiring lives in extension.ts. */
/**
 * Is the user looking at this window right now, and at which terminal inside it?
 *
 * Exists because the menu-bar app cannot answer that from outside. Every VS Code window in the
 * session shares one OS process, so "VS Code is frontmost" says nothing about *which* project the
 * user is looking at — and an app that suppressed notifications on that basis would silently swallow
 * every one of them, all day. Only the window itself knows.
 */
export interface FocusState {
  /** `vscode.window.state.focused` — is this window the one the user is in? */
  focused: boolean;
  /** Shell pid of this window's active terminal, or null if there isn't one. */
  activeTerminalShellPid: number | null;
}

export interface BridgeHost<T> {
  readonly ideName: string;
  getWorkspace(): string | null;
  listTerminals(): Promise<TerminalCandidate<T>[]>;
  focusTerminal(terminal: T): Promise<FocusOutcome>;
  getFocusState(): Promise<FocusState>;
  log(message: string): void;
}

export interface BridgeServer {
  readonly port: number;
  close(): Promise<void>;
}

/** Parse and validate a `POST /focus` body. Returns null if there is nothing usable to match on. */
export function parseFocusRequest(value: unknown): FocusRequest | null {
  if (typeof value !== 'object' || value === null) {
    return null;
  }
  const body = value as Record<string, unknown>;
  const shellPid = isValidPid(body.shellPid) ? body.shellPid : undefined;
  const ancestorPids = Array.isArray(body.ancestorPids) ? body.ancestorPids.filter(isValidPid) : undefined;
  if (shellPid === undefined && (ancestorPids === undefined || ancestorPids.length === 0)) {
    return null;
  }
  return { shellPid, ancestorPids };
}

export async function startBridgeServer<T>(host: BridgeHost<T>): Promise<BridgeServer> {
  const server = http.createServer((req, res) => {
    void handleRequest(host, req, res);
  });

  await new Promise<void>((resolve, reject) => {
    server.once('error', reject);
    // Port 0 = let the OS pick. 127.0.0.1 = loopback only, never 0.0.0.0.
    server.listen(0, '127.0.0.1', () => {
      server.removeListener('error', reject);
      resolve();
    });
  });

  const address = server.address();
  if (address === null || typeof address === 'string') {
    server.close();
    throw new Error(`expected a TCP address from listen(), got ${JSON.stringify(address)}`);
  }

  return {
    port: address.port,
    close: () =>
      new Promise<void>((resolve) => {
        server.close(() => resolve());
      }),
  };
}

async function handleRequest<T>(
  host: BridgeHost<T>,
  req: http.IncomingMessage,
  res: http.ServerResponse,
): Promise<void> {
  const method = req.method ?? 'GET';
  const pathname = new URL(req.url ?? '/', 'http://127.0.0.1').pathname;

  // A native client (URLSession, curl) never sends Origin; a browser always does on a
  // cross-origin request. Refusing it costs the Swift app nothing and closes the only
  // drive-by vector a loopback server has -- a random web page POSTing /focus at you.
  if (req.headers.origin !== undefined) {
    sendJson(res, 403, { error: 'forbidden', message: 'browser origins are not accepted' });
    return;
  }

  try {
    if (method === 'GET' && pathname === '/health') {
      const terminals = await host.listTerminals();
      const focus = await host.getFocusState();
      sendJson(res, 200, {
        ok: true,
        workspace: host.getWorkspace(),
        terminalCount: terminals.length,
        // Additive. The Swift client decodes unknown keys away, so an older client is unaffected —
        // and a *newer* client that gets no focus fields simply declines to suppress, which is the
        // safe direction: a spurious notification is a nuisance, a swallowed one is a broken feature.
        focused: focus.focused,
        activeTerminalShellPid: focus.activeTerminalShellPid,
      });
      return;
    }

    if (method === 'GET' && pathname === '/terminals') {
      const terminals = await host.listTerminals();
      sendJson(res, 200, {
        terminals: terminals.map((t) => ({
          // null, not undefined: the key must survive JSON.stringify even for a terminal
          // whose shell has not finished spawning.
          shellPid: t.shellPid ?? null,
          name: t.name,
          index: t.index,
        })),
      });
      return;
    }

    if (method === 'POST' && pathname === '/focus') {
      await handleFocus(host, req, res);
      return;
    }

    sendJson(res, 404, { error: 'not_found', message: `no route for ${method} ${pathname}` });
  } catch (error) {
    host.log(`error handling ${method} ${pathname}: ${describeError(error)}`);
    sendJson(res, 500, { error: 'internal_error', message: describeError(error) });
  }
}

async function handleFocus<T>(
  host: BridgeHost<T>,
  req: http.IncomingMessage,
  res: http.ServerResponse,
): Promise<void> {
  const raw = await readBody(req);

  let parsed: unknown;
  try {
    parsed = JSON.parse(raw.trim() === '' ? '{}' : raw);
  } catch {
    sendJson(res, 400, { error: 'invalid_json', message: 'body must be JSON' });
    return;
  }

  const request = parseFocusRequest(parsed);
  if (request === null) {
    sendJson(res, 400, {
      error: 'invalid_request',
      message: 'need a positive integer shellPid, or a non-empty ancestorPids array',
    });
    return;
  }

  const terminals = await host.listTerminals();
  const match = pickTerminal(terminals, request);

  if (match === null) {
    // Expected for every window that does not own this session. Not an error.
    host.log(`no terminal for shellPid=${String(request.shellPid)} in this window`);
    sendJson(res, 404, { focused: false });
    return;
  }

  const outcome = await host.focusTerminal(match.terminal);
  host.log(`focused "${match.name}" (shellPid=${match.matchedPid}, windowRaised=${outcome.windowRaised})`);
  sendJson(res, 200, {
    focused: true,
    matchedPid: match.matchedPid,
    // Additive, purely for debugging. Unknown keys are ignored by Swift's Codable.
    terminalName: match.name,
    index: match.index,
    windowRaised: outcome.windowRaised,
  });
}

function readBody(req: http.IncomingMessage): Promise<string> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    let size = 0;
    req.on('data', (chunk: Buffer) => {
      size += chunk.length;
      if (size > MAX_BODY_BYTES) {
        reject(new Error(`request body exceeded ${MAX_BODY_BYTES} bytes`));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

function sendJson(res: http.ServerResponse, status: number, body: unknown): void {
  const payload = Buffer.from(`${JSON.stringify(body)}\n`, 'utf8');
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': payload.byteLength,
    'Cache-Control': 'no-store',
  });
  res.end(payload);
}

function describeError(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
