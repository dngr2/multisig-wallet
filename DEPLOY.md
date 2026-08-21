# Deployment

This deploys the `MultisigFactory`. The factory is the only contract deployed by
the script. Individual multisig wallets are created **after** deployment by
calling `factory.createWallet(owners, threshold)` and sending the factory's flat
fee as `msg.value`.

> **Status:** this code is **unaudited**. Deploy to a **testnet first** and treat
> mainnet use at your own risk.

## Prerequisites

- [Foundry](https://book.getfoundry.sh/) installed (`forge`, `cast`).
- A funded **dedicated deployer key** used only for deployment — do not reuse a
  key that holds significant funds or that controls the wallets you will create.
- An RPC endpoint for the target chain.

## Environment variables

The deploy script reads its configuration from the environment. Set these before
running (e.g. in a `.env` file — already git-ignored — and `source .env`):

| Variable         | Type      | Meaning                                                  |
| ---------------- | --------- | -------------------------------------------------------- |
| `FACTORY_OWNER`  | `address` | Factory admin; may change the fee and the fee recipient. |
| `FEE_RECIPIENT`  | `address` | Receives collected deploy fees (must be non-zero).       |
| `DEPLOY_FEE`     | `uint256` | Flat per-wallet fee in **wei**; must be `<= 1 ether`.    |
| `RPC_URL`        | `string`  | RPC endpoint for the target chain.                       |

Set a zero fee with `DEPLOY_FEE=0`.

The broadcasting key is passed to `forge script` directly and is **not** read
from the script. Prefer an encrypted keystore account or a hardware wallet over a
raw private key.

## Deploy

Testnet first. Example command (using an encrypted keystore account):

```bash
source .env

forge script script/Deploy.s.sol:Deploy \
  --rpc-url "$RPC_URL" \
  --account deployer \
  --sender <DEPLOYER_ADDRESS> \
  --broadcast
```

Alternatively, with a raw private key (least preferred — avoid on shared machines):

```bash
forge script script/Deploy.s.sol:Deploy \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast
```

Drop `--broadcast` for a dry run (simulation only, no on-chain transaction).

The deployed factory address is printed to the console and recorded under
`broadcast/` (git-ignored).

## Verification

Add `--verify` (with the appropriate `--etherscan-api-key` / `--verifier` flags
for your target chain) to verify the factory during deployment, or verify later
with `forge verify-contract`. Verification is best-effort and depends on the
explorer supporting this compiler configuration (solc 0.8.26, `via_ir`, `cancun`).

## After deployment: creating a wallet

The script deploys only the factory. To create an individual multisig wallet,
call `createWallet` on the deployed factory, sending exactly `DEPLOY_FEE` wei:

```bash
cast send <FACTORY_ADDRESS> \
  "createWallet(address[],uint256)" \
  "[<OWNER_1>,<OWNER_2>,<OWNER_3>]" 2 \
  --value <DEPLOY_FEE> \
  --rpc-url "$RPC_URL" \
  --account deployer
```

Owner-set and threshold validation is enforced by the wallet's constructor.
