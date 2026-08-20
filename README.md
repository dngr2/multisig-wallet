# Multisig Wallet + Factory

An m-of-n multisignature wallet using **on-chain confirmations** (Gnosis-classic
style), plus a factory that deploys and indexes wallets for a bounded flat fee.
No off-chain signature aggregation — every confirmation is an on-chain action,
which keeps the trust model simple and the logic auditable.

## Contracts

### `MultisigWallet.sol`

- **m-of-n**: constructed with an owner set and a `threshold`. Constructor
  rejects an empty owner set, a zero owner, duplicate owners, and any
  `threshold` outside `1 <= threshold <= owners.length`.
- **Holds assets**: `receive()` accepts ETH; the wallet can hold and move ERC20s
  (and call any contract) through executed transactions.
- **Transaction lifecycle** (owners only):
  - `submitTransaction(to, value, data)` → `txId`
  - `confirmTransaction(txId)` / `revokeConfirmation(txId)` — one confirmation
    per owner, no double-confirm, only before execution.
  - `executeTransaction(txId)` — once confirmations `>= threshold`, performs the
    low-level `to.call{value}(data)`.
- **Reentrancy-safe execution**: follows checks-effects-interactions — the
  `executed` flag is set *before* the external call, and the whole transaction
  (flag included) reverts if the inner call fails, so a failed transaction stays
  retryable. A `nonReentrant` guard backs this up. A malicious target cannot
  re-enter `executeTransaction` to double-execute.
- **Self-governed owner set**: `addOwner`, `removeOwner`, `replaceOwner`, and
  `changeThreshold` are callable **only by the wallet itself**
  (`msg.sender == address(this)`). The only way to reach them is to submit and
  confirm a multisig transaction whose target is the wallet. No single owner or
  external admin can change the owner set or threshold.
  - **removeOwner rule**: a removal that would drop the owner count below the
    current `threshold` reverts. Lower the threshold first (via
    `changeThreshold`) if the set needs to shrink that far. This keeps the
    `threshold <= ownerCount` invariant intact and the wallet can never be
    bricked into an unsatisfiable threshold.
- **Views**: `getOwners`, `getConfirmationCount`, `isConfirmed`,
  `getTransaction`, `transactionCount`, `isOwner`, `ownerCount`.

### `MultisigFactory.sol`

- `createWallet(owners, threshold)` deploys a `MultisigWallet`, indexes it by
  creator and by each owner, charges an exact bounded flat fee (`msg.value`,
  capped by `MAX_FEE`) forwarded to `feeRecipient`, and emits `WalletCreated`.
- Owner-settable, bounded `fee` and `feeRecipient` (`setFee`, `setFeeRecipient`).
- Views: `allWalletsCount`, `getAllWallets`, `getWalletsByCreator`,
  `getWalletsByOwner`.

## Test

```bash
forge test
```

Coverage includes: deploy validation; submit→confirm→execute for ETH, ERC20 and
contract calls; below-threshold blocking; failed-inner-call retryability;
confirm/revoke logic; non-owner access control; the full self-governance path
(direct calls revert, multisig-routed calls work); a reentrancy attack that
cannot double-execute; and a stateful invariant suite over
submit/confirm/revoke/execute (no double execution, confirmation count matches
confirming owners, owner set stays valid).

## License

MIT

## Deep dive (v2): hardening + EIP-712 signatures, deadlines, live-owner confirmations

Second-pass review and hardening of the deployed contracts.

**Security fix — stale confirmation after owner change.** Execution now counts
confirmations against the *current* owner set rather than a cached counter. A
confirmation left behind by an owner who is later removed or replaced no longer
counts toward the threshold, so a transaction can never execute with fewer than
`threshold` live-owner approvals. `isConfirmed`, `getConfirmationCount` and the
new `getConfirmations` view all reflect the live owner set. Reentrancy, the
CEI/executed-flag ordering, threshold bounds and factory fee bounds were
re-reviewed and found sound (no change).

**Features.**
- `executeWithSignatures` — Safe-style EIP-712 execution: a single caller (e.g. a
  relayer) submits a batch of owner signatures over `(to, value, data, nonce,
  deadline)` and the call executes in one transaction, no on-chain
  submit/confirm round-trip. Signatures must be ordered by ascending signer
  address (enforcing uniqueness), each signer a current owner, at least
  `threshold` of them. A monotonic `execNonce` and the EIP-712 domain prevent
  replay across calls and chains; a failed inner call reverts the nonce so the
  bundle stays retryable.
- Per-tx expiry via `submitTransactionWithDeadline`; `executeTransaction` (and the
  signature flow) reject expired transactions. `getDeadline(txId)` reads it.
- `getConfirmations(txId)` lists the current owners confirming a transaction.

**Tests.** Regression tests for the stale-confirmation case (removed and replaced
owner), the full EIP-712 flow (happy path, replay, too-few/non-owner/duplicate/
unordered signers, expired deadline, failed-call nonce retention, self-governance
via signatures), deadlines, and the new view. The invariant suite now fuzzes
owner rotation and threshold changes and asserts a transaction only ever executes
on live-owner threshold.
