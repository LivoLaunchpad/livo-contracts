// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LiquidityTier} from "src/types/LiquidityTier.sol";

interface ILivoFactory {
    ////////////////// Structs //////////////////////

    /// @notice Constructor-only bundle of the configurable bonding curves for a single liquidity tier:
    ///         the no-vault (0%) curve plus the six vault curves (5%,10%,15%,20%,25%,30%). Passed to
    ///         the factory constructor for the THIN and THICK tiers (DEFAULT reuses the deployed base
    ///         curve + the six existing vault curves).
    struct TierCurves {
        address base;
        address[6] vaults;
    }

    /// @notice Constructor-only bundle of the THIN + THICK tier curve sets. Grouped into one struct
    ///         (rather than two `TierCurves` params) to keep the factory constructors' parameter count
    ///         — and thus their ABI-decode stack depth — within limits without `via_ir`.
    struct LiquidityTierConfig {
        TierCurves thin;
        TierCurves thick;
    }

    /// @notice Constructor-only bundle of the four token implementations the factory clones. Grouped
    ///         into one struct to keep the factory constructors' parameter count within the ABI-decode
    ///         stack limit without `via_ir`.
    struct TokenImpls {
        address base;
        address antiSniper;
        address tax;
        address taxAntiSniper;
    }

    /// @notice A single fee-receiver entry: account + shares in basis points (sum must == 10 000).
    /// @dev If `directFeesEnabled` is true, fees for this account are forwarded automatically on every
    ///      accrual instead of being held for `claim()`. A failed forward (malicious receiver) falls back
    ///      to the existing claimable accounting so swaps and graduation can never be DoS'd.
    struct FeeShare {
        address account;
        uint256 shares;
        bool directFeesEnabled;
    }

    /// @notice A single supply-share entry: account + shares in basis points (sum must == 10 000).
    struct SupplyShare {
        address account;
        uint256 shares;
    }

    /// @notice A single creator-vault entry passed to the struct-based `createToken` overload.
    ///         Locks `supplyBps` of the total supply (a multiple of 500 bps = 5%) into a vesting
    ///         vault owned by `owner`. The cliff is a pure lock-up; linear vesting begins after it.
    ///         Both clocks start at token creation (see `LivoCreatorVault`); claims are additionally
    ///         gated until the token graduates. The bonding curve is chosen from the SUM of
    ///         `supplyBps` across all vaults (≤ 3000 bps = 30%).
    struct CreatorVault {
        address owner;
        uint256 supplyBps;
        uint256 cliffSeconds;
        uint256 vestingSeconds;
    }

    /// @notice Token-identity bundle for the tier-less (tmp) struct-based `createToken` overload and the
    ///         legacy positional overload. Groups the inputs that define the token itself (name, symbol,
    ///         deterministic salt) and its fee receivers. `feeShares` must be non-empty — every token has
    ///         at least one receiver. Tokens created through this struct always use `LiquidityTier.DEFAULT`.
    /// @dev TEMPORARY: kept tier-less so existing frontends keep their `createToken` ABI while the
    ///      liquidity-tier UI is not ready. Once the frontend adopts tiers, this struct is removed and
    ///      `TokenSetupTiered` becomes the only setup struct.
    struct TokenSetup {
        string name;
        string symbol;
        bytes32 salt;
        FeeShare[] feeShares;
    }

    /// @notice Token-identity bundle for the tiered struct-based `createToken` overload. Same fields as
    ///         `TokenSetup` plus `liquidityTier`, which selects the post-graduation pool depth (and the
    ///         tier-specific bonding curve + graduation marketcap).
    /// @dev `liquidityTier`'s zero value is `LiquidityTier.THIN`, so set it explicitly.
    struct TokenSetupTiered {
        string name;
        string symbol;
        bytes32 salt;
        FeeShare[] feeShares;
        LiquidityTier liquidityTier;
    }

    ////////////////// Events //////////////////////

    event TokenCreated(
        address indexed token,
        string name,
        string symbol,
        address tokenOwner,
        address launchpad,
        address graduator,
        address feeHandler
    );

    event BuyOnDeploy(
        address indexed token,
        address indexed buyer,
        uint256 ethSpent,
        uint256 tokensBought,
        address[] recipients,
        uint256[] amounts
    );

    /// @notice Per-token Uniswap V4 LP fee in basis points. Emitted only by the V4 unified factory
    ///         (V2 has no LP-fee concept). Today the V4 hook hardcodes 100 bps; this event lets
    ///         indexers attach the value as a per-token attribute ahead of the field being honoured.
    event LpFeeBpsSet(address indexed token, uint16 lpFeeBps);

    /// @notice Emitted once per token that locks supply in creator vaults, after the vaults are
    ///         deployed and funded. `totalVaultAllocation` is the sum of `amounts`. Individual vault
    ///         configs (owner, cliff, vesting) are in the `CreatorVaultDeployed` events emitted by
    ///         the `LivoCreatorVaultFactory`.
    event CreatorVaultsCreated(
        address indexed token, uint256 totalVaultAllocation, address[] vaults, uint256[] amounts
    );

    ////////////////// Errors //////////////////////

    error InvalidNameOrSymbol();
    error InvalidTokenOwner();
    error InvalidFeeReceiver();
    error InvalidSupplyShares();
    error InvalidShares();
    error InvalidTokenAddress();
    error InvalidBuyOnDeploy();
    error MultipleDirectFeeReceivers();
    error InvalidAntiSniperConfig();
    error InvalidTaxConfig();
    error InvalidTaxBps();
    error InvalidTaxDuration();
    error TooManyCreatorVaults();
    error InvalidCreatorVault();
    error CreatorVaultAllocationTooHigh();
    error CreatorVaultDistributionFailed();

    // Note: `quoteBuyOnDeploy` is venue-specific (its buy fee derives from the venue's LP fee, which
    // for V4 lives in `UniV4Configs`), so it is declared on each concrete factory rather than here —
    // the same way the venue-specific `createToken` overloads are not part of this shared interface.
}
