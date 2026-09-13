# HVN Launch Runbook (Optimism)

End-to-end bootstrap: DAO timelock → RoyaltyRouterFactory → HVN token
→ Governor handover → haven-dapp wiring. Status: scripts compiled and
dry-run green on a local fork; nothing broadcast yet.

## Prerequisites

- Funded deployer EOA on OP (pay for 3 deploys + 1 launch).
- OP RPC URL; optional Routescan/Etherscan API key for `--verify`.
- Proposer/executor address (the deployer EOA at bootstrap).

## Step 1 — Deploy the timelock (DAO treasury)

```bash
PROPOSER=0x... EXECUTOR=0x... MIN_DELAY_DAYS=7 \
  forge script script/DeployDAO.s.sol:DeployDAO \
  --rpc-url $OP_RPC --broadcast --verify
```

Save the printed `timelock` address as `$TIMELOCK`. Min delay = 7 days
(604800s, asserted in dry-run). Proposer/executor move to the Governor
at handover (Step 4).

## Step 2 — Deploy the RoyaltyRouterFactory on OP

```bash
BOND=0xc5a0... HOOK=0x0F41715dc432692b66A5aDF8dCfef6Ac407b20c8 \
POOL_MANAGER=0x498581fF718922c3f8e6A244956aF099B2652b2b \
GOVERNANCE=$TIMELOCK DAO=$TIMELOCK \
DAO_BPS=1000 MAX_DAO_BPS=2000 STALE_DAYS=365 GRACE_DAYS=30 \
  forge script script/Deploy.s.sol:DeployFactory \
  --rpc-url $OP_RPC --broadcast --verify
```

Agreed params: 10% DAO take, 20% immutable cap (`MAX_DAO_BPS` can never
be raised after deploy), 365-day stale / 30-day grace reclaim windows.
Save the printed `factory` address as `$FACTORY`.

## Step 3 — Launch HVN (first graduated token)

Recommended curve: 15% buy/sell tax, 0.3% creator allocation, 20
bonding steps. Launch from the haven-dapp wizard (Optimism → graduate)
or via `factory.launch(...)` directly. Record the HVN token address.

## Step 4 — Decentralize: vote-wrapper + Governor, handover

1. Build the vote-wrapper (converts subDAO receipts into voting power).
   Status: **not built yet**.
2. Deploy Governor with the timelock as executor.
3. `grantRole(PROPOSER_ROLE, governor)` and
   `grantRole(EXECUTOR_ROLE, governor)` on the timelock.
4. Renounce deployer proposer/executor roles. From this point all
   treasury moves clear the 7-day timelock.

## Step 5 — Wire into haven-dapp

Set `NEXT_PUBLIC_GRADUATE_FACTORY_10=$FACTORY` (+ HVN address) in
haven-dapp config and redeploy. Wizard then defaults to Optimism →
graduate on all Glue + Uniswap + MintClub chains.

## Notes

- ETH takes stream to the timelock; only subDAO-token dumps wait out
  the delay. Dead-pool ETH reclaims stay callable post-handover.
- Timelock delay costs no extra gas per user tx; only governance
  execution goes through the delay.
