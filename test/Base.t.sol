// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IGlueHookMin} from "../src/interfaces/IGlueHookMin.sol";
import {IMintClubBond} from "../src/interfaces/IMintClubBond.sol";
import {ISwapper} from "../src/interfaces/ISwapper.sol";
import {RoyaltyRouter} from "../src/RoyaltyRouter.sol";
import {RoyaltyRouterFactory} from "../src/RoyaltyRouterFactory.sol";
import {V4Math} from "../src/libs/V4Math.sol";
import {MockERC20, MockWETH, MockBond, MockHook, MockPoolManager, MockSwapper} from "./mocks/Mocks.sol";

abstract contract Base is Test {
    address constant CREATOR = address(0xC0FFEE);
    address constant KEEPER = address(0xBEEF);
    address constant DAO = address(0xDA0);
    address constant GOV = address(0x60F);
    uint16 constant DAO_BPS = 1_000; // 10%
    uint16 constant MAX_DAO_BPS = 2_000; // 20%
    uint16 constant BOUNTY_BPS = 50; // 0.5%
    uint256 constant MIN_CLAIM = 1e15;
    uint64 constant STALE = 365 days;
    uint64 constant GRACE = 30 days;
    uint256 constant Q96 = 2 ** 96;

    MockWETH weth;
    MockERC20 token; // the mint.club token = pot MAIN
    MockERC20 hunt; // an alternative reserve / secondary
    MockBond bond;
    MockPoolManager pm;
    MockHook hook;
    RoyaltyRouterFactory factory;

    function setUp() public virtual {
        weth = new MockWETH();
        vm.deal(address(weth), 1_000_000 ether); // backs withdraw()
        token = new MockERC20();
        hunt = new MockERC20();
        bond = new MockBond();
        pm = new MockPoolManager();
        hook = new MockHook(address(weth), pm);
        factory = new RoyaltyRouterFactory(bond, hook, address(pm), GOV, DAO, DAO_BPS, MAX_DAO_BPS, STALE, GRACE);
        vm.warp(1_700_000_000);
    }

    /// Sorted V4 key; `hooks` = our mock.
    function key(address a, address b) internal view returns (IGlueHookMin.PoolKey memory k) {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        k = IGlueHookMin.PoolKey(c0, c1, 3000, 60, address(hook));
    }

    /// sqrt price for "`perTok` secondary per token" given the key's ordering.
    function sqrtFor(IGlueHookMin.PoolKey memory k, address tok, uint256 perTokWad) internal pure returns (uint160) {
        // price = currency1 / currency0
        uint256 ratioX192 = tok == k.currency1 ? (1e18 << 192) / perTokWad : (perTokWad << 192) / 1e18;
        return uint160(_sqrt(ratioX192));
    }

    function liqFor(IGlueHookMin.PoolKey memory k, address tok, uint160 sqrtP, uint256 tokens, uint256 secondary) internal pure returns (uint128) {
        (int24 lo, int24 hi) = V4Math.fullRangeTicks(k.tickSpacing);
        (uint256 a0, uint256 a1) = tok == k.currency0 ? (tokens, secondary) : (secondary, tokens);
        return V4Math.liquidityForAmounts(sqrtP, V4Math.getSqrtPriceAtTick(lo), V4Math.getSqrtPriceAtTick(hi), a0, a1);
    }

    function defaultConfig() internal pure returns (IGlueHookMin.ProgramConfig memory c) {
        c.compoundShareWad = 1e18;
        c.publicHarvest = true;
        c.secondaryRecipient = CREATOR;
        c.mainRecipient = CREATOR;
        c.minMain = type(uint256).max;
        c.minSecondary = type(uint256).max;
    }

    /// Bond with `reserve`, pot MAIN=token / SECONDARY=`secondary` at 0.001 secondary per token, program owned
    /// by the router's CREATE2 address (deployed by THIS test contract with salt 0), then the router itself.
    function launchAndRoute(address reserve, address secondary, address swapper) internal returns (IGlueHookMin.PoolKey memory k, RoyaltyRouter r) {
        bond.createBond(address(token), CREATOR, reserve);
        k = key(address(token), secondary);
        bytes memory args = abi.encode(bond, hook, address(pm), address(token), k, ISwapper(swapper), factory, BOUNTY_BPS, MIN_CLAIM, STALE, GRACE);
        address predicted = vm.computeCreate2Address(bytes32(0), keccak256(abi.encodePacked(type(RoyaltyRouter).creationCode, args)), address(this));
        vm.prank(CREATOR);
        hook.initPot(k, address(token), CREATOR);
        vm.prank(CREATOR);
        hook.createProgram(k, predicted, defaultConfig());
        pm.setSqrtPrice(hook.idOf(k), sqrtFor(k, address(token), 1e15));
        r = new RoyaltyRouter{salt: bytes32(0)}(bond, hook, address(pm), address(token), k, ISwapper(swapper), factory, BOUNTY_BPS, MIN_CLAIM, STALE, GRACE);
        assertEq(address(r), predicted);
        vm.prank(CREATOR);
        bond.updateBondCreator(address(token), address(r));
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2; y = x;
        while (z < y) { y = z; z = (x / z + z) / 2; }
    }
}
