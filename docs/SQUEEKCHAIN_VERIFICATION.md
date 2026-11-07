# Squeekchain verification record (2026-11-07)

Sources read: https://docs.squeekchain.com/ , https://docs.squeekchain.com/llms-full.txt ,
https://docs.squeekchain.com/assets/deployments/sepolia.json , and the published ABIs
`assets/abi/SqueekCore.json`, `SqueekMining.json`, `SqueekToken.json`.
Chain reads: Sepolia (chain id 11155111) via a public RPC at Ethereum block **12081684**.

## Deployment identity (docs vs chain)

| Check | Docs / sepolia.json | Chain | Match |
|---|---|---|---|
| Chain id | 11155111 | 11155111 | yes |
| SqueekCore proxy | `0xfd6c166d4b8e2962e65746a13e5a0797cd4de0c4` | has code (1525 bytes proxy) | yes |
| SqueekCore impl (EIP-1967 slot) | `0x6869d6102696243fd17013ab955d99cd0c522ad3` | same | yes |
| SqueekCore impl runtime hash | `0x65b5780a4fccafedeca1260806364d2bb512b4501c097253f792ae2839565a9c` | same | yes |
| SqueekMining proxy | `0x2dccb11fcc2defdd188555e45acb52231e82e218` | | yes |
| SqueekMining impl (EIP-1967 slot) | `0x32639fc0bbd16ba0b140f78950751591609cfaa4` | same | yes |
| SqueekMining impl runtime hash | `0xbcc7179f61610f44cf19a8fe4ffe27c06cba083a9430eb2787c5807b30e1e959` | same | yes |
| SqueekToken | `0xd78a3956cf63164d1fa1c622ad3c66623162fa1e` | runtime hash `0x6d6ea1d4…2433329` matches | yes |
| SqueekToken name/symbol/decimals | Squeek / SQK / 18 | same | yes |
| SqueekToken `mining()` | Mining proxy | `0x2dCcB11f…82e218` | yes |
| Admin Timelock (`bindings().governance`) | `0xaa2e9621de9ac23cbb36d1a1bac4c8b0694cc30d` | same | yes |

## Block counter (SqueekCore)

`state()` at block 12081684: `settledThroughRound 491, cumulativeWork 15458, cumulativeBlockUnits
1633969346865, blockHeight 1633, blockProgress 969346865, workPerThousandBlocks 8794, nonce 306,
paused false`. `blockHeight == cumulativeBlockUnits / 1e9` holds.

`configuration()`: genesis `1793735400`, roundDuration `600`, maxWorkPerRound `10000`,
maxRoundsPerBatch `16`, targetBlocksPerActiveRound `40`, difficultySmoothingRounds `30`,
blockUnitsPerBlock `1000000000` — all as documented. `blockInfo(1)` = (round 195, threshold 11).

## Issuance schedule (SqueekMining)

`issuanceSchedule()`: allowance `1890000000000000000000000000`, launchBonus
`105000000000000000000000000`, bonusBlocks `97020`, halvingBlocks `393470`, firstPeriodRate
`2592319617759930871476`, startHeight `0`. `SUPPLY_CAP()` = `2100000000000000000000000000`,
`MAX_CHECKPOINT_ROUNDS()` = 32.

Formula check (`R0 = 4 × floor((A − G) / (7H))`): computed `2592319617759930871476` = on-chain. The
compiled constant `SqueekIssuance.FIRST_PERIOD_RATE` is this value.

`issued(b)` on chain vs `SqueekIssuance.issued(b)`:

| b | on-chain | matches |
|---|---|---|
| 0 | 0 | yes |
| 1 | 3674570700011013122558 | yes |
| 2 | 7349141400022026245116 | yes |
| 97020 | 356506849315068493150601520 | yes |
| 97021 | 356509441634686253081472996 | yes |
| 393470 | 1124999999999999999999661720 | yes |
| 393471 | 1125001296159808879965097458 | yes |
| 786940 | 1634999999999999999999492580 | yes |
| 786941 | 1635000648079904439982210449 | yes |
| 1180410 | 1889999999999999999999408010 | yes |
| 2000000 | 1889999999999999999999408010 | yes |

## Actual minting behaviour

`SqueekMining.state()`: minted `6000573953117984429137624`, processedThroughRound 491, startRound 17,
startHeight 0, fundedBlocks 1633, bootstrapped/startCaptured/active true, paused false.
`issued(1633)` = `6000573953117984429137624` = minted: the live contract mints exactly the schedule.
`SqueekToken.totalMinted()` = `216000573953117984429137624` = premint `210000000e18` + minted;
`totalBurned()` = `159862591342600556196`; `totalSupply()` = totalMinted − totalBurned. All of the
documented supply identities hold.

## Launch configuration mirrored by CHEESE

| SQK (sepolia.json launchConfiguration) | CHEESE |
|---|---|
| premint 210,000,000 (team 63M, treasury 63M, liquidity 84M) | `CheeseToken` constructor premint, same split |
| allowance 1,890,000,000 | `MINING_ALLOWANCE` |
| launch bonus 105,000,000 over 97,020 blocks | `LAUNCH_BONUS`, `BONUS_BLOCKS` |
| halving every 393,470 blocks, three periods | `HALVING_BLOCKS`, `HALVING_PERIODS` |
| start at next round after `start()`; h0 = height at round startRound−1 | `activate()`, `StartHeightCaptured` |
| blocks ≤ h0 never issue | `startHeight` cursor |
| zero-amount checkpoints are valid and advance the cursor | `checkpoint()` returns `(true, 0)` |

## Discrepancies

None found between documentation and deployed contracts for any value CHEESE depends on. The docs
describe the deployment as testnet-only and "in active development"; `script/VerifySqueekchain.s.sol`
repeats every check above and must pass immediately before `activate()`.
