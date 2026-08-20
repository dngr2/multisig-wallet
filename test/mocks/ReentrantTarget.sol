// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MultisigWallet} from "../../src/MultisigWallet.sol";

/// @notice Malicious target that attempts to re-enter executeTransaction for the
///         same txId while it is mid-execution.
contract ReentrantTarget {
    MultisigWallet public immutable wallet;
    uint256 public immutable targetTxId;
    uint256 public reenterAttempts;
    bool public reentrySucceeded;

    constructor(MultisigWallet wallet_, uint256 targetTxId_) {
        wallet = wallet_;
        targetTxId = targetTxId_;
    }

    receive() external payable {
        reenterAttempts += 1;
        // Attempt to re-execute the same transaction. This must fail (guarded by
        // nonReentrant + the executed flag). Swallow the revert so the outer
        // call itself succeeds, letting us assert single execution afterwards.
        try wallet.executeTransaction(targetTxId) {
            reentrySucceeded = true;
        } catch {}
    }
}
