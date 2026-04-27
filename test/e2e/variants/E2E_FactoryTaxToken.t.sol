// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchpadBaseTests, LaunchpadBaseTestsWithUniv4GraduatorTaxableToken} from "test/launchpad/base.t.sol";
import {ILivoFactory} from "src/interfaces/ILivoFactory.sol";
import {E2EHappyPath} from "test/e2e/suites/E2EHappyPath.t.sol";
import {E2EGraduationFlows} from "test/e2e/suites/E2EGraduationFlows.t.sol";
import {E2ETaxWindow} from "test/e2e/suites/E2ETaxWindow.t.sol";

contract E2E_FactoryTaxToken is
    E2EHappyPath,
    E2EGraduationFlows,
    E2ETaxWindow,
    LaunchpadBaseTestsWithUniv4GraduatorTaxableToken
{
    function setUp() public override(LaunchpadBaseTests, LaunchpadBaseTestsWithUniv4GraduatorTaxableToken) {
        super.setUp();
    }

    function _factory() internal view override returns (address) {
        return address(factoryTax);
    }

    function _tokenImpl() internal view override returns (address) {
        return address(livoTaxToken);
    }

    function _createTestToken(bytes32 salt) internal override returns (address token) {
        vm.prank(creator);
        (token,) =
            factoryTax.createToken("E2E", "E2E", salt, _fs(creator), _noSs(), false, _taxCfg(0, 400, uint32(7 days)));
    }

    function _createTestTokenWithSplit(bytes32 salt, ILivoFactory.FeeShare[] memory feeReceivers)
        internal
        override
        returns (address token, address splitter)
    {
        vm.prank(creator);
        (token, splitter) =
            factoryTax.createToken("E2E", "E2E", salt, feeReceivers, _noSs(), false, _taxCfg(0, 400, uint32(7 days)));
    }

    function _createTokenWithDeployerBuy(bytes32 salt, uint256 ethValue, ILivoFactory.SupplyShare[] memory supplyShares)
        internal
        override
        returns (address token)
    {
        vm.deal(creator, ethValue);
        vm.prank(creator);
        (token,) = factoryTax.createToken{value: ethValue}(
            "E2E", "E2E", salt, _fs(creator), supplyShares, false, _taxCfg(0, 400, uint32(7 days))
        );
    }

    function _isV4Graduator() internal pure override returns (bool) {
        return true;
    }

    function _hasSniperProtection() internal pure override returns (bool) {
        return false;
    }

    function _hasTax() internal pure override returns (bool) {
        return true;
    }

    function _supportsRenounceOwnership() internal pure override returns (bool) {
        return true;
    }
}
