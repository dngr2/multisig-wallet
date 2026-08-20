# Pitch

A production-grade **m-of-n multisig wallet + factory**, built clean-room on
well-known patterns.

- **On-chain confirmations, not signature aggregation.** Every confirmation is
  a transaction, so the trust model is transparent and the logic is small enough
  to audit at a glance — the most-deployed multisig style on-chain.
- **Correctness where it counts.** The confirmation / execution / owner-management
  logic is the whole game, and it is covered by 53 passing tests plus a stateful
  invariant suite: a tx executes iff confirmations reach the threshold, never
  twice; the confirmation count always equals the owners currently confirming;
  the owner set stays non-empty, unique, and `threshold <= ownerCount`.
- **Reentrancy-safe execution.** Checks-effects-interactions plus a reentrancy
  guard; failed inner calls revert cleanly and stay retryable.
- **Self-governed owners.** Adding, removing, replacing owners and changing the
  threshold can happen only through a fully-confirmed multisig transaction — no
  admin backdoor.
- **Factory with a bounded flat fee.** One call deploys and indexes a wallet;
  the deploy fee is hard-capped and owner-tunable within that cap.

Foundry-tested, MIT-licensed, ready to deploy.
