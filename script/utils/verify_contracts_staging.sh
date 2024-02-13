#!/usr/bin/env bash

# Read the RPC URL
source .env

networks=(
    56
    42161
    10
    8453
    # add more networks here if needed
)

api_keys=(
    $BSCSCAN_API
    $ARBISCAN_API
    $OPSCAN_API
    $BASESCAN_API
    # add more API keys here if needed
)

## CONTRACTS VERIFICATION
empty_constructor_arg="$(cast abi-encode "constructor()")"
super_constructor_arg="$(cast abi-encode "constructor(address)" 0xB2C097ac459aFAc892ae5b35f6bd6a9Dd3071F47)"
superposition_constructor_arg="$(cast abi-encode "constructor(string, address, string, string)" https://ipfs-gateway.superform.xyz/ipns/k51qzi5uqu5dg90fqdo9j63m556wlddeux4mlgyythp30zousgh3huhyzouyq8/JSON/ 0xB2C097ac459aFAc892ae5b35f6bd6a9Dd3071F47 StagingSuperPositions SP)"
superregistry_constructor_arg="$(cast abi-encode "constructor(address)" 0x9736b60c4f749232d400B5605f21AE137a5Ebb71)"
super_rbac_arg="$(cast abi-encode 'constructor((address,address,address,address,address,address,address,address,address,address,address))' '(0x48aB8AdF869Ba9902Ad483FB1Ca2eFDAb6eabe92,0x48aB8AdF869Ba9902Ad483FB1Ca2eFDAb6eabe92,0xc5c971e6B9F01dcf06bda896AEA3648eD6e3EFb3,0x2759142A9e3cBbcCc1E3d5F76490eEE4007B8943,0x6A5DD913fE3CB5193E09D1810a3b9ff1C0f9c0D6,0x6A5DD913fE3CB5193E09D1810a3b9ff1C0f9c0D6,0xF1c73958118F22Fc3A3947f405DcEBF08a1E68f7,0x6A5DD913fE3CB5193E09D1810a3b9ff1C0f9c0D6,0x3ea519270248BdEE4a939df20049E02290bf9CaF,0xe1A61d90554131314cB30dB55B8AD4F4b6e21C3a,0xe9F074d003b377A197D336B8a1c86EdaA6cC4dEF)')"
wormhole_sr_arg="$(cast abi-encode "constructor(address, uint8)" 0xB2C097ac459aFAc892ae5b35f6bd6a9Dd3071F47 2)"

file_names=(
    "src/crosschain-data/extensions/CoreStateRegistry.sol"
    "src/crosschain-liquidity/DstSwapper.sol"
    "src/forms/ERC4626Form.sol"
    "src/EmergencyQueue.sol"
    "src/crosschain-data/adapters/hyperlane/HyperlaneImplementation.sol"
    "src/crosschain-data/adapters/layerzero/LayerzeroImplementation.sol"
    "src/crosschain-liquidity/lifi/LiFiValidator.sol"
    "src/payments/PayMaster.sol"
    "src/crosschain-data/utils/PayloadHelper.sol"
    "src/payments/PaymentHelper.sol"
    "src/crosschain-liquidity/socket/SocketValidator.sol"
    "src/SuperformFactory.sol"
    "src/SuperformRouter.sol"
    "src/crosschain-data/adapters/wormhole/automatic-relayer/WormholeARImplementation.sol"
    "src/SuperPositions.sol"
    "src/settings/SuperRegistry.sol"
    "src/settings/SuperRBAC.sol"
    "src/VaultClaimer.sol"
    "src/crosschain-data/BroadcastRegistry.sol"
    "src/crosschain-data/adapters/wormhole/specialized-relayer/WormholeSRImplementation.sol"
    # Add more file names here if needed
)

contract_names=(
    "CoreStateRegistry"
    "DstSwapper"
    "ERC4626Form"
    "EmergencyQueue"
    "HyperlaneImplementation"
    "LayerzeroImplementation"
    "LiFiValidator"
    "PayMaster"
    "PayloadHelper"
    "PaymentHelper"
    "SocketValidator"
    "SuperformFactory"
    "SuperformRouter"
    "WormholeARImplementation"
    "SuperPositions"
    "SuperRegistry"
    "SuperRBAC"
    "VaultClaimer"
    "BroadcastRegistry"
    "WormholeSRImplementation"
    # Add more contract names here if needed
)

contract_addresses=(
    0x80AAb0eA1243817E22D6ad76ebe06385900e906d
    0xAACA228C3fca21c41C4Ea82EBb2d8843bd830B3b
    0xB2f32B62B7537304b830dE6575Fe73c41ea52991
    0x7FE59421D6b85afa86d982E3186a74c72f6c4c03
    0x207BFE0Fb040F17cC61B67e4aaDfC59C9e170671
    0x1863862794cD8ec60daBF8B473fcA928B78cE563
    0x1921E55E07A049DE0a3853b4A34235E37e4F3425
    0x36560c6790FaEb44BEdA2606e6aC50f08fdF0c94
    0x5Ae08549F266a9B4cC95Ad8aac57bE6Af236b647
    0xfbdCa870c9878d71e6a3A0a312220De153404eA2
    0x71060c588Aa01e61253EE4ac231Ac1a2bC672Bb8
    0x9CA4480B65E5F3d57cFb942ac44A0A6Ab0B2C843
    0x21b69aC55e3B620aCF74b4362D34d5E51a8187b8
    0x3b6FABE94a5d0B160e2E1519495e7Fe9dD009Ea3
    0x9AB6Dd8c4FC98F859a3271db98B81777aC2893b0
    0xB2C097ac459aFAc892ae5b35f6bd6a9Dd3071F47
    0x9736b60c4f749232d400B5605f21AE137a5Ebb71
    0xf1930eD240cF9c4F1840aDB689E5d231687922C5
    0x5767897fc69A77AC68a75001a56fcA6c421adc6f
    0x44b451Ca87267a62A0C853ECFbaaC1C3E528a82C
    # Add more addresses here if needed
)

constructor_args=(
    $super_constructor_arg
    $super_constructor_arg
    $super_constructor_arg
    $super_constructor_arg
    $super_constructor_arg
    $super_constructor_arg
    $super_constructor_arg
    $super_constructor_arg
    $super_constructor_arg
    $super_constructor_arg
    $super_constructor_arg
    $super_constructor_arg
    $super_constructor_arg
    $super_constructor_arg
    $superposition_constructor_arg
    $superregistry_constructor_arg
    $super_rbac_arg
    $empty_constructor_arg
    $super_constructor_arg
    $wormhole_sr_arg
)

# loop through networks
for i in "${!networks[@]}"; do
    network="${networks[$i]}"
    api_key="${api_keys[$i]}"

    # loop through file_names and contract_names
    for j in "${!file_names[@]}"; do
        file_name="${file_names[$j]}"
        contract_name="${contract_names[$j]}"
        contract_address="${contract_addresses[$j]}"
        constructor_arg="${constructor_args[$j]}"

        # verify the contract
        if [[ $network == 43114 ]]; then
            forge verify-contract $contract_address \
                --chain-id $network \
                --num-of-optimizations 200 \
                --watch --compiler-version v0.8.23+commit.f704f362 \
                --constructor-args "$constructor_arg" \
                "$file_name:$contract_name" \
                --etherscan-api-key "$api_key" \
                --verifier-url 'https://api.routescan.io/v2/network/mainnet/evm/43114/etherscan'
        else
            forge verify-contract $contract_address \
                --chain-id $network \
                --num-of-optimizations 200 \
                --watch --compiler-version v0.8.23+commit.f704f362 \
                --constructor-args "$constructor_arg" \
                "$file_name:$contract_name" \
                --etherscan-api-key "$api_key"
        fi
    done
done
