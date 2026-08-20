// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MultisigWallet} from "../src/MultisigWallet.sol";
import {MockTarget} from "./mocks/MockTarget.sol";

/// @notice Covers the v2 deep-dive changes: the stale-confirmation-after-owner
///         -change fix, per-tx deadlines, the getConfirmations view, and the
///         EIP-712 signature execution flow.
contract MultisigDeepDiveTest is Test {
    MultisigWallet internal wallet;

    // Signing owners (need known private keys for EIP-712).
    uint256 internal aliceKey;
    uint256 internal bobKey;
    uint256 internal carolKey;
    uint256 internal daveKey;
    address internal alice;
    address internal bob;
    address internal carol;
    address internal dave;
    address internal attacker = makeAddr("attacker");

    address[] internal owners;

    function setUp() public {
        (alice, aliceKey) = makeAddrAndKey("alice");
        (bob, bobKey) = makeAddrAndKey("bob");
        (carol, carolKey) = makeAddrAndKey("carol");
        (dave, daveKey) = makeAddrAndKey("dave");

        owners = [alice, bob, carol];
        wallet = new MultisigWallet(owners, 2);
        vm.deal(address(wallet), 100 ether);
    }

    function _submit(address to, uint256 value, bytes memory data) internal returns (uint256 txId) {
        vm.prank(alice);
        txId = wallet.submitTransaction(to, value, data);
    }

    function _confirm(address owner, uint256 txId) internal {
        vm.prank(owner);
        wallet.confirmTransaction(txId);
    }

    function _exec(address owner, uint256 txId) internal {
        vm.prank(owner);
        wallet.executeTransaction(txId);
    }

    function _selfCall(bytes memory data) internal returns (uint256 txId) {
        txId = _submit(address(wallet), 0, data);
        _confirm(alice, txId);
        _confirm(bob, txId);
        _exec(alice, txId);
    }

    /*//////////////////////////////////////////////////////////////
          STALE CONFIRMATION AFTER OWNER CHANGE  (the key finding)
    //////////////////////////////////////////////////////////////*/

    /// @dev A malicious tx gathers a confirmation from an owner who is later
    ///      removed. That stale confirmation must NOT count toward the threshold
    ///      at execution time. Before the fix (cached counter) the tx would drain
    ///      the wallet with only two live-owner approvals against a 3-of-N gate.
    function test_StaleConfirmation_RemovedOwner_DoesNotCount() public {
        // Grow to a 4-owner, 3-of-4 wallet.
        _selfCall(abi.encodeWithSelector(MultisigWallet.addOwner.selector, dave));
        _selfCall(abi.encodeWithSelector(MultisigWallet.changeThreshold.selector, 3));
        assertEq(wallet.ownerCount(), 4);
        assertEq(wallet.threshold(), 3);

        // Malicious tx: drain 50 ether to the attacker. Confirmed by alice, bob,
        // carol => raw count 3 (would satisfy the old cached-counter gate).
        uint256 evil = _submit(attacker, 50 ether, "");
        _confirm(alice, evil);
        _confirm(bob, evil);
        _confirm(carol, evil);
        assertEq(wallet.getConfirmationCount(evil), 3);

        // Governance removes carol (count 4 -> 3, still >= threshold 3).
        uint256 gov = _submit(address(wallet), 0, abi.encodeWithSelector(MultisigWallet.removeOwner.selector, carol));
        _confirm(alice, gov);
        _confirm(bob, gov);
        _confirm(dave, gov);
        _exec(alice, gov);
        assertFalse(wallet.isOwner(carol));

        // carol's confirmation is now stale: only alice + bob (2) are live
        // confirmers against a threshold of 3.
        assertEq(wallet.getConfirmationCount(evil), 2);
        assertFalse(wallet.isConfirmed(evil));

        // Execution must revert; the attacker gets nothing.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MultisigWallet.NotEnoughConfirmations.selector, evil));
        wallet.executeTransaction(evil);
        assertEq(attacker.balance, 0);
    }

    /// @dev replaceOwner: the replaced owner's confirmation stops counting and the
    ///      new owner starts fresh.
    function test_StaleConfirmation_ReplacedOwner_DoesNotCount() public {
        // 2-of-3. Malicious tx confirmed by carol only.
        uint256 evil = _submit(attacker, 10 ether, "");
        _confirm(carol, evil);
        assertEq(wallet.getConfirmationCount(evil), 1);

        // Replace carol with dave.
        _selfCall(abi.encodeWithSelector(MultisigWallet.replaceOwner.selector, carol, dave));
        assertFalse(wallet.isOwner(carol));
        assertTrue(wallet.isOwner(dave));

        // carol's confirmation no longer counts; dave has not confirmed.
        assertEq(wallet.getConfirmationCount(evil), 0);

        // Even one fresh live confirmation (dave) is not enough for 2-of-3.
        _confirm(dave, evil);
        assertEq(wallet.getConfirmationCount(evil), 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MultisigWallet.NotEnoughConfirmations.selector, evil));
        wallet.executeTransaction(evil);
    }

    /*//////////////////////////////////////////////////////////////
                          getConfirmations VIEW
    //////////////////////////////////////////////////////////////*/

    function test_GetConfirmations_ListsCurrentConfirmers() public {
        uint256 txId = _submit(dave, 1 ether, "");
        _confirm(alice, txId);
        _confirm(carol, txId);

        address[] memory c = wallet.getConfirmations(txId);
        assertEq(c.length, 2);
        // Order follows the owner array [alice, bob, carol].
        assertEq(c[0], alice);
        assertEq(c[1], carol);
    }

    function test_GetConfirmations_ExcludesRemovedOwner() public {
        uint256 txId = _submit(dave, 1 ether, "");
        _confirm(alice, txId);
        _confirm(carol, txId);

        _selfCall(abi.encodeWithSelector(MultisigWallet.replaceOwner.selector, carol, dave));

        address[] memory c = wallet.getConfirmations(txId);
        assertEq(c.length, 1);
        assertEq(c[0], alice);
    }

    /*//////////////////////////////////////////////////////////////
                              DEADLINES
    //////////////////////////////////////////////////////////////*/

    function test_Deadline_ExecutesBeforeExpiry() public {
        uint256 dl = block.timestamp + 1 days;
        vm.prank(alice);
        uint256 txId = wallet.submitTransactionWithDeadline(dave, 1 ether, "", dl);
        assertEq(wallet.getDeadline(txId), dl);
        _confirm(alice, txId);
        _confirm(bob, txId);

        vm.warp(dl - 1);
        uint256 balBefore = dave.balance;
        _exec(carol, txId);
        assertEq(dave.balance, balBefore + 1 ether);
    }

    function test_Deadline_RevertsAfterExpiry() public {
        uint256 dl = block.timestamp + 1 days;
        vm.prank(alice);
        uint256 txId = wallet.submitTransactionWithDeadline(dave, 1 ether, "", dl);
        _confirm(alice, txId);
        _confirm(bob, txId);

        vm.warp(dl + 1);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(MultisigWallet.TxExpired.selector, txId));
        wallet.executeTransaction(txId);
    }

    function test_Deadline_ZeroMeansNoExpiry() public {
        vm.prank(alice);
        uint256 txId = wallet.submitTransactionWithDeadline(dave, 1 ether, "", 0);
        _confirm(alice, txId);
        _confirm(bob, txId);
        vm.warp(block.timestamp + 3650 days);
        uint256 balBefore = dave.balance;
        _exec(carol, txId);
        assertEq(dave.balance, balBefore + 1 ether);
    }

    /*//////////////////////////////////////////////////////////////
                    EIP-712 SIGNATURE EXECUTION
    //////////////////////////////////////////////////////////////*/

    function _sign(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Build a signature array from two signers, ordered by ascending signer
    ///      address (as executeWithSignatures requires).
    function _orderedSigs2(uint256 pkA, uint256 pkB, bytes32 digest) internal pure returns (bytes[] memory sigs) {
        sigs = new bytes[](2);
        if (vm.addr(pkA) < vm.addr(pkB)) {
            sigs[0] = _sign(pkA, digest);
            sigs[1] = _sign(pkB, digest);
        } else {
            sigs[0] = _sign(pkB, digest);
            sigs[1] = _sign(pkA, digest);
        }
    }

    function test_ExecuteWithSignatures_HappyPath() public {
        uint256 nonce = wallet.execNonce();
        bytes32 digest = wallet.hashExecute(dave, 1 ether, "", nonce, 0);
        bytes[] memory sigs = _orderedSigs2(aliceKey, bobKey, digest);

        uint256 balBefore = dave.balance;
        // Any caller (relayer) can submit.
        vm.prank(attacker);
        uint256 used = wallet.executeWithSignatures(dave, 1 ether, "", 0, sigs);

        assertEq(used, nonce);
        assertEq(dave.balance, balBefore + 1 ether);
        assertEq(wallet.execNonce(), nonce + 1);
    }

    function test_ExecuteWithSignatures_Replay_Reverts() public {
        uint256 nonce = wallet.execNonce();
        bytes32 digest = wallet.hashExecute(dave, 1 ether, "", nonce, 0);
        bytes[] memory sigs = _orderedSigs2(aliceKey, bobKey, digest);

        wallet.executeWithSignatures(dave, 1 ether, "", 0, sigs);

        // Replaying the same bundle now recovers signers over the new nonce's
        // digest -> not owners / out of order -> reverts.
        vm.expectRevert();
        wallet.executeWithSignatures(dave, 1 ether, "", 0, sigs);
    }

    function test_ExecuteWithSignatures_TooFewSignatures_Reverts() public {
        uint256 nonce = wallet.execNonce();
        bytes32 digest = wallet.hashExecute(dave, 1 ether, "", nonce, 0);
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _sign(aliceKey, digest);

        vm.expectRevert(abi.encodeWithSelector(MultisigWallet.NotEnoughSignatures.selector, 1, 2));
        wallet.executeWithSignatures(dave, 1 ether, "", 0, sigs);
    }

    function test_ExecuteWithSignatures_NonOwnerSigner_Reverts() public {
        uint256 nonce = wallet.execNonce();
        bytes32 digest = wallet.hashExecute(dave, 1 ether, "", nonce, 0);
        // alice + dave, but dave is not an owner.
        bytes[] memory sigs = _orderedSigs2(aliceKey, daveKey, digest);

        vm.expectRevert(abi.encodeWithSelector(MultisigWallet.NotOwner.selector, dave));
        wallet.executeWithSignatures(dave, 1 ether, "", 0, sigs);
    }

    function test_ExecuteWithSignatures_DuplicateSigner_Reverts() public {
        uint256 nonce = wallet.execNonce();
        bytes32 digest = wallet.hashExecute(dave, 1 ether, "", nonce, 0);
        // Same owner twice -> not strictly ascending.
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sign(aliceKey, digest);
        sigs[1] = _sign(aliceKey, digest);

        vm.expectRevert(MultisigWallet.UnorderedSigners.selector);
        wallet.executeWithSignatures(dave, 1 ether, "", 0, sigs);
    }

    function test_ExecuteWithSignatures_Unordered_Reverts() public {
        uint256 nonce = wallet.execNonce();
        bytes32 digest = wallet.hashExecute(dave, 1 ether, "", nonce, 0);
        bytes[] memory ordered = _orderedSigs2(aliceKey, bobKey, digest);
        // Swap to force descending order.
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = ordered[1];
        sigs[1] = ordered[0];

        vm.expectRevert(MultisigWallet.UnorderedSigners.selector);
        wallet.executeWithSignatures(dave, 1 ether, "", 0, sigs);
    }

    function test_ExecuteWithSignatures_ExpiredDeadline_Reverts() public {
        uint256 dl = block.timestamp + 100;
        uint256 nonce = wallet.execNonce();
        bytes32 digest = wallet.hashExecute(dave, 1 ether, "", nonce, dl);
        bytes[] memory sigs = _orderedSigs2(aliceKey, bobKey, digest);

        vm.warp(dl + 1);
        vm.expectRevert(abi.encodeWithSelector(MultisigWallet.TxExpired.selector, nonce));
        wallet.executeWithSignatures(dave, 1 ether, "", dl, sigs);
    }

    function test_ExecuteWithSignatures_FailedCall_RevertsAndKeepsNonce() public {
        MockTarget target = new MockTarget();
        bytes memory data = abi.encodeWithSignature("boom()");
        uint256 nonce = wallet.execNonce();
        bytes32 digest = wallet.hashExecute(address(target), 0, data, nonce, 0);
        bytes[] memory sigs = _orderedSigs2(aliceKey, bobKey, digest);

        vm.expectRevert(abi.encodeWithSelector(MultisigWallet.TxExecutionFailed.selector, nonce));
        wallet.executeWithSignatures(address(target), 0, data, 0, sigs);

        // Nonce untouched -> the same bundle can be retried later.
        assertEq(wallet.execNonce(), nonce);
    }

    /// @dev Composability: a signed execution can drive self-governance (addOwner)
    ///      just like an on-chain confirmed tx.
    function test_ExecuteWithSignatures_SelfGovernance_AddOwner() public {
        bytes memory data = abi.encodeWithSelector(MultisigWallet.addOwner.selector, dave);
        uint256 nonce = wallet.execNonce();
        bytes32 digest = wallet.hashExecute(address(wallet), 0, data, nonce, 0);
        bytes[] memory sigs = _orderedSigs2(aliceKey, bobKey, digest);

        wallet.executeWithSignatures(address(wallet), 0, data, 0, sigs);
        assertTrue(wallet.isOwner(dave));
        assertEq(wallet.ownerCount(), 4);
    }

    function test_DomainSeparator_IsSet() public view {
        assertTrue(wallet.domainSeparator() != bytes32(0));
    }
}
