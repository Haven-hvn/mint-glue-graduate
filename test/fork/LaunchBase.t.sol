// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {IMintClubBond} from "../../src/interfaces/IMintClubBond.sol";
import {IGlueHookMin} from "../../src/interfaces/IGlueHookMin.sol";
import {IERC20Min} from "../../src/interfaces/IERC20Min.sol";
import {RoyaltyRouter} from "../../src/RoyaltyRouter.sol";
import {RoyaltyRouterFactory} from "../../src/RoyaltyRouterFactory.sol";

/// Runs `launch` against the LIVE mint.club Bond and GlueHook on Base. `BASE_RPC` overrides the public RPC.
///   forge test --match-path 'test/fork/*' -vv
contract LaunchBaseForkTest is Test {
    IMintClubBond constant BOND = IMintClubBond(0xc5a076cad94176c2996B32d8466Be1cE757FAa27);
    IGlueHookMin constant HOOK = IGlueHookMin(0x0F41715dc432692b66A5aDF8dCfef6Ac407b20c8);
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    uint256 constant Q96 = 2 ** 96;
    // V4 TickMath sqrt prices at the spacing-60 full range (±887220)
    uint160 constant SQRT_LOWER = 4306310044;
    uint160 constant SQRT_UPPER = 1457652066949847389969617340386294118487833376468;

    // Fresh EOAs: `makeAddr("user")` collides with a live contract on Base that forwards ETH.
    address user = vm.addr(uint256(keccak256("royalty-router/fork/user")));
    address keeper = vm.addr(uint256(keccak256("royalty-router/fork/keeper")));
    address dao = vm.addr(uint256(keccak256("royalty-router/fork/dao")));
    address trader = vm.addr(uint256(keccak256("royalty-router/fork/trader")));
    RoyaltyRouterFactory factory;

    // curve: 1_000 free, then 0.0001 WETH/token up to 100_000, then 0.001 up to 1_000_000
    uint128 constant PRICE_STEP1 = 1e14;

    function setUp() public {
        vm.createSelectFork(vm.envOr("BASE_RPC", string("https://mainnet.base.org")));
        assertEq(user.code.length + keeper.code.length + dao.code.length + trader.code.length, 0, "fresh EOAs");
        factory = new RoyaltyRouterFactory(BOND, HOOK, POOL_MANAGER, dao, dao, 1_000, 2_000, 365 days, 30 days);
        vm.deal(user, 10 ether);
        deal(WETH, user, 10 ether);
        deal(WETH, trader, 10 ether);
        vm.prank(user);
        IERC20Min(WETH).approve(address(factory), type(uint256).max);
    }

    function _launchParams() internal view returns (RoyaltyRouterFactory.Launch memory L, uint256 seedEth, uint256 seedTokens) {
        uint128[] memory ranges = new uint128[](3);
        uint128[] memory prices = new uint128[](3);
        ranges[0] = 1_000e18; prices[0] = 0;
        ranges[1] = 100_000e18; prices[1] = PRICE_STEP1;
        ranges[2] = 1_000_000e18; prices[2] = 1e15;
        L.name = "Royalty Router Test";
        L.symbol = string.concat("RRT", vm.toString(block.number));
        L.bond = IMintClubBond.BondParams(300, 300, WETH, 1_000_000e18, ranges, prices);
        L.curveMint = 5_000e18;
        L.maxReserveIn = 1 ether;
        L.secondary = address(0);
        L.fee = 3000;
        L.tickSpacing = 60;
        // price = currency1/currency0 = token per ETH = 1 / 0.0001 = 10_000  →  sqrt = 100
        L.sqrtPriceX96 = uint160(100 * Q96);
        seedEth = 0.4 ether;
        seedTokens = 4_000e18;
        L.liquidity = _liquidityForAmounts(L.sqrtPriceX96, seedEth, seedTokens);
        L.compoundShareWad = 1e18;
        L.feeRecipient = user;
        L.minMain = type(uint256).max;
        L.minSecondary = type(uint256).max;
        L.bountyBps = 50;
        L.minClaim = 1e14;
    }

    /// Full-range V4 liquidity for (amount0 = ETH, amount1 = token) at sqrtP. Mirrors the SDK's math.
    function _liquidityForAmounts(uint160 sqrtP, uint256 amount0, uint256 amount1) internal pure returns (uint128) {
        uint256 l1 = amount1 * Q96 / (uint256(sqrtP) - SQRT_LOWER);
        uint256 t = amount0 * uint256(sqrtP) / Q96;
        uint256 l0 = t * uint256(SQRT_UPPER) / (uint256(SQRT_UPPER) - uint256(sqrtP));
        return uint128(l0 < l1 ? l0 : l1);
    }

    function test_fork_launchEndToEnd() public {
        (RoyaltyRouterFactory.Launch memory L, uint256 seedEth, uint256 seedTokens) = _launchParams();
        uint256 fee = BOND.creationFee();
        uint256 ethBefore = user.balance;
        uint256 wethBefore = IERC20Min(WETH).balanceOf(user);

        vm.prank(user);
        (address token, address router) = factory.launch{value: fee + 1 ether}(L);
        RoyaltyRouter r = RoyaltyRouter(payable(router));
        bytes32 id = keccak256(abi.encode(r.poolKey()));

        // ── roles ──
        (address creator,,,, address reserve,) = BOND.tokenBond(token);
        assertEq(creator, router, "router is creator");
        assertEq(reserve, WETH);
        IGlueHookMin.Pot memory pot = HOOK.potOf(id);
        assertTrue(pot.configured);
        assertEq(pot.admin, address(factory));
        assertEq(pot.main, token);
        assertEq(pot.secondary, address(0));
        IGlueHookMin.Program memory g = HOOK.programOf(id);
        assertTrue(g.exists);
        assertEq(g.owner, router, "router owns the position");
        assertEq(g.operator, router, "router holds the rules");
        assertTrue(g.publicHarvest);
        assertEq(g.compoundShareWad, 1e18);
        assertEq(g.buybackShareWad, 0);
        assertEq(g.liquidity, L.liquidity);
        assertEq(g.tickLower, -887220);
        assertEq(g.tickUpper, 887220);

        // ── money ──
        (uint256 cost, uint256 royalty) = _quoteMint(token, L.curveMint);
        assertEq(wethBefore - IERC20Min(WETH).balanceOf(user), cost, "reserve pulled = quoted mint cost");
        assertEq(r.pending(), royalty * 8_000 / 10_000, "seed mint royalty already on the router");
        uint256 ethSpent = ethBefore - user.balance;
        uint256 consumed0 = ethSpent - fee;
        uint256 consumed1 = 1_000e18 + L.curveMint - IERC20Min(token).balanceOf(user);
        console.log("liquidity          ", L.liquidity);
        console.log("ETH consumed (wei) ", consumed0);
        console.log("token consumed     ", consumed1);
        assertLe(consumed0, seedEth + 1e9, "ETH within target (+rounding)");
        assertLe(consumed1, seedTokens + 1e9, "tokens within target (+rounding)");
        assertGt(consumed0, seedEth * 99 / 100, "one side binds near the target");
        assertEq(address(factory).balance, 0);
        assertEq(IERC20Min(WETH).balanceOf(address(factory)), 0);
        assertEq(IERC20Min(token).balanceOf(address(factory)), 0);

        // ── a stranger trades on the curve; royalty flows to the router ──
        uint256 pendingBefore = r.pending();
        vm.startPrank(trader);
        IERC20Min(WETH).approve(address(BOND), type(uint256).max);
        BOND.mint(token, 10_000e18, 5 ether, trader);
        vm.stopPrank();
        assertGt(r.pending(), pendingBefore, "third-party mint pays the router");

        // ── keeper sweeps: half bought on the REAL curve, paired into the REAL hook position ──
        uint256 claimable = r.pending();
        uint256 supplyBefore = _supply(token);
        vm.prank(keeper);
        (uint128 added, uint256 bounty, uint256 daoCut) = r.sweep(0);
        assertEq(bounty, claimable * 50 / 10_000);
        assertEq(daoCut, claimable * 1_000 / 10_000);
        assertEq(IERC20Min(WETH).balanceOf(keeper), bounty);
        assertEq(IERC20Min(WETH).balanceOf(dao), daoCut);
        assertGt(added, 0, "liquidity was added");
        assertEq(HOOK.programOf(id).liquidity, L.liquidity + added, "hook position grew by exactly the added liquidity");
        assertGt(_supply(token), supplyBefore, "token side came from the curve");
        assertEq(IERC20Min(WETH).balanceOf(router), 0, "all WETH used or unwrapped");
        uint256 net = claimable - bounty - daoCut;
        assertLt(address(router).balance, net / 50, "native leftover is small (carried to the next sweep)");
        assertEq(HOOK.potOf(id).balance, 0, "nothing to the pot while the curve has supply");
        console.log("liquidity added    ", added);
        console.log("native leftover    ", address(router).balance);
        console.log("token leftover     ", IERC20Min(token).balanceOf(router));

        // ── the position is locked: the hook only answers to the router, and the router has no such entry ──
        IGlueHookMin.PoolKey memory pk = r.poolKey(); // cached: a view call would consume expectRevert
        vm.prank(user);
        vm.expectRevert();
        HOOK.removeProgramLiquidity(pk, 1, user);
        vm.prank(user);
        vm.expectRevert();
        HOOK.setProgramOperator(id, user);
        vm.prank(user);
        vm.expectRevert();
        HOOK.transferProgramOwnership(id, user);
        (bool ok,) = router.call(abi.encodeWithSignature("removeProgramLiquidity((address,address,uint24,int24,address),uint128,address)", pk, 1, user));
        assertFalse(ok, "router has no remove path");
        (ok,) = router.call(abi.encodeWithSignature("transferProgramOwnership(bytes32,address)", id, user));
        assertFalse(ok, "router has no transfer path");
    }

    function test_fork_predictMatchesDeployed() public {
        (RoyaltyRouterFactory.Launch memory L,,) = _launchParams();
        uint256 fee = BOND.creationFee();
        vm.prank(user);
        (address token, address router) = factory.launch{value: fee + 1 ether}(L);
        assertEq(factory.predict(token, RoyaltyRouter(payable(router)).poolKey(), address(0), 50, 1e14), router);
    }

    /// A token that goes quiet for a year: the DAO recovers BOTH sides from the REAL hook position.
    function test_fork_staleReclaim() public {
        (RoyaltyRouterFactory.Launch memory L,,) = _launchParams();
        uint256 fee = BOND.creationFee();
        vm.prank(user);
        (address token, address router) = factory.launch{value: fee + 1 ether}(L);
        RoyaltyRouter r = RoyaltyRouter(payable(router));
        bytes32 id = keccak256(abi.encode(r.poolKey()));
        vm.prank(keeper);
        r.sweep(0); // the seed mint's royalty becomes liquidity; lastActive = now

        vm.warp(block.timestamp + 365 days + 1);
        assertFalse(r.heartbeat(), "quiet");
        vm.prank(dao);
        r.initiateReclaim();
        vm.warp(block.timestamp + 30 days + 1);
        uint128 liq = HOOK.programOf(id).liquidity;
        vm.prank(dao);
        uint128 removed = r.reclaim();
        assertEq(removed, liq);
        assertEq(HOOK.programOf(id).liquidity, 0, "real position emptied");
        assertGt(dao.balance, 0, "ETH side recovered");
        assertGt(IERC20Min(token).balanceOf(dao), 0, "token side recovered");
        console.log("reclaimed ETH   ", dao.balance);
        console.log("reclaimed token ", IERC20Min(token).balanceOf(dao));
    }

    function _supply(address token) internal view returns (uint256) {
        (bool ok, bytes memory r) = token.staticcall(abi.encodeWithSignature("totalSupply()"));
        require(ok); return abi.decode(r, (uint256));
    }

    /// mint.club quote after the free range has been minted (supply = 1_000e18).
    function _quoteMint(address token, uint256 n) internal view returns (uint256 cost, uint256 royalty) {
        // cannot call getReserveForToken post-launch for the pre-launch supply; recompute like the bond does
        (cost, royalty) = (0, 0);
        uint256 base = n * PRICE_STEP1 / 1e18; // all inside step 1
        // bond: reserveAmount = base + royalty, royalty = base * mintRoyalty / 10000, with ceil rounding on base
        (, uint16 mintRoyalty,,,,) = BOND.tokenBond(token);
        royalty = base * mintRoyalty / 10_000;
        cost = base + royalty;
    }
}
