// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice The slice of GlueHook the router and factory need. Struct layouts mirror IGlueHook exactly.
interface IGlueHookMin {
    struct PoolKey {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    struct ProgramConfig {
        uint64 buybackShareWad;
        uint64 burnShareWad;
        uint64 compoundShareWad;
        uint64 potCompoundShareWad;
        uint64 potBurnShareWad;
        bool publicHarvest;
        address secondaryRecipient;
        address mainRecipient;
        uint256 minMain;
        uint256 minSecondary;
    }

    struct Program {
        uint128 liquidity;
        int24 tickLower;
        int24 tickUpper;
        bool exists;
        bool publicHarvest;
        uint64 buybackShareWad;
        address owner;
        uint64 burnShareWad;
        address secondaryRecipient;
        uint64 compoundShareWad;
        address mainRecipient;
        uint64 potCompoundShareWad;
        address operator;
        uint64 potBurnShareWad;
        uint256 minMain;
        uint256 minSecondary;
        uint256 carryMain;
        uint256 carrySecondary;
    }

    struct Pot {
        address admin;
        address main;
        address secondary;
        address recipient;
        bool configured;
        uint256 balance;
    }

    /// @notice The chain's canonical wrapped native token.
    function NATIVEWRAP() external view returns (address);

    /// @notice Fund a pot with its SECONDARY. Native: `msg.value == amount`. ERC20: approve first, no value.
    function donate(PoolKey calldata key, uint256 amount) external payable returns (uint256 credited);

    /// @notice Initialise the pool, declare the pot roles and create the seeded LP program in one call.
    ///         Caller becomes pot admin. `owner == address(0)` surrenders the program at birth: rules frozen,
    ///         liquidity locked forever, public harvest. `(0,0)` ticks = full range. Native side from
    ///         `msg.value` (excess refunded), ERC20 side from the caller's allowance to the hook.
    function launchPool(
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        address main,
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        address owner,
        ProgramConfig calldata config
    ) external payable returns (uint256 amount0, uint256 amount1);

    /// @notice Add liquidity to the pool's program position. OWNER only. Pending fees are harvested first.
    ///         Native side from `msg.value` (excess refunded), ERC20 side from the caller's allowance.
    function addProgramLiquidity(PoolKey calldata key, uint128 liquidity)
        external
        payable
        returns (uint256 amount0, uint256 amount1);

    /// @dev Owner-only on the hook; listed here only so tests can prove nobody but the router could call them.
    function removeProgramLiquidity(PoolKey calldata key, uint128 liquidity, address to)
        external
        returns (uint256 amount0, uint256 amount1);
    function transferProgramOwnership(bytes32 poolId, address newOwner) external;

    /// @notice Collect the program's pending LP fees and run the split. Public on our programs.
    function harvest(PoolKey calldata key) external returns (uint256 mainFees, uint256 secondaryFees);

    function potOf(bytes32 poolId) external view returns (Pot memory pot);
    function programOf(bytes32 poolId) external view returns (Program memory program);

    /// @dev Operator-only.
    function setProgramConfig(bytes32 poolId, ProgramConfig calldata config) external;
    /// @dev Operator-only. `address(0)` freezes the rules forever.
    function setProgramOperator(bytes32 poolId, address newOperator) external;
}
