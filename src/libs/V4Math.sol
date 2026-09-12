// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice The slice of Uniswap V4 math the router needs: TickMath.getSqrtPriceAtTick, the spacing-aligned
///         full range, LiquidityAmounts.getLiquidityForAmounts, and reading a pool's sqrt price from the
///         PoolManager via extsload. Verified against the live PoolManager on Base in the fork tests.
library V4Math {
    uint256 internal constant Q96 = 1 << 96;
    int24 internal constant MAX_USABLE_TICK = 887272;
    bytes32 internal constant POOLS_SLOT = bytes32(uint256(6)); // v4-core StateLibrary.POOLS_SLOT

    error TickOutOfRange();

    function fullRangeTicks(int24 spacing) internal pure returns (int24 lower, int24 upper) {
        int24 m = (MAX_USABLE_TICK / spacing) * spacing;
        return (-m, m);
    }

    /// @dev Port of Uniswap TickMath.getSqrtPriceAtTick.
    function getSqrtPriceAtTick(int24 tick) internal pure returns (uint160) {
        unchecked {
            uint256 absTick = tick < 0 ? uint256(-int256(tick)) : uint256(int256(tick));
            if (absTick > uint256(int256(MAX_USABLE_TICK))) revert TickOutOfRange();
            uint256 ratio = absTick & 0x1 != 0 ? 0xfffcb933bd6fad37aa2d162d1a594001 : 0x100000000000000000000000000000000;
            if (absTick & 0x2 != 0) ratio = (ratio * 0xfff97272373d413259a46990580e213a) >> 128;
            if (absTick & 0x4 != 0) ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
            if (absTick & 0x8 != 0) ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
            if (absTick & 0x10 != 0) ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644) >> 128;
            if (absTick & 0x20 != 0) ratio = (ratio * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
            if (absTick & 0x40 != 0) ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
            if (absTick & 0x80 != 0) ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
            if (absTick & 0x100 != 0) ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
            if (absTick & 0x200 != 0) ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
            if (absTick & 0x400 != 0) ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
            if (absTick & 0x800 != 0) ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
            if (absTick & 0x1000 != 0) ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
            if (absTick & 0x2000 != 0) ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
            if (absTick & 0x4000 != 0) ratio = (ratio * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
            if (absTick & 0x8000 != 0) ratio = (ratio * 0x31be135f97d08fd981231505542fcfa6) >> 128;
            if (absTick & 0x10000 != 0) ratio = (ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
            if (absTick & 0x20000 != 0) ratio = (ratio * 0x5d6af8dedb81196699c329225ee604) >> 128;
            if (absTick & 0x40000 != 0) ratio = (ratio * 0x2216e584f5fa1ea926041bedfe98) >> 128;
            if (absTick & 0x80000 != 0) ratio = (ratio * 0x48a170391f7dc42444e8fa2) >> 128;
            if (tick > 0) ratio = type(uint256).max / ratio;
            return uint160((ratio >> 32) + (ratio % (1 << 32) == 0 ? 0 : 1));
        }
    }

    /// @dev LiquidityAmounts.getLiquidityForAmounts for a position [sqrtA, sqrtB] at sqrtP.
    function liquidityForAmounts(uint160 sqrtP, uint160 sqrtA, uint160 sqrtB, uint256 amount0, uint256 amount1)
        internal
        pure
        returns (uint128)
    {
        if (sqrtA > sqrtB) (sqrtA, sqrtB) = (sqrtB, sqrtA);
        if (sqrtP <= sqrtA) return _toU128(_l0(amount0, sqrtA, sqrtB));
        if (sqrtP >= sqrtB) return _toU128(_l1(amount1, sqrtA, sqrtB));
        uint256 a = _l0(amount0, sqrtP, sqrtB);
        uint256 b = _l1(amount1, sqrtA, sqrtP);
        return _toU128(a < b ? a : b);
    }

    function _l0(uint256 amount0, uint160 lo, uint160 hi) private pure returns (uint256) {
        uint256 inter = Math.mulDiv(lo, hi, Q96);
        return Math.mulDiv(amount0, inter, uint256(hi) - lo);
    }

    function _l1(uint256 amount1, uint160 lo, uint160 hi) private pure returns (uint256) {
        return Math.mulDiv(amount1, Q96, uint256(hi) - lo);
    }

    /// @dev Amounts the PoolManager charges to ADD `liquidity` (rounds up like v4-core SqrtPriceMath).
    function amountsForLiquidity(uint160 sqrtP, uint160 sqrtA, uint160 sqrtB, uint128 liquidity)
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        if (sqrtA > sqrtB) (sqrtA, sqrtB) = (sqrtB, sqrtA);
        if (sqrtP <= sqrtA) return (_a0(sqrtA, sqrtB, liquidity), 0);
        if (sqrtP >= sqrtB) return (0, _a1(sqrtA, sqrtB, liquidity));
        return (_a0(sqrtP, sqrtB, liquidity), _a1(sqrtA, sqrtP, liquidity));
    }

    function _a0(uint160 lo, uint160 hi, uint128 l) private pure returns (uint256) {
        uint256 n = Math.mulDiv(uint256(l) << 96, uint256(hi) - lo, hi, Math.Rounding.Ceil);
        return Math.ceilDiv(n, lo);
    }

    function _a1(uint160 lo, uint160 hi, uint128 l) private pure returns (uint256) {
        return Math.mulDiv(l, uint256(hi) - lo, Q96, Math.Rounding.Ceil);
    }

    function _toU128(uint256 x) private pure returns (uint128) {
        return x > type(uint128).max ? type(uint128).max : uint128(x);
    }

    /// @dev Current sqrt price of `poolId` straight from PoolManager storage (StateLibrary.getSlot0).
    function sqrtPriceOf(address poolManager, bytes32 poolId) internal view returns (uint160) {
        bytes32 data = IExtsload(poolManager).extsload(keccak256(abi.encodePacked(poolId, POOLS_SLOT)));
        return uint160(uint256(data));
    }
}

interface IExtsload {
    function extsload(bytes32 slot) external view returns (bytes32);
}
