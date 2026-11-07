# Architecture

```
                 SqueekCore proxy (Sepolia)              SqueekMining proxy (Sepolia)
                 state().blockHeight, roundPage()        issuanceSchedule(), issued()
                           │ read-only                              │ read-only (verification script only)
                           ▼                                        ▼
            ┌──────────────────────────────┐        schedule constants transcribed into
            │  CheeseEmissionController    │◄────── src/libraries/SqueekIssuance.sol
            │  owner: $owner               │
            │  h0, lastHeight, issued()    │
            │  emissionPerPoint, pools[]   │
            └──────┬───────────┬───────────┘
   mintEmission()  │           │ pullRewards(poolId, hasStakers) -> (amount, synced)   (farm-only, per pool)
                   ▼           ▼
            ┌───────────┐   ┌──────────────┬──────────────┬──────────────┐
            │CheeseToken│   │CheeseFarmERC20│ CheeseFarmETH│CheeseFarmSIMD│
            │ cap 2.1B  │   │ asset: CHEESE │ asset: ETH   │ asset: sIMD  │
            │ premint   │   │ 400 points    │ 200 points   │ 200 points   │
            └───────────┘   └──────────────┴──────────────┴──────────────┘
                                                     Future Pool Reserve: 200 points, unminted
```

## Emission pipeline

1. **Certification** happens on Squeekchain: the Reporter settles rounds into `SqueekCore`; its
   `state().blockHeight` is the number of completed Squeek blocks.
2. **Anchor.** `activate()` sets `startRound`. The first `checkpoint()` that sees round `startRound-1`
   certified reads `roundPage(startRound-1, startRound-1, 0).end.cumulativeBlockUnits / 1e9` as h0.
3. **Pricing.** `checkpoint()` reads `blockHeight`, computes
   `emission = issued(height - h0) - issued(lastHeight - h0)` with the SQK formula, clips to the
   remaining allowance, and adds `emission / 1000` per point to `emissionPerPoint`. The share belonging
   to unassigned points is recorded in `reserveUnminted` and never minted.
4. **Settlement.** A pool owes `weight × (emissionPerPoint - pool.lastEmissionPerPoint)`. It is settled
   on weight change, enable/disable, and on `pullRewards`.
5. **Minting.** `pullRewards` (callable only by the pool's farm) mints the pool's accrual to the farm,
   or forfeits it when the farm has no shares. It also reports whether the sync succeeded; a deposit
   reverts (`SyncRequired`) when it did not, so certified-but-unpriced blocks can never be diluted.
6. **Distribution.** The farm adds the minted CHEESE to `rewardReserve` and `accRewardPerShare`;
   users claim `floor(shares × acc / 1e36) - debt` with `debt = ceil(shares × acc / 1e36)` at the last
   share change (512-bit `mulDiv`), clamped at zero and at `rewardReserve`.

SqueekCore reads (`state`, `configuration`, `roundPage`) are raw `staticcall`s: the payload must have
the exact static ABI size (256 / 352 bytes) or, for the dynamic `roundPage`, decode through the
contract's own external `decode*` helper inside `try/catch`. A revert, a missing contract, a wrong size
or undecodable data all read as "unavailable" and never revert a user's transaction.

Each step is O(1) in the number of pools and users.

## Why this matches SQK

SqueekMining prices each round as `issued(toBlock - h0) - issued(fundedBlocks)`; the result is a
telescoping sum, so any grouping of blocks yields `issued(totalBlocks)`. CHEESE prices the same
function between the same kind of heights and therefore emits exactly `issued(b)` for `b` blocks after
its own h0 (fuzz test `testFuzz_checkpointGroupingIsIrrelevant`). The constants A, G, N, H and R0 are
SqueekMining's; `issued()` is byte-for-byte the documented formula and reproduces the live values.

## Farm share math

* `shares = assets × (totalShares + 1e3) / (totalAssets + 1)` (floor)
* `assets = shares × (totalAssets + 1) / (totalShares + 1e3)` (floor)
* Withdraw: `gross = assets(shares)`; `fee = 15%`; `paid = gross - fee`; `retained = 14%`;
  `toTreasury = fee - retained`; `totalAssets -= paid + toTreasury`. If `totalShares` becomes 0,
  `toTreasury = totalAssets - paid` (the fee plus the residual no share can reach), `retained = 0`,
  and `totalAssets` ends at 0.
* Treasury push: `call{gas: 100_000}` (ETH) or a non-reverting `transfer` (tokens); on failure
  `treasuryOwed += toTreasury` and `payTreasury()` delivers it later. The user's `paid` is pushed with a
  reverting call, as it is their own address.
* Invariants: `balance >= totalAssets + treasuryOwed (+ rewardReserve when the asset is CHEESE)`,
  `Σ sharesOf == totalShares`, `assets(totalShares) <= totalAssets`, `Σ pendingRewards <= rewardReserve
  + unpulled pool emission`.

## Storage summary

`CheeseEmissionController`: `cheese`, `treasury`, `guardian`, `emissionsPaused`, `activated`,
`genesisTimestamp`, `startRound`, `startCaptured`, `startHeight`, `lastHeight`, `completed`,
`cumulativeEmission`, `emissionPerPoint`, `reserveUnminted`, `forfeitedEmission`, `totalMinted`,
`activeWeight`, `totalWeight`, `Pool[] _pools`, `mapping(farm => id+1)`.

`CheeseFarm`: `poolId`, `registered`, `depositsPaused`, `totalShares`, `totalAssets`, `rewardReserve`,
`treasuryOwed`, `accRewardPerShare`, `sharesOf`, `_rewardDebt`, `claimedOf`, `_pendingOf`.

No proxies, no delegatecall, no selfdestruct, no external library linking.
