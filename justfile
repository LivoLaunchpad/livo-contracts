##################### BUILD ################################
build:
    forge build

lint:
    forge lint src/

compile:
    forge fmt
    forge lint src/
    forge build
    just abis

# copies abis from out/ to abis/ for easier access in frontend
abis:
    @mkdir -p abis
    @jq '.abi' out/LivoLaunchpad.sol/LivoLaunchpad.json > abis/LivoLaunchpad.json
    @jq '.abi' out/ILivoToken.sol/ILivoToken.json > abis/ILivoToken.json
    @jq '.abi' out/ILivoClaims.sol/ILivoClaims.json > abis/ILivoClaims.json
    @jq '.abi' out/LivoFactoryBase.sol/LivoFactoryBase.json > abis/LivoFactoryBase.json
    @jq '.abi' out/LivoFactoryUniV2.sol/LivoFactoryUniV2.json > abis/LivoFactoryUniV2.json
    @jq '.abi' out/LivoFactoryTaxToken.sol/LivoFactoryTaxToken.json > abis/LivoFactoryTaxToken.json
    @jq '.abi' out/ILivoFeeSplitter.sol/ILivoFeeSplitter.json > abis/ILivoFeeSplitter.json
    @echo "✔ ABIs copied to abis/ directory"
    

##################### TESTING ################################
fast-test:
    forge test --no-match-contract Invariants

gas-report:
    forge test --no-match-contract Invariants --gas-report

test-curves:
    forge test --match-contract Curve

invariant-tests:
    forge test --match-contract Invariants

# Runs a super fast version of invariants for CI.(not so reliable at all) (runs=1, depth=5)
lean-invariants:
    sed -i 's/runs = [0-9]*/runs = 1/' foundry.toml
    sed -i 's/depth = [0-9]*/depth = 5/' foundry.toml
    forge test --match-contract Invariants

##################### INSPECTION ####################
error-inspection errorhex:
    forge inspect LivoLaunchpad errors | grep {{errorhex}}

taxtokenaddresses:
    sed -i 's#import {DeploymentAddressesMainnet as DeploymentAddresses} from "src/config/DeploymentAddresses.sol";#import {DeploymentAddressesSepolia as DeploymentAddresses} from "src/config/DeploymentAddresses.sol";#' src/tokens/LivoTaxableTokenUniV4.sol

# Prints a valid salt (produces a token address ending in 0x1110) for the given factory.
# Usage: just next-salt <factoryAddress>
next-salt factory:
    #!/usr/bin/env bash
    set -euo pipefail
    IMPL=$(cast call --rpc-url $SEPOLIA_RPC_URL {{factory}} "TOKEN_IMPLEMENTATION()(address)")
    INIT_CODE="0x3d602d80600a3d3981f3363d3d373d3d3d363d73${IMPL:2}5af43d82803e903d91602b57fd5bf3"
    cast create2 --ends-with 1110 --deployer {{factory}} --init-code "$INIT_CODE" \
        | awk '/^Salt:/ {print $2}'

##################### Deployed addresses (sepolia) #######################
launchpad := "0xd9f8bbe437a3423b725c6616C1B543775ecf1110"

bondingCurve := "0x1A7f2E2e4bdB14Dd75b6ce60ce7a6Ff7E0a3F3A5"
graduatorV2 := "0x7131c8141cd356dF22a9d30B292DB3f64B281AA5"
graduatorV4 := "0xc304593F9297f4f67E07cc7cAf3128F9027A2A3d"

factoryV2 := "0xB9f6A65AcA320e9Bca352620C4c75040B92DaC10"
factoryV4 := "0xE6A46F0c681F7F67b349C77Ff2329dB4F016691E"
factoryTaxToken := "0x124972595Af23c2FbEE4b77a24ceF8d6af800016"
hookAddress := "0x0591a87D3a56797812C4DA164C1B005c545400Cc"

# ##################### Create tokens #######################

# sharehonlder1 = 0x26fFa73c8fFcB8F4BF55d5A11a57c6bfEA7F4495
# sharehonlder2 = 0x643e37aCbbbc8e6e2b548C3eA150fDf9BAB8C27f
# tiswallet1 = 0xd6fa895fABA3FE48410e9A00504BB556C89dd2E6
# tiswallet2 = 0xdbB91f98C5826C89CC2312AD0B5a377a77613884

deploy-sepolia: taxtokenaddresses
    # Hook address is logged in deployment output (LivoSwapHook row)
    forge script Deployments --rpc-url sepolia --verify --account livo.dev --slow --broadcast

create-token-v2 tokenName value="0":
    SALT=$(just next-salt {{factoryV2}}) && echo "Using salt: $SALT" && \
        cast send --rpc-url $SEPOLIA_RPC_URL --account livo.dev {{factoryV2}} \
            "createToken(string,string,bytes32)" \
            {{tokenName}} {{uppercase(tokenName)}} "$SALT" --value {{value}}

create-token-v4 tokenName value="0":
    SALT=$(just next-salt {{factoryV4}}) && echo "Using salt: $SALT" && \
        cast send --rpc-url $SEPOLIA_RPC_URL --account livo.dev {{factoryV4}} \
            "createToken(string,string,address,bytes32)" \
            {{tokenName}} {{uppercase(tokenName)}} 0xBa489180Ea6EEB25cA65f123a46F3115F388f181 "$SALT" --value {{value}}

create-tax-token tokenName value="0":
    SALT=$(just next-salt {{factoryTaxToken}}) && echo "Using salt: $SALT" && \
        cast send --rpc-url $SEPOLIA_RPC_URL --account livo.dev {{factoryTaxToken}} \
            "createToken(string,string,address,bytes32,uint16,uint16,uint32)" \
            {{tokenName}} {{uppercase(tokenName)}} 0xBa489180Ea6EEB25cA65f123a46F3115F388f181 "$SALT" 300 500 1209600 --value {{value}}

create-token-v4-feesplit tokenName value="0":
    SALT=$(just next-salt {{factoryV4}}) && echo "Using salt: $SALT" && \
        cast send --rpc-url $SEPOLIA_RPC_URL --account livo.dev {{factoryV4}} \
            "createTokenWithFeeSplit(string,string,address[],uint256[],bytes32)" \
            {{tokenName}} {{uppercase(tokenName)}} \
            "[0x26fFa73c8fFcB8F4BF55d5A11a57c6bfEA7F4495,0x643e37aCbbbc8e6e2b548C3eA150fDf9BAB8C27f]" \
            "[3000,7000]" "$SALT" --value {{value}}

create-tax-token-feesplit tokenName value="0":
    SALT=$(just next-salt {{factoryTaxToken}}) && echo "Using salt: $SALT" && \
        cast send --rpc-url $SEPOLIA_RPC_URL --account livo.dev {{factoryTaxToken}} \
            "createTokenWithFeeSplit(string,string,address[],uint256[],bytes32,uint16,uint16,uint32)" \
            {{tokenName}} {{uppercase(tokenName)}} \
            "[0x26fFa73c8fFcB8F4BF55d5A11a57c6bfEA7F4495,0x643e37aCbbbc8e6e2b548C3eA150fDf9BAB8C27f]" \
            "[3000,7000]" "$SALT" 300 500 1209600 --value {{value}}

####################### Buys / sells #################################

buy tokenAddress value:
    cast send --rpc-url $SEPOLIA_RPC_URL --account livo.dev {{launchpad}} "buyTokensWithExactEth(address,uint256,uint256)" {{tokenAddress}} 1 175542935100 --value {{value}}

sell tokenAddress amount:
    cast send --rpc-url $SEPOLIA_RPC_URL --account livo.dev {{launchpad}} "sellExactTokens(address,uint256,uint256,uint256)" {{tokenAddress}} {{amount}} 1 340282366920938463463374607431768211455

v2buy tokenAddress value:
    TOKEN_ADDRESS={{tokenAddress}} IS_BUY=true AMOUNT_IN={{value}} forge script UniswapV2Swaps --rpc-url $SEPOLIA_RPC_URL --account livo.dev --slow --broadcast

v2sell tokenAddress amount:
    TOKEN_ADDRESS={{tokenAddress}} IS_BUY=false AMOUNT_IN={{amount}} forge script UniswapV2Swaps --rpc-url $SEPOLIA_RPC_URL --account livo.dev --slow --broadcast

##########################################################

v4approve tokenAddress:
    TOKEN_ADDRESS={{tokenAddress}} ACTION=0 HOOK_ADDRESS={{hookAddress}} forge script UniswapV4Swaps --rpc-url $SEPOLIA_RPC_URL --account livo.dev --slow --broadcast

v4buy tokenAddress value:
    TOKEN_ADDRESS={{tokenAddress}} ACTION=1 AMOUNT_IN={{value}} HOOK_ADDRESS={{hookAddress}} forge script UniswapV4Swaps --rpc-url $SEPOLIA_RPC_URL --account livo.dev --slow --broadcast

v4sell tokenAddress amount:
    TOKEN_ADDRESS={{tokenAddress}} ACTION=2 AMOUNT_IN={{amount}} HOOK_ADDRESS={{hookAddress}} forge script UniswapV4Swaps --rpc-url $SEPOLIA_RPC_URL --account livo.dev --slow --broadcast

##########################################################

collectFees:
    cast send --rpc-url $SEPOLIA_RPC_URL --account livo.dev {{graduatorV4}} "treasuryClaim()"


##########################################################

# forge verify-contract {{address}} {{contractName}} --compiler-version 0.8.28+commit.7893614a --chain-id 11155111 --watch --constructor-args $(cast abi-encode "constructor(address,address,address,address,address,address)" 0xd8861EBe9Ee353c4Dcaed86C7B90d354f064cc8D 0x812Cc2479174d1BA07Bb8788A09C6fe6dCD20e33 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543 0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4 0x000000000022D473030F116dDEE9F6B43aC78BA3 0x5bc9F6260a93f6FE2c16cF536B6479fc188e00C4)
