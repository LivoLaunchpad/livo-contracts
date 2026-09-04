// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "lib/forge-std/src/Script.sol";
import {console} from "lib/forge-std/src/console.sol";

import {LivoDividendSwapRegistry} from "src/dividends/LivoDividendSwapRegistry.sol";
import {Hop} from "src/interfaces/ILivoDividendSwapRegistry.sol";

/// @notice Writes the curated Uniswap V4 routes produced by `discover_xstock_routes.py` into the
///         `LivoDividendSwapRegistry`, so Robinhood Chain's ~190 xStocks become eligible dividend
///         payout assets. One `setRoute` transaction per asset; re-running it is an update, not a
///         duplicate.
///
/// @dev THE PROBE PICKS THE ROUTE, the discovery script only shortlists. `discover_xstock_routes.py`
///      cannot rank an ETH-quoted pool against a USDG-quoted one — `liquidity` is denominated in each
///      pool's own currencies — and cannot see that a fat 5% pool loses to a thin 0.05% one. So it
///      hands over CANDIDATES, and this script buys the asset through each of them against forked
///      state and keeps whichever delivers most. An asset whose every candidate reverts is reported
///      and skipped rather than broadcast.
///
/// @dev That probing is the whole reason this is a forge script rather than a loop of `cast send`.
///      A route naming the wrong pool does not fail loudly — it fails at some future `processDividends`,
///      on a clone nobody can patch, for a creator who picked that asset in good faith.
///
/// @dev IT IS ALSO THE HEALTH CHECK. Run WITHOUT `--broadcast` and it probes the route each asset is
///      already configured with alongside the fresh candidates, and says which of four things is true:
///      the live route still wins (`ok`), a candidate now beats it (`better`), the live route has
///      stopped working entirely (`BROKEN` — the pool it names was drained or liquidity moved), or the
///      asset has no route yet (`new`). A route is not self-maintaining: nothing on-chain re-checks
///      that the pool it names still has depth, and a rotted one fails every future conversion for
///      every token configured for that asset. This is what catches that.
///
/// @dev Only assets whose chosen route DIFFERS from the live one are broadcast, so re-running costs
///      nothing and adding one asset does not rewrite the other 190.
///
/// @dev The broadcaster must be an admin of the registry (or its owner). Routes are the one admin
///      lever that ADMITS an asset; nothing here can refuse one.
///
/// Usage (dry run):  forge script SetDividendRoutes --rpc-url robinhood-mainnet --account livo.dev
/// Usage (write):    forge script SetDividendRoutes --rpc-url robinhood-mainnet --account livo.dev --slow --broadcast
///
/// Env:
///   DIVIDEND_SWAP_REGISTRY  the registry proxy on this chain
///   ROUTES_JSON             (optional) path to the discovery output. Point it at a narrowed file
///                           (`discover_xstock_routes.py --only SYMBOL -o …`) to add one asset.
contract SetDividendRoutes is Script {
    /// @dev Native spent by the probe swap. Small enough that any pool worth routing through can
    ///      absorb it, large enough that a pool holding dust fails rather than passes.
    uint256 internal constant PROBE_AMOUNT = 0.001 ether;

    string internal constant DEFAULT_ROUTES_JSON = "script/operations/dividend-routes/routes.robinhood.mainnet.json";

    function run() external {
        LivoDividendSwapRegistry registry = LivoDividendSwapRegistry(vm.envAddress("DIVIDEND_SWAP_REGISTRY"));
        string memory json = vm.readFile(vm.envOr("ROUTES_JSON", DEFAULT_ROUTES_JSON));

        address[] memory assets = vm.parseJsonAddressArray(json, ".assets");
        // Pre-encoded `Hop[][]` rather than a JSON object per hop: `parseJson` decodes struct fields in
        // alphabetical order, which silently mismatches `Hop`'s declaration order.
        bytes[] memory encoded = vm.parseJsonBytesArray(json, ".candidates");
        require(assets.length == encoded.length, "assets/candidates length mismatch");

        console.log("=== Set dividend routes ===");
        console.log("Chain ID: %d", block.chainid);
        console.log("Registry: %s", address(registry));
        console.log("Assets:   %d", assets.length);

        Hop[][] memory chosen = _probe(registry, assets, encoded);

        uint256 written;
        uint256 unchanged;
        vm.startBroadcast();
        for (uint256 i; i < assets.length; ++i) {
            if (chosen[i].length == 0) continue;
            if (_sameRoute(chosen[i], registry.routeOf(assets[i]))) {
                ++unchanged;
                continue;
            }
            registry.setRoute(assets[i], chosen[i]);
            ++written;
        }
        vm.stopBroadcast();

        console.log(
            "=== Done: %d written, %d already current, %d unroutable ===",
            written,
            unchanged,
            assets.length - written - unchanged
        );
    }

    /// @dev Buys a little of every asset through every candidate route, all inside the simulation EVM,
    ///      then rolls the whole thing back. Nothing here is broadcast; the return value is the route
    ///      that bought the most of each asset, empty for an asset no candidate could buy at all.
    function _probe(LivoDividendSwapRegistry registry, address[] memory assets, bytes[] memory encoded)
        internal
        returns (Hop[][] memory chosen)
    {
        chosen = new Hop[][](assets.length);
        uint256 snapshot = vm.snapshotState();

        // An admin the registry does not know cannot set a route, so the probe borrows the owner's
        // identity rather than the broadcaster's — the broadcaster's own admin rights are checked for
        // real when the transaction lands.
        address owner = registry.owner();

        for (uint256 i; i < assets.length; ++i) {
            Hop[] memory live = registry.routeOf(assets[i]);
            // The live route is measured on the same footing as the candidates: it is the incumbent,
            // not a given. A route that has stopped working has to lose.
            uint256 liveOut = live.length == 0 ? 0 : _bought(registry, owner, assets[i], live);

            Hop[][] memory candidates = abi.decode(encoded[i], (Hop[][]));
            uint256 best;
            for (uint256 j; j < candidates.length; ++j) {
                uint256 out = _bought(registry, owner, assets[i], candidates[j]);
                if (out > best) {
                    best = out;
                    chosen[i] = candidates[j];
                }
            }

            if (best == 0 && liveOut == 0) {
                if (live.length == 0) console.log("  %s : no candidate route could buy it - skipped", assets[i]);
                else console.log("  %s : BROKEN - its live route AND every candidate fail", assets[i]);
                delete chosen[i];
            } else if (liveOut >= best) {
                // The incumbent still wins. Keeping it verbatim is what makes a re-run a no-op.
                chosen[i] = live;
                console.log("  %s : ok", assets[i]);
            } else if (live.length != 0) {
                console.log("  %s : better route found (live bought %d, new buys %d)", assets[i], liveOut, best);
            }
        }

        vm.revertToState(snapshot);
    }

    /// @dev How much of `asset` one probe-sized buy delivers through `hops`, or 0 if it cannot.
    /// @dev Rolled back before returning, so every candidate for an asset is measured against the same
    ///      pool state — otherwise the first probe would move the price the second one is judged on.
    /// @dev `minOut` of 1: the probe asks whether the pools exist and hold anything, and compares
    ///      candidates against each other. Pricing a real floor is the keeper's job, per conversion.
    function _bought(LivoDividendSwapRegistry registry, address owner, address asset, Hop[] memory hops)
        internal
        returns (uint256 out)
    {
        uint256 snapshot = vm.snapshotState();

        vm.prank(owner);
        registry.setRoute(asset, hops);
        vm.deal(address(this), PROBE_AMOUNT);

        try registry.swapNativeToAsset{value: PROBE_AMOUNT}(asset, 1, address(this)) returns (uint256 bought) {
            out = bought;
        } catch {
            out = 0;
        }

        vm.revertToState(snapshot);
    }

    /// @dev Whether two routes name the same pools in the same order. Compared by encoding rather than
    ///      field by field: `Hop` is fixed-shape, so equal encodings mean equal routes.
    function _sameRoute(Hop[] memory a, Hop[] memory b) internal pure returns (bool) {
        return keccak256(abi.encode(a)) == keccak256(abi.encode(b));
    }

    receive() external payable {}
}
