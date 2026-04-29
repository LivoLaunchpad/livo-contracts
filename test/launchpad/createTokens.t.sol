// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {
    LaunchpadBaseTestsWithUniv2Graduator,
    LaunchpadBaseTestsWithUniv4Graduator,
    LaunchpadBaseTestsWithUniv4GraduatorTaxableToken
} from "./base.t.sol";
import {LivoLaunchpad} from "src/LivoLaunchpad.sol";
import {LivoToken} from "src/tokens/LivoToken.sol";
import {TokenConfig, TokenState} from "src/types/tokenData.sol";
import {LivoTaxableTokenUniV4} from "src/tokens/LivoTaxableTokenUniV4.sol";
import {Vm} from "forge-std/Vm.sol";
import {LivoFactoryUniV2} from "src/factories/LivoFactoryUniV2.sol";
import {LivoFactoryTaxToken} from "src/factories/LivoFactoryTaxToken.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {ILivoFactory} from "src/interfaces/ILivoFactory.sol";

contract LivoTokenDeploymentTest is LaunchpadBaseTestsWithUniv2Graduator {
    function testDeployLivoToken_happyPath() public {
        vm.prank(creator);
        (address deployedToken,) = factoryV2.createToken(
            "TestToken", "TEST", _nextValidSalt(address(factoryV2), address(livoToken)), _fs(creator), _noSs()
        );

        assertTrue(deployedToken != address(0));

        LivoToken token = LivoToken(deployedToken);
        assertEq(token.name(), "TestToken");
        assertEq(token.symbol(), "TEST");
        assertEq(token.totalSupply(), TOTAL_SUPPLY);
        assertEq(token.balanceOf(address(launchpad)), TOTAL_SUPPLY);
        assertEq(token.graduator(), address(graduatorV2));

        TokenConfig memory config = launchpad.getTokenConfig(deployedToken);
        assertEq(address(config.bondingCurve), address(bondingCurve));
        assertEq(token.owner(), address(0));
        assertApproxEqRel(config.bondingCurve.getGraduationConfig().ethGraduationThreshold, GRADUATION_THRESHOLD, 1e10);

        TokenState memory state = launchpad.getTokenState(deployedToken);
        assertEq(state.ethCollected, 0);
        assertEq(state.graduated, false);

        assertEq(token.balanceOf(address(launchpad)), token.totalSupply());
    }

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

    function testTokenCreatedHasDifferentAddressThanImplementation() public {
        vm.prank(creator);
        (address deployedToken,) = factoryV2.createToken(
            "Sanitator", "SANIT", _nextValidSalt(address(factoryV2), address(livoToken)), _fs(creator), _noSs()
        );

        assertTrue(deployedToken != address(0));
        assertTrue(deployedToken != address(livoToken));
    }

    function testCannotCreateTokenWithEmptyName() public {
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(ILivoFactory.InvalidNameOrSymbol.selector));
        factoryV2.createToken("", "TEST", "0x12", _fs(creator), _noSs());
    }

    function testCannotCreateTokenWithEmptySymbol() public {
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(ILivoFactory.InvalidNameOrSymbol.selector));
        factoryV2.createToken("TestToken", "", "0x0", _fs(creator), _noSs());
    }

    function testCannotCreateTokenWithWrongEnding() public {
        bytes32 correctSalt = _nextValidSalt(address(factoryV2), address(livoToken));

        vm.startPrank(creator);
        vm.expectRevert(abi.encodeWithSelector(ILivoFactory.InvalidTokenAddress.selector));
        factoryV2.createToken("TestToken1", "TEST", bytes32(uint256(correctSalt) + 1), _fs(creator), _noSs());

        // with correct salt it should succeed
        factoryV2.createToken("TestToken1", "TEST", correctSalt, _fs(creator), _noSs());
        vm.stopPrank();
    }

    function testCanCreateTokenWithDuplicateSymbol() public {
        vm.prank(creator);
        (address token1,) = factoryV2.createToken(
            "TestToken1", "TEST", _nextValidSalt(address(factoryV2), address(livoToken)), _fs(creator), _noSs()
        );

        vm.prank(creator);
        (address token2,) = factoryV2.createToken(
            "TestToken2", "TEST", _nextValidSalt(address(factoryV2), address(livoToken)), _fs(creator), _noSs()
        );

        assertTrue(token1 != address(0));
        assertTrue(token2 != address(0));
        assertTrue(token1 != token2);

        assertEq(LivoToken(token1).symbol(), "TEST");
        assertEq(LivoToken(token2).symbol(), "TEST");
        assertEq(LivoToken(token1).name(), "TestToken1");
        assertEq(LivoToken(token2).name(), "TestToken2");
    }

    function testCanCreateTokensWithDifferentSymbols() public {
        vm.prank(creator);
        (address token1,) = factoryV2.createToken(
            "TestToken1", "TEST1", _nextValidSalt(address(factoryV2), address(livoToken)), _fs(creator), _noSs()
        );

        vm.prank(creator);
        (address token2,) = factoryV2.createToken(
            "TestToken2", "TEST2", _nextValidSalt(address(factoryV2), address(livoToken)), _fs(creator), _noSs()
        );

        assertTrue(token1 != address(0));
        assertTrue(token2 != address(0));
        assertTrue(token1 != token2);

        assertEq(LivoToken(token1).symbol(), "TEST1");
        assertEq(LivoToken(token2).symbol(), "TEST2");
    }

    function test_cantCreateTokenWithTooLongSymbol() public {
        string memory longSymbol = "TESTTESTTESTTESTTESTTESTTESTESESD";
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(ILivoFactory.InvalidNameOrSymbol.selector));
        factoryV2.createToken("TestToken", longSymbol, "0x12", _fs(creator), _noSs());
    }
}

contract LivoTokenV4DeploymentTest is LaunchpadBaseTestsWithUniv4Graduator {
    /// @dev when feeReceiver is zero address, then createToken reverts with InvalidFeeReceiver
    function test_createToken_v4_revertsOnZeroFeeReceiver() public {
        ILivoFactory.FeeShare[] memory zeroFs = new ILivoFactory.FeeShare[](1);
        zeroFs[0] = ILivoFactory.FeeShare({account: address(0), shares: 10_000});

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(ILivoFactory.InvalidFeeReceiver.selector));
        factoryV4.createToken("TestToken", "TEST", "0x12", zeroFs, _noSs(), false);
    }

    function test_createToken_v4_happyPath() public {
        vm.prank(creator);
        (address deployedToken,) = factoryV4.createToken(
            "TestToken", "TEST", _nextValidSalt(address(factoryV4), address(livoToken)), _fs(creator), _noSs(), false
        );

        assertTrue(deployedToken != address(0));

        LivoToken token = LivoToken(deployedToken);
        assertEq(token.name(), "TestToken");
        assertEq(token.symbol(), "TEST");
        assertEq(token.totalSupply(), TOTAL_SUPPLY);
        assertEq(token.balanceOf(address(launchpad)), TOTAL_SUPPLY);
        assertEq(token.graduator(), address(graduatorV4));
        assertEq(token.owner(), creator);

        TokenConfig memory config = launchpad.getTokenConfig(deployedToken);
        assertEq(address(config.bondingCurve), address(bondingCurve));
        assertApproxEqRel(config.bondingCurve.getGraduationConfig().ethGraduationThreshold, GRADUATION_THRESHOLD, 1e10);

        TokenState memory state = launchpad.getTokenState(deployedToken);
        assertEq(state.ethCollected, 0);
        assertEq(state.graduated, false);
    }

    /// @dev when renounceOwnership=true, then tokenOwner is set to address(0)
    function test_createToken_v4_renounceOwnership_setsOwnerToZero() public {
        vm.prank(creator);
        (address deployedToken,) = factoryV4.createToken(
            "TestToken", "TEST", _nextValidSalt(address(factoryV4), address(livoToken)), _fs(creator), _noSs(), true
        );
        assertEq(LivoToken(deployedToken).owner(), address(0));
    }

    /// @dev when renounceOwnership=false, then tokenOwner is msg.sender
    function test_createToken_v4_keepOwnership_setsOwnerToCaller() public {
        vm.prank(creator);
        (address deployedToken,) = factoryV4.createToken(
            "TestToken", "TEST", _nextValidSalt(address(factoryV4), address(livoToken)), _fs(creator), _noSs(), false
        );
        assertEq(LivoToken(deployedToken).owner(), creator);
    }
}

contract LivoTaxableTokenValidationTests is LaunchpadBaseTestsWithUniv4GraduatorTaxableToken {
    function test_cannotCreateToken_sellTaxAboveMax() public {
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(LivoFactoryTaxToken.InvalidTaxBps.selector));
        factoryTax.createToken(
            "TestToken", "TEST", "0x12", _fs(creator), _noSs(), false, _taxCfg(0, 401, uint32(14 days))
        );
    }

    function test_cannotCreateToken_taxDurationAboveMax() public {
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(LivoFactoryTaxToken.InvalidTaxDuration.selector));
        factoryTax.createToken(
            "TestToken", "TEST", "0x12", _fs(creator), _noSs(), false, _taxCfg(0, 400, uint32(14 days + 1))
        );
    }
}

contract LivoTaxableTokenEventTests is LaunchpadBaseTestsWithUniv4GraduatorTaxableToken {
    function test_LivoTaxableTokenInitialized_emittedOnCreation() public {
        vm.expectEmit(true, true, true, true);
        emit LivoTaxableTokenUniV4.LivoTaxableTokenInitialized(0, 400, 14 days);

        vm.prank(creator);
        (address deployedToken,) = factoryTax.createToken(
            "TestToken",
            "TEST",
            _nextValidSalt(address(factoryTax), address(livoTaxToken)),
            _fs(creator),
            _noSs(),
            false,
            _taxCfg(0, 400, uint32(14 days))
        );

        assertTrue(deployedToken != address(0));
    }

    function test_LaunchpadDoesNotEmitTokenCreated_eventRemoved() public {
        vm.recordLogs();

        vm.prank(creator);
        (address deployedToken,) = factoryTax.createToken(
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
        bytes32 taxInitSig = keccak256("LivoTaxableTokenInitialized(uint16,uint16,uint40)");

        uint256 tokenCreatedIndex = type(uint256).max;
        uint256 taxInitIndex = type(uint256).max;

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == tokenCreatedSig) {
                tokenCreatedIndex = i;
            } else if (logs[i].topics[0] == taxInitSig) {
                taxInitIndex = i;
            }
        }

        assertTrue(tokenCreatedIndex == type(uint256).max, "TokenCreated should not be emitted by launchpad");
        assertTrue(taxInitIndex != type(uint256).max, "LivoTaxableTokenInitialized event not found");

        assertTrue(deployedToken != address(0));
    }
}
