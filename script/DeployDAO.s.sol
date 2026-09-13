// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// Deploy the DAO timelock (treasury + governance) once per chain.
///   PROPOSER=0x... EXECUTOR=0x... MIN_DELAY_DAYS=7 \
///   forge script script/DeployDAO.s.sol:DeployDAO --rpc-url $RPC --broadcast --verify
///
/// PROPOSER/EXECUTOR are the deployer EOA at bootstrap; both roles move to
/// the Governor at handover. MIN_DELAY_DAYS defaults to 7.
contract DeployDAO is Script {
    function run() external {
        address proposer = vm.envAddress("PROPOSER");
        address executor = vm.envAddress("EXECUTOR");
        uint256 delayDays = vm.envOr("MIN_DELAY_DAYS", uint256(7));

        address[] memory proposers = new address[](1);
        proposers[0] = proposer;
        address[] memory executors = new address[](1);
        executors[0] = executor;

        vm.startBroadcast();
        TimelockController t = new TimelockController(delayDays * 1 days, proposers, executors, address(0));
        vm.stopBroadcast();
        console.log("timelock", address(t));
        console.log("minDelay", t.getMinDelay());
    }
}
