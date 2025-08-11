// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title PieceWiseLinearGood
 * @dev Gas-optimized piece-wise linear bonding curve with hardcoded nodes
 */
contract PieceWiseLinearGood {
    // Scale factor
    uint256 constant TOKEN_SCALE = 1e18;

    // note this curve assumes that the total supply is 1,000,000 tokens

    // // Supply nodes (x-coordinates)
    // uint256 constant X_NODE_0 = 0;
    // uint256 constant X_NODE_1 = 218750 * TOKEN_SCALE;
    // uint256 constant X_NODE_2 = 437500 * TOKEN_SCALE;
    // uint256 constant X_NODE_3 = 754896 * TOKEN_SCALE;
    // uint256 constant X_NODE_4 = 1000000 * TOKEN_SCALE; // Full supply graduation point

    // // Price nodes (y-coordinates)
    // uint256 constant P_NODE_0 = 0.000001e18;     // 1e-6 ETH
    // uint256 constant P_NODE_1 = 0.00001e18;      // 1e-5 ETH
    // uint256 constant P_NODE_2 = 0.00002e18;      // 2e-5 ETH
    // uint256 constant P_NODE_3 = 0.00006e18;      // 6e-5 ETH
    // uint256 constant P_NODE_4 = 0.00059059843885516e18; // ~0.0005905984388551599 ETH

    // Supply nodes (x-coordinates)
    uint256 constant X_NODE_0 = 0;
    uint256 constant X_NODE_1 = 218750 * TOKEN_SCALE;
    uint256 constant X_NODE_2 = 600000 * TOKEN_SCALE;
    uint256 constant X_NODE_3 = 700000 * TOKEN_SCALE;
    uint256 constant X_NODE_4 = 1000000 * TOKEN_SCALE; // Full supply graduation point

    // Price nodes (y-coordinates)
    uint256 constant P_NODE_0 = 0.0000007420289855072462e18;
    uint256 constant P_NODE_1 = 0.000007420289855072462e18;
    uint256 constant P_NODE_2 = 0.000014840579710144924e18;
    uint256 constant P_NODE_3 = 0.00004452173913043477e18;
    uint256 constant P_NODE_4 = 0.0005167701863354038e18;

    // Custom errors for gas efficiency
    error BuyExceedsSupply();
    error SellFromInvalidLevel();
    error CannotSellFromZeroSupply();
    error CannotSellMoreThanSupply();

    /**
     * @dev Get segment index for a given supply value
     * @param x Supply in token-wei
     * @return segmentIndex Index of the segment (0-4)
     */
    function _getSegmentIndex(uint256 x) internal pure returns (uint8 segmentIndex) {
        if (x < X_NODE_1) return 0;
        if (x < X_NODE_2) return 1;
        if (x < X_NODE_3) return 2;
        if (x < X_NODE_4) return 3;
        // review this should return 5 beyond the last node, right?
        return 4;
    }

    /**
     * @dev Get segment end for a given segment
     * @param segment Segment index
     * @return segmentEnd End supply value for the segment
     */
    function _getSegmentEnd(uint8 segment) internal pure returns (uint256 segmentEnd) {
        if (segment == 0) return X_NODE_1;
        if (segment == 1) return X_NODE_2;
        if (segment == 2) return X_NODE_3;
        if (segment == 3) return X_NODE_4;
        return X_NODE_4;
    }

    /**
     * @dev Get segment start for a given segment
     * @param segment Segment index
     * @return segmentStart Start supply value for the segment
     */
    function _getSegmentStart(uint8 segment) internal pure returns (uint256 segmentStart) {
        if (segment == 0) return X_NODE_0;
        if (segment == 1) return X_NODE_1;
        if (segment == 2) return X_NODE_2;
        if (segment == 3) return X_NODE_3;
        return X_NODE_4;
    }

    /**
     * @dev Linear interpolation between two points
     * @param x Current position
     * @param x0 Left node position
     * @param x1 Right node position
     * @param p0 Left node price
     * @param p1 Right node price
     * @return interpolatedPrice Price at position x
     */
    function _interpolatePrice(uint256 x, uint256 x0, uint256 x1, uint256 p0, uint256 p1)
        internal
        pure
        returns (uint256 interpolatedPrice)
    {
        if (x1 == x0) return p0;
        return p0 + mulDiv(p1 - p0, x - x0, x1 - x0);
    }

    /**
     * @dev Calculate trapezoid area for segment  // review inside a node segment
     * @param pLeft Price at left boundary
     * @param pRight Price at right boundary
     * @param width Width of the segment
     * @return area Trapezoid area
     */
    function _trapezoidArea(uint256 pLeft, uint256 pRight, uint256 width) internal pure returns (uint256 area) {
        return mulDiv(pLeft + pRight, width, 2 * TOKEN_SCALE);
    }

    /**
     * @dev Get price at specific supply using linear interpolation
     * @param x_int Supply in token-wei
     * @return priceWeiPerToken Price in wei per token
     */
    function priceAt(uint256 x_int) public pure returns (uint256 priceWeiPerToken) {
        uint8 segment = _getSegmentIndex(x_int);

        if (segment == 0) {
            return _interpolatePrice(x_int, X_NODE_0, X_NODE_1, P_NODE_0, P_NODE_1);
        } else if (segment == 1) {
            return _interpolatePrice(x_int, X_NODE_1, X_NODE_2, P_NODE_1, P_NODE_2);
        } else if (segment == 2) {
            return _interpolatePrice(x_int, X_NODE_2, X_NODE_3, P_NODE_2, P_NODE_3);
        } else if (segment == 3) {
            return _interpolatePrice(x_int, X_NODE_3, X_NODE_4, P_NODE_3, P_NODE_4);
        } else {
            return P_NODE_4; // review this
        }
    }

    /**
     * @dev Calculate cost to buy deltaTokens_int tokens starting from supply x_int
     * @param x_int Starting supply in token-wei
     * @param deltaTokens_int Amount of tokens to buy in token-wei
     * @return costWei Total cost in wei
     */
    function costToBuy(uint256 x_int, uint256 deltaTokens_int) public pure returns (uint256 costWei) {
        uint256 remaining = deltaTokens_int;
        uint256 curX = x_int;

        while (remaining > 0) {
            uint8 segment = _getSegmentIndex(curX);

            if (segment >= 4) {
                revert BuyExceedsSupply();
            }

            uint256 segmentEnd = _getSegmentEnd(segment);

            uint256 available = segmentEnd - curX;
            uint256 take = remaining <= available ? remaining : available;

            uint256 pLeft = priceAt(curX);
            uint256 pRight = priceAt(curX + take);
            uint256 segmentCost = _trapezoidArea(pLeft, pRight, take);

            costWei += segmentCost;
            remaining -= take;
            curX += take;
        }

        return costWei;
    }

    /**
     * @dev Calculate ETH received from selling deltaTokens_int tokens starting from supply x_int
     * @param x_int Starting supply in token-wei (before selling)
     * @param deltaTokens_int Amount of tokens to sell in token-wei
     * @return ethReceived Total ETH received in wei
     */
    function sellReturn(uint256 x_int, uint256 deltaTokens_int) public pure returns (uint256 ethReceived) {
        if (x_int < deltaTokens_int) {
            revert CannotSellMoreThanSupply();
        }

        uint256 remaining = deltaTokens_int;
        uint256 curX = x_int;

        while (remaining > 0) {
            if (curX == 0) {
                revert CannotSellFromZeroSupply();
            }

            uint8 segment = _getSegmentIndex(curX - 1); // Check segment for position just below current

            // review if we need this
            if (curX > X_NODE_4) {
                revert SellFromInvalidLevel();
            }

            uint256 segmentStart = _getSegmentStart(segment);

            uint256 availableInSegment = curX - segmentStart;
            uint256 take = remaining <= availableInSegment ? remaining : availableInSegment;

            uint256 pRight = priceAt(curX);
            uint256 pLeft = priceAt(curX - take);
            uint256 segmentReturn = _trapezoidArea(pLeft, pRight, take);

            ethReceived += segmentReturn;
            remaining -= take;
            curX -= take;
        }

        return ethReceived;
    }

    /**
     * @dev Full-precision multiplication and division
     * @param a First operand
     * @param b Second operand
     * @param denominator Divisor
     * @return result a * b / denominator
     */
    function mulDiv(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256) {
        return (a * b) / denominator;
        // review rounding directions...
    }
}
