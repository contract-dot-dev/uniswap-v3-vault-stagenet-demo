// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {UniswapV3Vault} from "../src/UniswapV3Vault.sol";

contract Deploy is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);

        UniswapV3Vault vault = new UniswapV3Vault();

        console.log("UniswapV3Vault deployed at:", address(vault));
        console.log(
            "Tick range: [%s, %s]",
            vm.toString(vault.tickLower()),
            vm.toString(vault.tickUpper())
        );

        vm.stopBroadcast();
    }
}
