// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {UniswapV3Vault} from "../src/UniswapV3Vault.sol";

/// @notice Closes the vault's current Uniswap V3 position and re-opens a new
///         one centred on the live tick, spanning the vault's hardcoded
///         `ticksEitherSide` above and below.
///
/// Required env vars:
///   VAULT        Address of the deployed UniswapV3Vault.
///   PRIVATE_KEY  Funded key to broadcast the transaction.
contract Rebalance is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address vaultAddr = vm.envAddress("VAULT");

        UniswapV3Vault vault = UniswapV3Vault(vaultAddr);

        int24 oldTickLower = vault.tickLower();
        int24 oldTickUpper = vault.tickUpper();
        uint256 tvlBefore = vault.getUsdTvl();

        console.log("Old tickLower:", vm.toString(oldTickLower));
        console.log("Old tickUpper:", vm.toString(oldTickUpper));
        console.log("USD TVL before:", tvlBefore);

        vm.startBroadcast(deployerKey);
        vault.rebalance();
        vm.stopBroadcast();

        console.log("New tickLower:", vm.toString(vault.tickLower()));
        console.log("New tickUpper:", vm.toString(vault.tickUpper()));
        console.log("USD TVL after: ", vault.getUsdTvl());
        console.log("Rebalance count:", vault.rebalanceCount());
        console.log("Active position id:", vault.tokenId());
    }
}
