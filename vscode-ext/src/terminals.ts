/**
 * Pure terminal-matching logic for the NotifyMe bridge.
 *
 * A Claude Code session runs as:
 *
 *     claude  ->  /bin/zsh  ->  VS Code "Code Helper" (the shared pty host)
 *
 * `vscode.Terminal.processId` resolves to the SHELL pid (the zsh), never to the claude
 * pid. So the join key between the Swift app and this extension is:
 *
 *     claude.ppid === terminal.processId        (we call that number `shellPid`)
 *
 * This module deliberately does not import `vscode`, so the matching rules can be
 * unit-tested in plain node against a fabricated terminal list.
 */

/** One VS Code terminal reduced to the fields we match on. `T` is an opaque terminal handle. */
export interface TerminalCandidate<T> {
  /** Whatever `vscode.Terminal.processId` resolved to. `undefined` while the shell is still spawning. */
  readonly shellPid: number | undefined;
  readonly name: string;
  /** Position in `vscode.window.terminals`. */
  readonly index: number;
  readonly terminal: T;
}

export interface FocusRequest {
  readonly shellPid?: number;
  /** claude's full ancestry chain, nearest-first. Survives wrapper scripts and subshells. */
  readonly ancestorPids?: readonly number[];
}

export interface TerminalMatch<T> {
  readonly terminal: T;
  readonly matchedPid: number;
  readonly index: number;
  readonly name: string;
}

export function isValidPid(value: unknown): value is number {
  return typeof value === 'number' && Number.isInteger(value) && value > 0;
}

/**
 * The pids to try, most-specific first: the shell pid, then each ancestor nearest-first.
 *
 * Invalid entries are dropped and duplicates collapsed, so a caller that repeats shellPid
 * as `ancestorPids[0]` (the natural way to build an ancestry chain) costs nothing.
 */
export function candidatePids(request: FocusRequest): number[] {
  const ordered = [request.shellPid, ...(request.ancestorPids ?? [])];
  const seen = new Set<number>();
  const result: number[] = [];
  for (const pid of ordered) {
    if (!isValidPid(pid) || seen.has(pid)) {
      continue;
    }
    seen.add(pid);
    result.push(pid);
  }
  return result;
}

/**
 * Find the terminal in THIS window that owns the given claude session.
 *
 * The candidate pid is the OUTER loop on purpose: `ancestorPids` is nearest-first, so a
 * closer ancestor must win over a more distant one even when the distant one happens to
 * sit earlier in `vscode.window.terminals`.
 *
 * Ties within a single pid resolve to the lowest terminal index, so the answer does not
 * depend on the order the caller happened to build the array in.
 *
 * Returns `null` when nothing matches. That is the *normal* outcome for every window
 * except the one that actually owns the session -- the Swift app broadcasts to all
 * windows and the owner claims it.
 */
export function pickTerminal<T>(
  terminals: readonly TerminalCandidate<T>[],
  request: FocusRequest,
): TerminalMatch<T> | null {
  for (const pid of candidatePids(request)) {
    let best: TerminalCandidate<T> | undefined;
    for (const candidate of terminals) {
      if (candidate.shellPid !== pid) {
        continue;
      }
      if (best === undefined || candidate.index < best.index) {
        best = candidate;
      }
    }
    if (best !== undefined) {
      return {
        terminal: best.terminal,
        matchedPid: pid,
        index: best.index,
        name: best.name,
      };
    }
  }
  return null;
}
