# JackpotHook invariant suite review

Reviewed the unmodified `src/JackpotHook.sol`, `test/fixtures/JackpotFixture.sol`,
both provided protected check files, and the new handler/suite against the assignment.
No reproducible implementation defect was found in this scope. There is no failing
sequence to preserve and no implementation behavior has been exempted from an invariant.

The fixture deploys the real PoolManager, router, and hook. The second initialized,
liquid pool shares native currency and the hook, but uses a distinct standard mock
ERC-20. Only six handler selectors are fuzz targets; neither the hook, tokens, nor
the fixture's roll-preimage helper can be called directly by the invariant fuzzer.

| Requirement | Check |
| --- | --- |
| Per-pool conservation | Ghost fees come from input magnitude / 100; tank credits from pees × 10 tokens; payouts from the independent outcome model. Compare each resulting balance with `pots`. |
| Claims backing | Sum both native pots against the native claim balance; compare each token pot against its distinct currency claim balance. Check all three hook wallet balances are zero. |
| Pool isolation | Snapshot the other pool's two pots and ticket counter before each action, including expected failures, and preserve any mismatch in a sticky flag. |
| Ticket identity and one-time payout | Compare every ticket's immutable metadata and drawn state with ghost issuance. A distinct keeper triggers draws. Check player, bystander, keeper, handler, router, and manager balances in all three currencies; retry every successful draw. |
| Prize rules | Compare transfers and exactly one correctly indexed `Drawn` event with the complete expected outcome. Bound emitted prizes and actual pot outflow. Deterministically exercise both sides of the small-prize minimum in both currencies and non-divisible jackpot pots. |
| Expiry | At B+257 force a hash that would win at a valid age, but require roll zero and no payout. Check duplicate expiry rejects. |
| Ticket counter | Compare each transition and the total against qualifying swaps; fills and draws cannot increment it. |

The handler catches `TooEarly`, `AlreadyDrawn`, `UnknownTicket`, invalid pee counts,
and missing-allowance settlement failures. Revert data must match exactly; state,
claims, ticket metadata, and participant balances must remain unchanged as applicable.
Unexpected swap/fill/draw reverts increment a persistent failure counter. No handler
assertions can disappear as discarded fuzz calls, and inline `fail-on-revert = true`
also makes an accidental harness revert fail the campaign.

Draw ages are exactly B+1, B+2, B+256, and B+257. Time only moves forward, so a
requested age already in the past is counted as a skipped draw. Separate deterministic
tests guarantee all age/roll combinations, all four swap modes, threshold and rounding
edges, three players, both attribution paths, both pools, minimum/maximum fills, and
rejection paths execute successfully. Payout expectations never use the emitted payout
or infer fees from observed pot changes.

Review improvements: added an explicit jackpot case where each pre-draw pot ends in
one wei, ensuring percentage floor rounding is covered independently of random inputs.
Swap magnitudes are bounded to keep this accounting campaign liquid and funded for
64 actions; existing unit/adversarial tests retain coverage of partial fills, extreme
amounts, rejecting receivers, reentrancy, and fee-on-transfer funding.

Validation commands (artifacts remain inside disposable scratch):

```sh
forge build --out test/scratch/out --cache-path test/scratch/cache
forge test --out test/scratch/out --cache-path test/scratch/cache
```

The suite configures 128 invariant runs and depth 64 in inline comments, without
changing configuration or dependencies. The full local run passed, including all
eight invariant properties over 8,192 calls with zero escaped handler reverts and
the deterministic handler checks. Existing tests also passed.
