# THE CHEESE VAULT — Smart Contracts V1

CHEESE ($CHEESE) is a Squeekchain-powered farming ecosystem on Ethereum Sepolia (chain id 11155111).
CHEESE mining emission follows the live SQK issuance schedule one for one: every newly certified Squeek
block, read from the official SqueekCore proxy, is priced with SqueekMining's exact formula (launch bonus
plus three halvings) and distributed across farm pools by allocation points.

This repository contains the complete, tested Solidity system, the deploy and Sepolia verification
scripts, the website ABI/config, and the security notes. No contract has been deployed by this job and
no gas has been spent: IMD's launch deploys the contracts through its factory after review. Nothing
here reuses or touches the existing BLOOM contracts.

## Contents

| Path | What it is |
|---|---|
| `src/CheeseToken.sol` | $CHEESE ERC-20 (permit), 2.1B cap, 210M premint, immutable emission authority |
| `src/CheeseEmissionController.sol` | Master emission controller: Squeek block cursor, SQK schedule, pool allocation |
| `src/CheeseFarm.sol` | Abstract farm: shares, Hamster Bite fee, reward accounting |
| `src/farms/CheeseFarmERC20.sol` | CHEESE Pool farm (fixed ERC-20 asset) |
| `src/farms/CheeseFarmETH.sol` | Native ETH farm |
| `src/farms/CheeseFarmSIMD.sol` | sIMD farm (asset set once by the owner after launch) |
| `src/libraries/SqueekIssuance.sol` | The verified SQK schedule constants and `issued(b)` |
| `src/interfaces/ISqueekCore.sol`, `ISqueekMining.sol` | Subsets of the published Squeekchain ABIs |
| `script/Deploy.s.sol` | Deploy + wire + hand-over, callable from tests; Sepolia rehearsal `run()` |
| `script/VerifySqueekchain.s.sol` | Read-only live check that CHEESE's schedule equals SQK's |
| `test/` | 87 unit, fuzz and invariant tests |
| `web/abi/*.json`, `web/config.sepolia.json` | Website integration ABI and configuration |
| `docs/ARCHITECTURE.md`, `docs/SECURITY.md`, `docs/SQUEEKCHAIN_VERIFICATION.md` | Design, findings, verified references |

## Verified Squeekchain integration (Sepolia)

Verified on 2026-11-07 against the docs (`docs.squeekchain.com`, `llms-full.txt`,
`assets/deployments/sepolia.json`) and the live chain at Ethereum block 12081684. Docs and chain agree
on every value CHEESE depends on. Full detail: `docs/SQUEEKCHAIN_VERIFICATION.md`.

| Item | Value |
|---|---|
| Release | `core-sepolia-20261103`, revision 7, chain id 11155111 |
| SqueekCore proxy (read by CHEESE) | `0xFD6C166D4B8E2962E65746a13e5a0797CD4dE0c4` |
| SqueekCore implementation / runtime hash | `0x6869D610…22ad3` / `0x65b5780a…5a9c` (EIP-1967 slot and code hash match) |
| SqueekMining proxy (schedule cross-check) | `0x2dCcB11fcC2dEfdd188555e45aCb52231e82e218` |
| SqueekMining implementation / runtime hash | `0x32639fc0…cFaa4` / `0xbcc7179f…e959` (match) |
| SqueekToken ($SQK) | `0xd78a3956cF63164d1Fa1C622ad3c66623162Fa1e`, cap 2.1e27, premint 2.1e26 |
| Block counter | `SqueekCore.state().blockHeight` = `cumulativeBlockUnits / 1e9`; rounds of 600 s from genesis `1793735400` |
| Schedule | A = 1,890,000,000e18, G = 105,000,000e18, N = 97,020, H = 393,470, R0 = 2,592,319,617,759,930,871,476 |
| Live minting behaviour | `SqueekMining.state().minted` (6,000,573.95 SQK at fundedBlocks 1633) equals `issued(1633)` exactly |

`SqueekIssuance.issued()` reproduces the on-chain `SqueekMining.issued()` at 0, 1, 2, N, N+1, H, H+1,
2H, 2H+1, 3H and beyond (test vectors in `test/Emission.t.sol`). The live `firstPeriodRate` equals the
compiled constant. No address, ABI function or emission parameter was invented.

## Token

* Name `CHEESE`, symbol `CHEESE`, 18 decimals, `MAX_SUPPLY` 2,100,000,000 CHEESE.
* Premint 210,000,000 CHEESE, the verified SQK split: 63,000,000 team, 63,000,000 treasury,
  84,000,000 liquidity, minted in the constructor to three recipient arguments. Farming emission is
  never preminted.
* Mining allowance 1,890,000,000 CHEESE. The only minter is the immutable `emissionAuthority`
  (the controller), fixed at construction. There is no owner on the token and no other mint path.
* The cap bounds `totalMinted`, so burns never reopen it (as SqueekToken does).

## Emission controller

* `activate()` (owner, once) reads `SqueekCore.configuration()`, verifies the 600 s round and 1e9
  block units, and schedules `startRound = currentRound + 1`, like `SqueekMining.start()`.
* The first checkpoint that sees round `startRound - 1` certified reads the completed height at that
  round through `roundPage(r, r, 0).end` and records it as h0. Blocks at or below h0 never emit.
* `checkpoint()` is permissionless. It prices `issued(height - h0) - issued(lastHeight - h0)` in O(1),
  clipped to the remaining allowance: delayed checkpoints, zero movement, halving crossings and large
  jumps all settle exactly; grouping is irrelevant (fuzz-tested).
* Only enabled pools' points are ever minted. The Future Pool Reserve (points not assigned to an
  enabled pool) stays unminted; `reserveUnminted` records it and it is never redistributed.
* Emission completes when `height - h0 >= 3H`; `EmissionCompleted` is emitted once and later
  checkpoints are no-ops. Farms keep working (fees, withdrawals, claims).
* Squeekchain unavailable, regressed, without code, or returning data of another shape (a proxy
  upgrade that changes a struct): `checkpoint()` returns `false`, emits `CoreUnavailable` or
  `CoreRegression`, changes nothing, and the next successful call catches up. SqueekCore is read
  through raw `staticcall`s whose payloads must have the exact ABI size and decode (via the
  `decode*` helpers), because Solidity's `try/catch` would otherwise revert in the user's
  transaction. Allocation changes and deposits require a successful sync (deposits revert with
  `SyncRequired`); withdrawals and claims never do.
* Pause (`pauseEmissions`, owner or guardian; `unpauseEmissions`, owner only): the pause first prices
  the blocks certified before it (best effort), so they belong to whoever was staked then. While
  paused no emission is priced, farms refuse deposits, allocation changes revert; withdrawals and
  claims keep working. Unpausing catches up, so the schedule still matches SQK.

### Pool allocation

Initial allocation (set by the owner after launch, see below): CHEESE 400, ETH 200, sIMD 200,
Future Pool Reserve 200 of `TOTAL_POINTS` 1000. API: `addPool`, `setPoolWeight`,
`batchSetPoolWeights` (distinct pool ids only), `disablePool`, `enablePool`, `checkpoint`,
`getPoolAllocation`, `getAllocation`, `previewPoolEmission`, `pendingCheckpoint`.

Accounting is a single `emissionPerPoint` accumulator; a pool settles lazily as
`weight × Δaccumulator`, so checkpoints and user actions cost the same with 3 or 60 pools (tested).
Every change checkpoints first, settles the affected pool under the old weight, and applies
prospectively. New pools and re-enabled pools start at the current accumulator.

## Farms

* Independent, nontransferable 18-decimal shares with a virtual offset (1e3 shares / 1 asset) against
  share-price manipulation; `totalAssets` and `rewardReserve` are tracked internally, never read from
  balances, so donations cannot move the price or be mistaken for rewards (`skimSurplus` sends them to
  the Treasury only).
* Deposits: 0% fee; shares at the current assets-per-share. Fee-on-transfer assets are credited by the
  amount received.
* Withdrawals: immediate, no cooldown. Hamster Bite: 15% of the gross assets backing the burned shares;
  85% to the withdrawer, 14% retained in the farm (raising assets per share for everyone remaining,
  including a partial withdrawer's own remaining shares), 1% to the Treasury. If no shares remain, the
  full 15% goes to the Treasury together with any residual the virtual offset left in the reserve, so
  the farm restarts empty and nothing is stranded.
* Treasury payment: pushed with a bounded gas stipend (`TREASURY_PUSH_GAS`, 100k). If the Treasury
  cannot receive (reverts, has no `receive`, burns the stipend, or the token refuses it) the amount is
  credited to `treasuryOwed`, `TreasuryPaymentDeferred` is emitted and the withdrawer is still paid.
  Anyone can later call `payTreasury()` to deliver the owed amount to the Treasury configured then.
  No Treasury setting can block withdrawals, even with ownership renounced.
* Rewards: MasterChef-style `accRewardPerShare` with 512-bit `mulDiv` products (a 1-wei first deposit
  makes the accumulator enormous; deposits of any size stay usable). Reward debts round up and the
  accumulator rounds down, so the entitlements of all accounts never sum above `rewardReserve` and
  every claim pays exactly what `pendingRewards` reports; a claim additionally never reverts on a
  reserve shortfall (it pays what exists and keeps the rest pending). Before any share change the
  farm pulls the pool's accrual from the controller; if the farm is empty the controller forfeits
  that accrual (never minted) so a later depositor cannot inherit it. `claim(to)` is independent of
  principal.
* Reentrancy: `nonReentrant` on deposit, withdraw, claim and skim; checks-effects-interactions; the ETH
  farm rejects plain transfers.
* Owner powers on a farm: pause deposits, skim surplus to Treasury, and (sIMD farm) set the asset once.
  No owner function moves principal or accrued rewards.

## Administration and roles

| Role | Powers |
|---|---|
| Owner (`Ownable2Step`) | bind token once, activate, add pools, set weights, enable/disable pools, set Treasury, set guardian, pause/unpause emissions, pause farm deposits, skim donated surplus, set the sIMD asset once |
| Guardian | pause emissions only (defaults to the owner; the deploy script moves it to the owner on hand-over) |
| Anyone | `checkpoint()`, deposit, withdraw, claim, `payTreasury()` |
| Controller | the only CHEESE minter; mints only to a pool's farm, only what that pool accrued |

The owner cannot mint, cannot move user principal, cannot take accrued rewards, cannot change fees,
and cannot rewrite the schedule. Every state change emits an event.

## Deployment parameters (IMD launch, Sepolia)

The launch deploys five contracts in this order (names are the Solidity names):

| # | Contract | Constructor arguments |
|---|---|---|
| 0 | `CheeseEmissionController` | `owner_` = `$owner`; `squeekCore_` = `0xFD6C166D4B8E2962E65746a13e5a0797CD4dE0c4`; `treasury_` = `$owner` |
| 1 | `CheeseToken` | `teamRecipient_` = `$owner`; `treasuryRecipient_` = `$owner`; `liquidityRecipient_` = `$owner`; `emissionAuthority_` = `$contract:CheeseEmissionController` |
| 2 | `CheeseFarmERC20` | `owner_` = `$owner`; `controller_` = `$contract:CheeseEmissionController`; `asset_` = `$contract:CheeseToken` |
| 3 | `CheeseFarmETH` | `owner_` = `$owner`; `controller_` = `$contract:CheeseEmissionController` |
| 4 | `CheeseFarmSIMD` | `owner_` = `$owner`; `controller_` = `$contract:CheeseEmissionController` |

Owner for this launch: `0xdea11b3a70b77134424d436f6eb455f1abbd4449`. The brief names no Treasury,
team or liquidity wallet, so those arguments resolve to the owner, who redistributes the premint and can
move the Treasury with `setTreasury`. Constructors touch no other contract. The manifest step writes
`launch.json`; this repository deliberately contains none.

### After launch (owner steps, in order)

1. `CheeseEmissionController.bindToken(CheeseToken)` — once; the token must name the controller as
   its emission authority.
2. `addPool(CheeseFarmERC20, 400)`, `addPool(CheeseFarmETH, 200)`, `addPool(CheeseFarmSIMD, 200)` —
   gives the 400/200/200/200 allocation; pool ids 0, 1, 2.
3. `CheeseFarmSIMD.setAsset(<sIMD token>)` — once. The sIMD Sepolia address comes from the IMD sIMD
   deployment; until it is set, deposits revert with `AssetNotConfigured` and the pool's emission is
   forfeited (never minted) when first pulled. Set it before activation or set the pool weight to 0 until
   then to avoid forfeiting.
4. Optionally `setTreasury(<treasury>)` and `setGuardian(<guardian contract or key>)`. Use an EOA or
   a Safe as Treasury: it must accept plain ETH within the 100k stipend and accept CHEESE/sIMD
   transfers, otherwise its share is deferred to `treasuryOwed` until `payTreasury()` succeeds.
5. `activate()` — schedules emission from the next full Squeek round. Run
   `forge script script/VerifySqueekchain.s.sol --rpc-url <sepolia>` immediately before; if it fails,
   do not activate and report the discrepancy.
6. Keep `checkpoint()` called (any address; a cron or the website) at least once per Squeek round for
   fresh reward displays. Deposits, withdrawals and claims checkpoint implicitly.

### Deployment approval

Per the brief, broadcasting needs one explicit approval naming the deployer, owner, Treasury, contract
addresses and gas budget. IMD's launch supplies deployer, addresses and the gas ceiling after this work
is accepted; the owner and Treasury are above. Estimated deployment gas from `forge build --sizes`
runtime sizes: about 5.6M gas for the five constructors combined (controller 15.3 KB, farms 7.2–7.8 KB,
token 4.5 KB runtime), plus about 0.6M gas for the six after-launch calls.

## Assumptions and open choices

* Squeekchain's Sepolia release is testnet-only and "in active development". CHEESE pins the proxy
  address (stable across upgrades) and re-verifies the clock constants at activation; a changed ABI
  (different return size or undecodable data) makes `checkpoint()` return `false` (no emission,
  nothing lost, withdrawals and claims unaffected) until the owner pauses and the team investigates.
  A reordering that keeps the same size and types cannot be detected on chain. The controller cannot
  be re-pointed; a new release would need a new controller.
* Rounding: each account may lose at most 1 wei of CHEESE per share change (debts round up); the dust
  stays in `rewardReserve`. The 100k Treasury gas stipend and the duplicate-id rejection in
  `batchSetPoolWeights` are design choices, not values from the brief.
* Emission accrued to a pool with no stakers is forfeited (never minted) rather than paid to the first
  depositor or the Treasury. This keeps "no retroactive rewards" strict; CHEESE total issuance is at
  most SQK's. Alternative (route to Treasury) noted in `docs/SECURITY.md`.
* The Future Pool Reserve is "points without an enabled pool". Disabled pools' points behave the same.
* Virtual offset 1e3 shares / 1 asset; `ACC_PRECISION` 1e36; both are named constants.
* The 15% / 14% / 1% fee split is exactly the brief's; there are no other fees.
* `MockSqueekCore` in tests reproduces the published ABI; it is not the real contract. The live
  behaviour is checked by `script/VerifySqueekchain.s.sol`, which needs an RPC and is not part of
  `forge test`.

## Operational responsibilities

| Who | Responsibility |
|---|---|
| Owner | after-launch steps above; monitor `CoreUnavailable` / `CoreRegression` / `TreasuryPaymentDeferred` events; pause on incident; rotate Treasury/guardian; redistribute the premint |
| Website / keeper | call `checkpoint()` each Squeek round; call `payTreasury()` on a farm whose `treasuryOwed() > 0`; show `pendingCheckpoint()`, `getPoolAllocation()`, `pendingRewards()` |
| Users | approve then `deposit` (ERC-20 farms) or `deposit{value}` (ETH farm); `withdraw(shares)`; `claim(to)` |
| Independent reviewer | adversarial review before funds are at risk (see `docs/SECURITY.md`) |

## Build and test

```
forge build
forge test
forge fmt --check
FOUNDRY_FUZZ_SEED=0xdf414340e80273b96b0da0b947078a573285f2d5cb8059314b94cca491a43568 forge test
forge script script/VerifySqueekchain.s.sol --rpc-url https://ethereum-sepolia-rpc.publicnode.com
```

Results on 2026-11-07 (solc 0.8.26, forge 1.8.3, fuzz seed above): 87 tests, 87 passed, 0 failed,
including 7 fuzz tests (256 runs each) and 7 invariants (64 runs × depth 32; the handler records any
unexpected deposit, withdraw or claim revert and an invariant fails on it). Also passed with a random
seed at 512 fuzz runs and 128 × 64 invariant runs. The Sepolia
verification script was exercised through equivalent `cast` reads (see
`docs/SQUEEKCHAIN_VERIFICATION.md`); it has not been run by this job as a `forge script`.

Dependencies are vendored as plain files: `lib/forge-std` 1.17.0 and `lib/openzeppelin-contracts`
5.4.0 (MIT). `foundry.toml` pins `solc = "0.8.26"` and `bytecode_hash = "none"`.

## IMD Swarm Job

This work is job `ef45bb39-6188-4c7b-8ef1-9e056dd24c04` on the IMD contributor network. The explorer
URL for the launched contracts is produced by the IMD launch after acceptance; none exists yet and
none is fabricated here. Website development is a separate IMD Swarm Job; it should consume
`web/config.sepolia.json` and `web/abi/` and take contract addresses only from the launch hand-off.
