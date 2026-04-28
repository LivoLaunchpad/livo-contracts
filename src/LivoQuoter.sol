// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ILivoLaunchpad} from "src/interfaces/ILivoLaunchpad.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {ILivoQuoter, LimitReason} from "src/interfaces/ILivoQuoter.sol";
import {TokenConfig, TokenState} from "src/types/tokenData.sol";

/// @title LivoQuoter
/// @notice Single source of truth the frontend talks to for quoting trades. It composes
///         `LivoLaunchpad`'s public quote/getMaxEthToSpend views with the per-buyer sniper cap
///         exposed by `ILivoToken.maxTokenPurchase`, clamps the input to whatever combination of
///         caps is currently binding, and reports which cap clamped the result through a
///         `LimitReason` code. By construction the returned `ethSpent` / `maxEth` are always safe
///         to broadcast against `LivoLaunchpad.buyTokensWithExactEth` without any cap-related
///         revert.
/// @dev Stateless and view-only. The launchpad address is immutable; deploy a new quoter per
///      launchpad.
contract LivoQuoter is ILivoQuoter {
    /// @notice The launchpad this quoter reads from.
    ILivoLaunchpad public immutable launchpad;

    /// @dev Upper bound on the forward-decrement loop used to neutralize the bonding curve's
    ///      non-symmetric invertibility (`forward(inverse(T)) > T`). In practice the loop
    ///      converges in 1-3 iterations; the cap is purely defensive.
    uint256 internal constant _SAFETY_LOOP_CAP = 64;

    error InvalidLaunchpad();

    constructor(address _launchpad) {
        require(_launchpad != address(0), InvalidLaunchpad());
        launchpad = ILivoLaunchpad(_launchpad);
    }

    /// @inheritdoc ILivoQuoter
    function quoteBuyTokensWithExactEth(address token, address buyer, uint256 ethValue)
        external
        view
        returns (BuyExactEthQuote memory q)
    {
        (LimitReason validity,) = _checkBuyValidity(token);
        if (validity != LimitReason.NONE) {
            q.reason = validity;
            return q;
        }

        (uint256 maxEth, LimitReason capReason) = _maxEthToSpendForBuyer(token, buyer);

        if (ethValue <= maxEth) {
            q.ethSpent = ethValue;
            q.reason = LimitReason.NONE;
        } else {
            q.ethSpent = maxEth;
            q.reason = capReason;
        }

        if (q.ethSpent > 0) {
            (, q.ethFee, q.tokensToReceive) = launchpad.quoteBuyTokensWithExactEth(token, q.ethSpent);
        }
    }

    /// @inheritdoc ILivoQuoter
    function quoteBuyExactTokens(address token, address buyer, uint256 tokenAmount)
        external
        view
        returns (BuyExactTokensQuote memory q)
    {
        (LimitReason validity,) = _checkBuyValidity(token);
        if (validity != LimitReason.NONE) {
            q.reason = validity;
            return q;
        }
        if (tokenAmount == 0) return q;

        // Compute the buyer's safe ETH ceiling — already accounts for graduation excess +
        // sniper cap. The reason returned here is the cap that *would* bind if the user spent
        // every available wei.
        (uint256 maxEth, LimitReason capReason) = _maxEthToSpendForBuyer(token, buyer);
        if (maxEth == 0) {
            q.reason = capReason;
            return q;
        }

        // Resolve the supply cap separately because it isn't part of `_maxEthToSpendForBuyer`.
        uint256 supplyCap = ILivoToken(token).balanceOf(address(launchpad));
        uint256 maxTokensAtMaxEth = _forwardTokens(token, maxEth);
        if (supplyCap < maxTokensAtMaxEth) {
            // Supply is tighter than graduation/sniper. Recompute maxEth via the safe inverse.
            (maxEth,) = _safeBuyExactTokens(token, supplyCap);
            maxTokensAtMaxEth = supplyCap;
            capReason = LimitReason.NOT_ENOUGH_SUPPLY;
        }

        if (tokenAmount > maxTokensAtMaxEth) {
            // Clamped path: we can only deliver `maxTokensAtMaxEth` tokens. Use `maxEth` as the
            // exact `msg.value` the user must broadcast.
            q.totalEthNeeded = maxEth;
            q.reason = capReason;
        } else {
            // Honor path: inverse-quote the requested amount, defensively clamp to `maxEth` in
            // case ceiling rounding pushes the inverse 1-2 wei above the cap, then forward
            // through the launchpad to get the *actual* delivery numbers below.
            (,, q.totalEthNeeded) = launchpad.quoteBuyExactTokens(token, tokenAmount);
            if (q.totalEthNeeded > maxEth) q.totalEthNeeded = maxEth;
            q.reason = LimitReason.NONE;
        }

        // Source of truth: forward-quote the chosen `totalEthNeeded` so every other field matches
        // exactly what the launchpad will compute on the eventual `buyTokensWithExactEth` call.
        (q.ethForReserves, q.ethFee, q.tokensReceived) = launchpad.quoteBuyTokensWithExactEth(token, q.totalEthNeeded);
    }

    /// @inheritdoc ILivoQuoter
    function quoteSellExactTokens(address token, uint256 tokenAmount)
        external
        view
        returns (SellExactTokensQuote memory q)
    {
        LimitReason validity = _checkSellValidity(token);
        if (validity != LimitReason.NONE) {
            q.reason = validity;
            return q;
        }

        if (tokenAmount == 0) return q;

        // Cap by reserves available on the launchpad. Under normal launchpad invariants this is
        // dead code (the launchpad always has enough ETH to cover any sell that came through the
        // bonding curve), but we honor `LimitReason.INSUFFICIENT_RESERVES` for symmetry.
        uint256 reservesEth = launchpad.getTokenState(token).ethCollected;
        (uint256 ethPulled, uint256 ethFee, uint256 ethForSeller) = launchpad.quoteSellExactTokens(token, tokenAmount);

        if (ethPulled <= reservesEth) {
            q.tokensSold = tokenAmount;
            q.ethPulledFromReserves = ethPulled;
            q.ethFee = ethFee;
            q.ethForSeller = ethForSeller;
            q.reason = LimitReason.NONE;
        } else {
            // Find tokens that pull exactly `reservesEth` from the curve, then re-quote forward.
            (,, uint256 tokensCapped) = launchpad.quoteSellTokensForExactEth(token, reservesEth);
            (ethPulled, ethFee, ethForSeller) = launchpad.quoteSellExactTokens(token, tokensCapped);
            q.tokensSold = tokensCapped;
            q.ethPulledFromReserves = ethPulled;
            q.ethFee = ethFee;
            q.ethForSeller = ethForSeller;
            q.reason = LimitReason.INSUFFICIENT_RESERVES;
        }
    }

    /// @inheritdoc ILivoQuoter
    function quoteSellTokensForExactEth(address token, uint256 ethAmount)
        external
        view
        returns (SellForExactEthQuote memory q)
    {
        LimitReason validity = _checkSellValidity(token);
        if (validity != LimitReason.NONE) {
            q.reason = validity;
            return q;
        }

        if (ethAmount == 0) return q;

        // The user's `ethAmount` is the post-fee ETH they want to receive. The maximum post-fee
        // ETH redeemable is `reservesEth * (BASIS - sellFeeBps) / BASIS`.
        TokenConfig memory cfg = launchpad.getTokenConfig(token);
        uint256 reservesEth = launchpad.getTokenState(token).ethCollected;
        uint256 maxPostFeeEth = reservesEth * (10_000 - cfg.sellFeeBps) / 10_000;

        uint256 effectiveEth;
        if (ethAmount <= maxPostFeeEth) {
            effectiveEth = ethAmount;
            q.reason = LimitReason.NONE;
        } else {
            effectiveEth = maxPostFeeEth;
            q.reason = LimitReason.INSUFFICIENT_RESERVES;
        }

        if (effectiveEth == 0) return q;

        (q.ethPulledFromReserves, q.ethFee, q.tokensRequired) =
            launchpad.quoteSellTokensForExactEth(token, effectiveEth);
        q.ethReceived = q.ethPulledFromReserves - q.ethFee;
    }

    /// @inheritdoc ILivoQuoter
    function getMaxEthToSpend(address token, address buyer) external view returns (uint256 maxEth, LimitReason reason) {
        (LimitReason validity,) = _checkBuyValidity(token);
        if (validity != LimitReason.NONE) return (0, validity);
        return _maxEthToSpendForBuyer(token, buyer);
    }

    /////////////////////// internal helpers ///////////////////////

    /// @dev Validity gate for buy quotes. Returns `NONE` when the token is registered and not
    ///      graduated; otherwise the matching reason code.
    function _checkBuyValidity(address token) internal view returns (LimitReason reason, TokenConfig memory cfg) {
        cfg = launchpad.getTokenConfig(token);
        if (address(cfg.bondingCurve) == address(0)) return (LimitReason.INVALID_TOKEN, cfg);
        if (launchpad.getTokenState(token).graduated) return (LimitReason.GRADUATED, cfg);
        return (LimitReason.NONE, cfg);
    }

    /// @dev Same as `_checkBuyValidity` but only returns the reason — sells don't need the config.
    function _checkSellValidity(address token) internal view returns (LimitReason) {
        TokenConfig memory cfg = launchpad.getTokenConfig(token);
        if (address(cfg.bondingCurve) == address(0)) return LimitReason.INVALID_TOKEN;
        if (launchpad.getTokenState(token).graduated) return LimitReason.GRADUATED;
        return LimitReason.NONE;
    }

    /// @dev Compute the max ETH `buyer` can spend on `token` right now without tripping any cap,
    ///      returning the binding cap's reason. Caller must ensure the token is registered and not
    ///      graduated.
    function _maxEthToSpendForBuyer(address token, address buyer)
        internal
        view
        returns (uint256 maxEth, LimitReason reason)
    {
        uint256 ethCapGrad = launchpad.getMaxEthToSpend(token);
        if (ethCapGrad == 0) return (0, LimitReason.GRADUATION_EXCESS);

        uint256 sniperCap = ILivoToken(token).maxTokenPurchase(buyer);
        if (sniperCap == type(uint256).max) return (ethCapGrad, LimitReason.GRADUATION_EXCESS);

        // Forward-quote at the graduation ceiling. If the buyer's sniper cap is at or above what
        // would fit anyway, sniper isn't binding.
        uint256 tokensAtGrad = _forwardTokens(token, ethCapGrad);
        if (sniperCap >= tokensAtGrad) return (ethCapGrad, LimitReason.GRADUATION_EXCESS);

        if (sniperCap == 0) return (0, LimitReason.SNIPER_CAP);

        // Sniper is the binding cap. Inverse-quote `sniperCap` and decrement until forward yields
        // at most `sniperCap` tokens — neutralizes the curve's non-symmetric invertibility.
        (uint256 ethSafe,) = _safeBuyExactTokens(token, sniperCap);
        return (ethSafe, LimitReason.SNIPER_CAP);
    }

    /// @dev Forward-quote tokens for a given ETH input, ignoring fee and ethForPurchase fields.
    function _forwardTokens(address token, uint256 ethValue) internal view returns (uint256 tokensOut) {
        (,, tokensOut) = launchpad.quoteBuyTokensWithExactEth(token, ethValue);
    }

    /// @dev Returns the largest `totalEthNeeded` such that broadcasting
    ///      `buyTokensWithExactEth{value: totalEthNeeded}` produces at most `tokenCap` tokens.
    ///      Starts from the launchpad's inverse quote (which over-estimates ETH due to ceiling
    ///      rounding) and decrements 1 wei at a time until the forward yields a safe amount.
    ///      The loop converges in 1-3 iterations under the constant-product curve and 100bps
    ///      fees; `_SAFETY_LOOP_CAP` is a defensive bound.
    /// @return ethSafe The corrected `totalEthNeeded`.
    /// @return tokensSafe The forward-quoted tokens at `ethSafe` (≤ `tokenCap`).
    function _safeBuyExactTokens(address token, uint256 tokenCap)
        internal
        view
        returns (uint256 ethSafe, uint256 tokensSafe)
    {
        if (tokenCap == 0) return (0, 0);

        (,, uint256 totalEth) = launchpad.quoteBuyExactTokens(token, tokenCap);

        for (uint256 i = 0; i < _SAFETY_LOOP_CAP; ++i) {
            if (totalEth == 0) return (0, 0);
            uint256 tokensOut = _forwardTokens(token, totalEth);
            if (tokensOut <= tokenCap) return (totalEth, tokensOut);
            unchecked {
                --totalEth;
            }
        }
        return (totalEth, _forwardTokens(token, totalEth));
    }
}
