# Multisig Wallet + Factory

A self-hosted m-of-n multisignature wallet (with a deploy-and-index factory) for
teams, DAOs, and treasuries that want to control shared funds without trusting a
hosted service. Owners confirm transactions on-chain; a transaction executes only
when enough current owners have approved it. Solidity 0.8.26, Foundry, MIT.

## What makes it different

Most of the value in a multisig is a single guarantee: *m of the n owners must
agree before money moves.* The subtle way that guarantee breaks is time — the
owner set changes, and approvals collected under the old set get counted under
the new one. This wallet is built so that cannot happen.

- **The m-of-n threshold is enforced against the LIVE owner set at execution
  time.** Confirmations are not tracked as a cached counter that can drift.
  `executeTransaction` recounts approvals against the *current* owners the moment
  it runs (`_countConfirmations`), so a confirmation left behind by an owner who
  was later removed or replaced does **not** count toward the threshold. A
  transaction can never execute on fewer than `threshold` approvals from owners
  who are owners *right now*. This repo's second-pass review caught and fixed
  exactly this class of bug — see [Security & testing](#security--testing).

- **Self-governed owner set.** `addOwner`, `removeOwner`, `replaceOwner`, and
  `changeThreshold` can be called *only by the wallet itself*
  (`msg.sender == address(this)`). The single path to them is a fully-confirmed
  multisig transaction whose target is the wallet. No owner, deployer, or factory
  admin has a backdoor to the owner set or threshold. A removal that would push
  the owner count below the threshold reverts, so the wallet can never be bricked
  into an unsatisfiable threshold.

- **Reentrancy-safe execution.** Execution follows checks-effects-interactions:
  the `executed` flag is set *before* the external call, and a `nonReentrant`
  guard backs it up, so a malicious target cannot re-enter to double-spend. If the
  inner call fails, the whole transaction reverts (flag included) and the
  transaction stays retryable.

- **Relayer-friendly EIP-712 execution.** `executeWithSignatures` lets a single
  caller (e.g. a relayer) execute a transaction from a batch of owner signatures
  in one call — no on-chain submit/confirm round-trip. Signers are checked against
  the live owner set, a monotonic nonce plus the EIP-712 domain block replay
  across calls and chains.

## Features

- **m-of-n wallet.** Constructed with an owner set and a `threshold`; the
  constructor rejects an empty set, the zero address, duplicates, and any
  `threshold` outside `1 <= threshold <= owners.length`.
- **Holds and moves assets.** `receive()` accepts ETH; executed transactions can
  move ERC-20s or call any contract via a low-level `to.call{value}(data)`.
- **On-chain confirmation lifecycle.** `submitTransaction`, `confirmTransaction`,
  `revokeConfirmation`, `executeTransaction` — one confirmation per owner, no
  double-confirm, no execution before threshold, no double-execution.
- **Self-governed owner management** with the threshold invariant enforced.
- **v2 — live-owner confirmation counting.** Execution and the `isConfirmed` /
  `getConfirmationCount` / `getConfirmations` views all evaluate against the
  current owner set, not a stale counter.
- **v2 — EIP-712 signature execution.** `executeWithSignatures` with ascending-
  address signer ordering (enforcing uniqueness in one pass), a consumed
  `execNonce`, and domain-separated digests.
- **v2 — per-transaction deadlines.** `submitTransactionWithDeadline` sets an
  expiry; `executeTransaction` and the signature flow reject expired transactions.
  `getDeadline(txId)` reads it.
- **Factory.** `createWallet(owners, threshold)` deploys a wallet, indexes it by
  creator and by each owner, charges an exact flat fee hard-capped at
  `MAX_FEE = 1 ether` and forwarded to `feeRecipient`, and emits `WalletCreated`.
  Fee and recipient are owner-settable within the cap.

## Security & testing

Run the suite with [Foundry](https://book.getfoundry.sh/):

```bash
forge test
```

**71 tests pass** across unit, deep-dive, factory, and stateful-invariant suites
(0 failed). Gas figures below are from `forge test --gas-report` on this repo.

**The caught bug — stale confirmation from a removed owner.** The first version
counted confirmations with a cached counter incremented on confirm and
decremented on revoke. Removing or replacing an owner did not touch that counter,
so a confirmation from a since-removed owner kept counting toward the threshold —
a transaction could execute with fewer than `threshold` *live* approvals, a
high-severity break of the core m-of-n guarantee. The fix counts confirmations
against the current owner set at execution time (`_countConfirmations`). Two
regression tests pin it down:

- `test_StaleConfirmation_RemovedOwner_DoesNotCount`
- `test_StaleConfirmation_ReplacedOwner_DoesNotCount`

Each collects a confirmation, removes/replaces that owner via the self-governance
path, and asserts the transaction can no longer execute on the stale approval.

**Ad-hoc mutation check.** As a sanity check on those tests, reverting the fix —
swapping the live-owner recount back for the cached counter — makes
`test_StaleConfirmation_RemovedOwner_DoesNotCount` fail. So the regression test
genuinely exercises the fixed path rather than passing vacuously. This is a manual
one-off check, not an automated mutation-testing run.

**Stateful invariants.** A handler fuzzes submit/confirm/revoke/execute together
with owner rotation and threshold changes, asserting:

- `invariant_ExecutesOnlyOnLiveThreshold` — a transaction only ever executes when
  its live-owner confirmation count met the threshold.
- `invariant_NoDoubleExecution` — no transaction executes twice.
- `invariant_OwnerSetValid` — the owner set stays non-empty and unique, `isOwner`
  agrees with the owner array, and `threshold <= ownerCount`.
- plus `invariant_ConfirmationCountMatchesOwners` and
  `invariant_ExecutedImpliesWasConfirmed`.

**Unit coverage** includes deploy validation; submit→confirm→execute for ETH,
ERC-20, and contract-call payloads; below-threshold blocking; failed-inner-call
retryability; confirm/revoke logic; non-owner access control; the full
self-governance path (direct calls revert, multisig-routed calls work); a
reentrancy attack that cannot double-execute; the full EIP-712 flow (happy path,
replay, too-few / non-owner / duplicate / unordered signers, expired deadline,
failed-call nonce retention, self-governance via signatures); and deadlines.

Approximate gas (average, from the gas report):

| Function              | Avg gas |
|-----------------------|---------|
| `submitTransaction`   | ~120,000 |
| `confirmTransaction`  | ~62,800  |
| `executeTransaction`  | ~100,500 |
| `executeWithSignatures` | ~65,200 |

## Usage

Deploy directly, or through the factory. Core lifecycle:

```solidity
// 1. Deploy a 2-of-3 wallet (directly, or via factory.createWallet).
address[] memory owners = new address[](3);
owners[0] = alice; owners[1] = bob; owners[2] = carol;
MultisigWallet wallet = new MultisigWallet(owners, 2);

// 2. Any owner submits a transaction (send 1 ETH to `recipient`).
uint256 txId = wallet.submitTransaction(recipient, 1 ether, "");

// 3. Owners confirm (submitting does not auto-confirm).
wallet.confirmTransaction(txId); // as alice
wallet.confirmTransaction(txId); // as bob  -> now 2 live confirmations

// 4. Once confirmations >= threshold, any owner executes.
wallet.executeTransaction(txId);
```

Changing the owner set goes through the wallet itself — submit a transaction
whose target is the wallet and whose calldata is the management call:

```solidity
bytes memory data = abi.encodeCall(MultisigWallet.addOwner, (dave));
uint256 id = wallet.submitTransaction(address(wallet), 0, data);
// confirm to threshold, then executeTransaction(id).
```

Relayer path — execute from a batch of owner signatures over the EIP-712
`Execute(address to,uint256 value,bytes data,uint256 nonce,uint256 deadline)`
struct (`hashExecute` reproduces the digest; signatures must be ordered by
ascending signer address):

```solidity
wallet.executeWithSignatures(to, value, data, deadline, signatures);
```

## License

MIT — see [LICENSE](LICENSE).

## Honest note

This is a clean-room implementation built on well-known multisig patterns and is
not audited. The security work here is a thorough test suite, stateful invariants,
and one caught-and-fixed high-severity bug with regression coverage — not a
third-party audit. Review it yourself before putting funds behind it.
