# Security notes and findings

Tests passing is not an audit. This system will hold user principal; an independent adversarial review
is required before it is advertised or funded. Tools run in this job: `forge build`, `forge test`
(unit, fuzz, invariants), `forge fmt`, forge's built-in lints. Slither and Mythril were not available
here; the code was written around Slither's rejection detectors (no `selfdestruct`, `transferFrom`
only from `msg.sender`, no initializers/upgrades, no uninitialized storage pointers, no Yul shifts, no
`abi.encodePacked` of dynamic values).

## Fixed during development

| # | Finding | Fix | Test |
|---|---|---|---|
| 1 | `claim()` harvested rewards into a pending bucket but did not clear it, so a second `claim()` would pay again from `rewardReserve` (draining other users' rewards). | `_pendingOf[msg.sender] = 0` before paying. | `test_rewardsAccrueProRataAndClaimIsIndependentOfPrincipal` ("nothing twice"), invariant `invariant_farmBalanceCoversPrincipal` |
| 2 | Farm constructor read `controller.token()`; the token is bound after launch, so the farm cached the zero address, and the launch rehearses constructors on an empty chain where the call reverts. | `cheese()` is read lazily from the controller; constructors touch no contract. | `test_constructorsNeedNoLiveContracts`, all reward tests |
| 3 | `pendingRewards()` ignored Squeek blocks certified since the last checkpoint, under-reporting to the website. | `previewPoolEmission()` includes the unsynced checkpoint. | `test_rewardsAccrueProRataAndClaimIsIndependentOfPrincipal` |

## Fixed after independent review (revision 1)

| # | Severity | Finding | Fix | Test |
|---|---|---|---|---|
| 4 | high | A 1-wei first deposit (1000 shares) made `accRewardPerShare` grow by `amount × 1e36 / 1000` per pull; later `shares × acc` products overflowed, so ordinary deposits reverted for good. | Every `shares × acc / 1e36` is a 512-bit `Math.mulDiv`. | `test_oneWeiFirstDepositorCannotBrickLaterDeposits`, `invariant_userActionsNeverRevertUnexpectedly` |
| 5 | high | Floored reward debts let the accounts' entitlements sum a wei above `rewardReserve`; the last claimer reverted, permanently once emission had completed. | Debts round up (`_debtFor`), harvests floor and clamp at zero, so the sum never exceeds the reserve; `claim` additionally pays `min(pending, reserve)` and keeps the rest pending instead of reverting. | `test_everyAccountCanClaimAfterEmissionEnds`, `test_claimNeverRevertsOnReserveShortfall`, `invariant_entitlementsNeverExceedReserve` |
| 6 | high | `withdraw` pushed the Treasury's share with a reverting call, so a Treasury that refuses ETH (or tokens) blocked every withdrawal, irrecoverably after `renounceOwnership`. | The Treasury push is a non-reverting call with a 100k gas stipend; on failure the amount is credited to `treasuryOwed` and anyone can `payTreasury()` later. The withdrawer's 85% never depends on the Treasury. | `test_revertingTreasuryNeverBlocksWithdrawalEvenWithoutAnOwner`, `test_deferredTreasuryShareIsPaidOnceTheTreasuryCanReceive`, `test_gasBurningOrReceiverlessTreasuryIsDeferredToo`, `test_erc20FarmDefersTreasuryShareTheTokenRefusesToDeliver` |
| 7 | medium | Deposits were accepted while SqueekCore was unreadable or regressed, so blocks certified before the deposit were later spread over the new shares. | `pullRewards` returns `synced`; `_deposit` reverts with `SyncRequired` unless the sync succeeded. Withdrawals and claims stay best-effort. | `test_depositWaitsForSyncWhileWithdrawAndClaimDoNot`, `test_firstDepositDuringOutageCannotInheritForfeitableEmission` |
| 8 | medium | `pauseEmissions` did not checkpoint first, so a staker exiting during the pause lost the blocks certified before it, which could then be forfeited. | `pauseEmissions` calls `_sync()` (best effort) before setting the flag. | `test_pausePricesBlocksCertifiedBeforeItForThoseStakedThen`, `test_pauseStillWorksWhenCoreIsUnavailable` |
| 9 | medium | `try/catch` does not cover return data that fails to decode or a target without code, so a SqueekCore upgrade that changed a struct would revert every withdraw and claim. | SqueekCore is read through raw `staticcall`s; the payload must have the exact static size and decode through `this.decode*` inside `try/catch`; any failure is "unavailable". | `test_undecodableCoreStateIsUnavailableNotARevert`, `test_coreWithoutCodeIsUnavailableNotARevert`, `test_undecodableRoundPageDelaysAnchorWithoutRevert`, `test_activateTreatsUndecodableConfigurationAsUnavailable` |
| 10 | low | `batchSetPoolWeights` with a repeated id applied the two passes, not the input order. | Duplicate ids revert with `DuplicatePoolId`. | `test_batchRejectsDuplicatePoolIds` |
| 11 | low | When the last real shares left, the part of retained fees attributable to the virtual shares stayed in `totalAssets` with no shares to reach it. | With `totalShares == 0` the whole remaining reserve goes to the Treasury with the fee; the farm restarts at the initial price. | `test_emptyFarmSweepsResidualRetainedFeeToTreasury`, `test_lastDepositorWithdrawalSendsFull15ToTreasury` |
| 12 | low | The deploy script's hand-over left the deployer as guardian. | `handOver` calls `setGuardian(owner)` first. | `test_wireAndHandOver` |

## Trust assumptions (by design, requested by the brief)

* **Owner** can reallocate future emission between pools (including to 0), pause emissions (which also
  closes deposits), pause a farm's deposits, change the Treasury, and skim donated surplus to it. The
  owner cannot mint, change fees, or move principal or accrued rewards. Recommend a multisig or timelock
  as owner; `Ownable2Step` prevents accidental loss of ownership.
* **Guardian** can only pause emissions.
* **Squeekchain** is the sole emission oracle. Its Reporter and admin Timelock control what gets
  certified; a malicious or buggy settlement would mis-price CHEESE in the same way it mis-prices SQK.
  The controller never substitutes zero progress and never backdates; a height regression is ignored and
  logged.
* **Treasury** receives the 1% (or full 15%) Hamster Bite share. A Treasury that cannot receive
  (reverts, no `receive`, burns the 100k stipend, token refuses it) never blocks withdrawals: its share
  is deferred to `treasuryOwed` and delivered by `payTreasury()` once a receiving Treasury is set
  (tested). Use a plain EOA or a Safe anyway, so the share arrives directly.

## Residual risks and recommendations

1. **Forfeited emission.** Emission accrued while a farm has no stakers is forfeited (never minted). This
   is intentional (no retroactive rewards) but means total CHEESE issuance can fall below SQK's if a pool
   sits empty. Operators should set an empty pool's weight to 0 (moving its points to the reserve) or
   seed it. An alternative design routes forfeited emission to the Treasury; it is a one-line change in
   `pullRewards` and should be a product decision.
2. **Pause semantics.** The pause prices the blocks certified before it (best effort; if SqueekCore is
   unreadable at that moment those blocks are caught up at unpause). Pause stops pricing but not the
   Squeek clock; unpausing emits the blocks certified *during* the pause to whoever holds shares then.
   Deposits are closed while paused so nobody new can be added, but existing depositors who withdraw
   during a pause forgo that catch-up. Documented; acceptable for an emergency tool.
3. **sIMD asset unset at launch.** Until `setAsset` is called, the sIMD pool's 200 points accrue and are
   forfeited at the first pull. Set the asset before `activate()`.
4. **Reward dust.** `amount × 1e36 / totalShares` floors and each account's debt rounds up, so an account
   can lose at most 1 wei per share change; dust stays in `rewardReserve` unclaimable. Never affects
   principal, and the sum of entitlements never exceeds the reserve (invariant-tested).
5. **Virtual offset.** With 1e3 virtual shares and 1 virtual asset, a first deposit of 1 wei is possible
   and the retained-fee mechanic lets a griefer raise assets-per-share by paying 15% per cycle. Tests show
   a later depositor keeps ~100% of value; the attack is uneconomic but the first deposit on each farm
   should still be made by the team. While the griefer's last share remains, a deposit too small for one
   share reverts with `ZeroShares`; once every share leaves, the residual goes to the Treasury and the
   price resets. A 1-wei first depositor alone in a farm collects that pool's whole emission for as long
   as nobody else deposits; that is the intended "whoever is staked earns" rule, not a loss to others.
6. **Owner-set addresses are checked only for non-zero** (Treasury, guardian) or for code (sIMD asset).
   A wrong sIMD address cannot be corrected (write-once); verify before calling.
7. **Gas of `claim`/`deposit`.** Each user action may perform the checkpoint and mint (≈330k gas worst
   case in tests). Acceptable on Sepolia; a keeper calling `checkpoint()` each round keeps user actions
   cheaper.
8. **Squeekchain ABI change.** The proxies may be upgraded by their admin Timelock. A breaking change
   (another return size, undecodable data, code removed) makes `checkpoint()` return `false` and leaves
   withdrawals, claims and views working; deposits wait. A change that keeps the same size and field
   types but another meaning cannot be detected on chain and would mis-price emission until the owner
   pauses. In both cases a new controller would be required. The controller's `squeekCore` is immutable
   by design (no re-pointing attack surface).
9. **Deferred Treasury share.** `treasuryOwed` is reserved against `skimSurplus` and paid only to the
   Treasury configured at `payTreasury()` time; a wrong Treasury that *can* receive is paid directly,
   so verify the address before `setTreasury`.

## Checklist (ethskills `security`, adapted)

- [x] Access control on every state-changing function; farm hooks restricted to the controller
- [x] Pausable tradeoff flagged (owner/guardian pause; documented above)
- [x] Reentrancy: CEI + `nonReentrant`; tested re-entry via ETH receive on withdraw/deposit/claim
- [x] Decimals: assets and shares both 18 decimals by design; fee-on-transfer measured
- [x] Oracle: not a price oracle; Squeekchain state read live, regression and unavailability handled
- [x] Integer math: multiply before divide; 512-bit `Math.mulDiv` on every share × accumulator product; floors analysed, debts round up
- [x] SafeERC20 everywhere; ETH via `call` with revert on failure for the user's payout, bounded non-reverting push plus pull fallback for the Treasury
- [x] External dependency: SqueekCore read defensively (raw `staticcall`, size check, guarded decode); no user action depends on it
- [x] Input validation: zero address/amount/shares, weight bounds, batch length, duplicate farm
- [x] Events on every state change
- [x] Permissionless maintenance (`checkpoint`)
- [x] No approvals granted by the contracts
- [x] Not upgradeable, no delegatecall, no signatures beyond OpenZeppelin `ERC20Permit`
- [ ] Slither / Mythril run (not available in this environment; verifier runs Slither)
- [ ] Independent adversarial review
- [ ] Source verification on Blockscout after the launch (`forge verify-contract`), by the deployer
