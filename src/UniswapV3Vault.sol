// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    IERC20Metadata
} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    IUniswapV3Factory
} from "./interfaces/IUniswapV3Factory.sol";
import {
    IUniswapV3Pool
} from "./interfaces/IUniswapV3Pool.sol";
import {FullMath} from "./libraries/FullMath.sol";
import {
    INonfungiblePositionManager
} from "./interfaces/INonfungiblePositionManager.sol";
import {
    AggregatorV3Interface
} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {
    LiquidityAmounts
} from "./libraries/LiquidityAmounts.sol";
import {TickMath} from "./libraries/TickMath.sol";
import {PositionMath} from "./PositionMath.sol";

// Rebalanceable Uniswap V3 liquidity position vault
// Owns a single liquidity position with mutable tick range
// Supports autocompounding and periodic rebalancing around current price
contract UniswapV3Vault is ERC20 {
    uint public version = 1;

    // *** LIBRARIES ***

    using SafeERC20 for IERC20;

    // *** STATE VARIABLES ***

    // The pool's token pair (Ethereum mainnet USDC/WETH)
    address public constant token0 =
        0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // USDC
    address public constant token1 =
        0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // WETH

    // The pool's fee tier (0.05%)
    uint24 public constant poolFee = 500;

    // The Uniswap V3 NonfungiblePositionManager (Ethereum mainnet)
    INonfungiblePositionManager public constant positionManager =
        INonfungiblePositionManager(
            0xC36442b4a4522E871399CD717aBDD847Ab11FE88
        );

    // Chainlink price feeds for token0 and token1 denominated in USD
    address public constant token0PriceFeed =
        0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6; // USDC/USD
    address public constant token1PriceFeed =
        0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419; // ETH/USD

    // The initial amounts of token0 and token1 to mint per 1e18 shares
    uint256 public constant init0 = 1e6; // 1 USDC (6 decimals)
    uint256 public constant init1 = 1e18; // 1 WETH (18 decimals)

    // Half-width of the initial tick range around the current pool tick
    int24 public constant ticksEitherSide = 1200; // ~12% range either side

    // The pool contract
    IUniswapV3Pool public immutable pool;

    // Mutable tick range (updated on rebalance)
    int24 public tickLower;
    int24 public tickUpper;

    // The NFT ID of the vault's position in the position manager
    uint256 public tokenId;

    // The constant for 1e18
    uint256 private constant ONE = 1e18;

    // Counters
    uint256 public rebalanceCount;
    uint256 public compoundCount;

    // Lifetime fees collected by the vault from its position(s),
    // accumulated across compound, rebalance, and withdraw calls.
    uint256 public totalFees0Collected;
    uint256 public totalFees1Collected;

    // *** EVENTS ***

    event Mint(
        address indexed sender,
        uint256 amount0,
        uint256 amount1,
        uint256 shares
    );

    event Withdraw(
        address indexed sender,
        uint256 amount0,
        uint256 amount1,
        uint256 shares
    );

    event Compound(
        uint256 amount0Used,
        uint256 amount1Used,
        uint128 liquidityAdded
    );

    event InitialPositionMinted(uint256 indexed tokenId);

    event Rebalance(
        int24 newTickLower,
        int24 newTickUpper,
        uint256 rebalanceCount
    );

    event FeesCollected(uint256 amount0, uint256 amount1);

    // *** CONSTRUCTOR ***

    constructor() ERC20("Uniswap V3 Vault Share", "UVS") {
        // Get the pool address from the position manager

        address factory = positionManager.factory();

        address poolAddress = IUniswapV3Factory(factory).getPool(
            token0,
            token1,
            poolFee
        );

        require(poolAddress != address(0), "Pool not found");

        pool = IUniswapV3Pool(poolAddress);

        // Compute tick range around current price

        (, int24 currentTick, , , , , ) = pool.slot0();

        int24 spacing = pool.tickSpacing();

        int24 alignedTick = (currentTick / spacing) * spacing;

        if (currentTick < 0 && currentTick % spacing != 0) {
            alignedTick -= spacing;
        }

        int24 ticksInSpacing = (ticksEitherSide / spacing) * spacing;

        require(ticksInSpacing > 0, "Invalid tick range");

        tickLower = alignedTick - ticksInSpacing;
        tickUpper = alignedTick + ticksInSpacing;

        IERC20(token0).approve(address(positionManager), type(uint256).max);
        IERC20(token1).approve(address(positionManager), type(uint256).max);
    }

    // *** VIEW FUNCTIONS ***

    // Returns the token0/token1 amounts owned by the vault's position,
    // scaled down by each token's decimals (i.e. whole-token units).
    function totalUnderlying()
        public
        view
        returns (uint256 amount0, uint256 amount1)
    {
        (uint256 raw0, uint256 raw1) = _totalUnderlyingRaw();

        amount0 = raw0 / (10 ** IERC20Metadata(token0).decimals());
        amount1 = raw1 / (10 ** IERC20Metadata(token1).decimals());
    }

    // Returns the USD TVL of the vault, in whole USD
    function getUsdTvl() public view returns (uint256 usdValue) {
        usdValue = _getUsdTvlRaw() / ONE;
    }

    // Returns the USD value of one share, in whole USD per share
    function getUsdSharePrice() external view returns (uint256 price) {
        uint256 supply = totalSupply();

        if (supply == 0) {
            return 0;
        }

        // Both _getUsdTvlRaw() and supply are 1e18-scaled, so their integer
        // ratio is USD per share at 1e0 scale.
        price = _getUsdTvlRaw() / supply;
    }

    // Returns the token amounts required to mint the given number of shares.
    function previewMint(
        uint256 shares
    ) external view returns (uint256 amount0, uint256 amount1) {
        (amount0, amount1) = _calculateMintAmountFromShares(shares);
    }

    // Returns the current pool tick
    function getCurrentTick() external view returns (int24) {
        (, int24 currentTick, , , , , ) = pool.slot0();
        return currentTick;
    }

    // Returns the fees the active position has accrued but not yet collected,
    // in raw token0/token1 units. Computed from pool fee growth accumulators,
    // matching what positionManager.collect would return at this block.
    function fees()
        external
        view
        returns (uint256 amount0, uint256 amount1)
    {
        if (tokenId == 0) {
            return (0, 0);
        }

        (amount0, amount1) = PositionMath.fees(positionManager, tokenId);
    }

    // Returns the lifetime fees the vault has collected from its position(s),
    // in raw token0/token1 units. Updated whenever the vault calls
    // positionManager.collect (compound, rebalance, withdraw).
    function cumulativeFees()
        external
        view
        returns (uint256 amount0, uint256 amount1)
    {
        amount0 = totalFees0Collected;
        amount1 = totalFees1Collected;
    }

    // *** EXTERNAL STATE-CHANGING FUNCTIONS ***

    // Mints vault shares by depositing the token0 and token1
    function mint(
        uint256 shares
    ) external returns (uint256 amount0, uint256 amount1) {
        (amount0, amount1) = _calculateMintAmountFromShares(shares);

        require(amount0 > 0 || amount1 > 0, "Can't deposit zero tokens");

        // Transfer the tokens from the sender to the vault

        if (amount0 > 0) {
            IERC20(token0).safeTransferFrom(msg.sender, address(this), amount0);
        }
        if (amount1 > 0) {
            IERC20(token1).safeTransferFrom(msg.sender, address(this), amount1);
        }

        if (tokenId == 0) {
            // Mint the initial position
            (uint256 mintedTokenId, , , ) = positionManager.mint(
                INonfungiblePositionManager.MintParams({
                    token0: token0,
                    token1: token1,
                    fee: poolFee,
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    amount0Desired: amount0,
                    amount1Desired: amount1,
                    amount0Min: 0,
                    amount1Min: 0,
                    recipient: address(this),
                    deadline: block.timestamp
                })
            );

            // Set the vault's position NFT ID on the initial mint
            tokenId = mintedTokenId;

            emit InitialPositionMinted(mintedTokenId);
        } else {
            // Increase the liquidity of the existing position
            _increaseLiquidity();
        }

        _mint(msg.sender, shares);

        emit Mint(msg.sender, amount0, amount1, shares);
    }

    // Burns shares and withdraws the caller's pro-rata share of vault's underlying assets
    function withdraw(
        uint256 shares
    ) external returns (uint256 amount0, uint256 amount1) {
        require(shares > 0, "Can't withdraw zero shares");

        uint256 supplyBefore = totalSupply();

        require(
            shares <= supplyBefore,
            "Can't withdraw more shares than the total supply"
        );

        if (tokenId != 0) {
            (, , , , , , , uint128 liquidity, , , , ) = positionManager
                .positions(tokenId);

            uint128 liquidityToBurn = uint128(
                FullMath.mulDiv(liquidity, shares, supplyBefore)
            );

            uint256 principal0;
            uint256 principal1;

            if (liquidityToBurn > 0) {
                (principal0, principal1) = positionManager.decreaseLiquidity(
                    INonfungiblePositionManager.DecreaseLiquidityParams({
                        tokenId: tokenId,
                        liquidity: liquidityToBurn,
                        amount0Min: 0,
                        amount1Min: 0,
                        deadline: block.timestamp
                    })
                );
            }

            (uint256 collected0, uint256 collected1) = positionManager.collect(
                INonfungiblePositionManager.CollectParams({
                    tokenId: tokenId,
                    recipient: address(this),
                    amount0Max: type(uint128).max,
                    amount1Max: type(uint128).max
                })
            );

            // The collect call drains everything owed, which equals the
            // principal just unlocked plus accrued fees. The remainder is fees.
            _accrueFees(collected0 - principal0, collected1 - principal1);
        }

        _burn(msg.sender, shares);

        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));

        amount0 = FullMath.mulDiv(balance0, shares, supplyBefore);
        amount1 = FullMath.mulDiv(balance1, shares, supplyBefore);

        if (amount0 > 0) {
            IERC20(token0).safeTransfer(msg.sender, amount0);
        }
        if (amount1 > 0) {
            IERC20(token1).safeTransfer(msg.sender, amount1);
        }

        emit Withdraw(msg.sender, amount0, amount1, shares);
    }

    // Collects fees and adds any idle balances back into the position
    function compound() external returns (uint128 liquidityAdded) {
        require(tokenId != 0, "No position");

        (uint256 fees0, uint256 fees1) = positionManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        _accrueFees(fees0, fees1);

        (
            uint128 liquidity,
            uint256 amount0Used,
            uint256 amount1Used
        ) = _increaseLiquidity();

        liquidityAdded = liquidity;

        compoundCount++;

        emit Compound(amount0Used, amount1Used, liquidityAdded);
    }

    // Removes all liquidity, recenters tick range around current price, and re-deposits
    function rebalance() external {
        require(tokenId != 0, "No position");

        // 1. Remove all liquidity from current position

        (, , , , , , , uint128 liquidity, , , , ) = positionManager.positions(
            tokenId
        );

        uint256 principal0;
        uint256 principal1;

        if (liquidity > 0) {
            (principal0, principal1) = positionManager.decreaseLiquidity(
                INonfungiblePositionManager.DecreaseLiquidityParams({
                    tokenId: tokenId,
                    liquidity: liquidity,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: block.timestamp
                })
            );
        }

        // 2. Collect all tokens

        (uint256 collected0, uint256 collected1) = positionManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        // The collect drains principal just unlocked plus accrued fees.
        // The remainder over the unlocked principal is fees.
        _accrueFees(collected0 - principal0, collected1 - principal1);

        // 3. Read current tick and compute new aligned tick range

        (, int24 currentTick, , , , , ) = pool.slot0();

        int24 spacing = pool.tickSpacing();

        int24 alignedTick = (currentTick / spacing) * spacing;

        if (currentTick < 0 && currentTick % spacing != 0) {
            alignedTick -= spacing;
        }

        int24 ticksInSpacing = (ticksEitherSide / spacing) * spacing;

        require(ticksInSpacing > 0, "Invalid tick range after alignment");

        // 4. Update tick range

        tickLower = alignedTick - ticksInSpacing;
        tickUpper = alignedTick + ticksInSpacing;

        // 5. Mint a new position with full token balances

        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));

        if (balance0 > 0 || balance1 > 0) {
            (uint256 newTokenId, , , ) = positionManager.mint(
                INonfungiblePositionManager.MintParams({
                    token0: token0,
                    token1: token1,
                    fee: poolFee,
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    amount0Desired: balance0,
                    amount1Desired: balance1,
                    amount0Min: 0,
                    amount1Min: 0,
                    recipient: address(this),
                    deadline: block.timestamp
                })
            );

            tokenId = newTokenId;
        }

        rebalanceCount++;

        emit Rebalance(tickLower, tickUpper, rebalanceCount);
    }

    // *** INTERNAL FUNCTIONS ***

    // Full-precision underlying token amounts (raw, no decimal scaling).
    // Used by mint pro-rata math and the raw USD TVL calculation.
    function _totalUnderlyingRaw()
        internal
        view
        returns (uint256 amount0, uint256 amount1)
    {
        if (tokenId != 0) {
            (uint160 sqrtPriceX96, , , , , , ) = pool.slot0();

            (uint256 pos0, uint256 pos1) = PositionMath.total(
                positionManager,
                tokenId,
                sqrtPriceX96
            );

            amount0 += pos0;
            amount1 += pos1;
        }

        // Idle tokens not used in mints are included in the underlying balance
        amount0 += IERC20(token0).balanceOf(address(this));
        amount1 += IERC20(token1).balanceOf(address(this));
    }

    // Full-precision USD TVL, scaled to 1e18.
    function _getUsdTvlRaw() internal view returns (uint256 usdValue) {
        (uint256 amount0, uint256 amount1) = _totalUnderlyingRaw();

        usdValue =
            _tokenUsdValue(amount0, token0, token0PriceFeed) +
            _tokenUsdValue(amount1, token1, token1PriceFeed);
    }

    function _accrueFees(uint256 fees0, uint256 fees1) internal {
        if (fees0 == 0 && fees1 == 0) {
            return;
        }

        totalFees0Collected += fees0;
        totalFees1Collected += fees1;

        emit FeesCollected(fees0, fees1);
    }

    function _increaseLiquidity()
        internal
        returns (uint128 liquidity, uint256 amount0Used, uint256 amount1Used)
    {
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));

        if (balance0 == 0 && balance1 == 0) {
            return (0, 0, 0);
        }

        (liquidity, amount0Used, amount1Used) = positionManager
            .increaseLiquidity(
                INonfungiblePositionManager.IncreaseLiquidityParams({
                    tokenId: tokenId,
                    amount0Desired: balance0,
                    amount1Desired: balance1,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: block.timestamp
                })
            );
    }

    function _calculateMintAmountFromShares(
        uint256 shares
    ) internal view returns (uint256 amount0, uint256 amount1) {
        require(shares > 0, "Must mint more than zero shares");

        uint256 shareSupplyBefore = totalSupply();

        (uint256 total0, uint256 total1) = _totalUnderlyingRaw();

        if (shareSupplyBefore == 0) {
            (uint160 sqrtPriceX96, , , , , , ) = pool.slot0();
            uint160 sqrtLower = TickMath.getSqrtRatioAtTick(tickLower);
            uint160 sqrtUpper = TickMath.getSqrtRatioAtTick(tickUpper);

            uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96,
                sqrtLower,
                sqrtUpper,
                init0,
                init1
            );

            require(liquidity > 0, "Insufficient init liquidity");

            (uint256 initAmount0, uint256 initAmount1) = LiquidityAmounts
                .getAmountsForLiquidity(
                    sqrtPriceX96,
                    sqrtLower,
                    sqrtUpper,
                    liquidity
                );

            amount0 = FullMath.mulDivRoundingUp(shares, initAmount0, ONE);
            amount1 = FullMath.mulDivRoundingUp(shares, initAmount1, ONE);
        } else {
            amount0 = FullMath.mulDivRoundingUp(
                shares,
                total0,
                shareSupplyBefore
            );
            amount1 = FullMath.mulDivRoundingUp(
                shares,
                total1,
                shareSupplyBefore
            );
        }
    }

    function _tokenUsdValue(
        uint256 amount,
        address token,
        address priceFeed
    ) internal view returns (uint256 value) {
        (, int256 answer, , , ) = AggregatorV3Interface(priceFeed)
            .latestRoundData();

        require(answer > 0, "Invalid price");

        uint8 feedDecimals = AggregatorV3Interface(priceFeed).decimals();
        uint8 tokenDecimals = IERC20Metadata(token).decimals();

        uint256 valueInFeedDecimals = FullMath.mulDiv(
            amount,
            uint256(answer),
            10 ** tokenDecimals
        );

        if (feedDecimals == 18) {
            return valueInFeedDecimals;
        }

        if (feedDecimals < 18) {
            return valueInFeedDecimals * (10 ** (18 - feedDecimals));
        }

        return valueInFeedDecimals / (10 ** (feedDecimals - 18));
    }
}
