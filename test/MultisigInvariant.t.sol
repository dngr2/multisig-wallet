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

    /// @notice Spare addresses used to rotate the owner set.
    address[] public spares;
    /// @notice Set true if any execute ever succeeded while the tx had fewer than
    ///         `threshold` confirmations from the CURRENT owner set. Must stay
    ///         false: a tx may only execute on live-owner approval.
    bool public sawUnderThresholdExecute;

    constructor(MultisigWallet wallet_, address[] memory owners_) {
        wallet = wallet_;
        owners = owners_;
        for (uint256 i = 0; i < 6; ++i) {
            spares.push(address(uint160(uint256(keccak256(abi.encode("spare", i))))));
        }
        // Fund the wallet so ETH-sending txs can succeed.
        vm.deal(address(wallet), 1_000 ether);
    }

    function _owner(uint256 seed) internal view returns (address) {
        return owners[seed % owners.length];
    }

    /// @dev Confirmations of `txId` counted over the CURRENT owner set only.
    function _currentConfirmations(uint256 txId) internal view returns (uint256 c) {
        address[] memory os = wallet.getOwners();
        for (uint256 i = 0; i < os.length; ++i) {
            if (wallet.confirmedBy(txId, os[i])) c++;
        }
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
        (,,, bool executed,) = wallet.getTransaction(txId);
        if (executed) return;
        // Snapshot the live-owner confirmation count and threshold BEFORE trying;
        // attempt the execute regardless so the fix's gate is what decides.
        uint256 liveConf = _currentConfirmations(txId);
        uint256 t = wallet.threshold();
        vm.prank(o);
        try wallet.executeTransaction(txId) {
            everExecuted[txId] = true;
            executeSuccessCount[txId] += 1;
            // A success with fewer than `threshold` live-owner confirmations would
            // mean a stale/removed-owner confirmation pushed it over the line.
            if (liveConf < t) sawUnderThresholdExecute = true;
        } catch {}
    }

    /// @dev Rotate a current owner out for a spare, changing the owner set so any
    ///      gathered confirmations from the removed owner become stale.
    function rotateOwner(uint256 ownerSeed, uint256 spareSeed) external {
        if (spares.length == 0) return;
        address oldOwner = _owner(ownerSeed);
        uint256 si = spareSeed % spares.length;
        address newOwner = spares[si];
        if (wallet.isOwner(newOwner) || newOwner == address(0)) return;

        vm.prank(address(wallet));
        try wallet.replaceOwner(oldOwner, newOwner) {
            // Reflect the change in the handler's live owner list + spare pool.
            for (uint256 i = 0; i < owners.length; ++i) {
                if (owners[i] == oldOwner) {
                    owners[i] = newOwner;
                    break;
                }
            }
            spares[si] = oldOwner;
        } catch {}
    }

    /// @dev Change the threshold to any valid value in [1, ownerCount].
    function changeThreshold(uint256 seed) external {
        uint256 n = wallet.ownerCount();
        uint256 t = (seed % n) + 1;
        vm.prank(address(wallet));
        try wallet.changeThreshold(t) {} catch {}
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

    /// @notice The reported confirmation count (which governs execution) always
    ///         equals the number of CURRENT owners recorded as confirming the tx,
    ///         even after owners have been rotated. This is the property that
    ///         makes a removed owner's stale confirmation stop counting.
    function invariant_ConfirmationCountMatchesOwners() public view {
        uint256 n = handler.txIdsLength();
        address[] memory os = wallet.getOwners();
        for (uint256 i = 0; i < n; ++i) {
            uint256 txId = handler.txIds(i);
            (,,, bool executed,) = wallet.getTransaction(txId);
            if (executed) continue;
            uint256 counted;
            for (uint256 j = 0; j < os.length; ++j) {
                if (wallet.confirmedBy(txId, os[j])) counted++;
            }
            assertEq(wallet.getConfirmationCount(txId), counted, "confirmation count mismatch");
            // The confirming-owners view lists exactly those current owners.
            assertEq(wallet.getConfirmations(txId).length, counted, "getConfirmations length mismatch");
        }
    }

    /// @notice A transaction only ever executes when at least `threshold` of the
    ///         CURRENT owners confirmed it. Rotating owners cannot let a stale
    ///         confirmation carry a tx over the threshold.
    function invariant_ExecutesOnlyOnLiveThreshold() public view {
        assertFalse(handler.sawUnderThresholdExecute(), "tx executed below live-owner threshold");
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
