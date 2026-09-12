// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IMintClubBond} from "./interfaces/IMintClubBond.sol";
import {IGlueHookMin} from "./interfaces/IGlueHookMin.sol";
import {ISwapper} from "./interfaces/ISwapper.sol";
import {IFeeSource} from "./interfaces/IFeeSource.sol";
import {IERC20Min} from "./interfaces/IERC20Min.sol";
import {RoyaltyRouter} from "./RoyaltyRouter.sol";

/// @title  RoyaltyRouterFactory
/// @notice ONE door and ONE governed knob.
///
///         {launch} — a NEW token, ONE transaction, no prior role calls: creates the mint.club token, points its
///         creator role at the router's predicted address, mints seed from the curve (royalty already flowing
///         to the router), launches the hooked pool with the ROUTER as the LP program's owner and operator,
///         deploys the router, refunds every leftover. The router has no transfer / config path and its only
///         remove path is the dead-token {RoyaltyRouter-reclaim}, so the position is locked while anyone trades; the factory becomes the pot admin
///         and has no `setRecipient` path, so the pot's recipient is frozen too. Every later {RoyaltyRouter-sweep}
///         adds locked full-range liquidity bought half on the curve, half in the pool's secondary.
///
///         The knob: the DAO take every router reads at sweep time — movable by `governance`, never above the
///         immutable `MAX_DAO_BPS`, frozen forever once governance is renounced. Nothing else is adjustable.
contract RoyaltyRouterFactory is IFeeSource {
    IMintClubBond public immutable BOND;
    IGlueHookMin public immutable HOOK;
    address public immutable POOL_MANAGER;
    /// @dev The DAO take, like mint.club's own 20%, but GOVERNED: `governance` may move the recipient and
    ///      the rate for every router at once, never above MAX_DAO_BPS. Renouncing governance freezes both.
    uint16 public immutable MAX_DAO_BPS;
    uint64 public immutable STALE_PERIOD; // see RoyaltyRouter: dead-token recovery gates
    uint64 public immutable GRACE_PERIOD;
    address public governance;
    address public dao;
    uint16 public daoBps;

    event FeeSet(address indexed dao, uint16 daoBps);
    event GovernanceSet(address indexed governance);


    error BadDao();
    error NotGovernance();

    error BadPeriods();

    constructor(
        IMintClubBond bond, IGlueHookMin hook, address poolManager, address governance_, address dao_, uint16 daoBps_, uint16 maxDaoBps,
        uint64 stalePeriod, uint64 gracePeriod
    ) {
        if (maxDaoBps > 5_000) revert BadDao(); // the ceiling itself is capped at 50%, forever
        if (stalePeriod < 90 days || gracePeriod < 7 days) revert BadPeriods(); // recovery is for DEAD tokens only
        STALE_PERIOD = stalePeriod;
        GRACE_PERIOD = gracePeriod;
        BOND = bond;
        HOOK = hook;
        POOL_MANAGER = poolManager;
        MAX_DAO_BPS = maxDaoBps;
        governance = governance_;
        emit GovernanceSet(governance_);
        _setFee(dao_, daoBps_);
    }

    // ─── governance ───────────────────────────────────────────────────────────────────────────────

    /// @notice Move the DAO take. Governance only. Applies to every router from its next sweep.
    function setFee(address dao_, uint16 daoBps_) external {
        if (msg.sender != governance) revert NotGovernance();
        _setFee(dao_, daoBps_);
    }

    /// @notice Hand governance over. `address(0)` renounces: the fee is frozen forever.
    function setGovernance(address governance_) external {
        if (msg.sender != governance) revert NotGovernance();
        governance = governance_;
        emit GovernanceSet(governance_);
    }

    function feeInfo() external view returns (address, uint16) {
        return (dao, daoBps);
    }

    function _setFee(address dao_, uint16 daoBps_) private {
        if (daoBps_ > MAX_DAO_BPS || (daoBps_ != 0 && dao_ == address(0))) revert BadDao();
        dao = dao_;
        daoBps = daoBps_;
        emit FeeSet(dao_, daoBps_);
    }

    // ─── one-click launch ─────────────────────────────────────────────────────────────────────────

    struct Launch {
        // mint.club token + curve
        string name;
        string symbol;
        IMintClubBond.BondParams bond;
        uint128 curveMint; // seed tokens to mint from the curve on top of any free range (0 = none)
        uint256 maxReserveIn; // slippage cap on that mint, in the reserve token, pulled from the caller
        // hooked pool
        address secondary; // pool's other side; address(0) = native
        uint24 fee;
        int24 tickSpacing;
        uint160 sqrtPriceX96; // price the curve currently quotes, as Q64.96 sqrt — computed off-chain
        uint128 liquidity; // full-range seed liquidity units
        uint256 secondarySeed; // ERC20 secondary pulled from the caller for the seed (native: msg.value)
        // LP program (owner = router, buyback = burn = potBurn = potCompound = 0, publicHarvest)
        uint64 compoundShareWad; // share of LP fees re-minted into the position; the rest goes to feeRecipient
        address feeRecipient; // LP-fee remainders on both sides + the pot recipient
        uint256 minMain;
        uint256 minSecondary;
        // router
        address swapper;
        uint16 bountyBps;
        uint256 minClaim;
    }

    event Launched(address indexed token, bytes32 indexed poolId, address router);

    error BadRoute();
    error PredictionMismatch();
    error RefundFailed();

    /// @notice The address {launch} deploys a router at for these constructor inputs.
    function predict(address token, IGlueHookMin.PoolKey memory key, address swapper, uint16 bountyBps, uint256 minClaim)
        public
        view
        returns (address)
    {
        bytes memory args = abi.encode(BOND, HOOK, POOL_MANAGER, token, key, ISwapper(swapper), this, bountyBps, minClaim, STALE_PERIOD, GRACE_PERIOD);
        bytes32 initHash = keccak256(abi.encodePacked(type(RoyaltyRouter).creationCode, args));
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(0), initHash)))));
    }

    /// @notice Create token + pool + router in one call. `msg.value` = mint.club creation fee + native seed
    ///         (when `secondary` is native); the caller must have approved this factory for `maxReserveIn`
    ///         reserve (when `curveMint > 0`) and `secondarySeed` secondary (when ERC20).
    function launch(Launch calldata L) external payable returns (address token, address router) {
        // 1. token; the factory is the creator for exactly two calls
        token = BOND.createToken{value: BOND.creationFee()}(IMintClubBond.TokenParams(L.name, L.symbol), L.bond);
        IGlueHookMin.PoolKey memory key = _key(token, L.secondary, L.fee, L.tickSpacing);
        router = predict(token, key, L.swapper, L.bountyBps, L.minClaim);
        BOND.updateBondCreator(token, router);

        // 2. seed tokens from the curve — its royalty already accrues to the router
        if (L.curveMint != 0) {
            (uint256 cost,) = BOND.getReserveForToken(token, L.curveMint);
            if (cost > L.maxReserveIn) revert BadRoute();
            _pull(L.bond.reserveToken, cost);
            IERC20Min(L.bond.reserveToken).approve(address(BOND), cost);
            BOND.mint(token, L.curveMint, cost, address(this));
        }

        // 3. pool + program owned by the (not yet deployed) router
        IERC20Min(token).approve(address(HOOK), IERC20Min(token).balanceOf(address(this)));
        if (L.secondary != address(0)) {
            _pull(L.secondary, L.secondarySeed);
            IERC20Min(L.secondary).approve(address(HOOK), L.secondarySeed);
        }
        HOOK.launchPool{value: L.secondary == address(0) ? address(this).balance : 0}(
            key, L.sqrtPriceX96, token, L.feeRecipient, 0, 0, L.liquidity, router, _config(L)
        );

        // 4. router at the address the creator role already points to
        address deployed = address(new RoyaltyRouter{salt: bytes32(0)}(
            BOND, HOOK, POOL_MANAGER, token, key, ISwapper(L.swapper), this, L.bountyBps, L.minClaim, STALE_PERIOD, GRACE_PERIOD
        ));
        if (deployed != router) revert PredictionMismatch();

        // 5. nothing stays here
        _refund(token);
        if (L.secondary != address(0)) _refund(L.secondary);
        if (L.curveMint != 0) _refund(L.bond.reserveToken);
        if (address(this).balance != 0) {
            (bool ok,) = msg.sender.call{value: address(this).balance}("");
            if (!ok) revert RefundFailed();
        }
        emit Launched(token, keccak256(abi.encode(key)), router);
    }

    /// @dev Hook refunds of unused native seed land here and are forwarded in {launch}.
    receive() external payable {}

    function _key(address token, address secondary, uint24 fee, int24 spacing)
        private
        view
        returns (IGlueHookMin.PoolKey memory)
    {
        (address c0, address c1) = token < secondary ? (token, secondary) : (secondary, token);
        return IGlueHookMin.PoolKey(c0, c1, fee, spacing, address(HOOK));
    }

    function _config(Launch calldata L) private pure returns (IGlueHookMin.ProgramConfig memory c) {
        c.compoundShareWad = L.compoundShareWad;
        c.publicHarvest = true; // a live owner would otherwise gate the manual harvest
        c.secondaryRecipient = L.feeRecipient;
        c.mainRecipient = L.feeRecipient;
        c.minMain = L.minMain;
        c.minSecondary = L.minSecondary;
    }

    function _pull(address asset, uint256 amount) private {
        if (!IERC20Min(asset).transferFrom(msg.sender, address(this), amount)) revert RefundFailed();
    }

    function _refund(address asset) private {
        uint256 bal = IERC20Min(asset).balanceOf(address(this));
        if (bal != 0 && !IERC20Min(asset).transfer(msg.sender, bal)) revert RefundFailed();
    }

}
