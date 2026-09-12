// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./Base.t.sol";

contract ReclaimTest is Base {
    IGlueHookMin.PoolKey k;
    RoyaltyRouter r;
    bytes32 id;

    function setUp() public override {
        super.setUp();
        (k, r) = launchAndRoute(address(weth), address(0), address(0));
        id = hook.idOf(k);
        vm.deal(address(hook), 100 ether); // the mock hook pays removals from its own balance
        bond.accrue(address(token), 10 ether);
        vm.prank(KEEPER);
        r.sweep(0); // position has liquidity; lastActive = now
    }

    // ─── heartbeat ──────────────────────────────────────────────────────────────────────────────

    function test_heartbeat_noActivityDoesNotStamp() public {
        uint64 before = r.lastActive();
        vm.warp(block.timestamp + 10 days);
        assertFalse(r.heartbeat());
        assertEq(r.lastActive(), before);
    }

    function test_heartbeat_poolFeesStamp() public {
        vm.warp(block.timestamp + 10 days);
        hook.setPendingFees(id, 0, 1); // one wei of pool fees = a trade happened
        assertTrue(r.heartbeat());
        assertEq(r.lastActive(), block.timestamp);
        (uint256 m, uint256 s) = hook.harvest(k);
        assertEq(m | s, 0, "heartbeat harvested the fees");
    }

    function test_heartbeat_curveRoyaltyStamps() public {
        vm.warp(block.timestamp + 10 days);
        bond.accrue(address(token), 1);
        assertTrue(r.heartbeat());
        assertEq(r.lastActive(), block.timestamp);
    }

    // ─── initiate ───────────────────────────────────────────────────────────────────────────────

    function test_initiate_onlyDao() public {
        vm.warp(block.timestamp + STALE + 1);
        vm.expectRevert(RoyaltyRouter.NotDao.selector);
        r.initiateReclaim();
    }

    function test_initiate_revertsBeforeStale() public {
        vm.warp(block.timestamp + STALE - 1);
        vm.prank(DAO);
        vm.expectRevert(RoyaltyRouter.NotStale.selector);
        r.initiateReclaim();
    }

    function test_initiate_revertsAndStampsIfTradedButNeverStamped() public {
        vm.warp(block.timestamp + STALE + 1);
        hook.setPendingFees(id, 5, 0); // traded on the pool, nobody called heartbeat
        vm.prank(DAO);
        assertFalse(r.initiateReclaim(), "activity found: not started");
        assertEq(r.lastActive(), block.timestamp, "...but stamped");
        assertEq(r.reclaimAt(), 0);
        vm.prank(DAO);
        vm.expectRevert(RoyaltyRouter.NotStale.selector); // the attempt stamped lastActive
        r.initiateReclaim();
    }

    function test_initiate_ok() public {
        vm.warp(block.timestamp + STALE + 1);
        vm.prank(DAO);
        assertTrue(r.initiateReclaim());
        assertEq(r.reclaimAt(), block.timestamp + GRACE);
    }

    // ─── grace window ───────────────────────────────────────────────────────────────────────────

    function test_grace_anyActivityCancels() public {
        vm.warp(block.timestamp + STALE + 1);
        vm.prank(DAO);
        r.initiateReclaim();
        bond.accrue(address(token), 1 ether); // the community trades
        vm.prank(KEEPER);
        r.sweep(0);
        assertEq(r.reclaimAt(), 0, "cancelled by the sweep");
        vm.warp(block.timestamp + GRACE + 1);
        vm.prank(DAO);
        vm.expectRevert(RoyaltyRouter.NoReclaim.selector);
        r.reclaim();
    }

    function test_reclaim_revertsDuringGrace() public {
        vm.warp(block.timestamp + STALE + 1);
        vm.prank(DAO);
        r.initiateReclaim();
        vm.warp(block.timestamp + GRACE - 1);
        vm.prank(DAO);
        vm.expectRevert(RoyaltyRouter.GraceNotOver.selector);
        r.reclaim();
    }

    function test_reclaim_lastMinuteActivityCancels() public {
        vm.warp(block.timestamp + STALE + 1);
        vm.prank(DAO);
        r.initiateReclaim();
        vm.warp(block.timestamp + GRACE + 1);
        hook.setPendingFees(id, 0, 3);
        vm.prank(DAO);
        assertEq(r.reclaim(), 0, "activity at the last gate: nothing removed");
        assertEq(r.reclaimAt(), 0, "...and the reclaim is cancelled");
        assertGt(hook.programOf(id).liquidity, 0);
    }

    // ─── reclaim ────────────────────────────────────────────────────────────────────────────────

    function test_reclaim_bothSidesAndLeftoversToDao() public {
        uint128 liq = hook.programOf(id).liquidity;
        assertGt(liq, 0);
        vm.deal(address(r), 0.1 ether); // stray leftovers in the router
        token.mint(address(r), 7 ether);
        vm.warp(block.timestamp + STALE + 1);
        vm.prank(DAO);
        r.initiateReclaim();
        vm.warp(block.timestamp + GRACE + 1);
        uint256 daoEth = DAO.balance;
        vm.prank(DAO);
        uint128 removed = r.reclaim();
        assertEq(removed, liq);
        assertEq(hook.programOf(id).liquidity, 0, "position emptied");
        assertGt(DAO.balance - daoEth, 0.1 ether, "ETH side + router leftover to the DAO");
        assertGt(token.balanceOf(DAO), 7 ether, "token side + router leftover to the DAO");
        assertEq(address(r).balance, 0);
        assertEq(token.balanceOf(address(r)), 0);
        assertEq(r.reclaimAt(), 0);
        // a revived token simply starts over: the router is still creator and owner
        bond.accrue(address(token), 10 ether);
        vm.prank(KEEPER);
        (uint128 added,,) = r.sweep(0);
        assertGt(added, 0);
    }

    function test_reclaim_onlyDao() public {
        vm.warp(block.timestamp + STALE + 1);
        vm.prank(DAO);
        r.initiateReclaim();
        vm.warp(block.timestamp + GRACE + 1);
        vm.expectRevert(RoyaltyRouter.NotDao.selector);
        r.reclaim();
    }
}
