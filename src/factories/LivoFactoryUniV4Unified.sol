// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AntiSniperConfigs} from "src/tokens/SniperProtection.sol";
import {TaxConfigInit, TaxConfigs} from "src/interfaces/ILivoTaxableToken.sol";
import {LivoFactoryAbstract} from "src/factories/LivoFactoryAbstract.sol";
import {LiquidityTier} from "src/types/LiquidityTier.sol";

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

    /// @notice Constructor-only bundle of the SMALL/LARGE tier V4 graduators (one per tier x hook fee).
    ///         The DEFAULT-tier pair is `GRADUATOR` (100 bps, abstract) + `GRADUATOR_0P5` (50 bps).
    struct TierGraduators {
        address small; // 100 bps hook
        address small0p5; // 50 bps hook
        address large; // 100 bps hook
        address large0p5; // 50 bps hook
    }

    /// @notice Constructor-only bundle of all the V4 tier additions (curves + graduators), grouped into
    ///         one struct to keep the constructor's parameter count within the ABI-decode stack limit.
    struct V4TierConfig {
        LiquidityTierConfig curves;
        TierGraduators graduators;
    }

    /// @notice Graduator paired with the 50-bps `LivoSwapHook` variant. The 100-bps graduator lives
    ///         in the abstract base as `GRADUATOR`.
    address public immutable GRADUATOR_0P5;

    /// @notice SMALL/LARGE tier graduators, one per (tier x hook fee). Each initializes its pool at the
    ///         tier-specific graduation price. Selected by `_resolveGraduator(lpFeeBps, tier)`.
    address public immutable GRADUATOR_SMALL; // 100 bps hook
    address public immutable GRADUATOR_SMALL_0P5; // 50 bps hook
    address public immutable GRADUATOR_LARGE; // 100 bps hook
    address public immutable GRADUATOR_LARGE_0P5; // 50 bps hook

    /// @notice Pre-graduation launchpad LP fee for V4 tokens (bps), charged on every bonding-curve trade
    ///         and split treasury/creator by `V4_LAUNCHPAD_TREASURY_SHARE_BPS`. Fixed at 1% for every V4
    ///         token regardless of the post-graduation hook fee it selects (`UniV4Configs.lpFeeBps`, 50 or
    ///         100): the pre-graduation rate is a constant launchpad policy, decoupled from the LP fee the
    ///         hook charges after graduation.
    uint16 internal constant V4_LAUNCHPAD_LP_FEE_BPS = 100;

    /// @notice Treasury share of the V4 pre-graduation LP fee (bps): 60 treasury / 40 creator.
    uint16 internal constant V4_LAUNCHPAD_TREASURY_SHARE_BPS = 6_000;

    error InvalidLpFeeBps();

    constructor(
        address launchpad,
        TokenImpls memory impls,
        address bondingCurve,
        address graduator,
        address graduator0p5,
        address masterFeeHandler,
        address creatorVaultFactory,
        address[6] memory vaultBondingCurves,
        V4TierConfig memory v4Tier
    )
        LivoFactoryAbstract(
            launchpad,
            impls,
            bondingCurve,
            graduator,
            masterFeeHandler,
            creatorVaultFactory,
            vaultBondingCurves,
            v4Tier.curves
        )
    {
        GRADUATOR_0P5 = graduator0p5;
        GRADUATOR_SMALL = v4Tier.graduators.small;
        GRADUATOR_SMALL_0P5 = v4Tier.graduators.small0p5;
        GRADUATOR_LARGE = v4Tier.graduators.large;
        GRADUATOR_LARGE_0P5 = v4Tier.graduators.large0p5;
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
    /// @dev DEPRECATED: legacy positional overload, kept for backwards compatibility (unchanged
    ///      signature). New integrations should use the struct-based overload that takes `creatorVaults`
    ///      and the full `TaxConfigs`. Always deploys with the 100-bps graduator/hook pair, no creator
    ///      vaults and no launch-tax decay — the `TaxConfigInit` is lifted into a `TaxConfigs` with the
    ///      decay fields zeroed.
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
        // overloads below expose the 50-bps variant. See the "V4-only event-emission rule" comment
        // above for why the emit lives here.
        // Build `tokenSetup` first (consuming the deep `name`/`symbol`/`salt`/`feeReceivers` calldata
        // params) before introducing the `taxConfigs` memory local, to keep the stack shallow enough
        // to compile without `via_ir`.
        // Legacy overload always uses the DEFAULT liquidity tier + the 100-bps graduator.
        TokenSetup memory tokenSetup = TokenSetup({
            name: name, symbol: symbol, salt: salt, feeShares: feeReceivers, liquidityTier: LiquidityTier.DEFAULT
        });
        TaxConfigs memory taxConfigs = _toTaxConfigs(taxCfg);
        _validateTotalFee(100, taxConfigs);
        token = _createToken(
            tokenSetup,
            renounceOwnership_ ? address(0) : msg.sender,
            address(GRADUATOR),
            supplyShares,
            taxConfigs,
            antiSniperCfg,
            new CreatorVault[](0)
        );
        emit LpFeeBpsSet(token, 100);
    }

    /// @notice Struct-based overload taking a `creatorVaults` array (pass empty for none) and the legacy
    ///         `TaxConfigInit` (static tax only). `univ4Configs.lpFeeBps` selects which graduator/hook pair
    ///         to use (100 or 50).
    /// @dev Kept with an unchanged signature for backwards compatibility. For the launch-tax decay, use
    ///      the `TaxConfigs` overload below; this one lifts `TaxConfigInit` into a `TaxConfigs` with the
    ///      decay fields zeroed.
    function createToken(
        TokenSetup calldata tokenSetup,
        TaxConfigInit calldata taxConfigs,
        UniV4Configs calldata univ4Configs,
        SupplyShare[] calldata buyOnDeployShares,
        AntiSniperConfigs calldata antiSniperConfigs,
        CreatorVault[] calldata creatorVaults
    ) external payable returns (address token) {
        TaxConfigs memory fullTaxConfigs = _toTaxConfigs(taxConfigs);
        _validateUniv4Configs(univ4Configs);
        _validateTotalFee(univ4Configs.lpFeeBps, fullTaxConfigs);
        token = _createToken(
            tokenSetup,
            univ4Configs.renounceOwnership ? address(0) : msg.sender,
            _resolveGraduator(univ4Configs.lpFeeBps, tokenSetup.liquidityTier),
            buyOnDeployShares,
            fullTaxConfigs,
            antiSniperConfigs,
            creatorVaults
        );
        emit LpFeeBpsSet(token, univ4Configs.lpFeeBps);
    }

    /// @notice Struct-based overload taking the full `TaxConfigs` (static tax + optional linear launch-tax
    ///         decay) and a `creatorVaults` array (pass empty for none). `univ4Configs.lpFeeBps` selects
    ///         which graduator/hook pair to use (100 or 50). This is the current recommended overload and
    ///         the only one that exposes launch-tax decay.
    function createToken(
        TokenSetup calldata tokenSetup,
        TaxConfigs calldata taxConfigs,
        UniV4Configs calldata univ4Configs,
        SupplyShare[] calldata buyOnDeployShares,
        AntiSniperConfigs calldata antiSniperConfigs,
        CreatorVault[] calldata creatorVaults
    ) external payable returns (address token) {
        _validateUniv4Configs(univ4Configs);
        _validateTotalFee(univ4Configs.lpFeeBps, taxConfigs);
        address tokenOwner = univ4Configs.renounceOwnership ? address(0) : msg.sender;
        address graduator = _resolveGraduator(univ4Configs.lpFeeBps, tokenSetup.liquidityTier);
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

    /// @dev Maps `(lpFeeBps, tier)` to the graduator that pairs with the matching `LivoSwapHook` variant
    ///      AND graduates at the tier's price. Callers MUST pre-validate `lpFeeBps` via
    ///      `_validateUniv4Configs`; this function trusts its input and treats anything other than 100
    ///      as the 50-bps branch.
    function _resolveGraduator(uint16 lpFeeBps, LiquidityTier tier) internal view returns (address) {
        bool is100 = lpFeeBps == 100;
        if (tier == LiquidityTier.DEFAULT) return is100 ? address(GRADUATOR) : GRADUATOR_0P5;
        if (tier == LiquidityTier.SMALL) return is100 ? GRADUATOR_SMALL : GRADUATOR_SMALL_0P5;
        return is100 ? GRADUATOR_LARGE : GRADUATOR_LARGE_0P5; // LARGE
    }

    /// @dev Pre-graduation launchpad LP fee, fixed at `V4_LAUNCHPAD_LP_FEE_BPS` (1%) for every V4 token
    ///      regardless of the post-graduation hook fee it selected. The pre-graduation rate is a constant
    ///      launchpad policy, decoupled from the post-graduation LP fee, so `graduator` is ignored.
    function _launchpadLpFeeBps(
        address /* graduator */
    )
        internal
        pure
        override
        returns (uint16)
    {
        return V4_LAUNCHPAD_LP_FEE_BPS;
    }

    /// @inheritdoc LivoFactoryAbstract
    function _launchpadTreasuryShareBps() internal pure override returns (uint16) {
        return V4_LAUNCHPAD_TREASURY_SHARE_BPS;
    }

    /// @notice Returns which token implementation `createToken(...)` would clone for the given inputs.
    /// @dev Mirrors the dispatch-relevant `createToken` inputs minus the identity fields (`name`,
    ///      `symbol`, `salt`) and ownership flag so the ABI stays stable when future features change
    ///      which inputs participate in dispatch. Today `taxCfg.taxDurationSeconds`,
    ///      `taxCfg.taxDecayDuration` (a decay-only token still clones the taxable impl) and
    ///      `antiSniperCfg.protectionWindowSeconds` matter for dispatch; disabled configs must
    ///      have all other tax/anti-sniper fields
    ///      empty/zero. Used by frontends to compute the initcode hash before mining a salt.
    function previewTokenImplementation(
        FeeShare[] calldata, /* feeReceivers */
        SupplyShare[] calldata, /* supplyShares */
        TaxConfigs calldata taxCfg,
        AntiSniperConfigs calldata antiSniperCfg
    ) external view returns (address) {
        _validateAntiSniperConfig(antiSniperCfg);
        _validateTaxConfig(taxCfg);
        return _previewTokenImplementation(taxCfg, antiSniperCfg);
    }

    /// @notice Quotes the ETH (msg.value) needed to receive ~`tokenAmount` tokens via the deployer buy.
    ///         Pass the same `taxCfg` and `univ4Configs` you'll pass to `createToken`; the buy fee is
    ///         derived from them (the fixed pre-graduation launchpad LP fee plus the buy tax) so the
    ///         frontend doesn't recompute it.
    /// @param tokenAmount Amount of tokens to receive
    /// @param totalLockedInVaultsBps Sum of `supplyBps` across the creator vaults (0 for none); selects
    ///        the same curve `createToken` uses. See `_quoteBuyOnDeploy`.
    /// @param taxCfg The tax config the token will be created with; only `buyTaxBps` affects the buy,
    ///        and only when the window is creation-anchored (`startTaxFromLaunch`) — a graduation-anchored
    ///        tax is not charged on the deploy buy (see `_deployBuyTaxBps`).
    /// @param univ4Configs The V4 config the token will be created with; `lpFeeBps` selects the
    ///        post-graduation hook fee. Validated here so the fee is one of the supported hook variants.
    ///        The deploy buy is a pre-graduation trade, so it is quoted at the fixed
    ///        `V4_LAUNCHPAD_LP_FEE_BPS`, not `lpFeeBps`.
    /// @return totalEthNeeded The msg.value to pass to createToken
    function quoteBuyOnDeploy(
        LiquidityTier liquidityTier,
        uint256 tokenAmount,
        uint256 totalLockedInVaultsBps,
        TaxConfigs calldata taxCfg,
        UniV4Configs calldata univ4Configs
    ) external view returns (uint256 totalEthNeeded) {
        _validateUniv4Configs(univ4Configs);
        return _quoteBuyOnDeploy(
            liquidityTier,
            tokenAmount,
            totalLockedInVaultsBps,
            uint256(V4_LAUNCHPAD_LP_FEE_BPS) + _deployBuyTaxBps(taxCfg)
        );
    }
}
