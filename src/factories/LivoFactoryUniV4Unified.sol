// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AntiSniperConfigs} from "src/tokens/SniperProtection.sol";
import {TaxConfigInit} from "src/interfaces/ILivoTaxableToken.sol";
import {LivoFactoryAbstract} from "src/factories/LivoFactoryAbstract.sol";

/// @notice Unified factory for the Uniswap V4 token family. Dispatches between four token
///         implementations based on whether `TaxConfigInit` and `AntiSniperConfigs` are
///         configured.
///
///         Replaces `LivoFactoryUniV4`, `LivoFactoryTaxToken`, `LivoFactoryUniV4SniperProtected`,
///         and `LivoFactoryTaxTokenSniperProtected`.
contract LivoFactoryUniV4Unified is LivoFactoryAbstract {
    /// @notice V4-specific config bundle for the struct-based `createToken` overload.
    /// @dev `lpFeeBps` selects which graduator (and thus which `LivoSwapHook` instance) the token
    ///      will use. Today only two values are accepted: `100` (routes to `GRADUATOR`) and `50`
    ///      (routes to `GRADUATOR_0P5`). The fee itself is still hardcoded in each hook's bytecode;
    ///      this field is the dispatch key, not a free-form bps value. `_validateUniv4Configs`
    ///      enforces the allowlist so misconfiguration is loud.
    struct UniV4Configs {
        bool renounceOwnership;
        uint16 lpFeeBps;
    }

    /// @notice Graduator paired with the 50-bps `LivoSwapHook` variant. The 100-bps graduator lives
    ///         in the abstract base as `GRADUATOR`.
    address public immutable GRADUATOR_0P5;

    /// @notice Treasury share of the V4 pre-graduation LP fee (bps): 60 treasury / 40 creator.
    uint16 internal constant V4_LAUNCHPAD_TREASURY_SHARE_BPS = 6_000;

    error InvalidLpFeeBps();

    constructor(
        address launchpad,
        address tokenImplBase,
        address tokenImplAntiSniper,
        address tokenImplTax,
        address tokenImplTaxAntiSniper,
        address bondingCurve,
        address graduator,
        address graduator0p5,
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
    {
        GRADUATOR_0P5 = graduator0p5;
    }

    /////////////////////// EXTERNAL FUNCTIONS /////////////////////////

    // V4-only event-emission rule: any event whose presence is meant to signal "this is a V4 token"
    // (today: `LpFeeBpsSet`) MUST be emitted here in the V4 factory overloads, never inside the
    // shared `_createToken` umbrella in `LivoFactoryAbstract`. The umbrella runs for V2 deploys
    // too, so emitting V4-only events from there would leak them onto V2 tokens and break indexers
    // that use the event as a V4 marker. When adding a new V4-only event, follow this same pattern
    // (emit after `_createToken(...)` returns, in both overloads below).

    /// @notice Deploys a V4-family Livo token and registers it in the launchpad.
    ///         Dispatches between four implementations based on `taxCfg` and `antiSniperCfg`.
    ///         The per-token fee config is registered with the master fee handler at deploy time.
    ///         If `msg.value > 0`, buys supply and distributes it across `supplyShares`.
    /// @dev DEPRECATED: legacy positional overload, kept for backwards compatibility. New
    ///      integrations should use the struct-based overload that takes `creatorVaults`.
    ///      Always deploys with the 100-bps graduator/hook pair and no creator vaults.
    function createToken(
        string calldata name,
        string calldata symbol,
        bytes32 salt,
        FeeShare[] calldata feeReceivers,
        SupplyShare[] calldata supplyShares,
        bool renounceOwnership_,
        TaxConfigInit calldata taxCfg,
        AntiSniperConfigs calldata antiSniperCfg
    ) external payable returns (address token) {
        // Positional overload always uses the 100-bps graduator/hook pair — only the struct-based
        // overload below exposes the 50-bps variant. See the "V4-only event-emission rule" comment
        // above for why the emit lives here.
        _validateTotalFee(100, taxCfg);
        TokenSetup memory tokenSetup = TokenSetup({name: name, symbol: symbol, salt: salt, feeShares: feeReceivers});
        address tokenOwner = renounceOwnership_ ? address(0) : msg.sender;
        token = _createToken(
            tokenSetup, tokenOwner, address(GRADUATOR), supplyShares, taxCfg, antiSniperCfg, new CreatorVault[](0)
        );
        emit LpFeeBpsSet(token, 100);
    }

    /// @notice Struct-based overload without creator vaults. `univ4Configs.lpFeeBps` selects which
    ///         graduator/hook pair to use (100 or 50).
    /// @dev DEPRECATED: kept for backwards compatibility. New integrations should use the
    ///      struct-based overload that takes `creatorVaults`. Always deploys with no creator vaults.
    function createToken(
        TokenSetup calldata tokenSetup,
        TaxConfigInit calldata taxConfigs,
        UniV4Configs calldata univ4Configs,
        SupplyShare[] calldata buyOnDeployShares,
        AntiSniperConfigs calldata antiSniperConfigs
    ) external payable returns (address token) {
        _validateUniv4Configs(univ4Configs);
        _validateTotalFee(univ4Configs.lpFeeBps, taxConfigs);
        address tokenOwner = univ4Configs.renounceOwnership ? address(0) : msg.sender;
        address graduator = _resolveGraduator(univ4Configs.lpFeeBps);
        token = _createToken(
            tokenSetup, tokenOwner, graduator, buyOnDeployShares, taxConfigs, antiSniperConfigs, new CreatorVault[](0)
        );
        emit LpFeeBpsSet(token, univ4Configs.lpFeeBps);
    }

    /// @notice Struct-based overload. Equivalent to the deprecated struct-based overload above, plus
    ///         the `creatorVaults` array (pass empty for none). `univ4Configs.lpFeeBps` selects which
    ///         graduator/hook pair to use (100 or 50). This is the current recommended overload.
    function createToken(
        TokenSetup calldata tokenSetup,
        TaxConfigInit calldata taxConfigs,
        UniV4Configs calldata univ4Configs,
        SupplyShare[] calldata buyOnDeployShares,
        AntiSniperConfigs calldata antiSniperConfigs,
        CreatorVault[] calldata creatorVaults
    ) external payable returns (address token) {
        _validateUniv4Configs(univ4Configs);
        _validateTotalFee(univ4Configs.lpFeeBps, taxConfigs);
        address tokenOwner = univ4Configs.renounceOwnership ? address(0) : msg.sender;
        address graduator = _resolveGraduator(univ4Configs.lpFeeBps);
        token = _createToken(
            tokenSetup, tokenOwner, graduator, buyOnDeployShares, taxConfigs, antiSniperConfigs, creatorVaults
        );
        emit LpFeeBpsSet(token, univ4Configs.lpFeeBps);
    }

    ///////////////////////// INTERNAL FUNCTIONS /////////////////////////

    /// @dev V4-specific config validation. `lpFeeBps` is the dispatch key for graduator/hook
    ///      selection — only the values matching a deployed hook variant are accepted, so a typo
    ///      reverts instead of silently routing to the wrong graduator. Add further V4-only
    ///      invariants here as the struct grows.
    function _validateUniv4Configs(UniV4Configs calldata configs) internal pure {
        require(configs.lpFeeBps == 100 || configs.lpFeeBps == 50, InvalidLpFeeBps());
    }

    /// @dev Maps `lpFeeBps` to the graduator that pairs with the matching `LivoSwapHook` variant.
    ///      Callers MUST pre-validate `lpFeeBps` via `_validateUniv4Configs`; this function trusts
    ///      its input and treats anything other than 100 as the 50-bps branch.
    function _resolveGraduator(uint16 lpFeeBps) internal view returns (address) {
        return lpFeeBps == 100 ? address(GRADUATOR) : GRADUATOR_0P5;
    }

    /// @dev Pre-graduation launchpad LP fee = the token's post-graduation hook fee. Inverse of
    ///      `_resolveGraduator`: the 100-bps graduator (`GRADUATOR`) → 100 bps, the 50-bps graduator
    ///      (`GRADUATOR_0P5`) → 50 bps. Keep in sync if a new graduator/hook fee variant is added.
    function _launchpadLpFeeBps(address graduator) internal view override returns (uint16) {
        return graduator == address(GRADUATOR) ? uint16(100) : uint16(50);
    }

    /// @inheritdoc LivoFactoryAbstract
    function _launchpadTreasuryShareBps() internal pure override returns (uint16) {
        return V4_LAUNCHPAD_TREASURY_SHARE_BPS;
    }

    /// @notice Returns which token implementation `createToken(...)` would clone for the given inputs.
    /// @dev Mirrors the dispatch-relevant `createToken` inputs minus the identity fields (`name`,
    ///      `symbol`, `salt`) and ownership flag so the ABI stays stable when future features change
    ///      which inputs participate in dispatch. Today only `taxCfg.taxDurationSeconds` and
    ///      `antiSniperCfg.protectionWindowSeconds` matter for dispatch; disabled configs must
    ///      have all other tax/anti-sniper fields
    ///      empty/zero. Used by frontends to compute the initcode hash before mining a salt.
    function previewTokenImplementation(
        FeeShare[] calldata, /* feeReceivers */
        SupplyShare[] calldata, /* supplyShares */
        TaxConfigInit calldata taxCfg,
        AntiSniperConfigs calldata antiSniperCfg
    ) external view returns (address) {
        _validateAntiSniperConfig(antiSniperCfg);
        _validateTaxConfig(taxCfg);
        return _previewTokenImplementation(taxCfg, antiSniperCfg);
    }

    /// @notice Quotes the ETH (msg.value) needed to receive ~`tokenAmount` tokens via the deployer buy.
    ///         Pass the same `taxCfg` and `univ4Configs` you'll pass to `createToken`; the buy fee is
    ///         derived from them (the chosen hook LP fee plus the buy tax) so the frontend doesn't
    ///         recompute it.
    /// @param tokenAmount Amount of tokens to receive
    /// @param totalLockedInVaultsBps Sum of `supplyBps` across the creator vaults (0 for none); selects
    ///        the same curve `createToken` uses. See `_quoteBuyOnDeploy`.
    /// @param taxCfg The tax config the token will be created with; only `buyTaxBps` affects the buy.
    /// @param univ4Configs The V4 config the token will be created with; `lpFeeBps` is the pre- and
    ///        post-graduation LP fee. Validated here so the fee is one of the supported hook variants.
    /// @return totalEthNeeded The msg.value to pass to createToken
    function quoteBuyOnDeploy(
        uint256 tokenAmount,
        uint256 totalLockedInVaultsBps,
        TaxConfigInit calldata taxCfg,
        UniV4Configs calldata univ4Configs
    ) external view returns (uint256 totalEthNeeded) {
        _validateUniv4Configs(univ4Configs);
        return _quoteBuyOnDeploy(tokenAmount, totalLockedInVaultsBps, uint256(univ4Configs.lpFeeBps) + taxCfg.buyTaxBps);
    }
}
