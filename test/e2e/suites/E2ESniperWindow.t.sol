// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LivoE2EBase} from "test/e2e/base/LivoE2EBase.t.sol";
import {SniperProtection, AntiSniperConfigs} from "src/tokens/SniperProtection.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/// @notice E2E suite for sniper-protected variants only. Verifies that the protection window
///         actually blocks oversized buys via the real launchpad path, that whitelisted addresses
///         bypass, that caps lift after the window, and that graduation succeeds during the window
///         (graduator is whitelisted by the variant's default config) and disables sniper checks
///         on subsequent post-graduation swaps.
abstract contract E2ESniperWindow is LivoE2EBase {
    /// @dev Buy size that yields >3% of TOTAL_SUPPLY at curve start (~42M tokens vs 30M cap).
    uint256 internal constant OVERSIZED_BUY = 0.1 ether;
    /// @dev Buy size that yields ~22M tokens at curve start, comfortably under the 3% cap.
    uint256 internal constant CAP_OK_BUY = 0.05 ether;

    function test_e2e_sniper_oversizedBuy_revertsDuringWindow() public {
        bytes32 salt = _nextValidSalt(_factory(), _tokenImpl());
        address token = _createTestToken(salt);

        // Confirm we're inside the window
        SniperProtection sp = SniperProtection(token);
        assertGt(uint256(sp.launchTimestamp()) + uint256(sp.protectionWindowSeconds()), block.timestamp);

        vm.deal(buyer, OVERSIZED_BUY);
        vm.prank(buyer);
        vm.expectRevert(SniperProtection.MaxBuyPerTxExceeded.selector);
        launchpad.buyTokensWithExactEth{value: OVERSIZED_BUY}(token, 0, DEADLINE);
    }

    function test_e2e_sniper_smallBuy_succeedsDuringWindow() public {
        bytes32 salt = _nextValidSalt(_factory(), _tokenImpl());
        address token = _createTestToken(salt);

        _launchpadBuy(token, CAP_OK_BUY);
        assertGt(IERC20(token).balanceOf(buyer), 0);
    }

    function test_e2e_sniper_capsLift_afterWindowExpires() public {
        bytes32 salt = _nextValidSalt(_factory(), _tokenImpl());
        address token = _createTestToken(salt);

        _warpPastSniperWindow(token);

        vm.deal(buyer, OVERSIZED_BUY);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: OVERSIZED_BUY}(token, 0, DEADLINE);
        assertGt(IERC20(token).balanceOf(buyer), 0);
    }

    function test_e2e_sniper_graduation_succeedsDuringWindow() public {
        bytes32 salt = _nextValidSalt(_factory(), _tokenImpl());
        address token = _createTestToken(salt);

        // The default E2E config whitelists both graduators, so the launchpad → graduator transfer
        // (which moves ~21% of supply, far above the 3% cap) bypasses the sniper check.
        // Use many small buys to graduate without hitting the per-tx cap on any single buy.
        SniperProtection sp = SniperProtection(token);
        assertGt(uint256(sp.launchTimestamp()) + uint256(sp.protectionWindowSeconds()), block.timestamp);

        _graduateInSmallBuys(token);

        assertTrue(launchpad.getTokenState(token).graduated);
        // Confirm we're still inside the window when graduation completes
        assertLt(block.timestamp, uint256(sp.launchTimestamp()) + uint256(sp.protectionWindowSeconds()));
    }

    function test_e2e_sniper_postGradSwap_unaffectedByCaps() public {
        bytes32 salt = _nextValidSalt(_factory(), _tokenImpl());
        address token = _createTestToken(salt);
        _graduateInSmallBuys(token);

        // We're still inside the protection window, but `graduated == true` lifts every cap.
        if (_hasTax()) _warpPastTaxWindow(token);

        vm.deal(alice, 2 ether);
        // Spend 2 ETH on a single swap — far above any pre-grad cap. Must succeed because the
        // sniper check no-ops once graduated.
        _swapBuyAuto(alice, token, 2 ether, 0);
        assertGt(IERC20(token).balanceOf(alice), 0);
    }
}
