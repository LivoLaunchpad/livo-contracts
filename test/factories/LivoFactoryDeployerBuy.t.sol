// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {
    LaunchpadBaseTestsWithUniv2Graduator,
    LaunchpadBaseTestsWithUniv4GraduatorTaxableToken
} from "test/launchpad/base.t.sol";
import {LivoToken} from "src/tokens/LivoToken.sol";
import {LivoTaxableTokenUniV4} from "src/tokens/LivoTaxableTokenUniV4.sol";
import {TokenState} from "src/types/tokenData.sol";
import {ILivoFactory} from "src/interfaces/ILivoFactory.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {LivoLaunchpad} from "src/LivoLaunchpad.sol";
import {LivoFactoryTaxToken} from "src/factories/LivoFactoryTaxToken.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";

contract LivoFactoryBaseDeployerBuyTest is LaunchpadBaseTestsWithUniv2Graduator {
    // ============ Happy Path ============

    /// @dev deployer can buy tokens with ETH during createToken
    function test_createToken_deployerBuy() public {
        uint256 ethToSpend = 0.1 ether;
        bytes32 salt = _nextValidSalt(address(factoryV2), address(livoToken));

        vm.prank(creator);
        address token = factoryV2.createToken{value: ethToSpend}("TestToken", "TEST", creator, salt);

        // deployer received tokens
        uint256 creatorBalance = LivoToken(token).balanceOf(creator);
        assertGt(creatorBalance, 0);
        assertLe(creatorBalance, TOTAL_SUPPLY * 1_000 / 10_000); // <= 10%

        // factory holds no tokens
        assertEq(LivoToken(token).balanceOf(address(factoryV2)), 0);

        // launchpad state is consistent
        TokenState memory state = launchpad.getTokenState(token);
        assertGt(state.ethCollected, 0);
        assertEq(state.releasedSupply, creatorBalance);
    }

    /// @dev deployer can buy tokens with ETH during createTokenWithFeeSplit
    function test_createTokenWithFeeSplit_deployerBuy() public {
        uint256 ethToSpend = 0.1 ether;
        bytes32 salt = _nextValidSalt(address(factoryV2), address(livoToken));

        address[] memory recipients = new address[](1);
        recipients[0] = creator;
        uint256[] memory shares = new uint256[](1);
        shares[0] = 10_000;

        vm.prank(creator);
        (address token,) =
            factoryV2.createTokenWithFeeSplit{value: ethToSpend}("TestToken", "TEST", recipients, shares, salt);

        uint256 creatorBalance = LivoToken(token).balanceOf(creator);
        assertGt(creatorBalance, 0);
        assertLe(creatorBalance, TOTAL_SUPPLY * 1_000 / 10_000);
        assertEq(LivoToken(token).balanceOf(address(factoryV2)), 0);
    }

    /// @dev createToken with msg.value=0 still works (backward compatible)
    function test_createToken_noEth_backwardCompatible() public {
        bytes32 salt = _nextValidSalt(address(factoryV2), address(livoToken));

        vm.prank(creator);
        address token = factoryV2.createToken("TestToken", "TEST", creator, salt);

        assertEq(LivoToken(token).balanceOf(creator), 0);
        assertEq(LivoToken(token).balanceOf(address(launchpad)), TOTAL_SUPPLY);
    }

    // ============ Cap Enforcement ============

    /// @dev reverts when ETH would buy more than 10% of supply
    function test_createToken_revertsWhenExceedingMaxBuy() public {
        // 1 ether should buy way more than 10% at the start of the curve
        bytes32 salt = _nextValidSalt(address(factoryV2), address(livoToken));

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(ILivoFactory.InvalidDeployerBuy.selector));
        factoryV2.createToken{value: 1 ether}("TestToken", "TEST", creator, salt);
    }

    // ============ Events ============

    /// @dev DeployerBuy event is emitted with correct params
    function test_createToken_emitsDeployerBuyEvent() public {
        uint256 ethToSpend = 0.05 ether;
        bytes32 salt = _nextValidSalt(address(factoryV2), address(livoToken));

        vm.prank(creator);
        vm.expectEmit(false, true, false, false);
        emit ILivoFactory.DeployerBuy(address(0), creator, 0, 0); // only check buyer indexed param
        factoryV2.createToken{value: ethToSpend}("TestToken", "TEST", creator, salt);
    }

    // ============ Admin: setMaxDeployerBuyBps ============

    /// @dev owner can update maxDeployerBuyBps
    function test_setMaxDeployerBuyBps() public {
        vm.prank(admin);
        factoryV2.setMaxDeployerBuyBps(500); // 5%
        assertEq(factoryV2.maxDeployerBuyBps(), 500);
    }

    /// @dev non-owner cannot update maxDeployerBuyBps
    function test_setMaxDeployerBuyBps_revertsForNonOwner() public {
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, creator));
        factoryV2.setMaxDeployerBuyBps(500);
    }

    /// @dev setting maxDeployerBuyBps to 0 disables deployer buy
    function test_createToken_revertsWhenMaxBuyIsZero() public {
        vm.prank(admin);
        factoryV2.setMaxDeployerBuyBps(0);

        bytes32 salt = _nextValidSalt(address(factoryV2), address(livoToken));

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(ILivoFactory.InvalidDeployerBuy.selector));
        factoryV2.createToken{value: 0.01 ether}("TestToken", "TEST", creator, salt);
    }

    /// @dev MaxDeployerBuyBpsUpdated event is emitted
    function test_setMaxDeployerBuyBps_emitsEvent() public {
        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit ILivoFactory.MaxDeployerBuyBpsUpdated(500);
        factoryV2.setMaxDeployerBuyBps(500);
    }

    // ============ quoteDeployerBuy ============

    /// @dev quoteDeployerBuy returns correct ETH that yields exactly tokenAmount
    function test_quoteDeployerBuy_roundTrip() public {
        uint256 tokenAmount = 50_000_000e18; // 5% of supply
        uint256 totalEthNeeded = factoryV2.quoteDeployerBuy(tokenAmount);

        bytes32 salt = _nextValidSalt(address(factoryV2), address(livoToken));

        vm.prank(creator);
        address token = factoryV2.createToken{value: totalEthNeeded}("TestToken", "TEST", creator, salt);

        uint256 creatorBalance = LivoToken(token).balanceOf(creator);
        assertGe(creatorBalance, tokenAmount);
    }

    /// @dev quoteDeployerBuy at max allowed tokens does not revert on createToken
    function test_quoteDeployerBuy_maxAllowedTokens_doesNotRevert() public {
        uint256 maxTokens = TOTAL_SUPPLY * factoryV2.maxDeployerBuyBps() / 10_000;
        uint256 totalEthNeeded = factoryV2.quoteDeployerBuy(maxTokens);

        bytes32 salt = _nextValidSalt(address(factoryV2), address(livoToken));

        vm.prank(creator);
        address token = factoryV2.createToken{value: totalEthNeeded}("TestToken", "TEST", creator, salt);

        uint256 creatorBalance = LivoToken(token).balanceOf(creator);
        assertGe(creatorBalance, maxTokens);
    }
}

contract LivoFactoryTaxTokenDeployerBuyTest is LaunchpadBaseTestsWithUniv4GraduatorTaxableToken {
    // ============ Happy Path ============

    /// @dev deployer can buy tokens with ETH during createToken
    function test_createToken_deployerBuy() public {
        uint256 ethToSpend = 0.1 ether;
        bytes32 salt = _nextValidSalt(address(factoryTax), address(livoTaxToken));

        vm.prank(creator);
        address token =
            factoryTax.createToken{value: ethToSpend}("TestToken", "TEST", creator, salt, 0, 500, uint32(14 days));

        uint256 creatorBalance = LivoTaxableTokenUniV4(payable(token)).balanceOf(creator);
        assertGt(creatorBalance, 0);
        assertLe(creatorBalance, TOTAL_SUPPLY * 1_000 / 10_000);
        assertEq(LivoTaxableTokenUniV4(payable(token)).balanceOf(address(factoryTax)), 0);
    }

    /// @dev createToken with msg.value=0 still works (backward compatible)
    function test_createToken_noEth_backwardCompatible() public {
        bytes32 salt = _nextValidSalt(address(factoryTax), address(livoTaxToken));

        vm.prank(creator);
        address token = factoryTax.createToken("TestToken", "TEST", creator, salt, 0, 500, uint32(14 days));

        assertEq(LivoTaxableTokenUniV4(payable(token)).balanceOf(creator), 0);
    }

    // ============ Cap Enforcement ============

    /// @dev reverts when ETH would buy more than 10% of supply
    function test_createToken_revertsWhenExceedingMaxBuy() public {
        bytes32 salt = _nextValidSalt(address(factoryTax), address(livoTaxToken));

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(ILivoFactory.InvalidDeployerBuy.selector));
        factoryTax.createToken{value: 1 ether}("TestToken", "TEST", creator, salt, 0, 500, uint32(14 days));
    }

    // ============ Admin: setMaxDeployerBuyBps ============

    /// @dev owner can update maxDeployerBuyBps
    function test_setMaxDeployerBuyBps() public {
        vm.prank(admin);
        factoryTax.setMaxDeployerBuyBps(500);
        assertEq(factoryTax.maxDeployerBuyBps(), 500);
    }

    /// @dev non-owner cannot update maxDeployerBuyBps
    function test_setMaxDeployerBuyBps_revertsForNonOwner() public {
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, creator));
        factoryTax.setMaxDeployerBuyBps(500);
    }

    // ============ quoteDeployerBuy ============

    /// @dev quoteDeployerBuy returns correct ETH that yields exactly tokenAmount
    function test_quoteDeployerBuy_roundTrip() public {
        uint256 tokenAmount = 50_000_000e18; // 5% of supply
        uint256 totalEthNeeded = factoryTax.quoteDeployerBuy(tokenAmount);

        bytes32 salt = _nextValidSalt(address(factoryTax), address(livoTaxToken));

        vm.prank(creator);
        address token =
            factoryTax.createToken{value: totalEthNeeded}("TestToken", "TEST", creator, salt, 0, 500, uint32(14 days));

        uint256 creatorBalance = LivoTaxableTokenUniV4(payable(token)).balanceOf(creator);
        assertGe(creatorBalance, tokenAmount);
    }

    /// @dev quoteDeployerBuy at max allowed tokens does not revert on createToken
    function test_quoteDeployerBuy_maxAllowedTokens_doesNotRevert() public {
        uint256 maxTokens = TOTAL_SUPPLY * factoryTax.maxDeployerBuyBps() / 10_000;
        uint256 totalEthNeeded = factoryTax.quoteDeployerBuy(maxTokens);

        bytes32 salt = _nextValidSalt(address(factoryTax), address(livoTaxToken));

        vm.prank(creator);
        address token =
            factoryTax.createToken{value: totalEthNeeded}("TestToken", "TEST", creator, salt, 0, 500, uint32(14 days));

        uint256 creatorBalance = LivoTaxableTokenUniV4(payable(token)).balanceOf(creator);
        assertGe(creatorBalance, maxTokens);
    }
}
