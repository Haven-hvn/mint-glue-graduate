// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice A stateless swap lego. Pulls `amountIn` of `tokenIn` from `msg.sender` (allowance), delivers
///         at least `minOut` of `tokenOut` back to `msg.sender` (native ETH when `tokenOut == address(0)`).
/// @dev The swapper is the router's ONLY trust surface on the swap path: it is fixed at deploy and its
///      own slippage / oracle policy is what protects a permissionless sweep from a sandwiching keeper.
interface ISwapper {
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut)
        external
        returns (uint256 amountOut);
}
