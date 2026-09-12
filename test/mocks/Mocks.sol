// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IMintClubBond} from "../../src/interfaces/IMintClubBond.sol";
import {IGlueHookMin} from "../../src/interfaces/IGlueHookMin.sol";
import {ISwapper} from "../../src/interfaces/ISwapper.sol";
import {IERC20Min} from "../../src/interfaces/IERC20Min.sol";
import {V4Math} from "../../src/libs/V4Math.sol";

/// Just enough PoolManager: the slot0 word GlueHook/V4Math read via extsload.
contract MockPoolManager {
    mapping(bytes32 => bytes32) public store;
    function extsload(bytes32 slot) external view returns (bytes32) { return store[slot]; }
    function setSqrtPrice(bytes32 poolId, uint160 sqrtP) external {
        store[keccak256(abi.encodePacked(poolId, bytes32(uint256(6))))] = bytes32(uint256(sqrtP));
    }
}

contract MockERC20 is IERC20Min {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) public returns (bool) { return _move(msg.sender, to, a); }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        require(allowance[f][msg.sender] >= a, "allowance");
        allowance[f][msg.sender] -= a;
        return _move(f, to, a);
    }
    function _move(address f, address to, uint256 a) internal returns (bool) {
        require(balanceOf[f] >= a, "balance");
        balanceOf[f] -= a; balanceOf[to] += a; return true;
    }
}

contract MockWETH is MockERC20 {
    function deposit() external payable { balanceOf[msg.sender] += msg.value; }
    function withdraw(uint256 a) external {
        require(balanceOf[msg.sender] >= a, "balance");
        balanceOf[msg.sender] -= a;
        (bool ok,) = msg.sender.call{value: a}(""); require(ok, "eth");
    }
}

/// Mirrors MCV2_Bond + MCV2_Royalty: creator-gated updateBondCreator, pull-only claim paid to msg.sender.
contract MockBond is IMintClubBond {
    struct B { address creator; address reserve; uint16 mintRoyalty; uint128 price; bool soldOut; }
    mapping(address => B) internal bonds;
    mapping(address => mapping(address => uint256)) public userTokenRoyaltyBalance;
    uint256 public creationFee = 0.001 ether;
    address public lastToken;

    error PermissionDenied(); error InvalidCreator(); error NothingToClaim(); error BadFee(); error Slippage();

    function createBond(address token, address creator, address reserve) external { bonds[token] = B(creator, reserve, 300, 1e15, false); }
    function setSoldOut(address token, bool v) external { bonds[token].soldOut = v; }
    function priceForNextMint(address token) external view returns (uint128) { return bonds[token].price; }

    /// Address the next createToken will deploy (CREATE from this contract at its current nonce).
    function predictNext() external view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xd6), bytes1(0x94), address(this), bytes1(uint8(_nonce + 1)))))));
    }
    uint8 internal _nonce;
    function createToken(TokenParams calldata, BondParams calldata bp) external payable returns (address token) {
        _nonce++;
        if (msg.value != creationFee) revert BadFee();
        MockERC20 t = new MockERC20();
        token = address(t);
        lastToken = token;
        bonds[token] = B(msg.sender, bp.reserveToken, bp.mintRoyalty, bp.stepPrices[bp.stepPrices.length - 1], false);
        if (bp.stepPrices[0] == 0) t.mint(msg.sender, bp.stepRanges[0]);
    }
    /// Flat curve at the last step price. reserveAmount INCLUDES the royalty, like the real bond.
    function getReserveForToken(address token, uint256 n) public view returns (uint256 reserveAmount, uint256 royalty) {
        B memory b = bonds[token];
        if (b.soldOut) revert Slippage(); // stands in for MCV2_Bond__ExceedMaxSupply
        uint256 base = n * b.price / 1e18;
        royalty = base * b.mintRoyalty / 10000;
        reserveAmount = base + royalty;
    }
    function mint(address token, uint256 n, uint256 maxReserve, address receiver) external returns (uint256 reserveAmount) {
        uint256 royalty;
        (reserveAmount, royalty) = getReserveForToken(token, n);
        if (reserveAmount > maxReserve) revert Slippage();
        B memory b = bonds[token];
        userTokenRoyaltyBalance[b.creator][b.reserve] += royalty - royalty * 2000 / 10000;
        MockERC20(token).mint(receiver, n);
        MockERC20(b.reserve).transferFrom(msg.sender, address(this), reserveAmount);
    }
    /// Simulates a trade: 80% of `royalty` to the creator, 20% to the protocol (dropped here).
    function accrue(address token, uint256 royalty) external {
        B memory b = bonds[token];
        MockERC20(b.reserve).mint(address(this), royalty);
        userTokenRoyaltyBalance[b.creator][b.reserve] += royalty - royalty * 2000 / 10000;
    }
    function tokenBond(address token) external view returns (address, uint16, uint16, uint40, address, uint256) {
        B memory b = bonds[token];
        return (b.creator, b.mintRoyalty, b.mintRoyalty, 0, b.reserve, 0);
    }
    function updateBondCreator(address token, address creator) external {
        if (bonds[token].creator != msg.sender) revert PermissionDenied();
        if (creator == address(0)) revert InvalidCreator();
        bonds[token].creator = creator;
    }
    function claimRoyalties(address reserve) external {
        uint256 a = userTokenRoyaltyBalance[msg.sender][reserve];
        if (a == 0) revert NothingToClaim();
        userTokenRoyaltyBalance[msg.sender][reserve] = 0;
        MockERC20(reserve).transfer(msg.sender, a);
    }
}

/// Mirrors the GlueHook surface the router touches: measured-delta donate, operator-gated program rules.
contract MockHook is IGlueHookMin {
    address public immutable NATIVEWRAP;
    MockPoolManager public immutable PM;
    mapping(bytes32 => Pot) internal pots;
    mapping(bytes32 => Program) internal programs;

    error PotNotReady(); error BadDonation(); error NotAllowed(); error BadConfig();

    constructor(address wrap, MockPoolManager pm) { NATIVEWRAP = wrap; PM = pm; }

    function idOf(PoolKey memory k) public pure returns (bytes32) { return keccak256(abi.encode(k)); }
    function initPot(PoolKey memory k, address main, address recipient) external {
        Pot storage p = pots[idOf(k)];
        p.admin = msg.sender; p.main = main; p.secondary = main == k.currency0 ? k.currency1 : k.currency0;
        p.recipient = recipient; p.configured = true;
    }
    function createProgram(PoolKey memory k, address owner, ProgramConfig memory c) external {
        Program storage g = programs[idOf(k)];
        g.exists = true; g.owner = owner; g.operator = owner; _apply(g, c);
    }
    function launchPool(
        PoolKey calldata k, uint160 sqrtP, address main, address recipient, int24, int24, uint128 liquidity, address owner, ProgramConfig calldata c
    ) external payable returns (uint256 amount0, uint256 amount1) {
        bytes32 id = idOf(k);
        if (pots[id].configured) revert PotNotReady();
        PM.setSqrtPrice(id, sqrtP);
        Pot storage p = pots[id];
        p.admin = msg.sender; p.main = main; p.secondary = main == k.currency0 ? k.currency1 : k.currency0;
        p.recipient = recipient; p.configured = true;
        Program storage g = programs[id];
        g.exists = true; g.owner = owner; g.operator = owner; _apply(g, c);
        if (owner == address(0)) g.publicHarvest = true;
        (amount0, amount1) = _pull(k, id, liquidity);
        g.liquidity += liquidity;
    }
    mapping(bytes32 => uint256) public pendingMain; mapping(bytes32 => uint256) public pendingSec;
    function setPendingFees(bytes32 id, uint256 m, uint256 s) external { pendingMain[id] = m; pendingSec[id] = s; }
    /// Public harvest (our programs set publicHarvest): returns and clears pending fees.
    function harvest(PoolKey calldata k) external returns (uint256 m, uint256 s) {
        bytes32 id = idOf(k); (m, s) = (pendingMain[id], pendingSec[id]); pendingMain[id] = 0; pendingSec[id] = 0;
    }
    /// Owner-only. Pays both sides of the position (round-down amounts at the live price) to `to`.
    function removeProgramLiquidity(PoolKey calldata k, uint128 liquidity, address to) external returns (uint256 a0, uint256 a1) {
        bytes32 id = idOf(k);
        Program storage g = programs[id];
        if (msg.sender != g.owner) revert NotAllowed();
        g.liquidity -= liquidity;
        (int24 lo, int24 hi) = V4Math.fullRangeTicks(k.tickSpacing);
        (a0, a1) = V4Math.amountsForLiquidity(V4Math.sqrtPriceOf(address(PM), id), V4Math.getSqrtPriceAtTick(lo), V4Math.getSqrtPriceAtTick(hi), liquidity);
        a0 = a0 > 2 ? a0 - 2 : 0; a1 = a1 > 2 ? a1 - 2 : 0; // round down like a real removal
        if (k.currency0 == address(0)) { (bool ok,) = to.call{value: a0}(""); require(ok); }
        else IERC20Min(k.currency0).transfer(to, a0);
        IERC20Min(k.currency1).transfer(to, a1);
    }
    function transferProgramOwnership(bytes32 id, address newOwner) external {
        Program storage g = programs[id];
        if (msg.sender != g.owner) revert NotAllowed();
        g.owner = newOwner;
    }
    /// Owner-only, like the real hook. Pulls the exact V4 amounts for `liquidity` at the live price.
    function addProgramLiquidity(PoolKey calldata k, uint128 liquidity) external payable returns (uint256 amount0, uint256 amount1) {
        bytes32 id = idOf(k);
        Program storage g = programs[id];
        if (!g.exists) revert PotNotReady();
        if (msg.sender != g.owner) revert NotAllowed();
        (amount0, amount1) = _pull(k, id, liquidity);
        g.liquidity += liquidity;
    }
    function _pull(PoolKey calldata k, bytes32 id, uint128 liquidity) internal returns (uint256 a0, uint256 a1) {
        (int24 lo, int24 hi) = V4Math.fullRangeTicks(k.tickSpacing);
        (a0, a1) = V4Math.amountsForLiquidity(
            V4Math.sqrtPriceOf(address(PM), id), V4Math.getSqrtPriceAtTick(lo), V4Math.getSqrtPriceAtTick(hi), liquidity
        );
        if (k.currency0 == address(0)) {
            if (msg.value < a0) revert BadDonation();
            (bool ok,) = msg.sender.call{value: msg.value - a0}(""); require(ok);
        } else {
            if (msg.value != 0) revert BadDonation();
            IERC20Min(k.currency0).transferFrom(msg.sender, address(this), a0);
        }
        IERC20Min(k.currency1).transferFrom(msg.sender, address(this), a1);
    }
    function donate(PoolKey calldata k, uint256 amount) external payable returns (uint256 credited) {
        Pot storage p = pots[idOf(k)];
        if (!p.configured) revert PotNotReady();
        if (p.secondary == address(0)) {
            if (msg.value != amount) revert BadDonation();
            credited = amount;
        } else {
            if (msg.value != 0) revert BadDonation();
            uint256 before = IERC20Min(p.secondary).balanceOf(address(this));
            IERC20Min(p.secondary).transferFrom(msg.sender, address(this), amount);
            credited = IERC20Min(p.secondary).balanceOf(address(this)) - before;
        }
        if (credited == 0) revert BadDonation();
        p.balance += credited;
    }
    function potOf(bytes32 id) external view returns (Pot memory) { return pots[id]; }
    function programOf(bytes32 id) external view returns (Program memory) { return programs[id]; }
    function setProgramConfig(bytes32 id, ProgramConfig calldata c) external {
        Program storage g = programs[id];
        if (!g.exists) revert PotNotReady();
        if (msg.sender != g.operator) revert NotAllowed();
        _apply(g, c);
    }
    function setProgramOperator(bytes32 id, address op) external {
        Program storage g = programs[id];
        if (!g.exists) revert PotNotReady();
        if (msg.sender != g.operator) revert NotAllowed();
        g.operator = op;
    }
    function _apply(Program storage g, ProgramConfig memory c) internal {
        if (uint256(c.potCompoundShareWad) + c.potBurnShareWad > 1e18) revert BadConfig();
        g.buybackShareWad = c.buybackShareWad; g.burnShareWad = c.burnShareWad; g.compoundShareWad = c.compoundShareWad;
        g.potCompoundShareWad = c.potCompoundShareWad; g.potBurnShareWad = c.potBurnShareWad;
        g.publicHarvest = c.publicHarvest; g.secondaryRecipient = c.secondaryRecipient; g.mainRecipient = c.mainRecipient;
        g.minMain = c.minMain; g.minSecondary = c.minSecondary;
    }
}

/// Fixed-rate swapper: out = in * RATE / 1e18. Pays native when tokenOut == address(0).
contract MockSwapper is ISwapper {
    uint256 public immutable RATE;
    constructor(uint256 rate) { RATE = rate; }
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut) external returns (uint256 out) {
        IERC20Min(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        out = amountIn * RATE / 1e18;
        require(out >= minOut, "slippage");
        if (tokenOut == address(0)) { (bool ok,) = msg.sender.call{value: out}(""); require(ok); }
        else MockERC20(tokenOut).mint(msg.sender, out);
    }
    receive() external payable {}
}

/// Re-enters sweep from inside the swap.
contract ReentrantSwapper is ISwapper {
    function swap(address tokenIn, address, uint256 amountIn, uint256) external returns (uint256) {
        IERC20Min(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        (bool ok, bytes memory r) = msg.sender.call(abi.encodeWithSignature("sweep(uint256)", 0));
        if (!ok) { assembly { revert(add(r, 32), mload(r)) } }
        return 0;
    }
}
