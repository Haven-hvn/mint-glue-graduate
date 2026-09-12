// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./Base.t.sol";
import {ReentrantSwapper} from "./mocks/Mocks.sol";
import {IFeeSource} from "../src/interfaces/IFeeSource.sol";

contract RoyaltyRouterTest is Base {
    // ─── route: RESERVE == SECONDARY (ERC20) ────────────────────────────────────────────────────

    function test_direct_splitsMintsAndLocksLiquidity() public {
        (IGlueHookMin.PoolKey memory k, RoyaltyRouter r) = launchAndRoute(address(hunt), address(hunt), address(0));
        bond.accrue(address(token), 10 ether); // creator share = 8 HUNT
        assertEq(r.pending(), 8 ether);
        uint128 lBefore = hook.programOf(hook.idOf(k)).liquidity;

        vm.prank(KEEPER);
        (uint128 liquidity, uint256 bounty, uint256 daoCut) = r.sweep(0);

        assertEq(bounty, 0.04 ether);
        assertEq(daoCut, 0.8 ether);
        assertEq(hunt.balanceOf(KEEPER), bounty);
        assertEq(hunt.balanceOf(DAO), daoCut);
        assertGt(liquidity, 0);
        assertEq(hook.programOf(hook.idOf(k)).liquidity, lBefore + liquidity, "position grew by exactly what was added");
        // half bought tokens on the curve at 0.001 (+3% royalty), the rest paired; only rounding dust may remain
        uint256 net = 8 ether - bounty - daoCut;
        assertLt(hunt.balanceOf(address(r)), net / 1000, "secondary dust only");
        assertLt(token.balanceOf(address(r)), 4 ether, "token dust only");
        assertEq(bond.userTokenRoyaltyBalance(address(r), address(hunt)), 0, "the curve mint's royalty was claimed into the same sweep");
        assertEq(hook.potOf(hook.idOf(k)).balance, 0, "nothing goes to the pot while the curve has supply");
    }

    function test_direct_strayFundsAreLockedToo() public {
        (IGlueHookMin.PoolKey memory k, RoyaltyRouter r) = launchAndRoute(address(hunt), address(hunt), address(0));
        bond.accrue(address(token), 1 ether);
        hunt.mint(address(r), 5 ether); // stray secondary
        token.mint(address(r), 1000 ether); // stray tokens
        uint128 lBefore = hook.programOf(hook.idOf(k)).liquidity;
        vm.prank(KEEPER);
        (uint128 liquidity,,) = r.sweep(0);
        assertGt(liquidity, 0);
        assertEq(hook.programOf(hook.idOf(k)).liquidity, lBefore + liquidity);
    }

    // ─── route: RESERVE == WETH, SECONDARY == native ────────────────────────────────────────────

    function test_unwrap_addsNativeSideLiquidity() public {
        (IGlueHookMin.PoolKey memory k, RoyaltyRouter r) = launchAndRoute(address(weth), address(0), address(0));
        bond.accrue(address(token), 10 ether);
        uint128 lBefore = hook.programOf(hook.idOf(k)).liquidity;
        vm.prank(KEEPER);
        (uint128 liquidity, uint256 bounty,) = r.sweep(0);
        assertGt(liquidity, 0);
        assertEq(hook.programOf(hook.idOf(k)).liquidity, lBefore + liquidity);
        assertEq(weth.balanceOf(KEEPER), bounty);
        assertEq(weth.balanceOf(address(r)), 0, "all WETH unwrapped");
        assertLt(address(r).balance, 0.01 ether, "native dust only");
    }

    // ─── route: swapper ──────────────────────────────────────────────────────────────────────────

    function test_swap_toErc20Secondary() public {
        MockSwapper sw = new MockSwapper(1e18); // 1 WETH -> 1 HUNT (mock)
        (IGlueHookMin.PoolKey memory k, RoyaltyRouter r) = launchAndRoute(address(weth), address(hunt), address(sw));
        bond.accrue(address(token), 1 ether);
        uint128 lBefore = hook.programOf(hook.idOf(k)).liquidity;
        vm.prank(KEEPER);
        (uint128 liquidity,,) = r.sweep(0);
        assertGt(liquidity, 0);
        assertEq(hook.programOf(hook.idOf(k)).liquidity, lBefore + liquidity);
        assertEq(weth.balanceOf(address(r)), 0);
    }

    function test_swap_respectsMinOut() public {
        (, RoyaltyRouter r) = launchAndRoute(address(weth), address(hunt), address(new MockSwapper(1e18)));
        bond.accrue(address(token), 1 ether);
        vm.expectRevert(bytes("slippage"));
        r.sweep(type(uint256).max);
    }

    function test_swap_reentrancyBlocked() public {
        (, RoyaltyRouter r) = launchAndRoute(address(weth), address(hunt), address(new ReentrantSwapper()));
        bond.accrue(address(token), 1 ether);
        vm.expectRevert(RoyaltyRouter.Reentrancy.selector);
        r.sweep(0);
    }

    // ─── curve sold out: fall back to the pot ────────────────────────────────────────────────────

    function test_soldOut_donatesToPot() public {
        (IGlueHookMin.PoolKey memory k, RoyaltyRouter r) = launchAndRoute(address(hunt), address(hunt), address(0));
        bond.accrue(address(token), 10 ether);
        bond.setSoldOut(address(token), true);
        vm.prank(KEEPER);
        (uint128 liquidity, uint256 bounty, uint256 daoCut) = r.sweep(0);
        assertEq(liquidity, 0);
        assertEq(hook.potOf(hook.idOf(k)).balance, 8 ether - bounty - daoCut, "everything net of fees went to the pot");
        assertEq(hunt.balanceOf(address(r)), 0);
    }

    // ─── thresholds ──────────────────────────────────────────────────────────────────────────────

    function test_sweep_revertsBelowMinimum() public {
        (, RoyaltyRouter r) = launchAndRoute(address(hunt), address(hunt), address(0));
        bond.accrue(address(token), MIN_CLAIM); // 80% of MIN_CLAIM < MIN_CLAIM
        vm.expectRevert(RoyaltyRouter.BelowMinimum.selector);
        r.sweep(0);
    }

    function test_sweep_revertsWhenNothingPending() public {
        (, RoyaltyRouter r) = launchAndRoute(address(hunt), address(hunt), address(0));
        vm.expectRevert(RoyaltyRouter.BelowMinimum.selector);
        r.sweep(0);
    }

    function testFuzz_feesExactAndPositionOnlyGrows(uint96 royalty) public {
        vm.assume(royalty >= 2 * MIN_CLAIM && royalty < 1_000 ether);
        (IGlueHookMin.PoolKey memory k, RoyaltyRouter r) = launchAndRoute(address(hunt), address(hunt), address(0));
        bond.accrue(address(token), royalty);
        uint256 claimed = r.pending();
        uint128 lBefore = hook.programOf(hook.idOf(k)).liquidity;
        vm.prank(KEEPER);
        (uint128 liquidity, uint256 bounty, uint256 daoCut) = r.sweep(0);
        assertEq(bounty, claimed * BOUNTY_BPS / 10_000);
        assertEq(daoCut, claimed * DAO_BPS / 10_000);
        assertEq(hook.programOf(hook.idOf(k)).liquidity, lBefore + liquidity);
        assertGt(liquidity, 0);
    }

    // ─── construction guards ─────────────────────────────────────────────────────────────────────

    function test_ctor_requiresBeingProgramOwner() public {
        bond.createBond(address(token), CREATOR, address(hunt));
        IGlueHookMin.PoolKey memory k = key(address(token), address(hunt));
        vm.startPrank(CREATOR);
        hook.initPot(k, address(token), CREATOR);
        hook.createProgram(k, CREATOR, defaultConfig()); // owner is NOT the router
        vm.stopPrank();
        vm.expectRevert(RoyaltyRouter.BadRoute.selector);
        new RoyaltyRouter(bond, hook, address(pm), address(token), k, ISwapper(address(0)), factory, BOUNTY_BPS, MIN_CLAIM, STALE, GRACE);
    }

    function test_ctor_rejectsSwapperOnDirectRoute() public {
        bond.createBond(address(token), CREATOR, address(hunt));
        IGlueHookMin.PoolKey memory k = key(address(token), address(hunt));
        vm.prank(CREATOR);
        hook.initPot(k, address(token), CREATOR);
        vm.expectRevert(RoyaltyRouter.BadRoute.selector);
        new RoyaltyRouter(bond, hook, address(pm), address(token), k, ISwapper(address(1)), factory, BOUNTY_BPS, MIN_CLAIM, STALE, GRACE);
    }

    function test_ctor_capsBounty() public {
        bond.createBond(address(token), CREATOR, address(hunt));
        IGlueHookMin.PoolKey memory k = key(address(token), address(hunt));
        vm.expectRevert(RoyaltyRouter.BadRoute.selector);
        new RoyaltyRouter(bond, hook, address(pm), address(token), k, ISwapper(address(0)), factory, 1_001, MIN_CLAIM, STALE, GRACE);
    }

    // ─── governed DAO take ───────────────────────────────────────────────────────────────────────

    function test_fee_changeAppliesToNextSweep() public {
        (, RoyaltyRouter r) = launchAndRoute(address(hunt), address(hunt), address(0));
        address dao2 = address(0xDA02);
        vm.prank(GOV);
        factory.setFee(dao2, 500);
        bond.accrue(address(token), 10 ether);
        (,, uint256 daoCut) = r.sweep(0);
        assertEq(daoCut, 0.4 ether); // 5% of 8
        assertEq(hunt.balanceOf(dao2), daoCut);
        assertEq(hunt.balanceOf(DAO), 0);
    }

    function test_fee_routerClampsToCeiling() public {
        (, RoyaltyRouter r) = launchAndRoute(address(hunt), address(hunt), address(0));
        vm.mockCall(address(factory), abi.encodeCall(IFeeSource.feeInfo, ()), abi.encode(DAO, uint16(9_999)));
        bond.accrue(address(token), 10 ether);
        (,, uint256 daoCut) = r.sweep(0);
        assertEq(daoCut, 8 ether * uint256(MAX_DAO_BPS) / 10_000);
    }

    /// No admin surface: the only non-view entry is sweep (plus receive).
    function test_noAdminSurface() public {
        (, RoyaltyRouter r) = launchAndRoute(address(hunt), address(hunt), address(0));
        string[7] memory sigs = ["withdraw()", "withdraw(address,uint256)", "setOwner(address)", "upgradeTo(address)",
            "updateBondCreator(address,address)", "removeProgramLiquidity((address,address,uint24,int24,address),uint128,address)",
            "transferProgramOwnership(bytes32,address)"];
        // reclaim exists but is DAO-gated and staleness-gated; from a stranger it must fail too
        (bool ok2,) = address(r).call(abi.encodeWithSignature("reclaim()"));
        assertFalse(ok2, "reclaim() from a stranger");
        for (uint256 i; i < sigs.length; i++) {
            (bool ok,) = address(r).call(abi.encodeWithSignature(sigs[i], address(this), 1));
            assertFalse(ok, sigs[i]);
        }
    }

    // ─── V4 math pinned to the live PoolManager (values recorded in the Base fork test) ──────────

    function test_v4math_matchesLiveValues() public pure {
        (int24 lo, int24 hi) = V4Math.fullRangeTicks(60);
        assertEq(lo, -887220); assertEq(hi, 887220);
        assertEq(V4Math.getSqrtPriceAtTick(lo), 4306310044);
        assertEq(V4Math.getSqrtPriceAtTick(hi), 1457652066949847389969617340386294118487833376468);
        assertEq(V4Math.getSqrtPriceAtTick(0), uint160(2 ** 96));
        uint160 sqrtP = uint160(100 * 2 ** 96);
        (uint256 a0, uint256 a1) = V4Math.amountsForLiquidity(sqrtP, 4306310044, 1457652066949847389969617340386294118487833376468, 40e18);
        assertEq(a0, 399999999999999998); assertEq(a1, 3999999999999999999998);
        assertEq(V4Math.liquidityForAmounts(sqrtP, 4306310044, 1457652066949847389969617340386294118487833376468, 0.4e18, 4000e18), 40e18);
    }
}
