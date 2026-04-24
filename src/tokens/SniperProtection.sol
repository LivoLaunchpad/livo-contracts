// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @dev Minimal interface fragment to check the launchpad's factory whitelist.
interface ILaunchpadFactoryCheck {
    function whitelistedFactories(address factory) external view returns (bool);
}

/// @title SniperProtection
/// @notice Reusable anti-sniper mixin for Livo tokens. Applies max-buy-per-tx and max-wallet
///         caps during a fixed window after token creation, only on buys from the bonding curve
///         (i.e. transfers whose `from` is the launchpad), and only before graduation.
/// @dev Intended to be inherited by opt-in token variants. The inheriting token is responsible
///      for calling `_setLaunchTimestamp()` in its initializer and `_checkSniperProtection(...)`
///      at the top of its `_update()` override.
abstract contract SniperProtection {
    /// @notice 3% of the 1B Livo total supply.
    uint256 public constant SNIPER_MAX_BUY_PER_TX = 30_000_000e18;

    /// @notice 3% of the 1B Livo total supply.
    uint256 public constant SNIPER_MAX_WALLET = 30_000_000e18;

    /// @notice Duration protection remains active after creation.
    uint40 public constant SNIPER_PROTECTION_WINDOW = 3 hours;

    /// @notice Anchor for the protection window. Set once by the inheriting contract's initializer.
    uint40 public launchTimestamp;

    error MaxBuyPerTxExceeded();
    error MaxWalletExceeded();

    function _setLaunchTimestamp() internal {
        launchTimestamp = uint40(block.timestamp);
    }

    /// @param from Transfer sender (as passed to `_update`).
    /// @param to Transfer recipient (as passed to `_update`).
    /// @param amount Transfer amount.
    /// @param launchpadAddr Address of the launchpad (the bonding-curve counterparty).
    /// @param graduated True if the token has already graduated.
    /// @param toBalance Recipient's balance BEFORE this transfer is applied (`balanceOf(to)`).
    /// @dev Whitelisted factories are exempt so the deployer-buy path (launchpad → factory →
    ///      deployer, atomically in `createToken`) can move up to the factory's own deployer-buy
    ///      cap without tripping the anti-sniper limits.
    /// @dev The snipper protection limits ignore the launchpad fees for simplicity
    function _checkSniperProtection(
        address from,
        address to,
        uint256 amount,
        address launchpadAddr,
        bool graduated,
        uint256 toBalance
    ) internal view {
        if (
            !graduated && from != address(0) && from == launchpadAddr
                && block.timestamp < launchTimestamp + SNIPER_PROTECTION_WINDOW
        ) {
            if (ILaunchpadFactoryCheck(launchpadAddr).whitelistedFactories(to)) return;

            require(amount <= SNIPER_MAX_BUY_PER_TX, MaxBuyPerTxExceeded());
            require(toBalance + amount <= SNIPER_MAX_WALLET, MaxWalletExceeded());
        }
    }
}
