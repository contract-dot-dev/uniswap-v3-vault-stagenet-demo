// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {
    IUniswapV3Pool
} from "./interfaces/IUniswapV3Pool.sol";
import {
    FixedPoint128
} from "./libraries/FixedPoint128.sol";
import {FullMath} from "./libraries/FullMath.sol";
import {TickMath} from "./libraries/TickMath.sol";
import {
    INonfungiblePositionManager
} from "./interfaces/INonfungiblePositionManager.sol";
import {
    LiquidityAmounts
} from "./libraries/LiquidityAmounts.sol";
import {
    IUniswapV3Factory
} from "./interfaces/IUniswapV3Factory.sol";

// Returns information about the tokens held in a Uniswap V3 NFT position
library PositionMath {
    // Returns the total amounts of token0 and token1 owned by a
    function total(
        INonfungiblePositionManager positionManager,
        uint256 tokenId,
        uint160 sqrtRatioX96
    ) internal view returns (uint256 amount0, uint256 amount1) {
        // Get the tokens actually provided as liquidity
        (uint256 amount0Principal, uint256 amount1Principal) = principal(
            positionManager,
            tokenId,
            sqrtRatioX96
        );

        // Get the unclaimed fees the position has earned
        (uint256 amount0Fee, uint256 amount1Fee) = fees(
            positionManager,
            tokenId
        );

        // Return their sum
        return (amount0Principal + amount0Fee, amount1Principal + amount1Fee);
    }

    // Calculates the tokens provided as liquidity by the NFT position
    function principal(
        INonfungiblePositionManager positionManager,
        uint256 tokenId,
        uint160 sqrtRatioX96
    ) internal view returns (uint256 amount0, uint256 amount1) {
        (
            ,
            ,
            ,
            ,
            ,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            ,
            ,
            ,

        ) = positionManager.positions(tokenId);

        (amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtRatioX96,
            TickMath.getSqrtRatioAtTick(tickLower),
            TickMath.getSqrtRatioAtTick(tickUpper),
            liquidity
        );
    }

    // Calculates the unclaimed fees the position has earned
    function fees(
        INonfungiblePositionManager positionManager,
        uint256 tokenId
    ) internal view returns (uint256 amount0, uint256 amount1) {
        // Get the position data
        (
            ,
            ,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 positionFeeGrowthInside0LastX128,
            uint256 positionFeeGrowthInside1LastX128,
            uint256 tokensOwed0,
            uint256 tokensOwed1
        ) = positionManager.positions(tokenId);

        // Get the pool address
        address poolAddress = IUniswapV3Factory(positionManager.factory())
            .getPool(token0, token1, fee);

        require(poolAddress != address(0), "Pool not found");

        IUniswapV3Pool pool = IUniswapV3Pool(poolAddress);

        // Get the current tick
        (, int24 tickCurrent, , , , , ) = pool.slot0();

        // Get the fee growth outside the position
        (
            ,
            ,
            uint256 lowerFeeGrowthOutside0X128,
            uint256 lowerFeeGrowthOutside1X128,
            ,
            ,
            ,

        ) = pool.ticks(tickLower);
        (
            ,
            ,
            uint256 upperFeeGrowthOutside0X128,
            uint256 upperFeeGrowthOutside1X128,
            ,
            ,
            ,

        ) = pool.ticks(tickUpper);

        // Calculate the fee growth inside the position
        // Note: Uniswap V3 uses unchecked math for fee growth accumulators (they wrap around)

        uint256 feeGrowthInside0X128;
        uint256 feeGrowthInside1X128;

        // Get fee growth inside based on current tick location possibilities
        unchecked {
            if (tickCurrent < tickLower) {
                feeGrowthInside0X128 =
                    lowerFeeGrowthOutside0X128 -
                    upperFeeGrowthOutside0X128;
                feeGrowthInside1X128 =
                    lowerFeeGrowthOutside1X128 -
                    upperFeeGrowthOutside1X128;
            } else if (tickCurrent < tickUpper) {
                uint256 feeGrowthGlobal0X128 = pool.feeGrowthGlobal0X128();
                uint256 feeGrowthGlobal1X128 = pool.feeGrowthGlobal1X128();
                feeGrowthInside0X128 =
                    feeGrowthGlobal0X128 -
                    lowerFeeGrowthOutside0X128 -
                    upperFeeGrowthOutside0X128;
                feeGrowthInside1X128 =
                    feeGrowthGlobal1X128 -
                    lowerFeeGrowthOutside1X128 -
                    upperFeeGrowthOutside1X128;
            } else {
                feeGrowthInside0X128 =
                    upperFeeGrowthOutside0X128 -
                    lowerFeeGrowthOutside0X128;
                feeGrowthInside1X128 =
                    upperFeeGrowthOutside1X128 -
                    lowerFeeGrowthOutside1X128;
            }

            // Calculate the amount of fees earned in token0 and token1
            amount0 =
                FullMath.mulDiv(
                    feeGrowthInside0X128 - positionFeeGrowthInside0LastX128,
                    liquidity,
                    FixedPoint128.Q128
                ) +
                tokensOwed0;

            amount1 =
                FullMath.mulDiv(
                    feeGrowthInside1X128 - positionFeeGrowthInside1LastX128,
                    liquidity,
                    FixedPoint128.Q128
                ) +
                tokensOwed1;
        }
    }
}
