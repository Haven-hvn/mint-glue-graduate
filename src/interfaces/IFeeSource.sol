// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Where a router reads the DAO take at sweep time. Implemented by the factory, governed there.
interface IFeeSource {
    /// @return dao Receives the DAO cut (in the router's RESERVE). Ignored when `bps == 0`.
    /// @return bps DAO cut in basis points of every claim.
    function feeInfo() external view returns (address dao, uint16 bps);

    /// @notice Hard ceiling on `bps`, immutable. Routers clamp to it independently.
    function MAX_DAO_BPS() external view returns (uint16);
}
