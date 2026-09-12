// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IMintClubBond} from "./interfaces/IMintClubBond.sol";
import {IGlueHookMin} from "./interfaces/IGlueHookMin.sol";
import {ISwapper} from "./interfaces/ISwapper.sol";
import {IFeeSource} from "./interfaces/IFeeSource.sol";
import {IERC20Min, IWETHMin} from "./interfaces/IERC20Min.sol";
import {V4Math} from "./libs/V4Math.sol";

/// @title  RoyaltyRouter
/// @notice Holds two roles for ONE mint.club token and turns its creator royalty into PERMANENT pool depth:
///           • mint.club bond CREATOR — royalties accrue here, pull-only
///           • GlueHook LP program OWNER — the only address that may add to the pool's hook-held position
///         Every {sweep}: claim → keeper bounty + DAO take (in the reserve token) → buy the token side ON THE
///         CURVE with half (its own royalty flows straight back here) → convert the other half to the pool's
///         SECONDARY → mint full-range liquidity into the program position. This contract has no
///         removeProgramLiquidity, transferProgramOwnership, setProgramConfig, or withdraw path, so what it
///         adds can leave only through {reclaim}, and the program's rules are frozen by construction.
///
///         STALE RECOVERY. Liquidity of a DEAD token is not stuck forever. Activity is read straight from the
///         two protocols (pending curve royalties, pool fees the hook harvests) — no oracle, no submission.
///         Every sweep and every {heartbeat} that finds activity stamps `lastActive`. Once STALE_PERIOD has
///         passed with none, the DAO may {initiateReclaim}; a GRACE_PERIOD then runs during which any activity
///         cancels it; only then may the DAO {reclaim} the position — both sides — to the DAO. Every gate
///         re-checks live activity, so a token that traded but was never stamped still cannot be reclaimed.
/// @dev    When the curve is sold out (max supply) the token side cannot be bought; the sweep then falls
///         back to donating the SECONDARY to the pot, the one other place value can go.
contract RoyaltyRouter {
    IMintClubBond public immutable BOND;
    IGlueHookMin public immutable HOOK;
    address public immutable POOL_MANAGER;
    address public immutable TOKEN;
    address public immutable RESERVE; // royalty asset (mint.club reserve token)
    address public immutable SECONDARY; // pool asset paired with TOKEN (address(0) = native)
    address public immutable NATIVEWRAP;
    ISwapper public immutable SWAPPER; // address(0) on the two swap-free routes
    IFeeSource public immutable FEES; // the factory: governed DAO take, read at sweep time
    uint16 public immutable MAX_DAO_BPS; // copied from FEES at birth; the router never pays more
    uint16 public immutable BOUNTY_BPS;
    uint16 public immutable MINT_ROYALTY_BPS; // the curve's mint royalty; sizes the token-side budget
    uint256 public immutable MIN_CLAIM; // in RESERVE units
    uint160 public immutable SQRT_LOWER; // full-range bounds for the pool's tick spacing
    uint160 public immutable SQRT_UPPER;
    uint64 public immutable STALE_PERIOD; // no activity for this long → the DAO may initiate a reclaim
    uint64 public immutable GRACE_PERIOD; // …then this long, during which any activity cancels it

    uint64 public lastActive; // last time a sweep or heartbeat saw curve or pool activity
    uint64 public reclaimAt; // 0 = no reclaim pending; otherwise the earliest time {reclaim} may run

    address private immutable C0;
    address private immutable C1;
    uint24 private immutable FEE;
    int24 private immutable SPACING;
    address private immutable HOOKS;
    bytes32 private immutable POOL_ID;
    bool private _locked;

    event Swept(
        address indexed keeper, uint256 claimed, uint256 bounty, uint256 daoCut, uint256 minted, uint128 liquidity, uint256 donated
    );

    event Heartbeat(bool active);
    event ReclaimInitiated(uint64 reclaimAt);
    event ReclaimCancelled();
    event Reclaimed(address indexed to, uint128 liquidity);

    error BadRoute();
    error BelowMinimum();
    error Reentrancy();
    error TransferFailed();
    error NotDao();
    error NotStale();
    error NoReclaim();
    error GraceNotOver();

    constructor(
        IMintClubBond bond,
        IGlueHookMin hook,
        address poolManager,
        address token,
        IGlueHookMin.PoolKey memory key,
        ISwapper swapper,
        IFeeSource fees,
        uint16 bountyBps,
        uint256 minClaim,
        uint64 stalePeriod,
        uint64 gracePeriod
    ) {
        (, uint16 mintRoyalty,,, address reserve,) = bond.tokenBond(token);
        bytes32 id = keccak256(abi.encode(key));
        IGlueHookMin.Pot memory pot = hook.potOf(id);
        IGlueHookMin.Program memory g = hook.programOf(id);
        if (reserve == address(0) || !pot.configured || pot.main != token || bountyBps > 1_000) revert BadRoute();
        // This contract must already be the program owner: the factory names the predicted address at launch
        if (!g.exists || g.owner != address(this)) revert BadRoute();
        address wrap = hook.NATIVEWRAP();
        bool swapFree = reserve == pot.secondary || (pot.secondary == address(0) && reserve == wrap);
        if (swapFree != (address(swapper) == address(0))) revert BadRoute();
        BOND = bond;
        HOOK = hook;
        POOL_MANAGER = poolManager;
        TOKEN = token;
        RESERVE = reserve;
        SECONDARY = pot.secondary;
        NATIVEWRAP = wrap;
        SWAPPER = swapper;
        FEES = fees;
        MAX_DAO_BPS = fees.MAX_DAO_BPS();
        BOUNTY_BPS = bountyBps;
        MINT_ROYALTY_BPS = mintRoyalty;
        MIN_CLAIM = minClaim;
        C0 = key.currency0;
        C1 = key.currency1;
        FEE = key.fee;
        SPACING = key.tickSpacing;
        HOOKS = key.hooks;
        POOL_ID = id;
        (int24 lo, int24 hi) = V4Math.fullRangeTicks(key.tickSpacing);
        SQRT_LOWER = V4Math.getSqrtPriceAtTick(lo);
        SQRT_UPPER = V4Math.getSqrtPriceAtTick(hi);
        STALE_PERIOD = stalePeriod;
        GRACE_PERIOD = gracePeriod;
        lastActive = uint64(block.timestamp);
    }

    /// @notice Claim royalties, pay the keeper and the DAO, turn the rest into locked liquidity. Anyone.
    /// @param minOut Minimum SECONDARY the swap must return (ignored on swap-free routes).
    function sweep(uint256 minOut) external returns (uint128 liquidity, uint256 bounty, uint256 daoCut) {
        if (_locked) revert Reentrancy();
        _locked = true;
        if (BOND.userTokenRoyaltyBalance(address(this), RESERVE) != 0) BOND.claimRoyalties(RESERVE);
        uint256 claimed = IERC20Min(RESERVE).balanceOf(address(this));
        if (claimed == 0 || claimed < MIN_CLAIM) revert BelowMinimum();

        bounty = (claimed * BOUNTY_BPS) / 10_000;
        (address dao, uint16 daoBps) = FEES.feeInfo();
        if (daoBps > MAX_DAO_BPS) daoBps = MAX_DAO_BPS;
        daoCut = dao == address(0) ? 0 : (claimed * daoBps) / 10_000;
        if (bounty != 0) _call(RESERVE, abi.encodeCall(IERC20Min.transfer, (msg.sender, bounty)));
        if (daoCut != 0) _call(RESERVE, abi.encodeCall(IERC20Min.transfer, (dao, daoCut)));

        // Token side from the curve. The mint pays the curve royalty r on top, and 80% of that royalty comes
        // straight back to this router (mint.club keeps 20%). The budget that leaves equal VALUE on both sides
        // after that refund is  spend = net·(1+r) / (2 + 0.2r).
        uint256 net = claimed - bounty - daoCut;
        uint256 minted = _mintFromCurve((net * (10_000 + MINT_ROYALTY_BPS)) / (20_000 + MINT_ROYALTY_BPS / 5));
        // That mint just credited its royalty back to us. Claim it now so it joins this sweep's secondary side
        // and so a sweep never leaves a self-made "pending" that would read as market activity later.
        if (minted != 0 && BOND.userTokenRoyaltyBalance(address(this), RESERVE) != 0) BOND.claimRoyalties(RESERVE);

        // Secondary side: whatever RESERVE is left, on the route fixed at birth
        uint256 rest = IERC20Min(RESERVE).balanceOf(address(this));
        if (RESERVE != SECONDARY && rest != 0) {
            if (address(SWAPPER) == address(0)) {
                IWETHMin(NATIVEWRAP).withdraw(rest);
            } else {
                _call(RESERVE, abi.encodeCall(IERC20Min.approve, (address(SWAPPER), rest)));
                SWAPPER.swap(RESERVE, SECONDARY, rest, minOut);
            }
        }

        // Pair EVERYTHING held (stray transfers included) into the locked position; leftovers wait here
        liquidity = _addLiquidity();
        uint256 donated;
        if (liquidity == 0 && minted == 0) donated = _donateSecondary(); // curve sold out: fund the pot instead
        _touch(); // a claim IS activity
        emit Swept(msg.sender, claimed, bounty, daoCut, minted, liquidity, donated);
        _locked = false;
    }

    // ─── stale recovery ───────────────────────────────────────────────────────────────────────────

    /// @notice Stamp `lastActive` if the token traded anywhere since the last stamp. Anyone. Also compounds
    ///         pending pool fees as a side effect of the check.
    function heartbeat() external returns (bool active) {
        active = _isActive();
        if (active) _touch();
        emit Heartbeat(active);
    }

    /// @notice DAO only. Allowed once STALE_PERIOD has passed with no stamped activity. If the live check finds
    ///         activity nobody stamped, it stamps it and returns false (a revert would undo the stamp).
    ///         Otherwise starts the grace window.
    function initiateReclaim() external returns (bool started) {
        address dao = _dao();
        if (msg.sender != dao) revert NotDao();
        if (block.timestamp < uint256(lastActive) + STALE_PERIOD) revert NotStale();
        if (_isActive()) { _touch(); return false; }
        reclaimAt = uint64(block.timestamp + GRACE_PERIOD);
        emit ReclaimInitiated(reclaimAt);
        return true;
    }

    /// @notice DAO only, after the grace window, if still no activity: remove the whole position — both sides —
    ///         and every balance held here to the DAO. The router stays creator; a revived token starts over.
    ///         Activity found at this last gate cancels the reclaim and returns 0 instead of reverting.
    function reclaim() external returns (uint128 liquidity) {
        address dao = _dao();
        if (msg.sender != dao) revert NotDao();
        if (reclaimAt == 0) revert NoReclaim();
        if (block.timestamp < reclaimAt) revert GraceNotOver();
        if (_isActive()) { _touch(); return 0; }
        liquidity = HOOK.programOf(POOL_ID).liquidity;
        if (liquidity != 0) HOOK.removeProgramLiquidity(poolKey(), liquidity, dao);
        _sendAll(RESERVE, dao);
        _sendAll(TOKEN, dao);
        if (SECONDARY != address(0)) _sendAll(SECONDARY, dao);
        if (address(this).balance != 0) {
            (bool ok,) = dao.call{value: address(this).balance}("");
            if (!ok) revert TransferFailed();
        }
        reclaimAt = 0;
        lastActive = uint64(block.timestamp);
        emit Reclaimed(dao, liquidity);
    }

    /// @dev Live activity: unclaimed curve royalties, or pool fees the hook has to harvest. Reads only the
    ///      two protocols' own state — nothing is reported from outside.
    function _isActive() private returns (bool) {
        if (BOND.userTokenRoyaltyBalance(address(this), RESERVE) != 0) return true;
        (uint256 m, uint256 sec) = HOOK.harvest(poolKey());
        return (m | sec) != 0;
    }

    function _touch() private {
        lastActive = uint64(block.timestamp);
        if (reclaimAt != 0) { reclaimAt = 0; emit ReclaimCancelled(); }
    }

    function _dao() private view returns (address dao) {
        (dao,) = FEES.feeInfo();
        if (dao == address(0)) revert NotDao();
    }

    function _sendAll(address asset, address to) private {
        uint256 b = IERC20Min(asset).balanceOf(address(this));
        if (b != 0) _call(asset, abi.encodeCall(IERC20Min.transfer, (to, b)));
    }

    /// @notice Royalties a {sweep} would claim right now, plus RESERVE already held here.
    function pending() external view returns (uint256) {
        return BOND.userTokenRoyaltyBalance(address(this), RESERVE) + IERC20Min(RESERVE).balanceOf(address(this));
    }

    function poolKey() public view returns (IGlueHookMin.PoolKey memory) {
        return IGlueHookMin.PoolKey(C0, C1, FEE, SPACING, HOOKS);
    }

    /// @dev Receives unwrapped WETH, native swap output, and the hook's native refunds.
    receive() external payable {}

    // ─── internals ────────────────────────────────────────────────────────────────────────────────

    /// @dev Mint as many tokens as `budget` RESERVE buys on the curve. Never reverts: a sold-out or
    ///      unquotable curve simply mints nothing and the budget stays for the fallback.
    function _mintFromCurve(uint256 budget) private returns (uint256 n) {
        if (budget == 0) return 0;
        uint256 price = BOND.priceForNextMint(TOKEN);
        if (price == 0) return 0;
        n = (budget * 1e18) / price;
        uint256 cost;
        for (uint256 i; i < 4 && n != 0; ++i) {
            (bool ok, bytes memory ret) = address(BOND).staticcall(abi.encodeCall(IMintClubBond.getReserveForToken, (TOKEN, n)));
            if (!ok) { n = n / 2; continue; } // past max supply: try a smaller mint
            (cost,) = abi.decode(ret, (uint256, uint256));
            if (cost <= budget) break;
            n = (n * budget) / cost; // crossed into a pricier step: scale down
            cost = 0;
        }
        if (n == 0 || cost == 0 || cost > budget) return 0;
        _call(RESERVE, abi.encodeCall(IERC20Min.approve, (address(BOND), cost)));
        BOND.mint(TOKEN, n, cost, address(this));
    }

    function _addLiquidity() private returns (uint128 l) {
        uint256 tk = IERC20Min(TOKEN).balanceOf(address(this));
        uint256 sec = SECONDARY == address(0) ? address(this).balance : IERC20Min(SECONDARY).balanceOf(address(this));
        if (tk == 0 || sec == 0) return 0;
        uint160 sqrtP = V4Math.sqrtPriceOf(POOL_MANAGER, POOL_ID);
        (uint256 a0, uint256 a1) = TOKEN == C0 ? (tk, sec) : (sec, tk);
        l = V4Math.liquidityForAmounts(sqrtP, SQRT_LOWER, SQRT_UPPER, a0, a1);
        l -= l / 1_000_000 + 1; // stay a hair under the balances so the PoolManager's round-up never trips
        if (l == 0) return 0;
        _call(TOKEN, abi.encodeCall(IERC20Min.approve, (address(HOOK), tk)));
        if (SECONDARY != address(0)) _call(SECONDARY, abi.encodeCall(IERC20Min.approve, (address(HOOK), sec)));
        HOOK.addProgramLiquidity{value: SECONDARY == address(0) ? sec : 0}(poolKey(), l);
    }

    function _donateSecondary() private returns (uint256 donated) {
        if (SECONDARY == address(0)) {
            uint256 v = address(this).balance;
            if (v != 0) donated = HOOK.donate{value: v}(poolKey(), v);
        } else {
            uint256 b = IERC20Min(SECONDARY).balanceOf(address(this));
            if (b != 0) {
                _call(SECONDARY, abi.encodeCall(IERC20Min.approve, (address(HOOK), b)));
                donated = HOOK.donate(poolKey(), b);
            }
        }
    }

    /// @dev Tolerates tokens that return nothing; reverts on `false` or a failed call.
    function _call(address token, bytes memory data) private {
        (bool ok, bytes memory ret) = token.call(data);
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TransferFailed();
    }
}
