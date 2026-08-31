// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2Step, Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable2Step.sol";

/// @title SwapRouteRegistry
/// @notice Protocol-curated `asset -> Uniswap-V2 swap path` registry. NOT a whitelist: a consumer that
///         must buy an arbitrary asset on-chain carries its own route, and an entry here OVERRIDES it.
///         An asset with no entry is perfectly usable — it simply uses the route it was configured with.
/// @dev Deliberately domain-agnostic: it knows nothing about the feature that made it necessary. Today
///      the only consumer is the token dividend module (`DividendDistribution._acquireDividendAsset`),
///      which buys a third payout asset with accrued native earnings; anything else needing a curated
///      route can share the same deployment.
/// @dev The reason it exists is REPAIR. Consumers are non-upgradeable clones, so the route they were
///      born with dies with its pool and takes that consumer's buffer with it. A live read here is the
///      only way to point one somewhere alive again. The trade-off is that an admin can change where a
///      swap executes — bounded by the `minOut` every consumer must pass, which is why `minOut` is not
///      optional on the consuming side. Being the exception rather than the rule, most assets never get
///      an entry at all.
/// @dev Two-tier access: the `owner` (a cold multisig) manages `admins`; `admins` (hot keeper keys)
///      manage the routes themselves, which change often enough that owner-only would be operationally
///      painful.
contract SwapRouteRegistry is Ownable2Step {
    /// @notice Addresses allowed to add/replace/remove routes.
    mapping(address admin => bool allowed) public admins;

    /// @notice The swap path for an asset, `path[0]` = the input token, `path[last]` = the asset itself.
    ///         Empty when no route is configured.
    mapping(address asset => address[] path) internal routes;

    /// @notice Emitted when the owner grants or revokes route-management rights.
    event AdminSet(address indexed admin, bool allowed);

    /// @notice Emitted on every route write. An empty `path` means the route was removed.
    event RouteSet(address indexed asset, address[] path);

    error NotRouteAdmin();
    error InvalidRoute();

    constructor(address owner_) Ownable(owner_) {}

    modifier onlyAdmin() {
        require(admins[msg.sender], NotRouteAdmin());
        _;
    }

    /// @notice Grants or revokes route-management rights. Owner only.
    function setAdmin(address admin, bool allowed) external onlyOwner {
        admins[admin] = allowed;
        emit AdminSet(admin, allowed);
    }

    /// @notice Sets (or, with an empty `path`, removes) the swap route for `asset`.
    /// @dev Only two things are checked, both of which would make the route functionally broken rather
    ///      than merely unusual: the path must have at least two hops, and it must actually END at
    ///      `asset` — otherwise a consumer would buy something other than what it asked for. The
    ///      intermediate hops and the input token are the admin's business.
    function setRoute(address asset, address[] calldata path) external onlyAdmin {
        if (path.length != 0) {
            require(path.length >= 2 && path[path.length - 1] == asset, InvalidRoute());
        }
        routes[asset] = path;
        emit RouteSet(asset, path);
    }

    /// @notice The configured swap path for `asset`, or an empty array if there is none.
    function getRoute(address asset) external view returns (address[] memory) {
        return routes[asset];
    }

    /// @notice Whether `asset` has a route configured. Consumers use this at configuration time to
    ///         reject an asset they would not be able to buy later.
    function hasRoute(address asset) external view returns (bool) {
        return routes[asset].length != 0;
    }
}
