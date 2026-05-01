// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UniswapV3Vault} from "../src/UniswapV3Vault.sol";

/// @notice Provides liquidity to the Uniswap V3 pool by minting vault shares.
///
/// Required env vars:
///   VAULT        Address of the deployed UniswapV3Vault.
///   PRIVATE_KEY  Funded key holding token0/token1.
///
/// Optional env vars:
///   SHARES       Number of shares to mint (default: 1e18).
contract Mint is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address vaultAddr = vm.envAddress("VAULT");
        uint256 shares = vm.envOr("SHARES", uint256(1e18));

        UniswapV3Vault vault = UniswapV3Vault(vaultAddr);
        IERC20 token0 = IERC20(vault.token0());
        IERC20 token1 = IERC20(vault.token1());

        (uint256 preview0, uint256 preview1) = vault.previewMint(shares);
        console.log("Previewed token0 in:", preview0);
        console.log("Previewed token1 in:", preview1);

        address sender = vm.addr(deployerKey);
        require(
            token0.balanceOf(sender) >= preview0,
            "Insufficient token0 balance"
        );
        require(
            token1.balanceOf(sender) >= preview1,
            "Insufficient token1 balance"
        );

        vm.startBroadcast(deployerKey);

        // Approve only what's needed for this mint.
        token0.approve(vaultAddr, preview0);
        token1.approve(vaultAddr, preview1);

        (uint256 amount0, uint256 amount1) = vault.mint(shares);

        vm.stopBroadcast();

        console.log("Shares minted:        ", shares);
        console.log("token0 deposited:     ", amount0);
        console.log("token1 deposited:     ", amount1);
        console.log("Vault total supply:   ", vault.totalSupply());
        console.log("Sender share balance: ", vault.balanceOf(sender));
        console.log("Active position id:   ", vault.tokenId());
    }
}
