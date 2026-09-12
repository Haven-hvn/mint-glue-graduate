// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ISwapper} from "../interfaces/ISwapper.sol";
import {IERC20Min, IWETHMin} from "../interfaces/IERC20Min.sol";

interface ISwapRouterV3 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

/// @title  UniswapV3Swapper
/// @notice Reference ISwapper: one Uniswap V3 pool (router + fee tier fixed at deploy). Stateless; only
///         ever moves the caller's own tokens. Slippage is the caller's `minOut`, so a router that relies
///         on this lego trusts its keepers not to sandwich themselves; prefer a swap-free route when you can.
contract UniswapV3Swapper is ISwapper {
    ISwapRouterV3 public immutable ROUTER;
    address public immutable WNATIVE;
    uint24 public immutable FEE;

    error TransferFailed();

    constructor(ISwapRouterV3 router, address wnative, uint24 fee) {
        ROUTER = router;
        WNATIVE = wnative;
        FEE = fee;
    }

    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut)
        external
        returns (uint256 amountOut)
    {
        bool native = tokenOut == address(0);
        if (!IERC20Min(tokenIn).transferFrom(msg.sender, address(this), amountIn)) revert TransferFailed();
        IERC20Min(tokenIn).approve(address(ROUTER), amountIn);
        amountOut = ROUTER.exactInputSingle(
            ISwapRouterV3.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: native ? WNATIVE : tokenOut,
                fee: FEE,
                recipient: native ? address(this) : msg.sender,
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            })
        );
        if (native) {
            IWETHMin(WNATIVE).withdraw(amountOut);
            (bool ok,) = msg.sender.call{value: amountOut}("");
            if (!ok) revert TransferFailed();
        }
    }

    receive() external payable {}
}
