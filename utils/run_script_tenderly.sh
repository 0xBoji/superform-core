#!/usr/bin/env bash

# Read the RPC URL
source .env

BSC_DEVNET=$(tenderly devnet spawn-rpc --project $TENDERLY_PROJECT_SLUG --template bscdevnet --account $TENDERLY_ACCOUNT_ID --access_key $TENDERLY_ACCESS_KEY --return-url)
POLYGON_DEVNET=$(tenderly devnet spawn-rpc --project $TENDERLY_PROJECT_SLUG --template polygondevnet --account $TENDERLY_ACCOUNT_ID --access_key $TENDERLY_ACCESS_KEY --return-url)
BASE_DEVNET=$(tenderly devnet spawn-rpc --project $TENDERLY_PROJECT_SLUG --template basedevnet --account $TENDERLY_ACCOUNT_ID --access_key $TENDERLY_ACCESS_KEY --return-url)

# Run the script
echo Running Stage 1: ...


FOUNDRY_PROFILE=default forge script script/Mainnet.Deploy.s.sol:MainnetDeploy --sig "deployStage1(uint256,uint256)" 0 1337 --rpc-url $BSC_DEVNET --broadcast --unlocked --sender 0x0000000000000000000000000000000000000000

wait

FOUNDRY_PROFILE=default forge script script/Mainnet.Deploy.s.sol:MainnetDeploy --sig "deployStage1(uint256,uint256)" 1 1337 --rpc-url $POLYGON_DEVNET --broadcast --unlocked --sender 0x0000000000000000000000000000000000000000

wait

FOUNDRY_PROFILE=default forge script script/Mainnet.Deploy.s.sol:MainnetDeploy --sig "deployStage1(uint256,uint256)" 2 1337 --rpc-url $BASE_DEVNET --broadcast --unlocked --sender 0x0000000000000000000000000000000000000000

wait

echo Running Stage 2: ...


FOUNDRY_PROFILE=default forge script script/Mainnet.Deploy.s.sol:MainnetDeploy --sig "deployStage2(uint256)" 0 --rpc-url $BSC_DEVNET --broadcast --unlocked --sender 0x0000000000000000000000000000000000000000

wait

FOUNDRY_PROFILE=default forge script script/Mainnet.Deploy.s.sol:MainnetDeploy --sig "deployStage2(uint256)" 1 --rpc-url $POLYGON_DEVNET --broadcast --unlocked --sender 0x0000000000000000000000000000000000000000

wait

FOUNDRY_PROFILE=default forge script script/Mainnet.Deploy.s.sol:MainnetDeploy --sig "deployStage2(uint256)" 2 --rpc-url $BASE_DEVNET --broadcast --unlocked --sender 0x0000000000000000000000000000000000000000

#echo Running Stage 3: ...

#wait

#FOUNDRY_PROFILE=default forge script script/Mainnet.Deploy.s.sol:MainnetDeploy --sig "deployStage3(uint256)" 0 --rpc-url $BSC_DEVNET --broadcast --unlocked --sender 0x0000000000000000000000000000000000000000

#wait

#FOUNDRY_PROFILE=default forge script script/Mainnet.Deploy.s.sol:MainnetDeploy --sig "deployStage3(uint256)" 1 --rpc-url $POLYGON_DEVNET --broadcast --unlocked --sender 0x0000000000000000000000000000000000000000

#wait

#FOUNDRY_PROFILE=default forge script script/Mainnet.Deploy.s.sol:MainnetDeploy --sig "deployStage3(uint256)" 2 --rpc-url $AVAX_DEVNET --broadcast --unlocked --sender 0x0000000000000000000000000000000000000000

