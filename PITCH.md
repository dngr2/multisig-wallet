# Pitch

A self-hosted m-of-n multisig wallet + factory for teams, DAOs, and treasuries.
On-chain confirmations, no hosted service to trust. Solidity 0.8.26, Foundry,
MIT.

**The edge: the m-of-n threshold is enforced against the live owner set.** A
multisig's whole job is that m of the n owners must agree before funds move. The
quiet way that breaks is time — owners change, and approvals gathered under the
old set get counted under the new one. Here execution recounts confirmations
against the *current* owners at the moment it runs, so an approval from a removed
or replaced owner cannot push a transaction over the threshold. This repo's
second-pass review caught exactly that bug (a cached counter that ignored owner
removal — a high-severity break of the core guarantee), fixed it, and pinned it
with regression tests.

- **Live-owner threshold enforcement.** `executeTransaction` counts approvals
  against the current owner set; stale confirmations never count.
- **Self-governed owners, no backdoor.** Adding, removing, replacing owners and
  changing the threshold happen only through a fully-confirmed multisig
  transaction — no admin key, no deployer override. Removals that would make the
  threshold unsatisfiable revert.
- **Reentrancy-safe execution.** Checks-effects-interactions plus a reentrancy
  guard; failed inner calls revert cleanly and stay retryable.
- **Relayer-friendly EIP-712 execution.** One caller submits a batch of owner
  signatures; a consumed nonce and the EIP-712 domain block replay across calls
  and chains.
- **Per-transaction deadlines** and a **factory** that deploys, indexes, and
  charges a hard-capped flat fee.

**Tested, not just written.** 71 passing tests (0 failed): unit coverage, the
full EIP-712 flow, a reentrancy attack that cannot double-execute, two regression
tests for the caught stale-confirmation bug, and a stateful invariant suite that
fuzzes owner rotation and threshold changes while asserting a transaction only
ever executes on a live-owner threshold and never twice.

Clean-room, MIT-licensed, unaudited — review before trusting funds to it.
