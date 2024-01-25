#!/usr/bin/env bash
# Note: How to set defaultKey - https://www.youtube.com/watch?v=VQe7cIpaE54

# Read the RPC URL
source .env

# Run the script

echo Running Update PaymentHelper: ...

#FOUNDRY_PROFILE=default forge script script/UpdatePaymentHelper.s.sol:UpdatePaymentHelper --sig "updatePaymentHelper(uint256)" 0 --rpc-url $ETHEREUM_RPC_URL --broadcast --with-gas-price 35000000000 --slow --account defaultKey --sender 0x48aB8AdF869Ba9902Ad483FB1Ca2eFDAb6eabe92

#wait

#FOUNDRY_PROFILE=default forge script script/UpdatePaymentHelper.s.sol:UpdatePaymentHelper --sig "updatePaymentHelper(uint256)" 1 --rpc-url $BSC_RPC_URL --broadcast --slow --account defaultKey --sender 0x48aB8AdF869Ba9902Ad483FB1Ca2eFDAb6eabe92

#wait

#FOUNDRY_PROFILE=default forge script script/UpdatePaymentHelper.s.sol:UpdatePaymentHelper --sig "updatePaymentHelper(uint256)" 2 --rpc-url $AVALANCHE_RPC_URL --broadcast --slow --account defaultKey --sender 0x48aB8AdF869Ba9902Ad483FB1Ca2eFDAb6eabe92

#wait

#FOUNDRY_PROFILE=default forge script script/UpdatePaymentHelper.s.sol:UpdatePaymentHelper --sig "updatePaymentHelper(uint256)" 3 --rpc-url $POLYGON_RPC_URL --broadcast --with-gas-price 150000000000 --slow --account defaultKey --sender 0x48aB8AdF869Ba9902Ad483FB1Ca2eFDAb6eabe92

#wait

#FOUNDRY_PROFILE=default forge script script/UpdatePaymentHelper.s.sol:UpdatePaymentHelper --sig "updatePaymentHelper(uint256)" 4 --rpc-url $ARBITRUM_RPC_URL --broadcast --slow --account defaultKey --sender 0x48aB8AdF869Ba9902Ad483FB1Ca2eFDAb6eabe92

#ait

#FOUNDRY_PROFILE=default forge script script/UpdatePaymentHelper.s.sol:UpdatePaymentHelper --sig "updatePaymentHelper(uint256)" 5 --rpc-url $OPTIMISM_RPC_URL --broadcast --slow --account defaultKey --sender 0x48aB8AdF869Ba9902Ad483FB1Ca2eFDAb6eabe92

#wait

FOUNDRY_PROFILE=default forge script script/UpdatePaymentHelper.s.sol:UpdatePaymentHelper --sig "updatePaymentHelper(uint256)" 6 --rpc-url $BASE_RPC_URL --broadcast --slow --account defaultKey --sender 0x48aB8AdF869Ba9902Ad483FB1Ca2eFDAb6eabe92

wait
