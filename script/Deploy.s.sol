// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {MultisigFactory} from "../src/MultisigFactory.sol";

/// @title Deploy
/// @notice Deploys the {MultisigFactory}. Individual wallets are NOT created
///         here; after deployment, callers create wallets via
///         `factory.createWallet(owners, threshold)` (sending the flat fee as
///         msg.value).
/// @dev Configuration is read from the environment:
///      - FACTORY_OWNER    (address) : factory admin (can set fee/recipient)
///      - FEE_RECIPIENT    (address) : receives collected deploy fees
///      - DEPLOY_FEE       (uint256) : flat per-wallet fee in wei (<= 1 ether)
///      The broadcasting key is supplied to `forge script` via
///      --private-key / --account / --ledger (see DEPLOY.md).
contract Deploy is Script {
    function run() external returns (MultisigFactory factory) {
        address factoryOwner = vm.envAddress("FACTORY_OWNER");
        address feeRecipient = vm.envAddress("FEE_RECIPIENT");
        uint256 deployFee = vm.envUint("DEPLOY_FEE");

        vm.startBroadcast();
        factory = new MultisigFactory(factoryOwner, feeRecipient, deployFee);
        vm.stopBroadcast();

        console2.log("MultisigFactory deployed at:", address(factory));
        console2.log("  owner:       ", factoryOwner);
        console2.log("  feeRecipient:", feeRecipient);
        console2.log("  fee (wei):   ", deployFee);
    }
}
