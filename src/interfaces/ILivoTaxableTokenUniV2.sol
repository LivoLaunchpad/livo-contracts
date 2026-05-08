// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ILivoToken} from "src/interfaces/ILivoToken.sol";
// re-exported so V2 callers can `import {TaxConfigInit} from "src/interfaces/ILivoTaxableTokenUniV2.sol"`
// without having to know that the struct lives in the V4 interface.
import {TaxConfigInit} from "src/interfaces/ILivoTaxableTokenUniV4.sol";

/// @title ILivoTaxableTokenUniV2
/// @notice Interface for tokens that support time-limited buy/sell taxes on a Uniswap V2 pair,
///         using intrinsic taxation: tax tokens are diverted into the contract balance during
///         pair-touching transfers, then periodically swapped to ETH on the V2 router and pushed
///         to the master fee handler via the standard `accrueFees` path.
interface ILivoTaxableTokenUniV2 is ILivoToken {
    /// @notice Returns the graduation timestamp for this token (0 before graduation).
    function graduationTimestamp() external view returns (uint40);

    /// @notice Manually triggers a swap of accumulated tax tokens to ETH and forwards the proceeds
    ///         to the master fee handler. Owner-only.
    /// @param amountOutMinWei Minimum ETH (in wei) the swap must yield, otherwise the V2 router
    ///        reverts. The caller is expected to derive this from `router.getAmountsOut` or a
    ///        private-mempool quote to bound MEV exposure.
    function swapBack(uint256 amountOutMinWei) external;
}
