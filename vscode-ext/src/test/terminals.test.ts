import assert from 'node:assert/strict';
import { describe, it } from 'node:test';

import { candidatePids, isValidPid, pickTerminal, type TerminalCandidate, type TerminalMatch } from '../terminals';
import { parseFocusRequest } from '../server';

/**
 * The terminal handle is opaque to the matcher, so a string stands in for `vscode.Terminal`.
 * This is the whole point of keeping terminals.ts free of any `vscode` import.
 */
type FakeTerminal = string;

function terminals(...rows: Array<[name: string, shellPid: number | undefined]>): TerminalCandidate<FakeTerminal>[] {
  return rows.map(([name, shellPid], index) => ({ name, shellPid, index, terminal: `handle:${name}` }));
}

/** Unwrap a match, failing the test if there isn't one. Keeps the assertions below null-free. */
function expectMatch<T>(match: TerminalMatch<T> | null): TerminalMatch<T> {
  if (match === null) {
    throw new Error('expected a terminal match, got null');
  }
  return match;
}

// The real ancestry verified on this machine: claude 8835 <- zsh 8413 <- Code Helper 2034.
const SHELL_PID = 8413;
const PTY_HOST_PID = 2034;

describe('isValidPid', () => {
  it('accepts positive integers', () => {
    assert.equal(isValidPid(1), true);
    assert.equal(isValidPid(SHELL_PID), true);
  });

  it('rejects everything that is not a positive integer', () => {
    for (const bad of [0, -1, 1.5, NaN, Infinity, '8413', null, undefined, {}, []]) {
      assert.equal(isValidPid(bad), false, `expected ${JSON.stringify(bad)} to be rejected`);
    }
  });
});

describe('candidatePids', () => {
  it('puts shellPid first, then ancestors nearest-first', () => {
    assert.deepEqual(candidatePids({ shellPid: 8413, ancestorPids: [9001, 2034] }), [8413, 9001, 2034]);
  });

  it('collapses the duplicate when the caller repeats shellPid as ancestorPids[0]', () => {
    // The natural way to build an ancestry chain, so it must cost nothing.
    assert.deepEqual(candidatePids({ shellPid: 8413, ancestorPids: [8413, 2034] }), [8413, 2034]);
  });

  it('drops invalid pids instead of matching on garbage', () => {
    assert.deepEqual(candidatePids({ shellPid: 0, ancestorPids: [-1, 1.5, NaN, 2034] }), [2034]);
  });

  it('works with ancestors only, or with nothing at all', () => {
    assert.deepEqual(candidatePids({ ancestorPids: [8413] }), [8413]);
    assert.deepEqual(candidatePids({}), []);
  });
});

describe('pickTerminal', () => {
  const window = terminals(['bash', 1111], ['zsh', SHELL_PID], ['pwsh', 3333]);

  it('matches the terminal whose processId is the claude parent shell', () => {
    const match = expectMatch(pickTerminal(window, { shellPid: SHELL_PID }));
    assert.equal(match.matchedPid, SHELL_PID);
    assert.equal(match.terminal, 'handle:zsh');
    assert.equal(match.index, 1);
    assert.equal(match.name, 'zsh');
  });

  it('returns null when this window does not own the session', () => {
    // The normal outcome for every window except the owner -- the server turns this into a 404.
    assert.equal(pickTerminal(window, { shellPid: 9999 }), null);
    assert.equal(pickTerminal([], { shellPid: SHELL_PID }), null);
  });

  it('falls back to the ancestry chain when shellPid itself does not match', () => {
    // The wrapper-script case: claude -> wrapper subshell (9001) -> the real terminal shell.
    const match = expectMatch(pickTerminal(window, { shellPid: 9001, ancestorPids: [9001, SHELL_PID, PTY_HOST_PID] }));
    assert.equal(match.matchedPid, SHELL_PID);
    assert.equal(match.terminal, 'handle:zsh');
  });

  it('prefers the nearest ancestor even when a further one sits earlier in the terminal list', () => {
    // 'bash' is index 0 and 'zsh' is index 1, but 8413 is the closer ancestor, so zsh must win.
    // This is why the candidate pid is the outer loop, not the terminal.
    const match = expectMatch(pickTerminal(window, { ancestorPids: [SHELL_PID, 1111] }));
    assert.equal(match.matchedPid, SHELL_PID);
    assert.equal(match.terminal, 'handle:zsh');
  });

  it('ignores terminals whose shell has not spawned yet (processId still undefined)', () => {
    const starting = terminals(['booting', undefined], ['zsh', SHELL_PID]);
    assert.equal(pickTerminal(starting, { shellPid: undefined }), null);
    const match = expectMatch(pickTerminal(starting, { shellPid: SHELL_PID }));
    assert.equal(match.terminal, 'handle:zsh');
  });

  it('never matches on an invalid pid', () => {
    assert.equal(pickTerminal(window, { shellPid: 0 }), null);
    assert.equal(pickTerminal(window, { ancestorPids: [] }), null);
  });

  it('breaks ties on the lowest index regardless of input order', () => {
    const shuffled: TerminalCandidate<FakeTerminal>[] = [
      { name: 'later', shellPid: SHELL_PID, index: 4, terminal: 'handle:later' },
      { name: 'earlier', shellPid: SHELL_PID, index: 2, terminal: 'handle:earlier' },
    ];
    const match = expectMatch(pickTerminal(shuffled, { shellPid: SHELL_PID }));
    assert.equal(match.terminal, 'handle:earlier');
    assert.equal(match.index, 2);
  });
});

describe('parseFocusRequest', () => {
  it('accepts the contract body', () => {
    assert.deepEqual(parseFocusRequest({ shellPid: 8413, ancestorPids: [8413, 2034] }), {
      shellPid: 8413,
      ancestorPids: [8413, 2034],
    });
  });

  it('accepts shellPid alone (ancestorPids is optional)', () => {
    assert.deepEqual(parseFocusRequest({ shellPid: 8413 }), { shellPid: 8413, ancestorPids: undefined });
  });

  it('filters junk out of ancestorPids rather than rejecting the whole request', () => {
    assert.deepEqual(parseFocusRequest({ shellPid: 8413, ancestorPids: ['x', -3, 2034] }), {
      shellPid: 8413,
      ancestorPids: [2034],
    });
  });

  it('rejects a body with nothing usable to match on', () => {
    assert.equal(parseFocusRequest({}), null);
    assert.equal(parseFocusRequest({ shellPid: '8413' }), null);
    assert.equal(parseFocusRequest({ shellPid: 0, ancestorPids: [] }), null);
    assert.equal(parseFocusRequest(null), null);
    assert.equal(parseFocusRequest('nope'), null);
  });
});
