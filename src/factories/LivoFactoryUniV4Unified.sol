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

    /// @notice Constructor-only bundle of the THIN/THICK tier V4 graduators (one per tier x hook fee).
    ///         The DEFAULT-tier pair is `GRADUATOR` (100 bps, abstract) + `GRADUATOR_0P5` (50 bps).
    struct TierGraduators {
        address thin; // 100 bps hook
        address thin0p5; // 50 bps hook
        address thick; // 100 bps hook
        address thick0p5; // 50 bps hook
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

    /// @notice THIN/THICK tier graduators, one per (tier x hook fee). Each initializes its pool at the
    ///         tier-specific graduation price. Selected by `_resolveGraduator(lpFeeBps, tier)`.
    address public immutable GRADUATOR_THIN; // 100 bps hook
    address public immutable GRADUATOR_THIN_0P5; // 50 bps hook
    address public immutable GRADUATOR_THICK; // 100 bps hook
    address public immutable GRADUATOR_THICK_0P5; // 50 bps hook

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
        GRADUATOR_THIN = v4Tier.graduators.thin;
        GRADUATOR_THIN_0P5 = v4Tier.graduators.thin0p5;
        GRADUATOR_THICK = v4Tier.graduators.thick;
        GRADUATOR_THICK_0P5 = v4Tier.graduators.thick0p5;
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
        TokenSetup memory tokenSetup = TokenSetup({name: name, symbol: symbol, salt: salt, feeShares: feeReceivers});
        TaxConfigs memory taxConfigs = _toTaxConfigs(taxCfg);
        _validateTotalFee(100, taxConfigs);
        token = _createToken(
            tokenSetup,
            LiquidityTier.DEFAULT,
            renounceOwnership_ ? address(0) : msg.sender,
            address(GRADUATOR),
            supplyShares,
            taxConfigs,
            antiSniperCfg,
            new CreatorVault[](0)
        );
        emit LpFeeBpsSet(token, 100);
    }

    /// @notice TMP struct-based overload: full `TaxConfigs` (static tax + optional launch-tax decay) and a
    ///         `creatorVaults` array (pass empty for none). `univ4Configs.lpFeeBps` selects the graduator/hook
    ///         pair (100 or 50). Always uses `LiquidityTier.DEFAULT`.
    /// @dev TEMPORARY: the tier-less overload existing frontends call while the liquidity-tier UI is not
    ///      ready. Removed once the frontend adopts tiers; use the `TokenSetupTiered` overload below to
    ///      select a tier.
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
        // Inline `tokenOwner`/`graduator` (rather than locals) to keep the stack shallow enough to compile
        // without `via_ir`.
        token = _createToken(
            tokenSetup,
            LiquidityTier.DEFAULT,
            univ4Configs.renounceOwnership ? address(0) : msg.sender,
            _resolveGraduator(univ4Configs.lpFeeBps, LiquidityTier.DEFAULT),
            buyOnDeployShares,
            taxConfigs,
            antiSniperConfigs,
            creatorVaults
        );
        emit LpFeeBpsSet(token, univ4Configs.lpFeeBps);
    }

    /// @notice Struct-based overload taking the full `TaxConfigs` (static tax + optional linear launch-tax
    ///         decay), a `creatorVaults` array (pass empty for none) and a `TokenSetupTiered` selecting the
    ///         liquidity tier. `univ4Configs.lpFeeBps` selects which graduator/hook pair to use (100 or 50).
    ///         This is the current recommended overload.
    function createToken(
        TokenSetupTiered calldata tokenSetup,
        TaxConfigs calldata taxConfigs,
        UniV4Configs calldata univ4Configs,
        SupplyShare[] calldata buyOnDeployShares,
        AntiSniperConfigs calldata antiSniperConfigs,
        CreatorVault[] calldata creatorVaults
    ) external payable returns (address token) {
        _validateUniv4Configs(univ4Configs);
        _validateTotalFee(univ4Configs.lpFeeBps, taxConfigs);
        // Inline `tokenOwner`/`graduator` (rather than locals) to keep the stack shallow enough to compile
        // without `via_ir` — the extra `base` build pushes this overload over the limit otherwise.
        TokenSetup memory base = TokenSetup({
            name: tokenSetup.name, symbol: tokenSetup.symbol, salt: tokenSetup.salt, feeShares: tokenSetup.feeShares
        });
        token = _createToken(
            base,
            tokenSetup.liquidityTier,
            univ4Configs.renounceOwnership ? address(0) : msg.sender,
            _resolveGraduator(univ4Configs.lpFeeBps, tokenSetup.liquidityTier),
            buyOnDeployShares,
            taxConfigs,
            antiSniperConfigs,
            creatorVaults
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
        if (tier == LiquidityTier.THIN) return is100 ? GRADUATOR_THIN : GRADUATOR_THIN_0P5;
        return is100 ? GRADUATOR_THICK : GRADUATOR_THICK_0P5; // THICK
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
