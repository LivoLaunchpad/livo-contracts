// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {ILivoFactory} from "src/interfaces/ILivoFactory.sol";

import {LaunchpadBaseTestsWithUniv4Graduator} from "test/launchpad/base.t.sol";
import {LivoFactoryAbstract} from "src/factories/LivoFactoryAbstract.sol";
import {LivoFactoryUniV2Unified} from "src/factories/LivoFactoryUniV2Unified.sol";
import {LivoFactoryUniV4Unified} from "src/factories/LivoFactoryUniV4Unified.sol";
import {ERC1967Proxy} from "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Initializable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";

/// @notice UUPS upgrade-safety tests for the unified factories. Locks in:
///         (1) ownership and immutable-readback semantics across an upgrade,
///         (2) upgrade auth (only owner),
///         (3) initializer is one-shot on the proxy and disabled on the implementation,
///         (4) `createToken` still works after the implementation is swapped out.
contract FactoryUpgradeTests is LaunchpadBaseTestsWithUniv4Graduator {
    function _deployV4ImplWithGraduator(address newGraduator) internal returns (address) {
        return address(
            new LivoFactoryUniV4Unified(
                address(launchpad),
                ILivoFactory.TokenImpls({
                    base: address(livoToken),
                    antiSniper: address(livoTokenSniper),
                    tax: address(livoTaxToken),
                    taxAntiSniper: address(livoTaxTokenSniper)
                }),
                address(bondingCurve),
                newGraduator,
                newGraduator,
                address(feeHandler),
                address(creatorVaultFactory),
                vaultCurves,
                _v4TierConfig()
            )
        );
    }

    function _deployV4ImplSameArgs() internal returns (address) {
        return _deployV4ImplWithGraduator(address(graduatorV4));
    }

    // ───────────── Owner / state preservation ─────────────

    function test_upgrade_preservesOwner() public {
        address before = factoryV4Unified.owner();
        assertEq(before, admin);

        address newImpl = _deployV4ImplSameArgs();
        vm.prank(admin);
        factoryV4Unified.upgradeToAndCall(newImpl, "");

        assertEq(factoryV4Unified.owner(), before);
    }

    function test_upgrade_preservesImmutables_whenSameArgs() public {
        address launchpadBefore = address(factoryV4Unified.LAUNCHPAD());
        address graduatorBefore = address(factoryV4Unified.GRADUATOR());
        address feeHandlerBefore = address(factoryV4Unified.MASTER_FEE_HANDLER());
        address tokenImplBefore = factoryV4Unified.TOKEN_IMPL_BASE();

        address newImpl = _deployV4ImplSameArgs();
        vm.prank(admin);
        factoryV4Unified.upgradeToAndCall(newImpl, "");

        assertEq(address(factoryV4Unified.LAUNCHPAD()), launchpadBefore);
        assertEq(address(factoryV4Unified.GRADUATOR()), graduatorBefore);
        assertEq(address(factoryV4Unified.MASTER_FEE_HANDLER()), feeHandlerBefore);
        assertEq(factoryV4Unified.TOKEN_IMPL_BASE(), tokenImplBefore);
    }

    /// @dev Proves the upgrade mechanism actually reroutes reads to the new implementation: a new
    ///      impl deployed with a different `graduator` argument shows up as the new value through
    ///      the proxy.
    function test_upgrade_swapsImmutables_whenDifferentArgs() public {
        address newGraduator = makeAddr("newGraduator");
        address newImpl = _deployV4ImplWithGraduator(newGraduator);

        vm.prank(admin);
        factoryV4Unified.upgradeToAndCall(newImpl, "");

        assertEq(address(factoryV4Unified.GRADUATOR()), newGraduator);
    }

    function test_upgrade_preservesMaxBuyOnDeployBps() public {
        // The constant ships at 1_000 (10%); upgrading to an impl built from the same code keeps it.
        uint256 before = factoryV4Unified.maxBuyOnDeployBps();
        assertEq(before, 1_000);

        address newImpl = _deployV4ImplSameArgs();
        vm.prank(admin);
        factoryV4Unified.upgradeToAndCall(newImpl, "");

        assertEq(factoryV4Unified.maxBuyOnDeployBps(), before);
    }

    // ───────────── Upgrade authorization ─────────────

    function test_upgrade_revertsForNonOwner() public {
        address newImpl = _deployV4ImplSameArgs();
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, creator));
        factoryV4Unified.upgradeToAndCall(newImpl, "");
    }

    // ───────────── Initializer safety ─────────────

    function test_initialize_revertsOnSecondCall() public {
        vm.prank(admin);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        factoryV4Unified.initialize();
    }

    /// @dev `_disableInitializers()` runs in the implementation's constructor, so calling
    ///      `initialize()` directly on the implementation must revert. Otherwise an attacker
    ///      could claim ownership of the implementation contract and (with `selfdestruct` /
    ///      `delegatecall` shenanigans) cause mischief.
    function test_implementationInitializeReverts() public {
        address impl = _deployV4ImplSameArgs();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        LivoFactoryUniV4Unified(impl).initialize();
    }

    // ───────────── End-to-end after upgrade ─────────────

    function test_createToken_worksAfterUpgrade() public {
        address newImpl = _deployV4ImplSameArgs();
        vm.prank(admin);
        factoryV4Unified.upgradeToAndCall(newImpl, "");

        bytes32 salt = _nextValidSalt(address(factoryV4Unified), address(livoToken));
        vm.prank(creator);
        address token = factoryV4Unified.createToken(
            "Upgraded", "UPG", salt, _fs(creator), _noSs(), false, _emptyTaxCfg(), _emptyAntiSniperCfg()
        );
        assertTrue(token != address(0));
    }
}
