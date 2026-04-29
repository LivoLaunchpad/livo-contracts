// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchpadBaseTestsWithUniv4GraduatorTaxableToken} from "test/launchpad/base.t.sol";
import {LivoTaxableTokenUniV4} from "src/tokens/LivoTaxableTokenUniV4.sol";
import {LivoFactoryTaxToken} from "src/factories/LivoFactoryTaxToken.sol";
import {ILivoFactory} from "src/interfaces/ILivoFactory.sol";
import {LivoLaunchpad} from "src/LivoLaunchpad.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {Vm} from "forge-std/Vm.sol";
import {Clones} from "lib/openzeppelin-contracts/contracts/proxy/Clones.sol";

contract LivoFactoryTaxTokenDeploymentTest is LaunchpadBaseTestsWithUniv4GraduatorTaxableToken {
    address public deployedToken;

    // ============ Modifiers ============

    modifier withTaxTokenCreated(uint16 sellTaxBps, uint32 taxDuration) {
        vm.prank(creator);
        (deployedToken,) = factoryTax.createToken(
            "TestToken",
            "TEST",
            _nextValidSalt(address(factoryTax), address(livoTaxToken)),
            _fs(creator),
            _noSs(),
            false,
            _taxCfg(0, sellTaxBps, taxDuration)
        );
        _;
    }

    // ============ Tax Validation ============

    /// @dev when sellTaxBps exceeds MAX_TAX_BPS, then createToken reverts with InvalidTaxBps
    function test_createToken_revertsOnSellTaxAboveMax() public {
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(LivoFactoryTaxToken.InvalidTaxBps.selector));
        factoryTax.createToken(
            "TestToken", "TEST", "0x12", _fs(creator), _noSs(), false, _taxCfg(0, 401, uint32(14 days))
        );
    }

    /// @dev when taxDurationSeconds exceeds MAX_SELL_TAX_DURATION_SECONDS, then createToken reverts with InvalidTaxDuration
    function test_createToken_revertsOnTaxDurationAboveMax() public {
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(LivoFactoryTaxToken.InvalidTaxDuration.selector));
        factoryTax.createToken(
            "TestToken", "TEST", "0x12", _fs(creator), _noSs(), false, _taxCfg(0, 400, uint32(14 days + 1))
        );
    }

    /// @dev when sellTaxBps equals MAX_TAX_BPS, then createToken succeeds
    function test_createToken_assertMaxSellTaxAccepted() public withTaxTokenCreated(400, uint32(14 days)) {
        assertTrue(deployedToken != address(0));
    }

    /// @dev when taxDurationSeconds equals MAX_SELL_TAX_DURATION_SECONDS, then createToken succeeds
    function test_createToken_assertMaxTaxDurationAccepted() public withTaxTokenCreated(100, uint32(14 days)) {
        assertTrue(deployedToken != address(0));
    }

    /// @dev when sellTaxBps and taxDuration are zero, then createToken succeeds with no tax
    function test_createToken_assertZeroTaxAccepted() public withTaxTokenCreated(0, 0) {
        assertTrue(deployedToken != address(0));
    }

    /// @dev when renounceOwnership=true, tax token's owner is address(0)
    function test_createToken_renounceOwnership_setsOwnerToZero() public {
        vm.prank(creator);
        (address token,) = factoryTax.createToken(
            "TestToken",
            "TEST",
            _nextValidSalt(address(factoryTax), address(livoTaxToken)),
            _fs(creator),
            _noSs(),
            true,
            _taxCfg(0, 400, uint32(14 days))
        );
        assertEq(LivoTaxableTokenUniV4(payable(token)).owner(), address(0));
    }

    /// @dev when renounceOwnership=false, tax token's owner is msg.sender
    function test_createToken_keepOwnership_setsOwnerToCaller() public {
        vm.prank(creator);
        (address token,) = factoryTax.createToken(
            "TestToken",
            "TEST",
            _nextValidSalt(address(factoryTax), address(livoTaxToken)),
            _fs(creator),
            _noSs(),
            false,
            _taxCfg(0, 400, uint32(14 days))
        );
        assertEq(LivoTaxableTokenUniV4(payable(token)).owner(), creator);
    }

    // ============ Input Validation ============

    /// @dev when name is empty, then createToken reverts with InvalidNameOrSymbol
    function test_createToken_revertsOnEmptyName() public {
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(ILivoFactory.InvalidNameOrSymbol.selector));
        factoryTax.createToken("", "TEST", "0x12", _fs(creator), _noSs(), false, _taxCfg(0, 400, uint32(14 days)));
    }

    /// @dev when symbol is empty, then createToken reverts with InvalidNameOrSymbol
    function test_createToken_revertsOnEmptySymbol() public {
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(ILivoFactory.InvalidNameOrSymbol.selector));
        factoryTax.createToken("TestToken", "", "0x0", _fs(creator), _noSs(), false, _taxCfg(0, 400, uint32(14 days)));
    }

    /// @dev when feeReceiver is zero address, then createToken reverts with InvalidFeeReceiver
    function test_createToken_revertsOnZeroFeeReceiver() public {
        ILivoFactory.FeeShare[] memory zeroFs = new ILivoFactory.FeeShare[](1);
        zeroFs[0] = ILivoFactory.FeeShare({account: address(0), shares: 10_000});

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(ILivoFactory.InvalidFeeReceiver.selector));
        factoryTax.createToken("TestToken", "TEST", "0x12", zeroFs, _noSs(), false, _taxCfg(0, 400, uint32(14 days)));
    }

    /// @dev when feeReceivers array is empty, then createToken reverts with InvalidFeeReceiver
    function test_createToken_revertsOnEmptyFeeReceivers() public {
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(ILivoFactory.InvalidFeeReceiver.selector));
        factoryTax.createToken("TestToken", "TEST", "0x12", _noFs(), _noSs(), false, _taxCfg(0, 400, uint32(14 days)));
    }

    // ============ Vanity Address Validation ============

    /// @dev when salt produces a token address not ending in 0x1110, then createToken reverts with InvalidTokenAddress
    function test_createToken_revertsOnInvalidTokenAddress() public {
        bytes32 badSalt;
        for (uint256 i = 0;; i++) {
            bytes32 salt = bytes32(i);
            address predicted = Clones.predictDeterministicAddress(address(livoTaxToken), salt, address(factoryTax));
            if (uint16(uint160(predicted)) != 0x1110) {
                badSalt = salt;
                break;
            }
        }
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(ILivoFactory.InvalidTokenAddress.selector));
        factoryTax.createToken(
            "TestToken", "TEST", badSalt, _fs(creator), _noSs(), false, _taxCfg(0, 400, uint32(14 days))
        );
    }

    // ============ Events ============

    /// @dev when tax token is created, then LivoTaxableTokenInitialized event is emitted with correct params
    function test_createToken_emitsLivoTaxableTokenInitialized() public {
        vm.expectEmit(true, true, true, true);
        emit LivoTaxableTokenUniV4.LivoTaxableTokenInitialized(0, 400, 14 days);

        vm.prank(creator);
        factoryTax.createToken(
            "TestToken",
            "TEST",
            _nextValidSalt(address(factoryTax), address(livoTaxToken)),
            _fs(creator),
            _noSs(),
            false,
            _taxCfg(0, 400, uint32(14 days))
        );
    }

    /// @dev when tax token is created, then launchpad does not emit the old TokenCreated event
    function test_createToken_launchpadDoesNotEmitTokenCreated() public {
        vm.recordLogs();

        vm.prank(creator);
        factoryTax.createToken(
            "TestToken",
            "TEST",
            _nextValidSalt(address(factoryTax), address(livoTaxToken)),
            _fs(creator),
            _noSs(),
            false,
            _taxCfg(0, 400, uint32(14 days))
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(logs.length > 0);

        bytes32 tokenCreatedSig = keccak256("TokenCreated(address,address,string,string,address,address,address)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != tokenCreatedSig, "TokenCreated should not be emitted by launchpad");
        }
    }
}

contract LivoFactoryTaxTokenWhitelistTest is LaunchpadBaseTestsWithUniv4GraduatorTaxableToken {
    // ============ Modifiers ============

    modifier withBlacklistedFactory() {
        vm.prank(admin);
        launchpad.blacklistFactory(address(factoryTax));
        _;
    }

    // ============ Whitelist / Blacklist Integration ============

    /// @dev when factory is whitelisted, then createToken succeeds
    function test_whitelistedFactory_canCreateToken() public {
        assertTrue(launchpad.whitelistedFactories(address(factoryTax)));

        vm.prank(creator);
        (address token,) = factoryTax.createToken(
            "TestToken",
            "TEST",
            _nextValidSalt(address(factoryTax), address(livoTaxToken)),
            _fs(creator),
            _noSs(),
            false,
            _taxCfg(0, 400, uint32(14 days))
        );
        assertTrue(token != address(0));
    }

    /// @dev when factory is blacklisted, then createToken reverts with UnauthorizedFactory
    function test_blacklistedFactory_cannotCreateToken() public withBlacklistedFactory {
        assertFalse(launchpad.whitelistedFactories(address(factoryTax)));

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(LivoLaunchpad.UnauthorizedFactory.selector));
        factoryTax.createToken(
            "TestToken",
            "TEST",
            _nextValidSalt(address(factoryTax), address(livoTaxToken)),
            _fs(creator),
            _noSs(),
            false,
            _taxCfg(0, 400, uint32(14 days))
        );
    }

    /// @dev when factory is whitelisted then blacklisted, then createToken reverts with UnauthorizedFactory
    function test_whitelistThenBlacklist_cannotCreateToken() public {
        assertTrue(launchpad.whitelistedFactories(address(factoryTax)));

        vm.prank(admin);
        launchpad.blacklistFactory(address(factoryTax));

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(LivoLaunchpad.UnauthorizedFactory.selector));
        factoryTax.createToken(
            "TestToken",
            "TEST",
            _nextValidSalt(address(factoryTax), address(livoTaxToken)),
            _fs(creator),
            _noSs(),
            false,
            _taxCfg(0, 400, uint32(14 days))
        );
    }

    /// @dev when factory is blacklisted then re-whitelisted, then createToken succeeds again
    function test_blacklistThenRewhitelist_canCreateToken() public withBlacklistedFactory {
        vm.prank(admin);
        launchpad.whitelistFactory(address(factoryTax));

        vm.prank(creator);
        (address token,) = factoryTax.createToken(
            "TestToken",
            "TEST",
            _nextValidSalt(address(factoryTax), address(livoTaxToken)),
            _fs(creator),
            _noSs(),
            false,
            _taxCfg(0, 400, uint32(14 days))
        );
        assertTrue(token != address(0));
    }

    /// @dev when non-owner calls whitelistFactory, then it reverts with OwnableUnauthorizedAccount
    function test_nonOwner_cannotWhitelistFactory() public {
        address newFactory = makeAddr("newFactory");

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, creator));
        launchpad.whitelistFactory(newFactory);
    }

    /// @dev when non-owner calls blacklistFactory, then it reverts with OwnableUnauthorizedAccount
    function test_nonOwner_cannotBlacklistFactory() public {
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, creator));
        launchpad.blacklistFactory(address(factoryTax));
    }
}
