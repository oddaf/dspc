# Direct Stability Parameters Change Module (DSPC)

A module for MakerDAO that enables direct changes to stability parameters (duty) for collateral types through a simple, secure interface.

## Overview

The DSPC module provides a streamlined way to modify stability fees for different collateral types in the Maker Protocol. It interfaces directly with the Jug contract and includes proper access controls.

## Features

- Direct stability fee modifications for any collateral type
- Owner-based access control
- Event emission for all parameter changes
- Simple, auditable implementation

## Installation

```bash
forge install
```

## Testing

```bash
forge test
```

## Usage

1. Deploy the contract with the Jug contract address:
```solidity
DSPC dspc = new DSPC(jugAddress);
```

2. Call the `file` function to modify stability fees:
```solidity
dspc.file("ETH-A", 1.05e27); // Sets 5% stability fee for ETH-A
```

## Security

The module implements a simple but effective authorization system where only the owner can make changes. The owner can be transferred to a new address if needed.

## License

AGPL-3.0-or-later
