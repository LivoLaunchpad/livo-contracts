// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

library TokenFeeConfigLib {
    uint256 internal constant BPS_TOTAL = 10_000;

    struct Config {
        // Packed into slot 0: bool (1 byte) + uint16 (2 bytes), 29 bytes free.
        bool isSplit;
        uint16 totalDirectBps; // bounded by BPS_TOTAL = 10_000, fits in uint16.
        uint256 ethPerBps;
        address[] directReceivers;
        address[] claimableRecipients;
    }

    /// @dev Returns whether this config has been registered.
    function isRegistered(Config storage cfg) internal view returns (bool) {
        return cfg.directReceivers.length != 0 || cfg.claimableRecipients.length != 0;
    }

    /// @dev Returns the sum of BPS allocated to claimable (non-direct) recipients.
    function claimableBpsTotal(Config storage cfg) internal view returns (uint256) {
        return BPS_TOTAL - cfg.totalDirectBps;
    }
}
