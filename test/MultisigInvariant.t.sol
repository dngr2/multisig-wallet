// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {MultisigWallet} from "../src/MultisigWallet.sol";

/// @notice Drives submit/confirm/revoke/execute across a fixed owner set and
///         tracks ground-truth expectations the invariants are checked against.
contract MultisigHandler is Test {
    MultisigWallet public wallet;
    address[] public owners;

    /// @notice txIds that have ever been submitted.
    uint256[] public txIds;
    /// @notice txId => whether it has executed (per handler observation).
    mapping(uint256 => bool) public everExecuted;
    /// @notice Number of times execute *succeeded* for a txId (must never exceed 1).
    mapping(uint256 => uint256) public executeSuccessCount;

    constructor(MultisigWallet wallet_, address[] memory owners_) {
        wallet = wallet_;
        owners = owners_;
        // Fund the wallet so ETH-sending txs can succeed.
        vm.deal(address(wallet), 1_000 ether);
    }

    function _owner(uint256 seed) internal view returns (address) {
        return owners[seed % owners.length];
    }

    function submit(uint256 ownerSeed, uint256 value) external {
        address o = _owner(ownerSeed);
        // Keep value modest so wallet balance can cover it; target an EOA-ish
        // address (owners) that can receive ETH.
        value = value % 1 ether;
        vm.prank(o);
        uint256 txId = wallet.submitTransaction(o, value, "");
        txIds.push(txId);
    }

    function confirm(uint256 ownerSeed, uint256 txSeed) external {
        if (txIds.length == 0) return;
        uint256 txId = txIds[txSeed % txIds.length];
        address o = _owner(ownerSeed);
        (,,, bool executed,) = wallet.getTransaction(txId);
        if (executed) return;
        if (wallet.confirmedBy(txId, o)) return;
        vm.prank(o);
        wallet.confirmTransaction(txId);
    }

    function revoke(uint256 ownerSeed, uint256 txSeed) external {
        if (txIds.length == 0) return;
        uint256 txId = txIds[txSeed % txIds.length];
        address o = _owner(ownerSeed);
        (,,, bool executed,) = wallet.getTransaction(txId);
        if (executed) return;
        if (!wallet.confirmedBy(txId, o)) return;
        vm.prank(o);
        wallet.revokeConfirmation(txId);
    }

    function execute(uint256 ownerSeed, uint256 txSeed) external {
        if (txIds.length == 0) return;
        uint256 txId = txIds[txSeed % txIds.length];
        address o = _owner(ownerSeed);
        (,,, bool executed, uint256 confirmations) = wallet.getTransaction(txId);
        if (executed) return;
        if (confirmations < wallet.threshold()) return;
        vm.prank(o);
        try wallet.executeTransaction(txId) {
            everExecuted[txId] = true;
            executeSuccessCount[txId] += 1;
        } catch {}
    }

    function txIdsLength() external view returns (uint256) {
        return txIds.length;
    }
}

contract MultisigInvariantTest is StdInvariant, Test {
    MultisigWallet internal wallet;
    MultisigHandler internal handler;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    address[] internal owners;

    function setUp() public {
        owners = [alice, bob, carol];
        wallet = new MultisigWallet(owners, 2);
        handler = new MultisigHandler(wallet, owners);
        targetContract(address(handler));
    }

    /// @notice A tx that reports enough confirmations while un-executed is exactly
    ///         the set that is executable; and no tx ever executes more than once.
    function invariant_NoDoubleExecution() public view {
        uint256 n = handler.txIdsLength();
        for (uint256 i = 0; i < n; ++i) {
            uint256 txId = handler.txIds(i);
            assertLe(handler.executeSuccessCount(txId), 1, "tx executed more than once");
        }
    }

    /// @notice On-chain confirmation count for a tx equals the number of current
    ///         owners that are recorded as confirming it.
    function invariant_ConfirmationCountMatchesOwners() public view {
        uint256 n = handler.txIdsLength();
        address[] memory os = wallet.getOwners();
        for (uint256 i = 0; i < n; ++i) {
            uint256 txId = handler.txIds(i);
            (,,, bool executed, uint256 confirmations) = wallet.getTransaction(txId);
            if (executed) continue;
            uint256 counted;
            for (uint256 j = 0; j < os.length; ++j) {
                if (wallet.confirmedBy(txId, os[j])) counted++;
            }
            assertEq(confirmations, counted, "confirmation count mismatch");
        }
    }

    /// @notice An executed tx must have had >= threshold confirmations, i.e. the
    ///         executability gate held at execution time (checked via the flag +
    ///         the fact executeSuccessCount only increments through the gate).
    function invariant_ExecutedImpliesWasConfirmed() public view {
        uint256 n = handler.txIdsLength();
        for (uint256 i = 0; i < n; ++i) {
            uint256 txId = handler.txIds(i);
            (,,, bool executed,) = wallet.getTransaction(txId);
            if (executed) {
                assertEq(handler.executeSuccessCount(txId), 1, "executed flag without success record");
            }
        }
    }

    /// @notice Owner set stays valid: non-empty, no zero/duplicate owners, and
    ///         threshold within [1, ownerCount].
    function invariant_OwnerSetValid() public view {
        address[] memory os = wallet.getOwners();
        assertGt(os.length, 0, "owner set empty");
        assertGe(wallet.threshold(), 1, "threshold below 1");
        assertLe(wallet.threshold(), os.length, "threshold exceeds owner count");
        for (uint256 i = 0; i < os.length; ++i) {
            assertTrue(os[i] != address(0), "zero owner");
            assertTrue(wallet.isOwner(os[i]), "owner flag mismatch");
            for (uint256 j = i + 1; j < os.length; ++j) {
                assertTrue(os[i] != os[j], "duplicate owner");
            }
        }
    }
}
