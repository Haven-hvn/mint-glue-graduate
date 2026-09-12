// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./Base.t.sol";

contract LaunchTest is Base {
    address constant USER = address(0x1234);

    function baseLaunch(address reserve, address secondary) internal view returns (RoyaltyRouterFactory.Launch memory L) {
        uint128[] memory ranges = new uint128[](2);
        uint128[] memory prices = new uint128[](2);
        ranges[0] = 1_000 ether; prices[0] = 0; // free-mint range → creator
        ranges[1] = 1_000_000 ether; prices[1] = 1e15; // 0.001 reserve per token
        L.name = "Test"; L.symbol = "TST";
        L.bond = IMintClubBond.BondParams(300, 300, reserve, 1_000_000 ether, ranges, prices);
        L.curveMint = 500 ether;
        L.maxReserveIn = 1 ether;
        L.secondary = secondary;
        L.fee = 3000; L.tickSpacing = 60;
        L.compoundShareWad = 1e18;
        L.feeRecipient = USER;
        L.minMain = type(uint256).max; L.minSecondary = type(uint256).max;
        L.swapper = address(0);
        L.bountyBps = BOUNTY_BPS;
        L.minClaim = MIN_CLAIM;
        // price the pool at the curve: 0.001 secondary per token; seed 1200 tokens + 1.2 secondary
        IGlueHookMin.PoolKey memory k = key(bond.predictNext(), secondary);
        L.sqrtPriceX96 = sqrtFor(k, bond.predictNext(), 1e15);
        L.liquidity = liqFor(k, bond.predictNext(), L.sqrtPriceX96, 1_200 ether, 1.2 ether);
        L.secondarySeed = 2 ether; // more than the 1.2 needed; excess refunded
    }

    function setUp() public override {
        super.setUp();
        vm.deal(USER, 100 ether);
        weth.mint(USER, 100 ether);
        hunt.mint(USER, 100_000 ether);
        vm.startPrank(USER);
        weth.approve(address(factory), type(uint256).max);
        hunt.approve(address(factory), type(uint256).max);
        vm.stopPrank();
    }

    function test_launch_wethReserve_nativePool() public {
        RoyaltyRouterFactory.Launch memory L = baseLaunch(address(weth), address(0));
        uint256 ethBefore = USER.balance;
        uint256 wethBefore = weth.balanceOf(USER);

        vm.prank(USER);
        (address token, address router) = factory.launch{value: 0.001 ether + 2 ether}(L); // fee + 2 ETH seed budget, 1.2 used

        // one transaction, every role where it should be
        (address creator,,,, address reserve,) = bond.tokenBond(token);
        assertEq(creator, router);
        assertEq(reserve, address(weth));
        assertTrue(router.code.length > 0);
        RoyaltyRouter r = RoyaltyRouter(payable(router));
        assertEq(r.TOKEN(), token);
        assertEq(r.SECONDARY(), address(0));
        assertEq(address(r.SWAPPER()), address(0));

        bytes32 id = hook.idOf(r.poolKey());
        IGlueHookMin.Pot memory pot = hook.potOf(id);
        assertEq(pot.admin, address(factory), "factory is pot admin: recipient frozen");
        assertEq(pot.main, token);
        IGlueHookMin.Program memory g = hook.programOf(id);
        assertTrue(g.exists);
        assertEq(g.owner, router, "router owns the position: no remove path anywhere");
        assertEq(g.operator, router, "router holds the rules: no config path anywhere");
        assertTrue(g.publicHarvest);
        assertEq(g.compoundShareWad, 1e18);
        assertEq(g.buybackShareWad, 0);
        assertEq(g.burnShareWad, 0);
        assertEq(g.potCompoundShareWad, 0);
        assertEq(g.secondaryRecipient, USER);

        // the seed mint's royalty already belongs to the router: 500 tokens * 0.001 = 0.5 WETH base, 3% royalty, 80% creator share
        assertEq(r.pending(), 0.5 ether * 300 / 10_000 * 8_000 / 10_000);

        // leftovers refunded: 1500 tokens (1000 free + 500 minted) − ~1200 seeded ≈ 300; ETH beyond fee + seed comes back
        assertApproxEqAbs(MockERC20(token).balanceOf(USER), 300 ether, 1e6);
        assertEq(MockERC20(token).balanceOf(address(factory)), 0);
        assertEq(address(factory).balance, 0);
        assertEq(weth.balanceOf(address(factory)), 0);
        assertApproxEqAbs(ethBefore - USER.balance, 0.001 ether + 1.2 ether, 1e6);
        assertEq(wethBefore - weth.balanceOf(USER), 0.5 ether + 0.5 ether * 300 / 10_000);

        // and the router works: the sweep grows the locked position
        vm.prank(KEEPER);
        (uint128 added,,) = r.sweep(0);
        assertGt(added, 0);
        assertEq(hook.programOf(id).liquidity, L.liquidity + added);
    }

    function test_launch_erc20ReserveAndPool() public {
        RoyaltyRouterFactory.Launch memory L = baseLaunch(address(hunt), address(hunt));
        vm.prank(USER);
        (address token, address router) = factory.launch{value: 0.001 ether}(L);
        RoyaltyRouter r = RoyaltyRouter(payable(router));
        assertEq(r.SECONDARY(), address(hunt));
        assertEq(hunt.balanceOf(address(factory)), 0);
        assertApproxEqAbs(MockERC20(token).balanceOf(USER), 300 ether, 1e6);
        // HUNT spent = curve mint cost (0.5 + 3% royalty) + 1.2 seed; the 0.8 excess of secondarySeed came back
        assertApproxEqAbs(100_000 ether - hunt.balanceOf(USER), 0.5 ether + 0.5 ether * 300 / 10_000 + 1.2 ether, 1e6);
        assertEq(address(factory).balance, 0);
    }

    function test_launch_freeRangeOnly() public {
        RoyaltyRouterFactory.Launch memory L = baseLaunch(address(weth), address(0));
        L.curveMint = 0;
        L.liquidity = L.liquidity * 5 / 6; // 1000 tokens available
        vm.prank(USER);
        (address token, address router) = factory.launch{value: 0.001 ether + 1 ether}(L);
        assertLe(MockERC20(token).balanceOf(USER), 1e6, "rounding dust at most");
        assertEq(RoyaltyRouter(payable(router)).pending(), 0);
    }

    function test_launch_revertsOnRouteMismatch() public {
        // HUNT reserve into a native pot with no swapper: the router constructor refuses, the whole launch unwinds
        RoyaltyRouterFactory.Launch memory L = baseLaunch(address(hunt), address(0));
        vm.prank(USER);
        vm.expectRevert(RoyaltyRouter.BadRoute.selector);
        factory.launch{value: 0.001 ether + 2 ether}(L);
    }

    function test_launch_revertsOnSeedSlippage() public {
        RoyaltyRouterFactory.Launch memory L = baseLaunch(address(weth), address(0));
        L.maxReserveIn = 0.1 ether;
        vm.prank(USER);
        vm.expectRevert(RoyaltyRouterFactory.BadRoute.selector);
        factory.launch{value: 0.001 ether + 2 ether}(L);
    }

    function test_launch_predictMatches() public {
        RoyaltyRouterFactory.Launch memory L = baseLaunch(address(weth), address(0));
        vm.prank(USER);
        (address token, address router) = factory.launch{value: 0.001 ether + 2 ether}(L);
        assertEq(factory.predict(token, RoyaltyRouter(payable(router)).poolKey(), address(0), BOUNTY_BPS, MIN_CLAIM), router);
    }

    function test_launch_daoTakeAppliesFromDayOne() public {
        RoyaltyRouterFactory.Launch memory L = baseLaunch(address(weth), address(0));
        vm.prank(USER);
        (, address router) = factory.launch{value: 0.001 ether + 2 ether}(L);
        vm.prank(KEEPER);
        (,, uint256 daoCut) = RoyaltyRouter(payable(router)).sweep(0);
        assertEq(weth.balanceOf(DAO), daoCut);
        assertGt(daoCut, 0);
    }
}
