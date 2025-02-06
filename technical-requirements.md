TL;DR: the Direct Stability Parameters Change (DSPC) Module will allow **permissioned** actors to modify the stability parameters (rates) in the Sky Protocol without requiring to go through the full executive vote process.

## Context

There are fundamentally 2 types of rates used in the Sky Protocol:

1. Stability Fee Rates: defined per collateral type (`ilk`), they are used to calculate the fee that vault owners need to pay when they borrow Dai/USDS from the Sky Protocol. They are part of the protocol's revenue.
2. Savings Rates (DSR and SSR): defined globally, it is the yield for users who wish to deposit Dai or USDS into the Sky Protocol. They can be thought of as a component of the protocol's expenses.

A fundamental part of the ability of the Sky Protocol to react to different market conditions is to able to update the system rates. Currently, the only way to update any rate within the core Sky Protocol is through a governance-coordinated executive vote. While this ensures the maximum level of transparency, both the crafting of the _spells_ &ndash; bespoke smart contracts that will carry out the actions defined by the executive vote &ndash; and the decentralized governance operational overheads severely hinder Sky Protocol's reaction time in volatile market scenarios.

We would like to introduce a new Instant Access Module (IAM) to allow system rates to be set independently of the main governance process. Unlike other IAMs in Sky Protocol, the Rates IAM would be permissioned, allowing well-known actors (i.e.: a facilitator multisg) to adjust the rates within a set of rules &ndash; a mix of on-chain and off-chain ones.

The actual off-chain process that would govern the operations of the module are out of the scope of this document. It must be discussed with the relevant stakeholders and added to the Atlas before the module is on-boarded into the protocol.

### Understanding rates in the Sky Protocol

Sky Protocol uses [compound rates](https://en.wikipedia.org/wiki/Compound_interest). Different from TradFi applications, where the common compounding periods are days or months, rates in the Sky Protocol compound every second. For that reason, we need to obtain the _equivalent rate_ per second relative to a human-readable yearly rate. The math involved is quite simple:

$$
r_{s} = \left[ \left(1 + r_{y}\right)^{1/t} \right] - 1
$$

Where:

- $r_s$: the per-second equivalent rate
- $r_y$: the human-readable yearly rate
- $t$: the number of seconds in a year

Applying the formula above to a $5\%$ yearly rate, we would end up with a $0.0000001547125957863212448\%$ per-second rate.

The way to interpret it is that if we multiply the present value by $1.000000001547125957863212448$ for each second during 1 year, the final value will be added of $5\%$.

Due to EVM's lack of support for fractional math, performing the conversion above on-chain can be impractical. Instead, the per-second rates are computed off-chain and stored on-chain as `RAY`s (integers with $27$ decimals precision). For instance, a $5\%$ yearly rate is represented as:

```
1000000001547125957863212448
```

Using a [variation](https://github.com/makerdao/sdai/blob/dfc7f41cb7599afcb0f0eb1ddaadbf9dd4015dce/src/SUsds.sol#L160-L182) of the infamous [exponentiation by squaring](https://en.wikipedia.org/wiki/Exponentiation_by_squaring) algorithm, we can perform calculations with the per-second rate with relative gas efficiency.

### Stability fees

Each `ilk` (collateral type) has an associated stability fee stored in the [`Jug`](https://etherscan.io/address/0x19c0976f590d67707e62397c87829d896dc0f1f1#code) named `duty`. Whenever `jug.drip(ilk)` is called, it calculates the accumulated rate between the current and the last time the function was called and updates the `Vat[ilk].rate` accumulator.

The `Jug` also features a `base` rate, which is **added** to `duty` in the calculation. However, [addition does not work well for compound rates](https://docs.makerdao.com/smart-contract-modules/rates-module/jug-detailed-documentation#base--ilk.duty-imbalance-in-drip), as `rate(base + duty) != rate(base) + rate(duty)`. This would require updates to every `ilk` `duty` whenever `base` is changed, which arguably defeats the purpose of having a base rate. For that reason, the value for `base` was set to zero when the Sky Protocol was launched and has never changed.

### DSR and SSR

Users can deposit Dai/USDS into the Sky Protocol and receive yield for it. That yield is sustainable as long as the revenues of the protocol can cover it.

The DSR is implemented in the [`Pot`](https://etherscan.io/address/0x197e90f9fad81970ba7976f33cbd77088e5d7cf7) contract, which uses `Vat`'s internal Dai representation. Originally that required users to have some knowledge on how the Sky Protocol worked to be able to use it. However community-led tokens &ndash; such as [Chai](https://etherscan.io/token/0x06af07097c9eeb7fd685c692751d5c66db49c215) and [sDAI](https://etherscan.io/token/0x83f20f44975d03b1b09e64809b757c47f942beea) &ndash; wrap `Pot`'s functionality and make it easier to use.

In the case of SSR, the functionality is packed within the fully ERC-4626 compatible [sUSDS](https://etherscan.io/token/0x4e7991e5c547ce825bdeb665ee14a3274f9f61e0) token, which largely simplifies its use.

It is important to notice that DSR and SSR rates are set separately and there is no on-chain enforced relationship between them. As of this writing, the SSR is set slightly higher than the DSR to incentivize users to migrate from Dai to USDS.

The functionality of compound rates is implemented very similarly to stability fees, with the exception that there is no concept of a `base` rate.

## Business Requirements

- Authorized actors are allowed to set the value for any stability parameter in the system.
- The constraints around the values to be set are defined by Sky Governance and can be freely modified after deployment.
- The constraints are:
  - The maximum value a rate is allowed to be set to through this module.
  - The minimum value a rate is allowed to be set to through this module.
  - The maximum size of each adjustment step, either up or down.
- The updates take effect immediately upon execution.

Useful links:

- [\[Public\] Idea: Stability Parameter Automator](https://docs.google.com/document/d/1_tHFQJqRRkybPC3LgUHsxCo1O6TTCpzZw2RwtpJ5oxg) by BA Labs

## Solution Design

:::danger
TODO: update the diagram to include the `Conv` contract as a dependency.
:::

![architecture-overview](https://hackmd.io/_uploads/rkdIvn08yx.png)

The Rates IAM module introduces 2 new components:

1. **Rates Manager:** a permissioned contract that allows whitelisted parties to adjust stability fees, the DSR and the SSR. It follows the traditional tiered permissioning model present in most Sky Protocol's components.
1. **Rates Manager Mom:** allows Sky Governance to disable the Rates Manager through an executive vote. It follows the Mom architecture, which allows bypassing the GSM delay.

It also depends on an existing `Conv` contract that can convert yearly basis points notation into per-second rates with 27 decimals.

## Implementation Details

To prevent extreme values from being set either by mistake or by a malicious whitelisted user, there are constraints that are applicable to all rates being set:

- `min`: the minimum value for rates that can be set using this module.
- `max`: the maximum value for rates that can be set using this module.
- `step`: limits how much rates can be increased/decreased at once.

`min` and `max` act like sanity checks, preventing values that are outside the range from being set.

`step` ensures that the fees cannot be changed too drastically in a single update.

The module receives BPS values as a param, and will fetch the stability fee from the `conv` module.

The parameters above are defined per stability parameter ID (`<ilk> | DSR | SSR`) as annual basis-points and stored as `uint16`, as it is enough to store rates from `0` to `100_00` bps.

```solidity
struct Cfg {
  uint16 min;
  uint16 max;
  uint16 step;
}

mapping(bytes32 => Cfg) cfgs; // cfgs[id]
```

Notice that we use `id` instead of `ilk` as the key for the mapping. `id` can be defined as:

```
id := <ilk> | "DSR" | "SSR"
```

In the Rates Manager, admin whitelist uses the `rely` / `deny` / `wards` / `auth` pattern and facilitator whitelist uses the `kiss` / `diss` / `bud` / `toll` pattern that are common in other tiered access level contract in the Sky Protocol.

All non-admin functions should revert in case the Rates Manager `bad == 1`. `bad` can only be set by the Rates Manager Mom or through an executive spell.

To set rate changes, whitelisted facilitators must call `set(rate_changes)`, where `rate_changes` is an array of a custom struct `ParamChange`:

```solidity
struct ParamChange {
  bytes32 id;
  uint256 bps;
}
```

This normalizes the calldata to set any rate in the system. The Rates Manager contract must be able to distinguish the special values for `id` and set the proper parameters.

The function validates that every rate in the update is within `[min, max]` range and if the change in either direction is lower than or equal `step`.

## Deployment Approach

Rates manager has one dependency, the Conv module (used to conver bps rates to per second MCD rates).

Parameters to be provided on deployment:

- `min`: the minimum value for rates that can be set using this module.
- `max`: the maximum value for rates that can be set using this module.
- `gap`: limits how much rates can be increased/decreased at once.
- `lag`: a timelock between the rates being set and actually applied to the system.
- `conv`: address of the `Conv` module

Setup of the contract includes:

- `MCD_PAUSE_PROXY` is added to `wards`.
- Rates Manager Mom is added to `wards`.
- Risk team multisig (provided by the team and verified by the community) is added to `buds`.
- Deployer account is removed from `wards`

The contract needs privileged access (`ward` of `Jug`, `Pot` and `sUSDS`), the access will have to be granted through the governance and Spell processes.

## Attack Vectors & Edge Cases

- Rates Manager needs to be a `ward` of `Jug`, `Pot` and `sUSDS`, meaning it would gain unlimited access to those contracts.
- Any multisig included in `buds` can change rates in the DSS system (with the constraints imposed by the module: `min`, `max` and `gap`). In case a multisig becomes adversarial the community should propose an emergency Spell for a. Prevent any updates initiated (`pop()`) and revoke access to the adversarial multisig (`diss()`). Alternatively, disabling the module (`file("bad")` on Rates Mgr Mom) will both prevent changes from happening and prevent any future rate change through the module.

## Assumptions

- This module depends on the `Conv` smart contract for verifying rate changes. In addition to `max`, `Conv` will also act as a ceiling, trying to set the rate to a ceiling higher than `Conv` supports will cause execution to revert.

## Alternative Designs

### Permissioned Rates Spell Factory

Another possibility would be to remove the centralization point from the operator to change rates. Instead, the module would contain a similar set of rules and permissions, but the operator would only be able to propose the rate changes. Then those changes would be encoded as an out-of-schedule spell that bypasses the GSM delay. Once it has enough support from the community, it would be effective right away.

The module could still feature the same restrictions (`min`, `max` and `gap`), but the operational oversight would shift to the broader community, since a regular voting process should happen.

In other words, this module would become a permissioned out-of-schedule spell factory for rate changes.

:::danger
TODO: update to include the new `Conv` contract.
:::
![spell-factory](https://hackmd.io/_uploads/ByHGN3fDkl.png)

Some concepts can be borrowed from the [Pre-deployed Emergency Spells](https://github.com/makerdao/dss-emergency-spells), as the mechanism for execution would be pretty similar. The main difference is that those spells are not meant to be reused.

:warning: The technical feasibility of this still needs discussion, as emergency spells are designed to work with contracts following the `Mom` architecture, however there is no Mom contract for rates.

## Rates IAM vs Rates Spell Factory

| Rates IAM                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   | Rates Spell Factory                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| This brings a centralization vector to setting the rates, which are the most important parameters for a **decentralized** stablecoin. It also makes the signers liable for the rate changes which affect hundreds of millions of debt. A short poll that gets voted with the proposed param changes could reduce the signers liabilities, but increases coordination effort.                                                                                                                                                                | Having the change proposed by a Msig, so the signers review the rates in the proposal which reduces the human error, and having a spell to vote the rates creates the perfect mix of decentralization, reducing collusion and low liabilities on the signers                                                                                                                                                                                                                                                                                     |
| New permissions to core modules (`Jug`, `Pot`, `sUSDS`) are required                                                                                                                                                                                                                                                                                                                                                                                                                                                                        | No new permissions required, as it would follow the spell architecture                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| Having a Msig taking the decisions speeds up reaction and reduces coordination efforts, but, the Sky protocol has been known for "stable rates with long notification times before changes happen" USP, which could not hold true if the Msig signers start making rate changes too frequently. Letting this USP go away can be a bug or a feature if intended. In the long-term, when the BA labs current contributors are no longer part of the protocol, would open the door for quick rate changes which could become a bug in the end. | The coordination burden involving the delegates would be highly increased. In extreme market scenarios, there might be a need to execute several spells within a span of a few days. (1) There might be a scenario where this kind of out-of-schedule spell is out for voting at the same time as regular spell. (1.a) It might not be clear to delegates which spell they should support first. (1.b) If a regular spell also changes rates, it will overwrite the out-of-schedule spell with the rate changes as soon as the GSM delay passes. |

## Changelog

- 2025-01-15: Initial draft (@amusingaxl)
- 2025-01-21: Apply the technical design document template (@amusingaxl)
