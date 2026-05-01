// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {UniswapV3Vault} from "../src/UniswapV3Vault.sol";

/// @notice Collects fees from the vault's Uniswap V3 position and redeposits
///         them as additional liquidity in the same range.
///
/// Required env vars:
///   VAULT        Address of the deployed UniswapV3Vault.
///   PRIVATE_KEY  Funded key to broadcast the transaction.
contract Compound is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address vaultAddr = vm.envAddress("VAULT");

        UniswapV3Vault vault = UniswapV3Vault(vaultAddr);

        uint256 tvlBefore = vault.getUsdTvl();
        uint256 sharePriceBefore = vault.getUsdSharePrice();

        console.log("USD TVL before:         ", tvlBefore);
        console.log("USD share price before: ", sharePriceBefore);

        vm.startBroadcast(deployerKey);
        uint128 liquidityAdded = vault.compound();
        vm.stopBroadcast();

        console.log("Liquidity added:        ", uint256(liquidityAdded));
        console.log("Compound count:         ", vault.compoundCount());
        console.log("USD TVL after:          ", vault.getUsdTvl());
        console.log("USD share price after:  ", vault.getUsdSharePrice());
    }
}
