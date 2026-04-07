# Decentralized Stablecoin (DSC)

A minimalistic algorithmic stablecoin pegged to $1 USD, backed by exogenous collateral (wETH, wBTC).

## Architecture

Two contracts work together:

- **`DecentralizedStableCoin.sol`** — The ERC-20 token (DSC). Only the DSCEngine can mint or burn it.
- **`DSCEngine.sol`** — The core logic. Manages collateral deposits, DSC minting, health factors, and liquidations.

---

## Minting Workflow

To mint DSC, a user must first deposit collateral worth more than the DSC they want to mint. The system requires **200% collateralization** (LIQUIDATION_THRESHOLD = 50).

```
User
 │
 ├─ 1. approve(DSCEngine, amount)        ← allow DSCEngine to pull tokens
 │        (called on the collateral token, e.g. wETH)
 │
 ├─ 2. depositCollateral(token, amount)
 │        │
 │        ├─ checks: amount > 0, token is allowed
 │        ├─ s_collateralDeposited[user][token] += amount
 │        ├─ emit CollateralDeposited
 │        └─ IERC20.transferFrom(user → DSCEngine)
 │
 └─ 3. mintDsc(amountDscToMint)
          │
          ├─ s_dscMinted[user] += amount
          ├─ _revertIfHealthFactorIsBroken(user)
          │        │
          │        └─ _healthFactor(user)
          │                 │
          │                 ├─ _getAccountInformation(user)
          │                 │       ├─ totalDscMinted = s_dscMinted[user]
          │                 │       └─ totalCollateralValueInUsd
          │                 │               │
          │                 │               └─ getAccountCollateralValueInUsd(user)
          │                 │                       │
          │                 │                       └─ getPrice(token, amount)
          │                 │                               └─ Chainlink.latestRoundData()
          │                 │
          │                 └─ returns (collateralUSD × 50/100 × 1e18) / dscMinted
          │                    if < 1e18 → revert DSCEngine_BreaksHealthFactor
          │
          └─ i_dsc.mint(user, amount)     ← DSC tokens sent to user
```

### Health Factor Formula

```
healthFactor = (collateralValueUSD × LIQUIDATION_THRESHOLD / 100) × 1e18 / dscMinted
```

- A health factor **≥ 1e18** means the position is safe
- A health factor **< 1e18** means the user is undercollateralized and can be liquidated

### Example

| Collateral deposited | DSC minted | Health Factor |
|---|---|---|
| $200 wETH | 50 DSC | `(200 × 50/100) × 1e18 / 50` = 2e18 ✅ |
| $200 wETH | 100 DSC | `(200 × 50/100) × 1e18 / 100` = 1e18 ✅ |
| $200 wETH | 150 DSC | `(200 × 50/100) × 1e18 / 150` = 0.66e18 ❌ liquidatable |

---

## Foundry

**Foundry is a blazing fast, portable and modular toolkit for Ethereum application development written in Rust.**

Foundry consists of:

- **Forge**: Ethereum testing framework (like Truffle, Hardhat and DappTools).
- **Cast**: Swiss army knife for interacting with EVM smart contracts, sending transactions and getting chain data.
- **Anvil**: Local Ethereum node, akin to Ganache, Hardhat Network.
- **Chisel**: Fast, utilitarian, and verbose solidity REPL.

## Documentation

https://book.getfoundry.sh/

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

### Deploy

```shell
$ forge script script/Counter.s.sol:CounterScript --rpc-url <your_rpc_url> --private-key <your_private_key>
```

### Cast

```shell
$ cast <subcommand>
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```
