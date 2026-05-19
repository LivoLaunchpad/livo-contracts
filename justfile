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
    @jq '.abi' out/ILivoQuoter.sol/ILivoQuoter.json > abis/ILivoQuoter.json
    @jq '.abi' out/ILivoToken.sol/ILivoToken.json > abis/ILivoToken.json
    @jq '.abi' out/ILivoClaims.sol/ILivoClaims.json > abis/ILivoClaims.json
    @jq '.abi' out/LivoFactoryUniV2Unified.sol/LivoFactoryUniV2Unified.json > abis/LivoFactoryUniV2Unified.json
    @jq '.abi' out/LivoFactoryUniV4Unified.sol/LivoFactoryUniV4Unified.json > abis/LivoFactoryUniV4Unified.json
    @jq '.abi' out/ILivoTaxableToken.sol/ILivoTaxableToken.json > abis/ILivoTaxableToken.json
    @echo "✔ ABIs copied to abis/ directory"
    

##################### TESTING ################################
fast-test:
    forge test --no-match-contract Invariants --no-match-path "test/integration/**"

gas-report:
    forge test --no-match-contract Invariants --no-match-path "test/integration/**" --gas-report

test-curves:
    forge test --match-contract Curve

invariant-tests:
    forge test --match-contract Invariants

integration-tests:
    forge test --match-path "test/integration/**"

# Runs a super fast version of invariants for CI.(not so reliable at all) (runs=1, depth=5)
lean-invariants:
    sed -i 's/runs = [0-9]*/runs = 1/' foundry.toml
    sed -i 's/depth = [0-9]*/depth = 5/' foundry.toml
    forge test --match-contract Invariants

##################### INSPECTION ####################
error-inspection errorhex:
    forge inspect LivoLaunchpad errors | grep {{errorhex}}

taxtokenaddresses:
    sed -i 's#import {DeploymentAddressesMainnet as DeploymentAddresses} from "src/config/DeploymentAddresses.sol";#import {DeploymentAddressesSepolia as DeploymentAddresses} from "src/config/DeploymentAddresses.sol";#' src/tokens/LivoTaxableTokenUniV2.sol src/tokens/LivoTaxableTokenUniV4.sol

# Prints a valid salt (produces a token address ending in 0x1110) for the given factory + impl getter.
# Unified factories expose multiple impl getters (TOKEN_IMPL_BASE, TOKEN_IMPL_TAX, ...); pass the one
# matching the variant being deployed so the create2 initcode hash is correct.
# Usage: just next-salt <factoryAddress> <implGetterName>
next-salt factory implFn:
    #!/usr/bin/env bash
    set -euo pipefail
    IMPL=$(cast call --rpc-url $SEPOLIA_RPC_URL {{factory}} "{{implFn}}()(address)")
    INIT_CODE="0x3d602d80600a3d3981f3363d3d373d3d3d363d73${IMPL:2}5af43d82803e903d91602b57fd5bf3"
    cast create2 --ends-with 1110 --deployer {{factory}} --init-code "$INIT_CODE" \
        | awk '/^Salt:/ {print $2}'

# Same as next-salt but skips the factory getter lookup — pass the impl address directly.
# Useful when the factory does not expose the getter you need, or when you already know the impl.
# Usage: just next-salt-impl <factoryAddress> <implAddress>
next-salt-impl factory impl:
    #!/usr/bin/env bash
    set -euo pipefail
    IMPL="{{impl}}"
    IMPL="${IMPL#0x}"
    INIT_CODE="0x3d602d80600a3d3981f3363d3d373d3d3d363d73${IMPL}5af43d82803e903d91602b57fd5bf3"
    cast create2 --ends-with 1110 --deployer {{factory}} --init-code "$INIT_CODE" \
        | awk '/^Salt:/ {print $2}'

##################### Deployed addresses (sepolia) #######################
launchpad := "0xd9f8bbe437a3423b725c6616C1B543775ecf1110"

bondingCurve := "0x1A7f2E2e4bdB14Dd75b6ce60ce7a6Ff7E0a3F3A5"
graduatorV2 := "0x1c10331F153cD344Feb030Aad7A11E2119F6f59A"
graduatorV4 := "0xc304593F9297f4f67E07cc7cAf3128F9027A2A3d"

# Unified factories — each dispatches between base / tax / sniper-protected / tax+sniper impls
# based on the configs passed to createToken. See deployments.sepolia.sol for the source of truth.
factoryV2 := "0x87Dd69F8d294fA9cd704fccd38d36d6197F80868"
factoryV4 := "0x2a992f6f5F7c049A165a13069BE3DbDEaa5C391b"
hookAddress := "0x0591a87D3a56797812C4DA164C1B005c545400Cc"

livodev := "0xBa489180Ea6EEB25cA65f123a46F3115F388f181"

# ##################### Create tokens #######################
#
# Unified factory `createToken` signatures:
#   V2: (string,string,bytes32,FeeShare[],SupplyShare[],TaxConfigInit,AntiSniperConfigs)
#   V4: (string,string,bytes32,FeeShare[],SupplyShare[],bool renounceOwnership_,TaxConfigInit,AntiSniperConfigs)
#
# Canonical ABI tuples:
#   FeeShare           = (address,uint256,bool)            — account, sharesBps, directFeesEnabled (sum bps == 10_000)
#   SupplyShare        = (address,uint256)                 — account, sharesBps (empty when no deployer buy)
#   TaxConfigInit      = (uint16,uint16,uint32)            — buyTaxBps, sellTaxBps, taxDurationSeconds  ((0,0,0) disables)
#   AntiSniperConfigs  = (uint16,uint16,uint40,address[])  — maxBuyPerTxBps, maxWalletBps, protectionWindowSeconds, whitelist  ((0,0,0,[]) disables)
#
# Test wallets:
#   tiswallet1 = 0xd6fa895fABA3FE48410e9A00504BB556C89dd2E6
#   tiswallet2 = 0xdbB91f98C5826C89CC2312AD0B5a377a77613884

deploy-sepolia: taxtokenaddresses
    # Hook address is logged in deployment output (LivoSwapHook row)
    forge script Deployments --rpc-url sepolia --verify --account livo.dev --slow --broadcast

# Re-deploys the four token implementations and all six factories (V2/V4/TaxToken + sniper-protected
# variants) against the existing Livo core, then whitelists them on the launchpad.
deploy-sepolia-factories: taxtokenaddresses
    forge script DeploymentsFactories --rpc-url sepolia --verify --account livo.dev --slow --broadcast

deploy-mainnet-factories:
    forge script DeploymentsFactories --rpc-url mainnet --verify --account livo.dev --slow --broadcast

# Mines a valid hook salt and deploys LivoSwapHook (50 bps LP fee build).
# After broadcast, paste the deployed address into src/config/deployments.{sepolia,mainnet}.sol
# and run `just export-deployments`.
deploy-swap-hook-sepolia:
    forge script DeployLivoSwapHook --rpc-url sepolia --verify --account livo.dev --slow --broadcast

deploy-swap-hook-mainnet:
    forge script DeployLivoSwapHook --rpc-url mainnet --verify --account livo.dev --slow --broadcast

# Regenerates deployments.{mainnet,sepolia}.md from the matching .sol manifests.
# CI runs the same command and fails if the result is not committed.
export-deployments:
    forge script ExportDeployments

# Plain V2 token: no tax, no sniper protection. Single fee receiver (livodev), no deployer buy.
univ2 tokenName value="0":
    SALT=$(just next-salt {{factoryV2}} TOKEN_IMPL_BASE) && echo "Using salt: $SALT" && \
        cast send --rpc-url $SEPOLIA_RPC_URL --account livo.dev {{factoryV2}} \
            "createToken(string,string,bytes32,(address,uint256,bool)[],(address,uint256)[],(uint16,uint16,uint32),(uint16,uint16,uint40,address[]))" \
            {{tokenName}} {{uppercase(tokenName)}} "$SALT" \
            "[({{livodev}},10000,false)]" "[]" \
            "(0,0,0)" "(0,0,0,[])" --value {{value}}

# Plain V4 token: no tax, no sniper protection. Single fee receiver (livodev), no deployer buy. Ownership retained.
univ4 tokenName value="0":
    SALT=$(just next-salt {{factoryV4}} TOKEN_IMPL_BASE) && echo "Using salt: $SALT" && \
        cast send --rpc-url $SEPOLIA_RPC_URL --account livo.dev {{factoryV4}} \
            "createToken(string,string,bytes32,(address,uint256,bool)[],(address,uint256)[],bool,(uint16,uint16,uint32),(uint16,uint16,uint40,address[]))" \
            {{tokenName}} {{uppercase(tokenName)}} "$SALT" \
            "[({{livodev}},10000,false)]" "[]" false \
            "(0,0,0)" "(0,0,0,[])" --value {{value}}

# Taxable V2 token: tax enabled (buy=300, sell=500, duration=1209600 = 2 weeks), no sniper protection.
univ2-taxable tokenName value="0":
    SALT=$(just next-salt {{factoryV2}} TOKEN_IMPL_TAX) && echo "Using salt: $SALT" && \
        cast send --rpc-url $SEPOLIA_RPC_URL --account livo.dev {{factoryV2}} \
            "createToken(string,string,bytes32,(address,uint256,bool)[],(address,uint256)[],(uint16,uint16,uint32),(uint16,uint16,uint40,address[]))" \
            {{tokenName}} {{uppercase(tokenName)}} "$SALT" \
            "[({{livodev}},10000,false)]" "[]" \
            "(300,500,1209600)" "(0,0,0,[])" --value {{value}}

# Taxable V4 token: tax enabled (buy=300, sell=500, duration=1209600 = 2 weeks), no sniper protection. Ownership retained.
univ4-taxable tokenName value="0":
    SALT=$(just next-salt {{factoryV4}} TOKEN_IMPL_TAX) && echo "Using salt: $SALT" && \
        cast send --rpc-url $SEPOLIA_RPC_URL --account livo.dev {{factoryV4}} \
            "createToken(string,string,bytes32,(address,uint256,bool)[],(address,uint256)[],bool,(uint16,uint16,uint32),(uint16,uint16,uint40,address[]))" \
            {{tokenName}} {{uppercase(tokenName)}} "$SALT" \
            "[({{livodev}},10000,false)]" "[]" false \
            "(300,500,1209600)" "(0,0,0,[])" --value {{value}}

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
