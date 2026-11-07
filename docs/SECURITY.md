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
* **Treasury** receives the 1% (or full 15%) Hamster Bite share. A Treasury that reverts on ETH receipt
  blocks ETH-farm withdrawals until the owner changes it (tested); use a plain EOA or a Safe.

## Residual risks and recommendations

1. **Forfeited emission.** Emission accrued while a farm has no stakers is forfeited (never minted). This
   is intentional (no retroactive rewards) but means total CHEESE issuance can fall below SQK's if a pool
   sits empty. Operators should set an empty pool's weight to 0 (moving its points to the reserve) or
   seed it. An alternative design routes forfeited emission to the Treasury; it is a one-line change in
   `pullRewards` and should be a product decision.
2. **Pause semantics.** Pause stops pricing but not the Squeek clock; unpausing emits the missed blocks to
   whoever holds shares then. Deposits are closed while paused so nobody new can be added, but existing
   depositors who withdraw during a pause forgo the catch-up. Documented; acceptable for an emergency
   tool.
3. **sIMD asset unset at launch.** Until `setAsset` is called, the sIMD pool's 200 points accrue and are
   forfeited at the first pull. Set the asset before `activate()`.
4. **Reward dust.** `amount × 1e36 / totalShares` floors; dust stays in `rewardReserve` unclaimable.
   Negligible (sub-wei per distribution) and never affects principal.
5. **Virtual offset.** With 1e3 virtual shares and 1 virtual asset, a first deposit of 1 wei is possible
   and the retained-fee mechanic lets a griefer raise assets-per-share by paying 15% per cycle. Tests show
   a later depositor keeps ~100% of value; the attack is uneconomic but the first deposit on each farm
   should still be made by the team.
6. **Owner-set addresses are checked only for non-zero** (Treasury, guardian) or for code (sIMD asset).
   A wrong sIMD address cannot be corrected (write-once); verify before calling.
7. **Gas of `claim`/`deposit`.** Each user action may perform the checkpoint and mint (≈330k gas worst
   case in tests). Acceptable on Sepolia; a keeper calling `checkpoint()` each round keeps user actions
   cheaper.
8. **Squeekchain ABI change.** The proxies may be upgraded by their admin Timelock. A breaking change
   makes `checkpoint()` return `false` forever; the owner should pause and a new controller would be
   required. The controller's `squeekCore` is immutable by design (no re-pointing attack surface).

## Checklist (ethskills `security`, adapted)

- [x] Access control on every state-changing function; farm hooks restricted to the controller
- [x] Pausable tradeoff flagged (owner/guardian pause; documented above)
- [x] Reentrancy: CEI + `nonReentrant`; tested re-entry via ETH receive on withdraw/deposit/claim
- [x] Decimals: assets and shares both 18 decimals by design; fee-on-transfer measured
- [x] Oracle: not a price oracle; Squeekchain state read live, regression and unavailability handled
- [x] Integer math: multiply before divide; `Math.mulDiv`; floors analysed
- [x] SafeERC20 everywhere; ETH via `call` with revert on failure
- [x] Input validation: zero address/amount/shares, weight bounds, batch length, duplicate farm
- [x] Events on every state change
- [x] Permissionless maintenance (`checkpoint`)
- [x] No approvals granted by the contracts
- [x] Not upgradeable, no delegatecall, no signatures beyond OpenZeppelin `ERC20Permit`
- [ ] Slither / Mythril run (not available in this environment; verifier runs Slither)
- [ ] Independent adversarial review
- [ ] Source verification on Blockscout after the launch (`forge verify-contract`), by the deployer
