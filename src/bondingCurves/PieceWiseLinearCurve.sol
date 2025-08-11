// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title PieceWiseLinearGood
 * @dev Gas-optimized piece-wise linear bonding curve with hardcoded nodes
 */
contract PieceWiseLinearGood {
    uint256 constant TOKEN_SCALE = 1e18;
    
    // Hardcoded node values for gas efficiency
    uint256 constant X_NODE_0 = 0;
    uint256 constant X_NODE_1 = 218750 * TOKEN_SCALE;
    uint256 constant X_NODE_2 = 437500 * TOKEN_SCALE;
    uint256 constant X_NODE_3 = 754896 * TOKEN_SCALE;
    // review by here, the full supply should have been sold (and it should be already graduated???)
    uint256 constant X_NODE_4 = 1000000 * TOKEN_SCALE;
    
    uint256 constant P_NODE_0 = 0.000001e18;     // 1e-6 ETH
    uint256 constant P_NODE_1 = 0.00001e18;      // 1e-5 ETH
    uint256 constant P_NODE_2 = 0.00002e18;      // 2e-5 ETH
    uint256 constant P_NODE_3 = 0.00006e18;      // 6e-5 ETH
    uint256 constant P_NODE_4 = 0.00059059843885516e18; // ~0.0005905984388551599 ETH

    /**
     * @dev Get price at specific supply using linear interpolation
     * @param x_int Supply in token-wei
     * @return priceWeiPerToken Price in wei per token
     */
    function priceAt(uint256 x_int) public pure returns (uint256 priceWeiPerToken) {
        if (x_int < X_NODE_1) {
            // Segment 0: [0, 218750e18)
            if (X_NODE_1 == X_NODE_0) return P_NODE_0;
            uint256 deltaX = x_int - X_NODE_0;
            uint256 segWidth = X_NODE_1 - X_NODE_0;
            uint256 diffP = P_NODE_1 - P_NODE_0;
            return P_NODE_0 + mulDiv(diffP, deltaX, segWidth);
        } else if (x_int < X_NODE_2) {
            // Segment 1: [218750e18, 437500e18)
            if (X_NODE_2 == X_NODE_1) return P_NODE_1;
            uint256 deltaX = x_int - X_NODE_1;
            uint256 segWidth = X_NODE_2 - X_NODE_1;
            uint256 diffP = P_NODE_2 - P_NODE_1;
            return P_NODE_1 + mulDiv(diffP, deltaX, segWidth);
        } else if (x_int < X_NODE_3) {
            // Segment 2: [437500e18, 754896e18)
            if (X_NODE_3 == X_NODE_2) return P_NODE_2;
            uint256 deltaX = x_int - X_NODE_2;
            uint256 segWidth = X_NODE_3 - X_NODE_2;
            uint256 diffP = P_NODE_3 - P_NODE_2;
            return P_NODE_2 + mulDiv(diffP, deltaX, segWidth);
        } else if (x_int < X_NODE_4) {
            // Segment 3: [754896e18, 1000000e18)
            if (X_NODE_4 == X_NODE_3) return P_NODE_3;
            uint256 deltaX = x_int - X_NODE_3;
            uint256 segWidth = X_NODE_4 - X_NODE_3;
            uint256 diffP = P_NODE_4 - P_NODE_3;
            return P_NODE_3 + mulDiv(diffP, deltaX, segWidth);
        } else {
            // At or beyond last node
            return P_NODE_4;
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
            uint256 take;
            uint256 pLeft;
            uint256 pRight;
            
            if (curX < X_NODE_1) {
                // Segment 0
                uint256 avail = X_NODE_1 - curX;
                take = remaining <= avail ? remaining : avail;
                pLeft = priceAt(curX);
                pRight = priceAt(curX + take);
            } else if (curX < X_NODE_2) {
                // Segment 1
                uint256 avail = X_NODE_2 - curX;
                take = remaining <= avail ? remaining : avail;
                pLeft = priceAt(curX);
                pRight = priceAt(curX + take);
            } else if (curX < X_NODE_3) {
                // Segment 2
                uint256 avail = X_NODE_3 - curX;
                take = remaining <= avail ? remaining : avail;
                pLeft = priceAt(curX);
                pRight = priceAt(curX + take);
            } else if (curX < X_NODE_4) {
                // Segment 3
                uint256 avail = X_NODE_4 - curX;
                take = remaining <= avail ? remaining : avail;
                pLeft = priceAt(curX);
                pRight = priceAt(curX + take);
            } else {
                revert("buy exceeds supply");
            }
            
            // Trapezoid cost: (pLeft + pRight) * take / (2 * TOKEN_SCALE)
            uint256 numerator = pLeft + pRight;
            uint256 denom = 2 * TOKEN_SCALE;
            uint256 costAdd = mulDiv(numerator, take, denom);
            
            costWei += costAdd;
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
        require(x_int >= deltaTokens_int, "cannot sell more than current supply");
        
        uint256 remaining = deltaTokens_int;
        uint256 curX = x_int;
        
        while (remaining > 0) {
            uint256 take;
            uint256 pLeft;
            uint256 pRight;
            
            // Find which segment we're in and how much we can sell from this segment
            if (curX > X_NODE_4) {
                // Beyond last segment - shouldn't happen in normal flow
                revert("sell from invalid supply level");
            } else if (curX > X_NODE_3) {
                // Segment 3: selling from (754896e18, 1000000e18]
                uint256 segmentStart = X_NODE_3;
                uint256 availInSegment = curX - segmentStart;
                take = remaining <= availInSegment ? remaining : availInSegment;
                
                pRight = priceAt(curX);
                pLeft = priceAt(curX - take);
            } else if (curX > X_NODE_2) {
                // Segment 2: selling from (437500e18, 754896e18]
                uint256 segmentStart = X_NODE_2;
                uint256 availInSegment = curX - segmentStart;
                take = remaining <= availInSegment ? remaining : availInSegment;
                
                pRight = priceAt(curX);
                pLeft = priceAt(curX - take);
            } else if (curX > X_NODE_1) {
                // Segment 1: selling from (218750e18, 437500e18]
                uint256 segmentStart = X_NODE_1;
                uint256 availInSegment = curX - segmentStart;
                take = remaining <= availInSegment ? remaining : availInSegment;
                
                pRight = priceAt(curX);
                pLeft = priceAt(curX - take);
            } else if (curX > X_NODE_0) {
                // Segment 0: selling from (0, 218750e18]
                uint256 segmentStart = X_NODE_0;
                uint256 availInSegment = curX - segmentStart;
                take = remaining <= availInSegment ? remaining : availInSegment;
                
                pRight = priceAt(curX);
                pLeft = priceAt(curX - take);
            } else {
                // At zero supply - nothing to sell
                revert("cannot sell from zero supply");
            }
            
            // Trapezoid area: (pLeft + pRight) * take / (2 * TOKEN_SCALE)
            uint256 numerator = pLeft + pRight;
            uint256 denom = 2 * TOKEN_SCALE;
            uint256 ethFromSegment = mulDiv(numerator, take, denom);
            
            ethReceived += ethFromSegment;
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
    }
}