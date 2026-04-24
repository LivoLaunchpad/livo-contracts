// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchpadBaseTestsWithUniv2Graduator} from "test/launchpad/base.t.sol";
import {LivoToken} from "src/tokens/LivoToken.sol";
import {TokenConfig, TokenState} from "src/types/tokenData.sol";
import {ILivoFactory} from "src/interfaces/ILivoFactory.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {LivoLaunchpad} from "src/LivoLaunchpad.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {Clones} from "lib/openzeppelin-contracts/contracts/proxy/Clones.sol";

contract LivoFactoryBaseDeploymentTest is LaunchpadBaseTestsWithUniv2Graduator {
    address public deployedToken;

    // ============ Modifiers ============

    modifier withCreatedToken() {
        vm.prank(creator);
        (deployedToken,) = factoryV2.createToken(
            "TestToken", "TEST", _nextValidSalt(address(factoryV2), address(livoToken)), _fs(creator), _noSs()
        );
        _;
    }

    // ============ Happy Path ============

    /// @dev when factory is whitelisted and params are valid, then token is deployed and registered in launchpad
    function test_createToken_assertTokenDeployedAndRegistered() public withCreatedToken {
        assertTrue(deployedToken != address(0));

        LivoToken token = LivoToken(deployedToken);
        assertEq(token.name(), "TestToken");
        assertEq(token.symbol(), "TEST");
        assertEq(token.totalSupply(), TOTAL_SUPPLY);
        assertEq(token.balanceOf(address(launchpad)), TOTAL_SUPPLY);
        assertEq(token.graduator(), address(graduatorV2));
        assertEq(token.owner(), address(0));

        TokenConfig memory config = launchpad.getTokenConfig(deployedToken);
        assertEq(address(config.bondingCurve), address(bondingCurve));
        assertApproxEqRel(config.bondingCurve.ethGraduationThreshold(), GRADUATION_THRESHOLD, 1e10);

        TokenState memory state = launchpad.getTokenState(deployedToken);
        assertEq(state.ethCollected, 0);
        assertEq(state.graduated, false);
    }

    // ============ Input Validation ============

    /// @dev when name is empty, then createToken reverts with InvalidNameOrSymbol
    function test_createToken_revertsOnEmptyName() public {
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(ILivoFactory.InvalidNameOrSymbol.selector));
        factoryV2.createToken("", "TEST", "0x12", _fs(creator), _noSs());
    }

    /// @dev when symbol is empty, then createToken reverts with InvalidNameOrSymbol
    function test_createToken_revertsOnEmptySymbol() public {
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(ILivoFactory.InvalidNameOrSymbol.selector));
        factoryV2.createToken("TestToken", "", "0x0", _fs(creator), _noSs());
    }

    /// @dev when symbol exceeds 32 bytes, then createToken reverts with InvalidNameOrSymbol
    function test_createToken_revertsOnTooLongSymbol() public {
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(ILivoFactory.InvalidNameOrSymbol.selector));
        factoryV2.createToken("TestToken", "TESTTESTTESTTESTTESTTESTTESTESESD", "0x12", _fs(creator), _noSs());
    }

    /// @dev when implementation is initialized directly, then it reverts with InvalidInitialization
    function test_cannotInitializeImplementation() public {
        LivoToken imp = new LivoToken();
        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        imp.initialize(
            ILivoToken.InitializeParams({
                name: "ImplToken",
                symbol: "IMPL",
                tokenOwner: msg.sender,
                graduator: address(graduatorV2),
                launchpad: address(this),
                feeHandler: address(feeHandler),
                feeReceiver: msg.sender
            })
        );
    }

    /// @dev UniV2 factory requires a non-empty feeReceivers list, same as the V4 factories
    function test_createToken_UniV2_revertsOnEmptyFeeReceivers() public {
        bytes32 salt = _nextValidSalt(address(factoryV2), address(livoToken));
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(ILivoFactory.InvalidFeeReceiver.selector));
        factoryV2.createToken("TestToken", "TEST", salt, _noFs(), _noSs());
    }

    /// @dev UniV2 tokens keep `tokenOwner = address(0)` even with a real fee receiver
    function test_createToken_UniV2_tokenOwnerIsZero() public {
        bytes32 salt = _nextValidSalt(address(factoryV2), address(livoToken));
        vm.prank(creator);
        (address token,) = factoryV2.createToken("TestToken", "TEST", salt, _fs(creator), _noSs());
        assertEq(LivoToken(token).owner(), address(0));
        assertEq(LivoToken(token).feeReceiver(), creator);
    }

    // ============ Clone Uniqueness ============

    /// @dev when two tokens share the same symbol, then both are created with different addresses
    function test_createToken_assertDuplicateSymbolsYieldDifferentAddresses() public {
        vm.prank(creator);
        (address token1,) = factoryV2.createToken(
            "TestToken1", "TEST", _nextValidSalt(address(factoryV2), address(livoToken)), _fs(creator), _noSs()
        );

        vm.prank(creator);
        (address token2,) = factoryV2.createToken(
            "TestToken2", "TEST", _nextValidSalt(address(factoryV2), address(livoToken)), _fs(creator), _noSs()
        );

        assertTrue(token1 != token2);
        assertEq(LivoToken(token1).symbol(), "TEST");
        assertEq(LivoToken(token2).symbol(), "TEST");
        assertEq(LivoToken(token1).name(), "TestToken1");
        assertEq(LivoToken(token2).name(), "TestToken2");
    }

    /// @dev when tokens are created with different symbols, then both succeed with correct metadata
    function test_createToken_assertDifferentSymbolsBothSucceed() public {
        vm.prank(creator);
        (address token1,) = factoryV2.createToken(
            "TestToken1", "TEST1", _nextValidSalt(address(factoryV2), address(livoToken)), _fs(creator), _noSs()
        );

        vm.prank(creator);
        (address token2,) = factoryV2.createToken(
            "TestToken2", "TEST2", _nextValidSalt(address(factoryV2), address(livoToken)), _fs(creator), _noSs()
        );

        assertTrue(token1 != token2);
        assertEq(LivoToken(token1).symbol(), "TEST1");
        assertEq(LivoToken(token2).symbol(), "TEST2");
    }

    /// @dev when token is created, then its address differs from the implementation
    function test_createToken_assertCloneAddressDiffersFromImplementation() public withCreatedToken {
        assertTrue(deployedToken != address(livoToken));
    }

    // ============ Vanity Address Validation ============

    /// @dev when salt produces a token address not ending in 0x1110, then createToken reverts with InvalidTokenAddress
    function test_createToken_revertsOnInvalidTokenAddress() public {
        // Find a salt that does NOT produce a 0x1110-ending address
        bytes32 badSalt;
        for (uint256 i = 0;; i++) {
            bytes32 salt = bytes32(i);
            address predicted = Clones.predictDeterministicAddress(address(livoToken), salt, address(factoryV2));
            if (uint16(uint160(predicted)) != 0x1110) {
                badSalt = salt;
                break;
            }
        }
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(ILivoFactory.InvalidTokenAddress.selector));
        factoryV2.createToken("TestToken", "TEST", badSalt, _fs(creator), _noSs());
    }
}

contract LivoFactoryBaseWhitelistTest is LaunchpadBaseTestsWithUniv2Graduator {
    // ============ Modifiers ============

    modifier withBlacklistedFactory() {
        vm.prank(admin);
        launchpad.blacklistFactory(address(factoryV2));
        _;
    }

    // ============ Whitelist / Blacklist Integration ============

    /// @dev when factory is whitelisted, then createToken succeeds
    function test_whitelistedFactory_canCreateToken() public {
        assertTrue(launchpad.whitelistedFactories(address(factoryV2)));

        vm.prank(creator);
        (address token,) = factoryV2.createToken(
            "TestToken", "TEST", _nextValidSalt(address(factoryV2), address(livoToken)), _fs(creator), _noSs()
        );
        assertTrue(token != address(0));
    }

    /// @dev when factory is whitelisted then blacklisted, then createToken reverts with UnauthorizedFactory
    function test_whitelistThenBlacklist_cannotCreateToken() public withBlacklistedFactory {
        assertFalse(launchpad.whitelistedFactories(address(factoryV2)));

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(LivoLaunchpad.UnauthorizedFactory.selector));
        factoryV2.createToken(
            "TestToken", "TEST", _nextValidSalt(address(factoryV2), address(livoToken)), _fs(creator), _noSs()
        );
    }

    /// @dev when factory is blacklisted then re-whitelisted, then createToken succeeds again
    function test_blacklistThenRewhitelist_canCreateToken() public withBlacklistedFactory {
        vm.prank(admin);
        launchpad.whitelistFactory(address(factoryV2));

        vm.prank(creator);
        (address token,) = factoryV2.createToken(
            "TestToken", "TEST", _nextValidSalt(address(factoryV2), address(livoToken)), _fs(creator), _noSs()
        );
        assertTrue(token != address(0));
    }

    /// @dev when non-owner calls whitelistFactory, then it reverts with OwnableUnauthorizedAccount
    function test_nonOwner_cannotWhitelistFactory() public {
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, creator));
        launchpad.whitelistFactory(address(factoryV2));
    }

    /// @dev when non-owner calls blacklistFactory, then it reverts with OwnableUnauthorizedAccount
    function test_nonOwner_cannotBlacklistFactory() public {
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, creator));
        launchpad.blacklistFactory(address(factoryV2));
    }
}
