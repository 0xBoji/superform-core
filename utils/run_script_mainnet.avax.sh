#!/usr/bin/env bash

# Read the RPC URL
source .env


# Run the script
echo Running Script: ...

forge script script/Test.Mainnet.Deploy.Single.s.sol:TestMainnetDeploySingle --sig "deploy(uint256)" 2 --rpc-url $AVALANCHE_RPC_URL --broadcast \
    --force \
    --slow 
