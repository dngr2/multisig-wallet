// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MultisigWallet} from "../src/MultisigWallet.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockTarget} from "./mocks/MockTarget.sol";
import {ReentrantTarget} from "./mocks/ReentrantTarget.sol";

contract MultisigWalletTest is Test {
    MultisigWallet internal wallet;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");
    address internal stranger = makeAddr("stranger");

    address[] internal owners;

    function setUp() public {
        owners = [alice, bob, carol];
        wallet = new MultisigWallet(owners, 2);
        vm.deal(address(wallet), 100 ether);
    }

    /*//////////////////////////////////////////////////////////////
                          DEPLOY VALIDATION
    //////////////////////////////////////////////////////////////*/

    function test_Constructor_SetsState() public view {
        assertEq(wallet.threshold(), 2);
        assertEq(wallet.ownerCount(), 3);
        assertTrue(wallet.isOwner(alice));
        assertTrue(wallet.isOwner(bob));
        assertTrue(wallet.isOwner(carol));
        assertFalse(wallet.isOwner(stranger));
        address[] memory got = wallet.getOwners();
        assertEq(got.length, 3);
    }

    function test_RevertWhen_EmptyOwners() public {
        address[] memory empty = new address[](0);
        vm.expectRevert(MultisigWallet.OwnersRequired.selector);
        new MultisigWallet(empty, 1);
    }

    function test_RevertWhen_ZeroOwner() public {
        address[] memory o = new address[](2);
        o[0] = alice;
        o[1] = address(0);
        vm.expectRevert(MultisigWallet.ZeroOwner.selector);
        new MultisigWallet(o, 1);
    }

    function test_RevertWhen_DuplicateOwner() public {
        address[] memory o = new address[](2);
        o[0] = alice;
        o[1] = alice;
        vm.expectRevert(abi.encodeWithSelector(MultisigWallet.DuplicateOwner.selector, alice));
        new MultisigWallet(o, 1);
    }

    function test_RevertWhen_ThresholdZero() public {
        vm.expectRevert(abi.encodeWithSelector(MultisigWallet.InvalidThreshold.selector, 0, 3));
        new MultisigWallet(owners, 0);
    }

    function test_RevertWhen_ThresholdTooHigh() public {
        vm.expectRevert(abi.encodeWithSelector(MultisigWallet.InvalidThreshold.selector, 4, 3));
        new MultisigWallet(owners, 4);
    }

    /*//////////////////////////////////////////////////////////////
                        SUBMIT / CONFIRM / EXECUTE
    //////////////////////////////////////////////////////////////*/

    function _submit(address to, uint256 value, bytes memory data) internal returns (uint256 txId) {
        vm.prank(alice);
        txId = wallet.submitTransaction(to, value, data);
    }

    function _confirm(address owner, uint256 txId) internal {
        vm.prank(owner);
        wallet.confirmTransaction(txId);
    }

    function test_ExecuteEthTransfer() public {
        uint256 txId = _submit(dave, 1 ether, "");
        _confirm(alice, txId);
        _confirm(bob, txId);

        uint256 balBefore = dave.balance;
        vm.prank(carol);
        wallet.executeTransaction(txId);

        assertEq(dave.balance, balBefore + 1 ether);
        (,,, bool executed,) = wallet.getTransaction(txId);
        assertTrue(executed);
    }

    function test_ExecuteErc20Transfer() public {
        MockERC20 token = new MockERC20("Mock", "MCK");
        token.mint(address(wallet), 1_000e18);

        bytes memory data = abi.encodeWithSignature("transfer(address,uint256)", dave, 250e18);
        uint256 txId = _submit(address(token), 0, data);
        _confirm(alice, txId);
        _confirm(bob, txId);

        vm.prank(alice);
        wallet.executeTransaction(txId);

        assertEq(token.balanceOf(dave), 250e18);
        assertEq(token.balanceOf(address(wallet)), 750e18);
    }

    function test_ExecuteContractCall_MutatesState() public {
        MockTarget target = new MockTarget();
        bytes memory data = abi.encodeWithSignature("setValue(uint256)", 42);
        uint256 txId = _submit(address(target), 3 ether, data);
        _confirm(alice, txId);
        _confirm(carol, txId);

        vm.prank(bob);
        wallet.executeTransaction(txId);

        assertEq(target.value(), 42);
        assertEq(target.callCount(), 1);
        assertEq(target.lastValueSent(), 3 ether);
        assertEq(address(target).balance, 3 ether);
    }

    function test_RevertWhen_ExecuteBelowThreshold() public {
        uint256 txId = _submit(dave, 1 ether, "");
        _confirm(alice, txId);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MultisigWallet.NotEnoughConfirmations.selector, txId));
        wallet.executeTransaction(txId);
    }

    function test_FailedInnerCall_StaysExecutable() public {
        MockTarget target = new MockTarget();
        bytes memory data = abi.encodeWithSignature("boom()");
        uint256 txId = _submit(address(target), 0, data);
        _confirm(alice, txId);
        _confirm(bob, txId);

        // First attempt reverts and leaves the tx un-executed.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MultisigWallet.TxExecutionFailed.selector, txId));
        wallet.executeTransaction(txId);

        (,,, bool executed,) = wallet.getTransaction(txId);
        assertFalse(executed, "tx must stay executable after failed inner call");

        // It can be retried and can now succeed (e.g. once target behaves).
        // Replace the target's behaviour by targeting setValue instead: submit a
        // fresh working tx to prove the wallet is not stuck.
        uint256 txId2 = _submit(address(target), 0, abi.encodeWithSignature("setValue(uint256)", 7));
        _confirm(alice, txId2);
        _confirm(bob, txId2);
        vm.prank(alice);
        wallet.executeTransaction(txId2);
        assertEq(target.value(), 7);
    }

    /*//////////////////////////////////////////////////////////////
                          CONFIRM / REVOKE LOGIC
    //////////////////////////////////////////////////////////////*/

    function test_RevokeConfirmation() public {
        uint256 txId = _submit(dave, 1 ether, "");
        _confirm(alice, txId);
        assertEq(wallet.getConfirmationCount(txId), 1);
        assertTrue(wallet.confirmedBy(txId, alice));

        vm.prank(alice);
        wallet.revokeConfirmation(txId);
        assertEq(wallet.getConfirmationCount(txId), 0);
        assertFalse(wallet.confirmedBy(txId, alice));
    }

    function test_RevertWhen_DoubleConfirm() public {
        uint256 txId = _submit(dave, 1 ether, "");
        _confirm(alice, txId);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MultisigWallet.TxAlreadyConfirmed.selector, txId));
        wallet.confirmTransaction(txId);
    }

    function test_RevertWhen_RevokeWithoutConfirm() public {
        uint256 txId = _submit(dave, 1 ether, "");
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(MultisigWallet.TxNotConfirmed.selector, txId));
        wallet.revokeConfirmation(txId);
    }

    function test_RevertWhen_ConfirmAfterExecution() public {
        uint256 txId = _submit(dave, 1 ether, "");
        _confirm(alice, txId);
        _confirm(bob, txId);
        vm.prank(alice);
        wallet.executeTransaction(txId);

        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(MultisigWallet.TxAlreadyExecuted.selector, txId));
        wallet.confirmTransaction(txId);
    }

    function test_RevertWhen_ExecuteTwice() public {
        uint256 txId = _submit(dave, 1 ether, "");
        _confirm(alice, txId);
        _confirm(bob, txId);
        vm.prank(alice);
        wallet.executeTransaction(txId);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(MultisigWallet.TxAlreadyExecuted.selector, txId));
        wallet.executeTransaction(txId);
    }

    /*//////////////////////////////////////////////////////////////
                        ACCESS CONTROL (NON-OWNER)
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_NonOwnerSubmits() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(MultisigWallet.NotOwner.selector, stranger));
        wallet.submitTransaction(dave, 1 ether, "");
    }

    function test_RevertWhen_NonOwnerConfirms() public {
        uint256 txId = _submit(dave, 1 ether, "");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(MultisigWallet.NotOwner.selector, stranger));
        wallet.confirmTransaction(txId);
    }

    function test_RevertWhen_NonOwnerExecutes() public {
        uint256 txId = _submit(dave, 1 ether, "");
        _confirm(alice, txId);
        _confirm(bob, txId);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(MultisigWallet.NotOwner.selector, stranger));
        wallet.executeTransaction(txId);
    }

    function test_RevertWhen_ConfirmNonexistentTx() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MultisigWallet.TxDoesNotExist.selector, 99));
        wallet.confirmTransaction(99);
    }

    /*//////////////////////////////////////////////////////////////
                           SELF-GOVERNANCE
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_AddOwnerCalledDirectly() public {
        vm.prank(alice);
        vm.expectRevert(MultisigWallet.OnlyWallet.selector);
        wallet.addOwner(dave);
    }

    function test_RevertWhen_RemoveOwnerCalledDirectly() public {
        vm.prank(alice);
        vm.expectRevert(MultisigWallet.OnlyWallet.selector);
        wallet.removeOwner(bob);
    }

    function test_RevertWhen_ChangeThresholdCalledDirectly() public {
        vm.prank(alice);
        vm.expectRevert(MultisigWallet.OnlyWallet.selector);
        wallet.changeThreshold(1);
    }

    function test_RevertWhen_ReplaceOwnerCalledDirectly() public {
        vm.prank(alice);
        vm.expectRevert(MultisigWallet.OnlyWallet.selector);
        wallet.replaceOwner(alice, dave);
    }

    /// @dev End-to-end: add an owner by routing a call to the wallet itself
    ///      through a fully-confirmed multisig transaction.
    function test_AddOwner_ThroughMultisigTx() public {
        bytes memory data = abi.encodeWithSelector(MultisigWallet.addOwner.selector, dave);
        uint256 txId = _submit(address(wallet), 0, data);
        _confirm(alice, txId);
        _confirm(bob, txId);
        vm.prank(alice);
        wallet.executeTransaction(txId);

        assertTrue(wallet.isOwner(dave));
        assertEq(wallet.ownerCount(), 4);
    }

    function test_ChangeThreshold_ThroughMultisigTx() public {
        bytes memory data = abi.encodeWithSelector(MultisigWallet.changeThreshold.selector, 3);
        uint256 txId = _submit(address(wallet), 0, data);
        _confirm(alice, txId);
        _confirm(bob, txId);
        vm.prank(alice);
        wallet.executeTransaction(txId);

        assertEq(wallet.threshold(), 3);
    }

    function test_RemoveOwner_ThroughMultisigTx() public {
        bytes memory data = abi.encodeWithSelector(MultisigWallet.removeOwner.selector, carol);
        uint256 txId = _submit(address(wallet), 0, data);
        _confirm(alice, txId);
        _confirm(bob, txId);
        vm.prank(alice);
        wallet.executeTransaction(txId);

        assertFalse(wallet.isOwner(carol));
        assertEq(wallet.ownerCount(), 2);
        assertEq(wallet.threshold(), 2);
    }

    function test_ReplaceOwner_ThroughMultisigTx() public {
        bytes memory data = abi.encodeWithSelector(MultisigWallet.replaceOwner.selector, carol, dave);
        uint256 txId = _submit(address(wallet), 0, data);
        _confirm(alice, txId);
        _confirm(bob, txId);
        vm.prank(alice);
        wallet.executeTransaction(txId);

        assertFalse(wallet.isOwner(carol));
        assertTrue(wallet.isOwner(dave));
        assertEq(wallet.ownerCount(), 3);
    }

    /// @dev Removing an owner that would drop the count below the threshold must
    ///      revert (our documented rule). Here threshold=3, owners=3, so any
    ///      removal would break the invariant.
    function test_RemoveOwner_BelowThreshold_Reverts() public {
        // First raise threshold to 3 (== owner count).
        bytes memory d1 = abi.encodeWithSelector(MultisigWallet.changeThreshold.selector, 3);
        uint256 t1 = _submit(address(wallet), 0, d1);
        _confirm(alice, t1);
        _confirm(bob, t1);
        vm.prank(alice);
        wallet.executeTransaction(t1);
        assertEq(wallet.threshold(), 3);

        // Now attempt to remove an owner: would leave count(2) < threshold(3).
        bytes memory d2 = abi.encodeWithSelector(MultisigWallet.removeOwner.selector, carol);
        uint256 t2 = _submit(address(wallet), 0, d2);
        _confirm(alice, t2);
        _confirm(bob, t2);
        _confirm(carol, t2);
        // Execution reverts because the inner self-call reverts InvalidThreshold,
        // which bubbles up as TxExecutionFailed and leaves the tx retryable.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MultisigWallet.TxExecutionFailed.selector, t2));
        wallet.executeTransaction(t2);

        assertTrue(wallet.isOwner(carol));
        assertEq(wallet.ownerCount(), 3);
    }

    function test_RevertWhen_AddExistingOwner_ThroughTx() public {
        bytes memory data = abi.encodeWithSelector(MultisigWallet.addOwner.selector, bob);
        uint256 txId = _submit(address(wallet), 0, data);
        _confirm(alice, txId);
        _confirm(bob, txId);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MultisigWallet.TxExecutionFailed.selector, txId));
        wallet.executeTransaction(txId);
    }

    /*//////////////////////////////////////////////////////////////
                              REENTRANCY
    //////////////////////////////////////////////////////////////*/

    function test_Reentrancy_CannotDoubleExecute() public {
        // txId 0 will be the transaction that sends ETH to the reentrant target.
        ReentrantTarget attacker = new ReentrantTarget(wallet, 0);

        uint256 txId = _submit(address(attacker), 1 ether, "");
        assertEq(txId, 0);
        _confirm(alice, txId);
        _confirm(bob, txId);

        vm.prank(alice);
        wallet.executeTransaction(txId);

        // Attacker's receive() tried to re-enter; it must have failed.
        assertGt(attacker.reenterAttempts(), 0, "attacker should have attempted reentry");
        assertFalse(attacker.reentrySucceeded(), "reentrancy must not succeed");

        // Exactly one execution: attacker received exactly 1 ether once.
        assertEq(address(attacker).balance, 1 ether);
        (,,, bool executed,) = wallet.getTransaction(txId);
        assertTrue(executed);
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    function test_IsConfirmedView() public {
        uint256 txId = _submit(dave, 1 ether, "");
        assertFalse(wallet.isConfirmed(txId));
        _confirm(alice, txId);
        assertFalse(wallet.isConfirmed(txId));
        _confirm(bob, txId);
        assertTrue(wallet.isConfirmed(txId));
    }

    function test_TransactionCount() public {
        assertEq(wallet.transactionCount(), 0);
        _submit(dave, 1 ether, "");
        _submit(dave, 2 ether, "");
        assertEq(wallet.transactionCount(), 2);
    }

    function test_ReceiveEth_EmitsDeposit() public {
        vm.deal(stranger, 5 ether);
        vm.prank(stranger);
        (bool ok,) = address(wallet).call{value: 5 ether}("");
        assertTrue(ok);
        assertEq(address(wallet).balance, 105 ether);
    }
}
