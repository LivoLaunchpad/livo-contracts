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

    /// @notice Factory that deployed this token (captured as `msg.sender` at `_initializeSniperProtection`).
    /// @dev Used to exempt the deployer-buy path's launchpad → factory hop from the caps.
    address internal factory;

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
        factory = msg.sender;

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
    /// @param graduatorAddr Address of the graduator (graduation-reserve recipient).
    /// @param graduated True if the token has already graduated.
    /// @param toBalance Recipient's balance BEFORE this transfer is applied (`balanceOf(to)`).
    /// @dev The factory recipient is exempt so the deployer-buy path (launchpad → factory →
    ///      supplyShares, atomically in `createToken`) can move up to the factory's own
    ///      deployer-buy cap without tripping the anti-sniper limits.
    /// @dev The graduator recipient is exempt for the same reason: graduation moves the entire
    ///      graduation reserve (~80% of supply) from the launchpad to the graduator in a single
    ///      hop before `markGraduated()` flips the gate, so without this exemption a graduation
    ///      triggered inside the protection window would always revert with `MaxBuyPerTxExceeded`.
    /// @dev The sniper protection limits ignore the launchpad fees for simplicity
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
        if (
            !graduated && from != address(0) && from == launchpadAddr
                && block.timestamp < launchTimestamp + protectionWindowSeconds
        ) {
            if (to == factoryAddr) return;
            if (to == graduatorAddr) return;
            if (sniperBypass[to]) return;

            uint256 maxTx = (_ANTI_SNIPER_TOTAL_SUPPLY * maxBuyPerTxBps) / 10_000;
            require(amount <= maxTx, MaxBuyPerTxExceeded());

            uint256 maxWallet = (_ANTI_SNIPER_TOTAL_SUPPLY * maxWalletBps) / 10_000;
            require(toBalance + amount <= maxWallet, MaxWalletExceeded());
        }
    }

    /// @notice Largest token amount `buyer` may receive from the launchpad right now without
    ///         tripping the per-tx or per-wallet caps. Returns `type(uint256).max` when no
    ///         sniper cap applies (window closed, graduated, or whitelisted).
    /// @dev Does not account for launchpad-side limits (available supply, graduation excess
    ///      cap). Callers should `min()` with `LivoLaunchpad.getMaxEthToSpend` converted to
    ///      tokens via the bonding curve.
    /// @dev The `factory` and `graduator` recipient exemptions in `_checkSniperProtection` are
    ///      intentionally NOT mirrored here: neither address ever buys via
    ///      `LivoLaunchpad.buyTokensWithExactEth` (factory only receives during the
    ///      `createToken` deployer-buy hop, graduator only at graduation), so spending storage
    ///      reads to model that case is unnecessary.
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
