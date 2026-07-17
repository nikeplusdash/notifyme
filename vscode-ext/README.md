# NotifyMe Bridge

The VS Code half of NotifyMe. The Swift menu-bar app cannot focus a specific VS Code
terminal tab — VS Code exposes no AppleScript interface — so this extension does it.

## How the join works

A Claude Code session runs as:

```
claude (pid 8835)  ->  /bin/zsh (pid 8413)  ->  VS Code "Code Helper" (the pty host)
```

`vscode.Terminal.processId` resolves to the **shell** pid (the zsh), never the claude pid.
So the join key is:

```
claude.ppid === terminal.processId        // we call that number `shellPid`
```

The Swift app resolves claude's parent pid and POSTs it here. Each VS Code window runs its
own extension host, so **each window registers its own port and its own server**. The Swift
app broadcasts `POST /focus` to all of them; the window that owns the terminal answers `200`,
every other window answers `404`. A 404 is normal, not an error.

## Registration file

On activate, the extension listens on an ephemeral port and writes:

`~/.notifyme/ide/<port>.json`

```json
{
  "port": 51234,
  "pid": 12345,
  "workspace": "/Users/nikeshkumar/Documents/Projects/DataMap",
  "ideName": "Visual Studio Code",
  "startedAt": 1783980000000
}
```

- `workspace` is the first `vscode.workspace.workspaceFolders` entry, or `null` when the
  window has no folder open.
- `pid` is the **extension host** pid (`process.pid`) — unique per window, and it dies with
  the window. It is deliberately *not* the VS Code main-process pid, which every window
  shares and so cannot tell you whether a registration is stale.
- The file is `0600`, and is deleted on `deactivate()`.
- On activate, registrations whose `pid` is no longer alive are pruned (VS Code crashed, or
  was SIGKILLed, so `deactivate()` never ran).

## HTTP API

Plain `node:http`, bound to **127.0.0.1 only**. This is local IPC, not a network service.

### `GET /health`

```json
{ "ok": true, "workspace": "/Users/nikeshkumar/Documents/Projects/DataMap", "terminalCount": 3 }
```

### `GET /terminals` (debugging aid)

```json
{ "terminals": [ { "shellPid": 8413, "name": "zsh", "index": 0 } ] }
```

`shellPid` is `null` for a terminal whose shell has not finished spawning yet (VS Code has
not resolved `processId`). Such a terminal can never match.

### `POST /focus`

```json
{ "shellPid": 8413, "ancestorPids": [8413, 2034] }
```

`ancestorPids` is optional (claude's ancestry, nearest-first). It is tried in order when
`shellPid` itself does not match, which survives users who wrap claude in a subshell or a
wrapper script.

- **Match in this window** → `terminal.show(false)`, then raise the OS window →
  `200 { "focused": true, "matchedPid": 8413, "terminalName": "zsh", "index": 1, "windowRaised": true }`
- **No match in this window** → `404 { "focused": false }` (normal — another window owns it)
- **Nothing usable to match on** → `400`
- **Request carries an `Origin` header** → `403`. A native client never sends `Origin`; a
  browser always does cross-origin. This closes the only drive-by vector a loopback server
  has (a random web page POSTing `/focus` at you) and costs the Swift app nothing.

`terminalName`, `index` and `windowRaised` are additive debugging fields on top of the
contract. Swift's `Codable` ignores unknown keys, so they are safe to leave in.

## Build

```bash
npm install
npm run typecheck   # tsc --noEmit
npm run compile     # -> out/
npm test            # unit tests for the matching logic
```

No runtime dependencies. Only `@types/vscode`, `@types/node`, `typescript` as dev deps.

## Sideloading

Symlink the extension into VS Code (run from the repo root):

```bash
ln -sfn "$(pwd)/vscode-ext" ~/.vscode/extensions/notifyme-bridge
```

Confirm VS Code accepts the manifest:

```bash
$ code --list-extensions --show-versions | grep notifyme
notifyme.notifyme-bridge@0.1.0
```

### You must reload VS Code yourself

The extension only activates inside a real extension host, which means a window reload:

1. Run `npm run compile` (VS Code loads `out/`, not `src/`).
2. In **each** open VS Code window: Command Palette (`Cmd+Shift+P`) →
   **Developer: Reload Window**. New windows pick it up automatically.
3. Confirm every window registered:

   ```bash
   ls -la ~/.notifyme/ide/
   cat ~/.notifyme/ide/*.json
   ```

   You should see **one file per open VS Code window** (including any window with no folder
   open, which registers with `"workspace": null`).

4. Smoke-test the real thing. Pick a port from that directory, then:

   ```bash
   PORT=<port from the filename>
   curl -s http://127.0.0.1:$PORT/health
   curl -s http://127.0.0.1:$PORT/terminals          # find a real terminal's shellPid
   curl -s -X POST http://127.0.0.1:$PORT/focus \
        -H 'Content-Type: application/json' \
        -d '{"shellPid": <a shellPid from /terminals>}'
   ```

   That window should come to the foreground with that terminal focused.

5. There is also **NotifyMe: Show Bridge Status** in the Command Palette, which shows
   the port, workspace and live terminal list, and opens the `NotifyMe Bridge` output
   channel.

### Verifying without VS Code

`src/server.ts` takes a `BridgeHost` rather than importing `vscode`, so the whole server can
be booted in plain node against a mock terminal list — no extension host needed:

```js
const { startBridgeServer } = require('./out/server.js');

startBridgeServer({
  ideName: 'Visual Studio Code',
  getWorkspace: () => '/some/workspace',
  listTerminals: async () => [{ shellPid: 8413, name: 'zsh', index: 0, terminal: 'fake' }],
  focusTerminal: async () => ({ windowRaised: true }),
  log: console.error,
}).then((s) => console.log('listening on', s.port));
```

Likewise `src/terminals.ts` holds the matching rules as pure functions over an injected
terminal list, which is what `src/test/terminals.test.ts` exercises.

## Raising the window

`terminal.show(false)` focuses the terminal *within* its window, but it cannot bring VS Code's
OS window to the foreground — and on macOS a background app cannot raise itself.

So after showing the terminal, `/focus` also runs the built-in `workbench.action.focusWindow`,
which in VS Code's own source resolves to:

```js
hostService.focus(activeWindow, { mode: 2 /* Force */ })
// -> isMacintosh && Electron app.focus({ steal: true }), then raises THIS window
```

That is a real force-to-foreground, so **the extension completes the teleport on its own** —
the Swift app does not need Accessibility APIs or window-title matching to pick the right
window. The response reports `windowRaised` so the Swift side can tell whether it happened.
It is best-effort: a failure there never fails an otherwise good match.
