// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {FullHappyPathMatrix} from "test/integration/fork/suites/FullHappyPathMatrix.t.sol";
import {ForkIntegrationCaseLib} from "test/integration/fork/base/ForkIntegrationCaseLib.t.sol";

/// @notice Sepolia entrypoint for the chain-neutral full happy-path fork matrix.
contract SepoliaFullHappyPathMatrix is FullHappyPathMatrix {
    function _chainConfig() internal view override returns (ForkIntegrationCaseLib.ForkChainConfig memory) {
        return _sepoliaConfig();
    }
}
