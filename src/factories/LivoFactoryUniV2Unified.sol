// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AntiSniperConfigs} from "src/tokens/SniperProtection.sol";
import {TaxConfigInit} from "src/interfaces/ILivoTaxableToken.sol";
import {LivoFactoryAbstract} from "src/factories/LivoFactoryAbstract.sol";

/// @notice Unified factory for the Uniswap V2 token family. Dispatches between four token
///         implementations based on whether `TaxConfigInit` and `AntiSniperConfigs` are
///         configured.
///
///         Replaces `LivoFactoryUniV2` and `LivoFactoryUniV2SniperProtected`, and now also
///         covers the new tax variants (`LivoTaxableTokenUniV2`, `LivoTaxableTokenUniV2SniperProtected`).
///
///         Ownership rule: all V2-family tokens are deployed with `tokenOwner = address(0)`.
///         Tax cap: V2 has no post-graduation LP fee, so the per-direction tax can reach the full
///         `MAX_TOTAL_FEE_BPS` (5%). Pre-graduation the launchpad additionally charges
///         `V2_LAUNCHPAD_LP_FEE_BPS`, so a trader transiently pays up to 6% on the bonding curve —
///         bounded by the launchpad's own (looser) per-trade cap, not by `_validateTotalFee`.
contract LivoFactoryUniV2Unified is LivoFactoryAbstract {
    /// @notice Pre-graduation launchpad LP fee for V2 tokens (bps), charged on every bonding-curve
    ///         trade and split treasury/creator by `V2_LAUNCHPAD_TREASURY_SHARE_BPS`. It exists only
    ///         pre-graduation (V2 has no post-graduation LP fee) and does NOT count against the tax cap
    ///         (see `V2_POST_GRADUATION_LP_FEE_BPS`); the launchpad's own looser per-trade cap absorbs
    ///         it on top of the tax.
    uint16 internal constant V2_LAUNCHPAD_LP_FEE_BPS = 100;

    /// @notice Post-graduation LP fee for V2 tokens (bps): none. V2 graduates to Uniswap V2, which
    ///         carries no Livo LP fee, so the post-graduation fee a trader pays is the tax alone. This
    ///         is the LP fee `_validateTotalFee` caps against, letting the V2 tax reach the full
    ///         `MAX_TOTAL_FEE_BPS` (5%) regardless of the pre-graduation launchpad fee.
    uint16 internal constant V2_POST_GRADUATION_LP_FEE_BPS = 0;

    /// @notice Treasury share of the V2 pre-graduation LP fee (bps): 50/50 treasury/creator.
    uint16 internal constant V2_LAUNCHPAD_TREASURY_SHARE_BPS = 5_000;

    constructor(
        address launchpad,
        address tokenImplBase,
        address tokenImplAntiSniper,
        address tokenImplTax,
        address tokenImplTaxAntiSniper,
        address bondingCurve,
        address graduator,
        address masterFeeHandler,
        address creatorVaultFactory,
        address[6] memory vaultBondingCurves
    )
        LivoFactoryAbstract(
            launchpad,
            tokenImplBase,
            tokenImplAntiSniper,
            tokenImplTax,
            tokenImplTaxAntiSniper,
            bondingCurve,
            graduator,
            masterFeeHandler,
            creatorVaultFactory,
            vaultBondingCurves
        )
    {}

    /////////////////////// EXTERNAL FUNCTIONS /////////////////////////

    /// @notice Deploys a V2-family Livo token and registers it in the launchpad.
    ///         Dispatches between four implementations based on `taxCfg` and `antiSniperCfg`.
    ///         The per-token fee config is registered with the master fee handler at deploy time.
    ///         If `msg.value > 0`, buys supply and distributes it across `supplyShares`.
    /// @dev DEPRECATED: legacy positional overload, kept for backwards compatibility. New
    ///      integrations should use the struct-based overload that takes `creatorVaults`.
    ///      Always deploys with no creator vaults.
    function createToken(
        string calldata name,
        string calldata symbol,
        bytes32 salt,
        FeeShare[] calldata feeReceivers,
        SupplyShare[] calldata supplyShares,
        TaxConfigInit calldata taxCfg,
        AntiSniperConfigs calldata antiSniperCfg
    ) external payable returns (address token) {
        // V2-family tokens are always deployed ownerless. Routes through the shared `_createToken`
        // umbrella so this overload and the struct-based overload below share the same internal flow.
        // `LpFeeBpsSet` is emitted only by the V4 factory — V2 has no LP-fee concept.
        _validateTotalFee(V2_POST_GRADUATION_LP_FEE_BPS, taxCfg);
        TokenSetup memory tokenSetup = TokenSetup({name: name, symbol: symbol, salt: salt, feeShares: feeReceivers});
        token = _createToken(
            tokenSetup, address(0), address(GRADUATOR), supplyShares, taxCfg, antiSniperCfg, new CreatorVault[](0)
        );
    }

    /// @notice Struct-based overload taking a `creatorVaults` array (pass empty for none).
    ///         This is the current recommended overload.
    function createToken(
        TokenSetup calldata tokenSetup,
        TaxConfigInit calldata taxConfigs,
        SupplyShare[] calldata buyOnDeployShares,
        AntiSniperConfigs calldata antiSniperConfigs,
        CreatorVault[] calldata creatorVaults
    ) external payable returns (address token) {
        // V2-family tokens are always deployed ownerless; V2 never emits `LpFeeBpsSet`.
        _validateTotalFee(V2_POST_GRADUATION_LP_FEE_BPS, taxConfigs);
        token = _createToken(
            tokenSetup, address(0), address(GRADUATOR), buyOnDeployShares, taxConfigs, antiSniperConfigs, creatorVaults
        );
    }

    /// @notice Returns which token implementation `createToken(...)` would clone for the given inputs.
    /// @dev Mirrors the full `createToken` input set minus the identity fields (`name`, `symbol`,
    ///      `salt`) so the ABI stays stable when future features change which inputs participate in
    ///      dispatch. Today only `taxCfg.taxDurationSeconds` and `antiSniperCfg.protectionWindowSeconds`
    ///      matter for dispatch; disabled configs must have all other tax/anti-sniper fields
    ///      empty/zero. Used by frontends to compute the initcode hash before mining a salt.
    function previewTokenImplementation(
        FeeShare[] calldata, /* feeReceivers */
        SupplyShare[] calldata, /* supplyShares */
        TaxConfigInit calldata taxCfg,
        AntiSniperConfigs calldata antiSniperCfg
    ) external view returns (address) {
        _validateAntiSniperConfig(antiSniperCfg);
        _validateTaxConfig(taxCfg);
        _validateTotalFee(V2_POST_GRADUATION_LP_FEE_BPS, taxCfg);
        return _previewTokenImplementation(taxCfg, antiSniperCfg);
    }

    /// @notice Quotes the ETH (msg.value) needed to receive ~`tokenAmount` tokens via the deployer buy.
    ///         Pass the same `taxCfg` you'll pass to `createToken`; the buy fee is derived from it (the
    ///         fixed V2 pre-graduation LP fee plus the buy tax) so the frontend doesn't recompute it.
    /// @param tokenAmount Amount of tokens to receive
    /// @param totalLockedInVaultsBps Sum of `supplyBps` across the creator vaults (0 for none); selects
    ///        the same curve `createToken` uses. See `_quoteBuyOnDeploy`.
    /// @param taxCfg The tax config the token will be created with; only `buyTaxBps` affects the buy,
    ///        and only when the window is creation-anchored (`startTaxFromLaunch`) — a graduation-anchored
    ///        tax is not charged on the deploy buy (see `_deployBuyTaxBps`).
    /// @return totalEthNeeded The msg.value to pass to createToken
    function quoteBuyOnDeploy(uint256 tokenAmount, uint256 totalLockedInVaultsBps, TaxConfigInit calldata taxCfg)
        external
        view
        returns (uint256 totalEthNeeded)
    {
        return
            _quoteBuyOnDeploy(tokenAmount, totalLockedInVaultsBps, _deployBuyTaxBps(taxCfg) + V2_LAUNCHPAD_LP_FEE_BPS);
    }

    ///////////////////////// INTERNAL FUNCTIONS /////////////////////////

    /// @dev V2 has a single graduator and a fixed pre-graduation launchpad LP fee (no post-graduation
    ///      LP fee to mirror), so `graduator` is ignored.
    function _launchpadLpFeeBps(
        address /* graduator */
    )
        internal
        pure
        override
        returns (uint16)
    {
        return V2_LAUNCHPAD_LP_FEE_BPS;
    }

    /// @inheritdoc LivoFactoryAbstract
    function _launchpadTreasuryShareBps() internal pure override returns (uint16) {
        return V2_LAUNCHPAD_TREASURY_SHARE_BPS;
    }
}
