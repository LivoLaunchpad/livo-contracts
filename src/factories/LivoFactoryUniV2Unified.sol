// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LivoToken} from "src/tokens/LivoToken.sol";
import {LivoTokenSniperProtected} from "src/tokens/LivoTokenSniperProtected.sol";
import {AntiSniperConfigs} from "src/tokens/SniperProtection.sol";

import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {LivoFactoryAbstract} from "src/factories/LivoFactoryAbstract.sol";

/// @notice Unified factory for the Uniswap V2 token family. Dispatches between two token
///         implementations based on whether `AntiSniperConfigs` is configured. Ownership is
///         always renounced at creation (`tokenOwner == address(0)`) — V2 tokens have no
///         `setFeeReceiver` path, so the fee receiver is permanent.
///
///         Replaces `LivoFactoryUniV2` and `LivoFactoryUniV2SniperProtected`.
contract LivoFactoryUniV2Unified is LivoFactoryAbstract {
    /// @notice Token implementation cloned when no anti-sniper protection is requested.
    address public immutable TOKEN_IMPL_BASE;
    /// @notice Token implementation cloned when anti-sniper protection is requested.
    address public immutable TOKEN_IMPL_ANTISNIPER;

    constructor(
        address launchpad,
        address tokenImplBase,
        address tokenImplAntiSniper,
        address bondingCurve,
        address graduator,
        address masterFeeHandler
    ) LivoFactoryAbstract(launchpad, bondingCurve, graduator, masterFeeHandler) {
        TOKEN_IMPL_BASE = tokenImplBase;
        TOKEN_IMPL_ANTISNIPER = tokenImplAntiSniper;
    }

    /////////////////////// EXTERNAL FUNCTIONS /////////////////////////

    /// @notice Deploys a V2-family Livo token with ownership renounced and registers it in the launchpad.
    ///         If `antiSniperCfg.protectionWindowSeconds != 0`, deploys the sniper-protected variant.
    ///         If `feeReceivers.length >= 2`, also deploys a `FeeSplitter` as the fee receiver.
    ///         If `msg.value > 0`, buys supply and distributes it across `supplyShares`.
    function createToken(
        string calldata name,
        string calldata symbol,
        bytes32 salt,
        FeeShare[] calldata feeReceivers,
        SupplyShare[] calldata supplyShares,
        AntiSniperConfigs calldata antiSniperCfg
    ) external payable returns (address token) {
        _validateInputs(feeReceivers, supplyShares);
        token = _dispatchAndInitialize(name, symbol, salt, antiSniperCfg);
        LAUNCHPAD.launchToken(token, BONDING_CURVE);
        _finalizeCreation(token, feeReceivers, supplyShares);
    }

    /// @notice Returns which token implementation `createToken(...)` would clone for the given inputs.
    /// @dev Mirrors the full `createToken` input set minus the identity fields (`name`, `symbol`,
    ///      `salt`) so the ABI stays stable when future features change which inputs participate in
    ///      dispatch. Today only `antiSniperCfg.protectionWindowSeconds` matters; the other params
    ///      are ignored. Used by frontends to compute the initcode hash before mining a salt.
    function previewTokenImplementation(
        FeeShare[] calldata, /* feeReceivers */
        SupplyShare[] calldata, /* supplyShares */
        AntiSniperConfigs calldata antiSniperCfg
    ) external view returns (address) {
        return _isAntiSniperConfigured(antiSniperCfg) ? TOKEN_IMPL_ANTISNIPER : TOKEN_IMPL_BASE;
    }

    /////////////////////// INTERNAL FUNCTIONS /////////////////////////

    function _isAntiSniperConfigured(AntiSniperConfigs calldata a) internal pure returns (bool) {
        return a.protectionWindowSeconds != 0;
    }

    function _dispatchAndInitialize(
        string calldata name,
        string calldata symbol,
        bytes32 salt,
        AntiSniperConfigs calldata antiSniperCfg
    ) internal returns (address token) {
        bool antiSniper = _isAntiSniperConfigured(antiSniperCfg);
        address impl = antiSniper ? TOKEN_IMPL_ANTISNIPER : TOKEN_IMPL_BASE;

        ILivoToken.InitializeParams memory initParams;
        (token, initParams) = _cloneAndCreateToken(impl, name, symbol, salt, address(0));

        if (antiSniper) {
            LivoTokenSniperProtected(token).initialize(initParams, antiSniperCfg);
        } else {
            LivoToken(token).initialize(initParams);
        }
    }
}
