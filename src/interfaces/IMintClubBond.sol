// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice The slice of mint.club's MCV2_Bond the router needs. Struct getters drop the `steps` array.
interface IMintClubBond {
    struct TokenParams {
        string name;
        string symbol;
    }

    struct BondParams {
        uint16 mintRoyalty;
        uint16 burnRoyalty;
        address reserveToken;
        uint128 maxSupply;
        uint128[] stepRanges;
        uint128[] stepPrices;
    }

    /// @dev `msg.value` must equal {creationFee}. The caller becomes the bond creator. A zero-price first
    ///      step mints `stepRanges[0]` tokens to the creator for free.
    function createToken(TokenParams calldata tp, BondParams calldata bp) external payable returns (address);
    function creationFee() external view returns (uint256);

    /// @return reserveAmount Total reserve the mint costs, royalty INCLUDED.
    function getReserveForToken(address token, uint256 tokensToMint)
        external
        view
        returns (uint256 reserveAmount, uint256 royalty);
    /// @dev Pulls `reserveAmount` from `msg.sender`; the royalty accrues to the CURRENT bond creator.
    function mint(address token, uint256 tokensToMint, uint256 maxReserveAmount, address receiver)
        external
        returns (uint256 reserveAmount);

    function tokenBond(address token)
        external
        view
        returns (
            address creator,
            uint16 mintRoyalty,
            uint16 burnRoyalty,
            uint40 createdAt,
            address reserveToken,
            uint256 reserveBalance
        );

    /// @dev Creator-only. Royalties accrue to `bond.creator`; they are pull-only and paid to `msg.sender`.
    function updateBondCreator(address token, address creator) external;

    /// @dev Pays `msg.sender` its full accrued balance in `reserveToken`. Reverts when zero.
    function claimRoyalties(address reserveToken) external;

    function userTokenRoyaltyBalance(address user, address reserveToken) external view returns (uint256);

    /// @return Current step price: reserve wei per 1e18 token wei.
    function priceForNextMint(address token) external view returns (uint128);
}
