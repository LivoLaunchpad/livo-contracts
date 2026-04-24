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
/// @notice Reusable anti-sniper mixin for Livo tokens. Applies configurable max-buy-per-tx and
///         max-wallet caps during a configurable window after token creation, only on buys from
///         the bonding curve (i.e. transfers whose `from` is the launchpad), and only before
///         graduation.
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
    error ProtectionWindowTooShort();
    error ProtectionWindowTooLong();

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
        require(cfg.protectionWindowSeconds >= ANTI_SNIPER_MIN_WINDOW, ProtectionWindowTooShort());
        require(cfg.protectionWindowSeconds <= ANTI_SNIPER_MAX_WINDOW, ProtectionWindowTooLong());

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
    /// @param factoryAddr Address of the factory that deployed this token (deployer-buy recipient).
    /// @param graduated True if the token has already graduated.
    /// @param toBalance Recipient's balance BEFORE this transfer is applied (`balanceOf(to)`).
    /// @dev The factory recipient is exempt so the deployer-buy path (launchpad → factory →
    ///      supplyShares, atomically in `createToken`) can move up to the factory's own
    ///      deployer-buy cap without tripping the anti-sniper limits.
    /// @dev The sniper protection limits ignore the launchpad fees for simplicity
    function _checkSniperProtection(
        address from,
        address to,
        uint256 amount,
        address launchpadAddr,
        address factoryAddr,
        bool graduated,
        uint256 toBalance
    ) internal view {
        if (
            !graduated && from != address(0) && from == launchpadAddr
                && block.timestamp < launchTimestamp + protectionWindowSeconds
        ) {
            if (to == factoryAddr) return;
            if (sniperBypass[to]) return;

            uint256 maxWallet = (_ANTI_SNIPER_TOTAL_SUPPLY * maxWalletBps) / 10_000;
            require(toBalance + amount <= maxWallet, MaxWalletExceeded());

            uint256 maxTx = (_ANTI_SNIPER_TOTAL_SUPPLY * maxBuyPerTxBps) / 10_000;
            require(amount <= maxTx, MaxBuyPerTxExceeded());
        }
    }
}
