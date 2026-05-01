// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {UniswapV3Vault} from "../src/UniswapV3Vault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ISwapRouter {
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

    function exactInputSingle(
        ExactInputSingleParams calldata params
    ) external payable returns (uint256 amountOut);
}

contract UniswapV3VaultTest is Test {
    // Mainnet addresses
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant SWAP_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

    uint24 constant POOL_FEE = 500; // 0.05%

    UniswapV3Vault vault;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address trader = makeAddr("trader");

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_RPC_URL"));

        vault = new UniswapV3Vault();

        _fundAndApprove(alice, 500_000e6, 200e18);
        _fundAndApprove(bob, 500_000e6, 200e18);

        deal(USDC, trader, 10_000_000e6);
        deal(WETH, trader, 5000e18);
        vm.startPrank(trader);
        IERC20(USDC).approve(SWAP_ROUTER, type(uint256).max);
        IERC20(WETH).approve(SWAP_ROUTER, type(uint256).max);
        vm.stopPrank();
    }

    // ========== Deployment ==========

    function testDeployment() public view {
        assertEq(vault.token0(), USDC);
        assertEq(vault.token1(), WETH);
        assertEq(vault.poolFee(), POOL_FEE);
        assertEq(vault.tokenId(), 0);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.rebalanceCount(), 0);
        assertEq(vault.compoundCount(), 0);
        assertTrue(vault.tickLower() < vault.tickUpper());
    }

    function testPreviewMintBeforeFirstDeposit() public view {
        (uint256 amount0, uint256 amount1) = vault.previewMint(1e18);
        assertTrue(
            amount0 > 0 || amount1 > 0,
            "Preview should return non-zero amounts"
        );
    }

    // ========== Mint ==========

    function testFirstMint() public {
        uint256 shares = 1e18;

        (uint256 previewAmount0, uint256 previewAmount1) = vault.previewMint(
            shares
        );

        vm.prank(alice);
        (uint256 amount0, uint256 amount1) = vault.mint(shares);

        assertEq(vault.totalSupply(), shares);
        assertEq(vault.balanceOf(alice), shares);
        assertTrue(vault.tokenId() != 0, "Token ID should be set");
        assertEq(amount0, previewAmount0);
        assertEq(amount1, previewAmount1);

        console2.log("First mint - USDC deposited:", amount0);
        console2.log("First mint - WETH deposited:", amount1);
    }

    function testSecondMintKeepsSamePosition() public {
        vm.prank(alice);
        vault.mint(1e18);

        uint256 tokenIdAfterFirst = vault.tokenId();

        vm.prank(bob);
        vault.mint(1e18);

        assertEq(vault.totalSupply(), 2e18);
        assertEq(vault.balanceOf(alice), 1e18);
        assertEq(vault.balanceOf(bob), 1e18);
        assertEq(vault.tokenId(), tokenIdAfterFirst);
    }

    function testMintMultipleShares() public {
        vm.prank(alice);
        vault.mint(5e18);

        assertEq(vault.totalSupply(), 5e18);
        assertEq(vault.balanceOf(alice), 5e18);
    }

    function testCannotMintZeroShares() public {
        vm.expectRevert("Must mint more than zero shares");
        vm.prank(alice);
        vault.mint(0);
    }

    // ========== Withdraw ==========

    function testWithdrawAll() public {
        uint256 shares = 1e18;

        vm.prank(alice);
        vault.mint(shares);

        uint256 usdc0 = IERC20(USDC).balanceOf(alice);
        uint256 weth0 = IERC20(WETH).balanceOf(alice);

        vm.prank(alice);
        (uint256 amount0, uint256 amount1) = vault.withdraw(shares);

        assertEq(vault.totalSupply(), 0);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(IERC20(USDC).balanceOf(alice), usdc0 + amount0);
        assertEq(IERC20(WETH).balanceOf(alice), weth0 + amount1);

        console2.log("Withdraw - returned USDC:", amount0);
        console2.log("Withdraw - returned WETH:", amount1);
    }

    function testWithdrawPartial() public {
        vm.prank(alice);
        vault.mint(2e18);

        vm.prank(alice);
        vault.withdraw(1e18);

        assertEq(vault.totalSupply(), 1e18);
        assertEq(vault.balanceOf(alice), 1e18);
    }

    function testCannotWithdrawZeroShares() public {
        vm.prank(alice);
        vault.mint(1e18);

        vm.expectRevert("Can't withdraw zero shares");
        vm.prank(alice);
        vault.withdraw(0);
    }

    function testCannotWithdrawMoreThanSupply() public {
        vm.prank(alice);
        vault.mint(1e18);

        vm.expectRevert("Can't withdraw more shares than the total supply");
        vm.prank(alice);
        vault.withdraw(2e18);
    }

    // ========== Compound ==========

    function testCompound() public {
        vm.prank(alice);
        vault.mint(10e18);

        _swap(WETH, USDC, 100e18);
        _swap(USDC, WETH, 200_000e6);

        uint128 liquidityAdded = vault.compound();

        assertEq(vault.compoundCount(), 1);
        console2.log("Compound - liquidity added:", uint256(liquidityAdded));
    }

    function testCannotCompoundWithoutPosition() public {
        vm.expectRevert("No position");
        vault.compound();
    }

    // ========== Rebalance ==========

    function testRebalance() public {
        vm.prank(alice);
        vault.mint(10e18);

        int24 oldTickLower = vault.tickLower();
        int24 oldTickUpper = vault.tickUpper();

        // Move the price so the rebalance recenters on a different tick
        _swap(WETH, USDC, 500e18);

        vault.rebalance();

        assertEq(vault.rebalanceCount(), 1);
        assertTrue(
            vault.tickLower() != oldTickLower ||
                vault.tickUpper() != oldTickUpper,
            "Tick range should change"
        );
        assertTrue(vault.tickLower() < vault.tickUpper());
        assertTrue(vault.tokenId() != 0);

        console2.log("Old tickLower:", oldTickLower);
        console2.log("Old tickUpper:", oldTickUpper);
        console2.log("New tickLower:", vault.tickLower());
        console2.log("New tickUpper:", vault.tickUpper());
    }

    function testRebalanceMultipleTimes() public {
        vm.prank(alice);
        vault.mint(10e18);

        _swap(WETH, USDC, 200e18);
        vault.rebalance();
        assertEq(vault.rebalanceCount(), 1);

        _swap(USDC, WETH, 400_000e6);
        vault.rebalance();
        assertEq(vault.rebalanceCount(), 2);

        _swap(WETH, USDC, 100e18);
        vault.rebalance();
        assertEq(vault.rebalanceCount(), 3);
    }

    function testCannotRebalanceWithoutPosition() public {
        vm.expectRevert("No position");
        vault.rebalance();
    }

    // ========== View Functions ==========

    function testTotalUnderlyingAfterDeposit() public {
        (uint256 before0, uint256 before1) = vault.totalUnderlying();
        assertEq(before0, 0);
        assertEq(before1, 0);

        vm.prank(alice);
        vault.mint(1e18);

        (uint256 after0, uint256 after1) = vault.totalUnderlying();
        assertTrue(
            after0 > 0 || after1 > 0,
            "Underlying should be non-zero after deposit"
        );

        console2.log("Total underlying USDC:", after0);
        console2.log("Total underlying WETH:", after1);
    }

    function testGetUsdTvl() public {
        vm.prank(alice);
        vault.mint(1e18);

        uint256 tvl = vault.getUsdTvl();
        assertTrue(tvl > 0, "TVL should be non-zero");

        console2.log("USD TVL (1e18):", tvl);
    }

    function testGetUsdSharePrice() public {
        assertEq(vault.getUsdSharePrice(), 0);

        vm.prank(alice);
        vault.mint(1e18);

        uint256 sharePrice = vault.getUsdSharePrice();
        assertTrue(sharePrice > 0, "Share price should be non-zero");

        console2.log("USD share price (1e18):", sharePrice);
    }

    // ========== Integration ==========

    function testMultipleDepositorsWithdrawAll() public {
        vm.prank(alice);
        (uint256 aliceDep0, uint256 aliceDep1) = vault.mint(2e18);

        vm.prank(bob);
        (uint256 bobDep0, uint256 bobDep1) = vault.mint(1e18);

        assertEq(vault.totalSupply(), 3e18);

        vm.prank(alice);
        (uint256 aliceRet0, uint256 aliceRet1) = vault.withdraw(2e18);

        vm.prank(bob);
        (uint256 bobRet0, uint256 bobRet1) = vault.withdraw(1e18);

        assertEq(vault.totalSupply(), 0);
        assertTrue(aliceRet0 > 0 || aliceRet1 > 0, "Alice should get tokens");
        assertTrue(bobRet0 > 0 || bobRet1 > 0, "Bob should get tokens");

        // Total value out should be close to total value in (< 1% leak)
        uint256 totalDep0 = aliceDep0 + bobDep0;
        uint256 totalDep1 = aliceDep1 + bobDep1;
        uint256 totalRet0 = aliceRet0 + bobRet0;
        uint256 totalRet1 = aliceRet1 + bobRet1;

        assertTrue(
            totalRet0 >= (totalDep0 * 99) / 100,
            "Total USDC out should be >= 99% of USDC in"
        );
        assertTrue(
            totalRet1 >= (totalDep1 * 99) / 100,
            "Total WETH out should be >= 99% of WETH in"
        );

        console2.log("Alice returned USDC:", aliceRet0, "WETH:", aliceRet1);
        console2.log("Bob   returned USDC:", bobRet0, "WETH:", bobRet1);
    }

    function testDepositWithdrawNoMajorValueLeak() public {
        vm.prank(alice);
        (uint256 dep0, uint256 dep1) = vault.mint(1e18);

        vm.prank(alice);
        (uint256 ret0, uint256 ret1) = vault.withdraw(1e18);

        assertTrue(ret0 >= (dep0 * 99) / 100, "Should not lose >1% of USDC");
        assertTrue(ret1 >= (dep1 * 99) / 100, "Should not lose >1% of WETH");

        console2.log("Deposited USDC:", dep0, "Returned:", ret0);
        console2.log("Deposited WETH:", dep1, "Returned:", ret1);
    }

    function testSharePriceDoesNotDecreaseAfterCompound() public {
        vm.prank(alice);
        vault.mint(10e18);

        uint256 priceBefore = vault.getUsdSharePrice();

        _swap(WETH, USDC, 50e18);
        _swap(USDC, WETH, 100_000e6);

        vault.compound();

        uint256 priceAfter = vault.getUsdSharePrice();
        assertTrue(
            priceAfter >= priceBefore,
            "Share price should not decrease after compound"
        );

        console2.log("Price before compound:", priceBefore);
        console2.log("Price after compound: ", priceAfter);
    }

    function testRebalancePreservesValue() public {
        vm.prank(alice);
        vault.mint(10e18);

        uint256 tvlBefore = vault.getUsdTvl();

        vault.rebalance();

        uint256 tvlAfter = vault.getUsdTvl();

        // TVL should not drop by more than 1% (rounding / unused tokens)
        assertTrue(
            tvlAfter >= (tvlBefore * 99) / 100,
            "Rebalance should not destroy >1% of TVL"
        );

        console2.log("TVL before rebalance:", tvlBefore);
        console2.log("TVL after rebalance: ", tvlAfter);
    }

    // ========== Helpers ==========

    function _fundAndApprove(
        address user,
        uint256 usdcAmount,
        uint256 wethAmount
    ) internal {
        deal(USDC, user, usdcAmount);
        deal(WETH, user, wethAmount);
        vm.startPrank(user);
        IERC20(USDC).approve(address(vault), type(uint256).max);
        IERC20(WETH).approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    function _swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) internal {
        vm.prank(trader);
        ISwapRouter(SWAP_ROUTER).exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: POOL_FEE,
                recipient: trader,
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
    }
}
