// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IMintClubBond} from "../src/interfaces/IMintClubBond.sol";
import {IGlueHookMin} from "../src/interfaces/IGlueHookMin.sol";
import {RoyaltyRouterFactory} from "../src/RoyaltyRouterFactory.sol";

/// Deploy the factory once per chain.
///   BOND=0x... HOOK=0x0F41715dc432692b66A5aDF8dCfef6Ac407b20c8 POOL_MANAGER=0x498581fF718922c3f8e6A244956aF099B2652b2b \
///   GOVERNANCE=0x... DAO=0x... DAO_BPS=1000 MAX_DAO_BPS=2000 STALE_DAYS=365 GRACE_DAYS=30 \
///   forge script script/Deploy.s.sol:DeployFactory --rpc-url $RPC --broadcast --verify
contract DeployFactory is Script {
    function run() external {
        vm.startBroadcast();
        RoyaltyRouterFactory f = new RoyaltyRouterFactory(
            IMintClubBond(vm.envAddress("BOND")),
            IGlueHookMin(vm.envAddress("HOOK")),
            vm.envAddress("POOL_MANAGER"),
            vm.envAddress("GOVERNANCE"),
            vm.envAddress("DAO"),
            uint16(vm.envUint("DAO_BPS")),
            uint16(vm.envUint("MAX_DAO_BPS")),
            uint64(vm.envUint("STALE_DAYS") * 1 days),
            uint64(vm.envUint("GRACE_DAYS") * 1 days)
        );
        vm.stopBroadcast();
        console.log("factory", address(f));
    }
}
