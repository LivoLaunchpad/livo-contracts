// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchpadBaseTests} from "test/launchpad/base.t.sol";
import {LivoFactoryUniV4Unified} from "src/factories/LivoFactoryUniV4Unified.sol";
import {LivoToken} from "src/tokens/LivoToken.sol";
import {LivoTokenSniperProtected} from "src/tokens/LivoTokenSniperProtected.sol";
import {LivoTaxableTokenUniV4} from "src/tokens/LivoTaxableTokenUniV4.sol";
import {LivoTaxableTokenUniV4SniperProtected} from "src/tokens/LivoTaxableTokenUniV4SniperProtected.sol";
import {LivoTaxableTokenUniV2} from "src/tokens/LivoTaxableTokenUniV2.sol";
import {LivoTaxableTokenUniV2SniperProtected} from "src/tokens/LivoTaxableTokenUniV2SniperProtected.sol";
import {AntiSniperConfigs} from "src/tokens/SniperProtection.sol";
import {TaxConfigInit} from "src/interfaces/ILivoTaxableToken.sol";
import {ILivoFactory} from "src/interfaces/ILivoFactory.sol";

/// @notice Cross-signature parity tests. The unified factories expose two `createToken` overloads
///         (legacy positional + new struct-based). Both must produce byte-identical token state.
///         The test deploys the same logical token via each overload across a state snapshot/revert
///         and asserts the resulting token address and key fields match exactly.
contract LivoFactoryStructSigParityTests is LaunchpadBaseTests {
    struct TokenSnapshot {
        address token;
        address owner;
        uint16 buyTaxBps;
        uint16 sellTaxBps;
        uint40 taxDurationSeconds;
        uint16 maxBuyPerTxBps;
        uint16 maxWalletBps;
        uint40 protectionWindowSeconds;
    }

    function setUp() public virtual override {
        super.setUp();
    }

    /// @dev V2 parity: both signatures must clone to the same address and write the same config.
    function testFuzz_v2_signaturesProduceIdenticalToken(
        uint16 buyTaxBps,
        uint16 sellTaxBps,
        uint32 taxDurationSeconds,
        uint16 maxBuyPerTxBps,
        uint16 maxWalletBps,
        uint40 protectionWindowSeconds
    ) public {
        (TaxConfigInit memory taxCfg, AntiSniperConfigs memory snipCfg) = _clampConfigs(
            buyTaxBps, sellTaxBps, taxDurationSeconds, maxBuyPerTxBps, maxWalletBps, protectionWindowSeconds, 500
        );

        address impl = factoryV2Unified.previewTokenImplementation(_fs(creator), _noSs(), taxCfg, snipCfg);
        bytes32 salt = _nextValidSalt(address(factoryV2Unified), impl);

        TokenSnapshot memory legacy = _deployV2Legacy(salt, taxCfg, snipCfg);

        TokenSnapshot memory struct_ = _deployV2Struct(salt, taxCfg, snipCfg);

        _assertParity(legacy, struct_);
    }

    /// @dev V4 parity: same as V2 plus the `renounceOwnership` flag and the new `lpFeeBps`
    ///      placeholder. Per the current behaviour, `lpFeeBps` is fixed to 100.
    function testFuzz_v4_signaturesProduceIdenticalToken(
        uint16 buyTaxBps,
        uint16 sellTaxBps,
        uint32 taxDurationSeconds,
        uint16 maxBuyPerTxBps,
        uint16 maxWalletBps,
        uint40 protectionWindowSeconds,
        bool renounceOwnership
    ) public {
        (TaxConfigInit memory taxCfg, AntiSniperConfigs memory snipCfg) = _clampConfigs(
            buyTaxBps, sellTaxBps, taxDurationSeconds, maxBuyPerTxBps, maxWalletBps, protectionWindowSeconds, 400
        );

        address impl = factoryV4Unified.previewTokenImplementation(_fs(creator), _noSs(), taxCfg, snipCfg);
        bytes32 salt = _nextValidSalt(address(factoryV4Unified), impl);

        TokenSnapshot memory legacy = _deployV4Legacy(salt, taxCfg, snipCfg, renounceOwnership);

        TokenSnapshot memory struct_ = _deployV4Struct(salt, taxCfg, snipCfg, renounceOwnership);

        _assertParity(legacy, struct_);
    }

    /// @dev Deploys via the legacy positional V2 overload, snapshots state, then reverts the EVM
    ///      so the next deploy can reuse the salt.
    function _deployV2Legacy(bytes32 salt, TaxConfigInit memory taxCfg, AntiSniperConfigs memory snipCfg)
        internal
        returns (TokenSnapshot memory snap)
    {
        uint256 evmSnap = vm.snapshotState();
        vm.prank(creator);
        address token = factoryV2Unified.createToken("ParityTok", "PT", salt, _fs(creator), _noSs(), taxCfg, snipCfg);
        snap = _readV2(token, taxCfg.taxDurationSeconds != 0, snipCfg.protectionWindowSeconds != 0);
        vm.revertToState(evmSnap);
    }

    /// @dev Deploys via the new struct-based V2 overload.
    function _deployV2Struct(bytes32 salt, TaxConfigInit memory taxCfg, AntiSniperConfigs memory snipCfg)
        internal
        returns (TokenSnapshot memory snap)
    {
        ILivoFactory.TokenSetup memory ts =
            ILivoFactory.TokenSetup({name: "ParityTok", symbol: "PT", salt: salt, feeShares: _fs(creator)});
        vm.prank(creator);
        address token = factoryV2Unified.createToken(ts, taxCfg, _noSs(), snipCfg);
        snap = _readV2(token, taxCfg.taxDurationSeconds != 0, snipCfg.protectionWindowSeconds != 0);
    }

    /// @dev Deploys via the legacy positional V4 overload, snapshots, then reverts so the salt is
    ///      reusable for the struct-based deploy.
    function _deployV4Legacy(
        bytes32 salt,
        TaxConfigInit memory taxCfg,
        AntiSniperConfigs memory snipCfg,
        bool renounceOwnership
    ) internal returns (TokenSnapshot memory snap) {
        uint256 evmSnap = vm.snapshotState();
        vm.prank(creator);
        address token = factoryV4Unified.createToken(
            "ParityTok", "PT", salt, _fs(creator), _noSs(), renounceOwnership, taxCfg, snipCfg
        );
        snap = _readV4(token, taxCfg.taxDurationSeconds != 0, snipCfg.protectionWindowSeconds != 0);
        vm.revertToState(evmSnap);
    }

    /// @dev Deploys via the new struct-based V4 overload. `lpFeeBps` is fixed at 100 (matches the
    ///      hook's hardcoded constant).
    function _deployV4Struct(
        bytes32 salt,
        TaxConfigInit memory taxCfg,
        AntiSniperConfigs memory snipCfg,
        bool renounceOwnership
    ) internal returns (TokenSnapshot memory snap) {
        ILivoFactory.TokenSetup memory ts = ILivoFactory.TokenSetup({
            name: "ParityTok", symbol: "PT", salt: salt, feeShares: _fs(creator)
        });
        LivoFactoryUniV4Unified.UniV4Configs memory v4Cfg =
            LivoFactoryUniV4Unified.UniV4Configs({renounceOwnership: renounceOwnership, lpFeeBps: 100});
        vm.prank(creator);
        address token = factoryV4Unified.createToken(ts, taxCfg, v4Cfg, _noSs(), snipCfg);
        snap = _readV4(token, taxCfg.taxDurationSeconds != 0, snipCfg.protectionWindowSeconds != 0);
    }

    function _assertParity(TokenSnapshot memory a, TokenSnapshot memory b) internal pure {
        assertEq(a.token, b.token, "token address parity");
        assertEq(a.owner, b.owner, "owner parity");
        assertEq(a.buyTaxBps, b.buyTaxBps, "buyTaxBps parity");
        assertEq(a.sellTaxBps, b.sellTaxBps, "sellTaxBps parity");
        assertEq(a.taxDurationSeconds, b.taxDurationSeconds, "taxDurationSeconds parity");
        assertEq(a.maxBuyPerTxBps, b.maxBuyPerTxBps, "maxBuyPerTxBps parity");
        assertEq(a.maxWalletBps, b.maxWalletBps, "maxWalletBps parity");
        assertEq(a.protectionWindowSeconds, b.protectionWindowSeconds, "protectionWindowSeconds parity");
    }

    /// @dev Bound fuzzed inputs to valid ranges and enforce the sentinel invariants
    ///      (`taxDurationSeconds == 0 ⟺ bps == 0`, `protectionWindowSeconds == 0 ⟹ all-zero`).
    ///      `maxTaxBps` differs by venue (V2 = 500, V4 = 400).
    function _clampConfigs(
        uint16 buyTaxBps,
        uint16 sellTaxBps,
        uint32 taxDurationSeconds,
        uint16 maxBuyPerTxBps,
        uint16 maxWalletBps,
        uint40 protectionWindowSeconds,
        uint16 maxTaxBps
    ) internal pure returns (TaxConfigInit memory taxCfg, AntiSniperConfigs memory snipCfg) {
        uint16 boundedBuy = uint16(_clamp(buyTaxBps, 0, maxTaxBps));
        uint16 boundedSell = uint16(_clamp(sellTaxBps, 0, maxTaxBps));
        uint32 boundedTaxDur = uint32(_clamp(taxDurationSeconds, 0, 120 * 365 days));
        if (boundedTaxDur == 0) {
            boundedBuy = 0;
            boundedSell = 0;
        } else if (boundedBuy == 0 && boundedSell == 0) {
            boundedSell = 1;
        }

        // SniperProtection's init enforces [10, 300] bps and [1 minute, 1 day] window when enabled.
        // 50/50 split: half the runs disable sniper protection (sentinel zero), half configure it.
        uint16 boundedMaxBuy;
        uint16 boundedMaxWallet;
        uint40 boundedWindow;
        if (protectionWindowSeconds % 2 == 0) {
            boundedMaxBuy = 0;
            boundedMaxWallet = 0;
            boundedWindow = 0;
        } else {
            boundedMaxWallet = uint16(_clamp(maxWalletBps, 10, 300));
            // SniperProtection also enforces maxBuyPerTxBps <= maxWalletBps
            boundedMaxBuy = uint16(_clamp(maxBuyPerTxBps, 10, boundedMaxWallet));
            boundedWindow = uint40(_clamp(protectionWindowSeconds, 1 minutes, 1 days));
        }

        taxCfg = TaxConfigInit({buyTaxBps: boundedBuy, sellTaxBps: boundedSell, taxDurationSeconds: boundedTaxDur});
        snipCfg = AntiSniperConfigs({
            maxBuyPerTxBps: boundedMaxBuy,
            maxWalletBps: boundedMaxWallet,
            protectionWindowSeconds: boundedWindow,
            whitelist: new address[](0)
        });
    }

    function _clamp(uint256 x, uint256 lo, uint256 hi) internal pure returns (uint256) {
        require(hi >= lo, "_clamp: hi<lo");
        return lo + (x % (hi - lo + 1));
    }

    /// @dev Reads back the dispatched V2 token's fields via the impl-specific concrete cast.
    function _readV2(address token, bool hasTax, bool hasSniper) internal view returns (TokenSnapshot memory snap) {
        snap.token = token;
        if (hasTax && hasSniper) {
            LivoTaxableTokenUniV2SniperProtected t = LivoTaxableTokenUniV2SniperProtected(payable(token));
            snap.owner = t.owner();
            snap.buyTaxBps = t.buyTaxBps();
            snap.sellTaxBps = t.sellTaxBps();
            snap.taxDurationSeconds = t.taxDurationSeconds();
            snap.maxBuyPerTxBps = t.maxBuyPerTxBps();
            snap.maxWalletBps = t.maxWalletBps();
            snap.protectionWindowSeconds = t.protectionWindowSeconds();
        } else if (hasTax) {
            LivoTaxableTokenUniV2 t = LivoTaxableTokenUniV2(payable(token));
            snap.owner = t.owner();
            snap.buyTaxBps = t.buyTaxBps();
            snap.sellTaxBps = t.sellTaxBps();
            snap.taxDurationSeconds = t.taxDurationSeconds();
        } else if (hasSniper) {
            LivoTokenSniperProtected t = LivoTokenSniperProtected(token);
            snap.owner = t.owner();
            snap.maxBuyPerTxBps = t.maxBuyPerTxBps();
            snap.maxWalletBps = t.maxWalletBps();
            snap.protectionWindowSeconds = t.protectionWindowSeconds();
        } else {
            snap.owner = LivoToken(token).owner();
        }
    }

    /// @dev Reads back the dispatched V4 token's fields via the impl-specific concrete cast.
    function _readV4(address token, bool hasTax, bool hasSniper) internal view returns (TokenSnapshot memory snap) {
        snap.token = token;
        if (hasTax && hasSniper) {
            LivoTaxableTokenUniV4SniperProtected t = LivoTaxableTokenUniV4SniperProtected(payable(token));
            snap.owner = t.owner();
            snap.buyTaxBps = t.buyTaxBps();
            snap.sellTaxBps = t.sellTaxBps();
            snap.taxDurationSeconds = t.taxDurationSeconds();
            snap.maxBuyPerTxBps = t.maxBuyPerTxBps();
            snap.maxWalletBps = t.maxWalletBps();
            snap.protectionWindowSeconds = t.protectionWindowSeconds();
        } else if (hasTax) {
            LivoTaxableTokenUniV4 t = LivoTaxableTokenUniV4(payable(token));
            snap.owner = t.owner();
            snap.buyTaxBps = t.buyTaxBps();
            snap.sellTaxBps = t.sellTaxBps();
            snap.taxDurationSeconds = t.taxDurationSeconds();
        } else if (hasSniper) {
            LivoTokenSniperProtected t = LivoTokenSniperProtected(token);
            snap.owner = t.owner();
            snap.maxBuyPerTxBps = t.maxBuyPerTxBps();
            snap.maxWalletBps = t.maxWalletBps();
            snap.protectionWindowSeconds = t.protectionWindowSeconds();
        } else {
            snap.owner = LivoToken(token).owner();
        }
    }
}
