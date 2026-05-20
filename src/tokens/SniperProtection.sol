// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Dev-supplied anti-sniper configuration passed to the token's initializer.
/// @dev Immutable once set: no setters exist on the inheriting token.
struct AntiSniperConfigs {
    /// @notice Max tokens per tx, in basis points of TOTAL_SUPPLY. Range: 10..300 (0.1%..3%).
    uint16 maxBuyPerTxBps;
    /// @notice Max wallet balance, in basis points of TOTAL_SUPPLY. Range: 10..300 (0.1%..3%).
    uint16 maxWalletBps;
    /// @notice Duration the protection remains active after token creation. Range: 1 minute..24h.
    uint40 protectionWindowSeconds;
    /// @notice Addresses that bypass the caps during the protection window.
    address[] whitelist;
}

/// @title SniperProtection
/// @notice Reusable anti-sniper mixin for Livo tokens, active during a configurable window after
///         token creation and only before graduation. Enforces two caps:
///           - Per-wallet cap: applied on EVERY incoming transfer (regardless of source), so a
///             sniper cannot sybil-buy from many wallets and consolidate into one.
///           - Per-tx cap: applied only on bonding-curve buys (`from == launchpad`), to throttle
///             a single oversized buy. Wallet-to-wallet transfers are not subject to it —
///             consolidation is already contained by the per-wallet cap.
/// @dev Intended to be inherited by opt-in token variants. The inheriting token is responsible
///      for calling `_initializeSniperProtection(cfg)` in its initializer and
///      `_checkSniperProtection(...)` at the top of its `_update()` override.
abstract contract SniperProtection {
    /// @notice Min allowed value for max-per-tx and max-wallet caps, in bps.
    uint16 public constant ANTI_SNIPER_MIN_BPS = 10; // 0.1%

    /// @notice Max allowed value for max-per-tx and max-wallet caps, in bps.
    uint16 public constant ANTI_SNIPER_MAX_BPS = 300; // 3%

    /// @notice Min allowed protection window duration.
    uint40 public constant ANTI_SNIPER_MIN_WINDOW = 1 minutes;

    /// @notice Max allowed protection window duration.
    uint40 public constant ANTI_SNIPER_MAX_WINDOW = 1 days;

    /// @notice Max number of dev-supplied whitelist entries that bypass sniper caps.
    /// @dev Includes the deployer address if the dev chooses to add it to the list.
    uint256 public constant MAX_WHITELISTED = 5;

    /// @dev Mirrors `LivoToken.TOTAL_SUPPLY` (different name to avoid collision through multiple
    ///      inheritance). Kept as an internal constant so the mixin stays self-contained.
    uint256 internal constant _ANTI_SNIPER_TOTAL_SUPPLY = 1_000_000_000e18;

    /// @notice Max tokens per tx during the protection window, in bps of TOTAL_SUPPLY.
    uint16 public maxBuyPerTxBps;

    /// @notice Max wallet balance during the protection window, in bps of TOTAL_SUPPLY.
    uint16 public maxWalletBps;

    /// @notice Duration the protection remains active after `launchTimestamp`.
    uint40 public protectionWindowSeconds;

    /// @notice Anchor for the protection window. Set once by `_initializeSniperProtection`.
    uint40 public launchTimestamp;

    /// @notice Dev-supplied addresses that bypass the caps during the protection window.
    mapping(address account => bool isWhitelisted) public sniperBypass;

    error MaxBuyPerTxExceeded();
    error MaxWalletExceeded();
    error MaxBuyPerTxBpsTooLow();
    error MaxBuyPerTxBpsTooHigh();
    error MaxWalletBpsTooLow();
    error MaxWalletBpsTooHigh();
    error MaxBuyPerTxBpsExceedsMaxWalletBps();
    error ProtectionWindowTooShort();
    error ProtectionWindowTooLong();
    error WhitelistTooLong();

    event SniperProtectionInitialized(
        uint16 maxBuyPerTxBps, uint16 maxWalletBps, uint40 protectionWindowSeconds, address[] whitelist
    );

    /// @dev Validates and stores the anti-sniper configs, anchors the window to the current
    ///      block timestamp, and records each whitelist entry.
    function _initializeSniperProtection(AntiSniperConfigs memory cfg) internal {
        require(cfg.maxBuyPerTxBps >= ANTI_SNIPER_MIN_BPS, MaxBuyPerTxBpsTooLow());
        require(cfg.maxBuyPerTxBps <= ANTI_SNIPER_MAX_BPS, MaxBuyPerTxBpsTooHigh());
        require(cfg.maxWalletBps >= ANTI_SNIPER_MIN_BPS, MaxWalletBpsTooLow());
        require(cfg.maxWalletBps <= ANTI_SNIPER_MAX_BPS, MaxWalletBpsTooHigh());
        require(cfg.maxBuyPerTxBps <= cfg.maxWalletBps, MaxBuyPerTxBpsExceedsMaxWalletBps());
        require(cfg.protectionWindowSeconds >= ANTI_SNIPER_MIN_WINDOW, ProtectionWindowTooShort());
        require(cfg.protectionWindowSeconds <= ANTI_SNIPER_MAX_WINDOW, ProtectionWindowTooLong());
        require(cfg.whitelist.length <= MAX_WHITELISTED, WhitelistTooLong());

        maxBuyPerTxBps = cfg.maxBuyPerTxBps;
        maxWalletBps = cfg.maxWalletBps;
        protectionWindowSeconds = cfg.protectionWindowSeconds;
        launchTimestamp = uint40(block.timestamp);

        uint256 n = cfg.whitelist.length;
        for (uint256 i; i < n; ++i) {
            sniperBypass[cfg.whitelist[i]] = true;
        }

        emit SniperProtectionInitialized(
            cfg.maxBuyPerTxBps, cfg.maxWalletBps, cfg.protectionWindowSeconds, cfg.whitelist
        );
    }

    /// @param from Transfer sender (as passed to `_update`).
    /// @param to Transfer recipient (as passed to `_update`).
    /// @param amount Transfer amount.
    /// @param launchpadAddr Address of the launchpad (the bonding-curve counterparty).
    /// @param factoryAddr Address of the factory that deployed this token. Sourced by the caller
    ///        from the host token's `tokenFactory` (transient): non-zero only inside the same tx
    ///        that initialized the token, which is the only window in which the launchpad →
    ///        factory → supplyShares deployer-buy hops happen. After that tx it reads
    ///        `address(0)`.
    /// @param graduatorAddr Address of the graduator (graduation-reserve recipient).
    /// @param graduated True if the token has already graduated.
    /// @param toBalance Recipient's balance BEFORE this transfer is applied (`balanceOf(to)`).
    /// @dev The per-wallet cap applies to every incoming transfer (modulo the bypass list); the
    ///      per-tx cap applies only when the source is the launchpad (i.e. on bonding-curve
    ///      buys). This lets a sniper-fragmented buy still be consolidation-blocked while
    ///      keeping ordinary wallet-to-wallet movement free of an artificial per-tx ceiling.
    /// @dev `to` exemptions (skip the entire check):
    ///        - `launchpadAddr`: sellers returning tokens to the curve (and the recipient of
    ///          the initial mint, although that path is also exempt via the `launchTimestamp ==
    ///          0` early-return below).
    ///        - `factoryAddr`: deployer-buy hop `launchpad → factory`, atomic with `createToken`.
    ///        - `graduatorAddr`: graduation moves the entire graduation reserve (~80% of supply)
    ///          from the launchpad to the graduator in a single hop BEFORE `markGraduated()`
    ///          flips the gate; without this, graduation inside the window would always revert.
    ///        - `sniperBypass[to]`: dev-supplied whitelist.
    /// @dev `from` exemptions (skip the entire check):
    ///        - `factoryAddr`: factory → supplyShare recipients during the deployer-buy split.
    ///          These splits are dev-configured and may legitimately exceed the per-wallet cap.
    ///        - `graduatorAddr`: defense in depth for any pre-`markGraduated` graduator moves.
    /// @dev Mints (`from == 0`) only happen inside `_initializeLivoToken` before
    ///      `_initializeSniperProtection` runs, when `launchTimestamp == 0`, so the window
    ///      early-return covers them. Burns (`to == 0`) are rejected by OZ ERC20 v5 before
    ///      reaching `_update`; they can only shrink balances anyway.
    /// @dev The sniper protection limits ignore the launchpad fees for simplicity.
    function _checkSniperProtection(
        address from,
        address to,
        uint256 amount,
        address launchpadAddr,
        address factoryAddr,
        address graduatorAddr,
        bool graduated,
        uint256 toBalance
    ) internal view {
        if (graduated) return;
        if (block.timestamp >= launchTimestamp + protectionWindowSeconds) return;

        // sells (to launchpad) not affected
        if (to == launchpadAddr) return;

        // required by either the token creation or graduation steps
        if (to == factoryAddr) return;
        if (to == graduatorAddr) return;
        if (from == factoryAddr) return;
        if (from == graduatorAddr) return;

        if (sniperBypass[to]) return;

        // Per-tx cap: only on curve buys. Wallet-to-wallet transfers don't trip it; the
        // per-wallet cap below already bounds the receivable amount to `maxWallet` per address.
        // Checked before the per-wallet cap so an oversized buy reverts with the more specific
        // `MaxBuyPerTxExceeded` rather than `MaxWalletExceeded`.
        if (from == launchpadAddr) {
            uint256 maxTx = (_ANTI_SNIPER_TOTAL_SUPPLY * maxBuyPerTxBps) / 10_000;
            require(amount <= maxTx, MaxBuyPerTxExceeded());
        }

        // Per-wallet cap: every non-bypassed incoming transfer.
        uint256 maxWallet = (_ANTI_SNIPER_TOTAL_SUPPLY * maxWalletBps) / 10_000;
        require(toBalance + amount <= maxWallet, MaxWalletExceeded());
    }

    /// @notice Largest token amount `buyer` may receive from the launchpad right now without
    ///         tripping the per-tx or per-wallet caps. Returns `type(uint256).max` when no
    ///         sniper cap applies (window closed, graduated, or whitelisted).
    /// @dev Does not account for launchpad-side limits (available supply, graduation excess
    ///      cap). Callers should `min()` with `LivoLaunchpad.getMaxEthToSpend` converted to
    ///      tokens via the bonding curve.
    /// @dev The `factory` / `graduator` / `launchpad` exemptions in `_checkSniperProtection`
    ///      are intentionally NOT mirrored here: none of those addresses ever buys via
    ///      `LivoLaunchpad.buyTokensWithExactEth` (factory only receives during the
    ///      `createToken` deployer-buy hop, graduator only at graduation, launchpad is the
    ///      seller), so spending storage reads to model those cases is unnecessary.
    function _maxTokenPurchase(address buyer, uint256 buyerBalance, bool graduated) internal view returns (uint256) {
        if (graduated) return type(uint256).max;
        if (sniperBypass[buyer]) return type(uint256).max;
        if (block.timestamp >= launchTimestamp + protectionWindowSeconds) return type(uint256).max;

        uint256 maxTx = (_ANTI_SNIPER_TOTAL_SUPPLY * maxBuyPerTxBps) / 10_000;
        uint256 maxWallet = (_ANTI_SNIPER_TOTAL_SUPPLY * maxWalletBps) / 10_000;
        uint256 walletRemaining = buyerBalance >= maxWallet ? 0 : maxWallet - buyerBalance;

        return maxTx < walletRemaining ? maxTx : walletRemaining;
    }
}
