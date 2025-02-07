# Network 1 (Ethereum Mainnet) Deployment Configuration

This directory contains the configuration files for deploying DSPC on Ethereum Mainnet.

## Files

### dspc-deploy.json
Configuration for deploying DSPC and DSPCMom contracts:
- `conv`: Address of the converter contract that handles rate conversions between basis points and ray format

## Usage

1. Update `dspc-deploy.json` with the correct `conv` address
2. Run the deployment script:
```bash
forge script script/DSPCDeploy.s.sol:DSPCDeployScript \
    --rpc-url $ETH_RPC_URL \
    --broadcast
```

The deployment script will:
1. Load system addresses from chainlog (jug, pot, susds)
2. Deploy DSPC and DSPCMom contracts
3. Set up permissions (mom owned by pause proxy, mom has authority over DSPC)
4. Export addresses to `/script/output/1/dspc-deploy.json`
