# PoC — C-1: BuildersV4 retroactive withdraw-lock increase (Morpheus / MOR)

Foundry fork PoC for finding C-1: a subnet admin (a role anyone can acquire
permissionlessly — `createSubnet` is public and the live subnet creation fee
is 0) can retroactively raise a subnet's `withdrawLockPeriodAfterDeposit`
via `editSubnet`. `_validateSubnet` enforces only the 7-day minimum — no
upper bound, no timelock, no grandfathering — and `withdraw()` reads the
current lock against the staker's old `lastDeposit`, so existing stakers
can be locked permanently (100 years, or uint128.max).

## Run it (one command)

Prerequisites: Foundry (`forge`).

```bash
forge test --fork-url https://mainnet.base.org --fork-block-number 53428250
```

Expected result: **2 passed**
- `test_EditSubnet_PermanentLock` (gas: 1190884) — victim's 100 MOR stays
  deposited; withdraw reverts at +1y and +100y after the lock is raised to
  uint128.max; the same withdraw succeeds under the original 7-day terms
  (snapshot control branch).
- `test_EditSubnet_100yLock` (gas: 880811) — same attack with a 100-year
  lock, reverting with "BU: user withdraw is locked" after 99 years.

Target: BuildersV4 @ 0x42BB446eAE6dca7723a9eBdb81EA88aFe77eF4B9 on Base,
fork pinned to block 53,428,250. No privileged account is used anywhere:
the subnet creator, the victim staker, and the lock edit are all ordinary
unprivileged actions. No Morpheus contract is mocked or modified.

## Files

- `foundry.toml` — solc 0.8.20.
- `test/EditSubnetLock.t.sol` — the PoC suite (2 tests).
- `lib/forge-std/` — vendored test library, so a clean clone runs with no
  extra setup beyond an RPC endpoint.
