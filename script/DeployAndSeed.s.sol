// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UniswapV3Vault} from "../src/UniswapV3Vault.sol";

/// @notice Deploys a fresh UniswapV3Vault and seeds it with initial liquidity
///         in a single broadcast.
///
/// Required env vars:
///   PRIVATE_KEY  Funded key holding token0 (USDC) and token1 (WETH).
///
/// Optional env vars:
///   SHARES       Number of shares to mint into the fresh vault.
///                Default: 500_000e18 (~$1M TVL on the first mint).
contract DeployAndSeed is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        uint256 shares = vm.envOr("SHARES", uint256(500_000e18));
        address sender = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        UniswapV3Vault vault = new UniswapV3Vault();

        console.log("UniswapV3Vault deployed at:", address(vault));
        console.log(
            "Tick range: [%s, %s]",
            vm.toString(vault.tickLower()),
            vm.toString(vault.tickUpper())
        );

        IERC20 token0 = IERC20(vault.token0());
        IERC20 token1 = IERC20(vault.token1());

        (uint256 amount0In, uint256 amount1In) = vault.previewMint(shares);
        console.log("Previewed token0 in:", amount0In);
        console.log("Previewed token1 in:", amount1In);

        require(
            token0.balanceOf(sender) >= amount0In,
            "Insufficient token0 balance for seed mint"
        );
        require(
            token1.balanceOf(sender) >= amount1In,
            "Insufficient token1 balance for seed mint"
        );

        token0.approve(address(vault), amount0In);
        token1.approve(address(vault), amount1In);

        (uint256 amount0, uint256 amount1) = vault.mint(shares);

        vm.stopBroadcast();

        console.log("Shares minted:        ", shares);
        console.log("token0 deposited:     ", amount0);
        console.log("token1 deposited:     ", amount1);
        console.log("Vault total supply:   ", vault.totalSupply());
        console.log("Sender share balance: ", vault.balanceOf(sender));
        console.log("Active position id:   ", vault.tokenId());
        console.log("USD TVL:              ", vault.getUsdTvl());
        console.log("USD share price:      ", vault.getUsdSharePrice());
    }
}
