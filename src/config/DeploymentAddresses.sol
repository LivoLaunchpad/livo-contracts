// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title Deployment Address Constants for Ethereum Mainnet
/// @notice Centralized constants for protocol infrastructure addresses on Ethereum Mainnet
/// @dev These addresses are network-specific and must be updated for other chains
library DeploymentAddressesEthereumMainnet {
    /// @notice Blockchain ID for Ethereum Mainnet
    uint256 public constant BLOCKCHAIN_ID = 1;

    /// @notice Uniswap V4 Pool Manager contract
    /// @dev Core contract managing all V4 pools and their lifecycle
    address public constant UNIV4_POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;

    /// @notice Uniswap V4 Position Manager contract
    /// @dev Manages liquidity positions for V4 pools
    address public constant UNIV4_POSITION_MANAGER = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;

    /// @notice Uniswap V4 Universal Router contract
    /// @dev Handles routing and execution of V4 swaps
    address public constant UNIV4_UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;

    /// @notice Permit2 contract
    /// @dev Token approval contract used across multiple protocols
    /// @dev Note: Permit2 may be deployed at the same address on multiple chains
    address public constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    /// @notice Wrapped Ether (WETH) token contract
    /// @dev Official WETH contract for Ethereum Mainnet
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    /// @notice Uniswap V2 Router contract
    /// @dev Handles routing and execution of V2 swaps
    address public constant UNIV2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;

    /// @notice Uniswap V2 Factory contract
    /// @dev Creates and manages V2 pair contracts
    address public constant UNIV2_FACTORY = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;

    /// @notice keccak256 of the UniswapV2Pair contract creation code used by UNIV2_FACTORY
    /// @dev Required by `LivoGraduatorUniswapV2` to predict the CREATE2 pair address without
    ///      deploying the pair upfront. Canonical stock UniswapV2 value.
    bytes32 public constant UNIV2_PAIR_INIT_CODE_HASH =
        0x96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f;

    /// @notice Dead address used for burning LP tokens
    /// @dev Standard burn address that works on all chains
    address public constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @notice Livo Treasury
    address public constant LIVO_TREASURY = 0x2F56CB340FeA590a2A801081118bF3143309329D;
}

/// @title Deployment Address Constants for Sepolia Testnet
/// @notice Centralized constants for protocol infrastructure addresses on Sepolia Testnet
library DeploymentAddressesEthereumSepolia {
    /// @notice Blockchain ID for Sepolia Testnet
    uint256 public constant BLOCKCHAIN_ID = 11155111;

    /// @notice Uniswap V4 Pool Manager contract
    address public constant UNIV4_POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;

    /// @notice Uniswap V4 Position Manager contract
    address public constant UNIV4_POSITION_MANAGER = 0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4;

    /// @notice Uniswap V4 Universal Router contract
    address public constant UNIV4_UNIVERSAL_ROUTER = 0x3A9D48AB9751398BbFa63ad67599Bb04e4BdF98b;

    /// @notice Permit2 contract
    address public constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    /// @notice Wrapped Ether (WETH) token contract
    address public constant WETH = 0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9; // this is WETH deployed by uniswap for uniswap tests

    /// @notice Uniswap V2 Router contract
    address public constant UNIV2_ROUTER = 0xC532a74256D3Db42D0Bf7a0400fEFDbad7694008;

    /// @notice Uniswap V2 Factory contract
    address public constant UNIV2_FACTORY = 0x7E0987E5b3a30e3f2828572Bb659A548460a3003;

    /// @notice keccak256 of the UniswapV2Pair contract creation code used by UNIV2_FACTORY
    /// @dev Required by `LivoGraduatorUniswapV2` to predict the CREATE2 pair address without
    ///      deploying the pair upfront. The Sepolia factory at `UNIV2_FACTORY` is NOT Uniswap's
    ///      canonical V2 deployment — it's a fork whose pair init code differs from mainnet, so
    ///      the hash here is different from the stock mainnet value. Derived empirically from the
    ///      CREATE2 input of a pair created by this factory; verified by predicting a known pair.
    bytes32 public constant UNIV2_PAIR_INIT_CODE_HASH =
        0x4156ccc01dad273e6c65c4335c428a2ff4a4b0c95a9a228f6bfed45a069d3fe7;

    /// @notice Dead address used for burning LP tokens
    /// @dev Standard burn address that works on all chains
    address public constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @notice Livo Treasury
    address public constant LIVO_TREASURY = 0xBa489180Ea6EEB25cA65f123a46F3115F388f181;
}

/// @title Deployment Address Constants for Robinhood Chain Mainnet (chain id 4663)
/// @notice Centralized constants for protocol infrastructure addresses on Robinhood Chain.
/// @dev Robinhood Chain is an Arbitrum L2 with native ETH. Uniswap V4 + V2 are officially
///      deployed (verified on-chain). The V2 factory uses the CANONICAL UniswapV2 pair init
///      code hash (verified by predicting an existing pair). Permit2 is at the canonical address.
library DeploymentAddressesRobinhoodMainnet {
    /// @notice Blockchain ID for Robinhood Chain Mainnet
    uint256 public constant BLOCKCHAIN_ID = 4663;

    /// @notice Uniswap V4 Pool Manager contract
    address public constant UNIV4_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;

    /// @notice Uniswap V4 Position Manager contract
    address public constant UNIV4_POSITION_MANAGER = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;

    /// @notice Uniswap V4 Universal Router contract
    address public constant UNIV4_UNIVERSAL_ROUTER = 0x8876789976dEcBfCbBbe364623C63652db8C0904;

    /// @notice Permit2 contract (canonical address)
    address public constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    /// @notice Wrapped Ether (WETH) token contract
    address public constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;

    /// @notice Uniswap V2 Router contract
    address public constant UNIV2_ROUTER = 0x89e5DB8B5aA49aA85AC63f691524311AEB649eba;

    /// @notice Uniswap V2 Factory contract
    address public constant UNIV2_FACTORY = 0x8bcEaA40B9AcdfAedF85AdF4FF01F5Ad6517937f;

    /// @notice keccak256 of the UniswapV2Pair contract creation code used by UNIV2_FACTORY
    /// @dev Robinhood's official V2 factory uses the CANONICAL UniswapV2 pair init code hash
    ///      (same as Ethereum mainnet). Verified by predicting an existing pair created by this
    ///      factory and matching `getPair()`.
    bytes32 public constant UNIV2_PAIR_INIT_CODE_HASH =
        0x96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f;

    /// @notice Dead address used for burning LP tokens
    address public constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @notice Livo Treasury. TEMPORARY: set to livo.dev — REPLACE with the real Robinhood treasury before production.
    address public constant LIVO_TREASURY = 0xBa489180Ea6EEB25cA65f123a46F3115F388f181;
}

/// @title Deployment Address Constants for Robinhood Chain Testnet (chain id 46630)
/// @notice Centralized constants for protocol infrastructure addresses on Robinhood Chain Testnet.
/// @dev Uniswap V4 + Permit2 are deployed; the V4 set below is the one whose PositionManager
///      reports this chain's canonical WETH. Uniswap V2 is NOT deployed on the testnet, so the V2
///      router/factory are zero — a from-scratch deploy must skip the V2 graduator + V2 factory here.
library DeploymentAddressesRobinhoodTestnet {
    /// @notice Blockchain ID for Robinhood Chain Testnet
    uint256 public constant BLOCKCHAIN_ID = 46630;

    /// @notice Uniswap V4 Pool Manager contract
    address public constant UNIV4_POOL_MANAGER = 0x552815eF68E6eb418A3d65D0AA1043d93204F612;

    /// @notice Uniswap V4 Position Manager contract
    address public constant UNIV4_POSITION_MANAGER = 0x00EB6902D1e3be1A8C667041f9E75b77B7Ad3ba6;

    /// @notice Uniswap V4 Universal Router contract
    address public constant UNIV4_UNIVERSAL_ROUTER = 0xE28c0e44F4016b073db20cF28971CAc6ce3664D3;

    /// @notice Permit2 contract (canonical address)
    address public constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    /// @notice Wrapped Ether (WETH) token contract
    address public constant WETH = 0x7943e237c7F95DA44E0301572D358911207852Fa;

    /// @notice Uniswap V2 Router — NOT deployed on Robinhood testnet (V2 graduation unavailable)
    address public constant UNIV2_ROUTER = address(0);

    /// @notice Uniswap V2 Factory — NOT deployed on Robinhood testnet (V2 graduation unavailable)
    address public constant UNIV2_FACTORY = address(0);

    /// @notice Placeholder (canonical) hash — unused while UNIV2_ROUTER/FACTORY are zero.
    bytes32 public constant UNIV2_PAIR_INIT_CODE_HASH =
        0x96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f;

    /// @notice Dead address used for burning LP tokens
    address public constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @notice Livo Treasury. TEMPORARY: set to livo.dev — REPLACE with the real Robinhood treasury before production.
    address public constant LIVO_TREASURY = 0xBa489180Ea6EEB25cA65f123a46F3115F388f181;
}
