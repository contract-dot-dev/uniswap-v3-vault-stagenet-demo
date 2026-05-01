// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UniswapV3Vault} from "../src/UniswapV3Vault.sol";

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

/// @notice Swaps against the same Uniswap V3 pool the vault uses, to push
///         price around and generate fees the vault can collect.
///
/// Required env vars:
///   VAULT        Address of the deployed UniswapV3Vault.
///   PRIVATE_KEY  Funded key holding the input token.
///   AMOUNT_IN    Amount of input token to swap (in token's smallest unit).
///
/// Optional env vars:
///   ZERO_FOR_ONE Swap direction. true = token0 -> token1 (default: true).
///   SWAP_ROUTER  Uniswap V3 SwapRouter (default: mainnet 0xE592...1564).
contract Swap is Script {
    address constant DEFAULT_SWAP_ROUTER =
        0xE592427A0AEce92De3Edee1F18E0157C05861564;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address vaultAddr = vm.envAddress("VAULT");
        uint256 amountIn = vm.envUint("AMOUNT_IN");
        bool zeroForOne = vm.envOr("ZERO_FOR_ONE", true);
        address router = vm.envOr("SWAP_ROUTER", DEFAULT_SWAP_ROUTER);

        UniswapV3Vault vault = UniswapV3Vault(vaultAddr);
        address token0 = vault.token0();
        address token1 = vault.token1();
        uint24 fee = vault.poolFee();

        address tokenIn = zeroForOne ? token0 : token1;
        address tokenOut = zeroForOne ? token1 : token0;

        address sender = vm.addr(deployerKey);
        require(
            IERC20(tokenIn).balanceOf(sender) >= amountIn,
            "Insufficient input token balance"
        );

        console.log("Swapping via router:", router);
        console.log("tokenIn:            ", tokenIn);
        console.log("tokenOut:           ", tokenOut);
        console.log("amountIn:           ", amountIn);

        vm.startBroadcast(deployerKey);

        IERC20(tokenIn).approve(router, amountIn);

        uint256 amountOut = ISwapRouter(router).exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: fee,
                recipient: sender,
                deadline: block.timestamp + 600,
                amountIn: amountIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        vm.stopBroadcast();

        console.log("amountOut:          ", amountOut);
    }
}
