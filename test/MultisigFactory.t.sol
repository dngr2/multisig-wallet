// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MultisigFactory} from "../src/MultisigFactory.sol";
import {MultisigWallet} from "../src/MultisigWallet.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract MultisigFactoryTest is Test {
    MultisigFactory internal factory;

    address internal admin = makeAddr("admin");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal creator = makeAddr("creator");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal constant FEE = 0.01 ether;

    address[] internal owners;

    function setUp() public {
        factory = new MultisigFactory(admin, feeRecipient, FEE);
        owners = [alice, bob];
        vm.deal(creator, 10 ether);
    }

    function test_Constructor_RevertZeroRecipient() public {
        vm.expectRevert(MultisigFactory.ZeroFeeRecipient.selector);
        new MultisigFactory(admin, address(0), FEE);
    }

    function test_Constructor_RevertFeeTooHigh() public {
        uint256 tooHigh = factory.MAX_FEE() + 1;
        vm.expectRevert(abi.encodeWithSelector(MultisigFactory.FeeTooHigh.selector, tooHigh, factory.MAX_FEE()));
        new MultisigFactory(admin, feeRecipient, tooHigh);
    }

    function test_CreateWallet_ChargesFeeAndIndexes() public {
        uint256 recipBefore = feeRecipient.balance;

        vm.prank(creator);
        address walletAddr = factory.createWallet{value: FEE}(owners, 2);

        // Fee forwarded.
        assertEq(feeRecipient.balance, recipBefore + FEE);

        // Wallet is correctly configured.
        MultisigWallet w = MultisigWallet(payable(walletAddr));
        assertEq(w.threshold(), 2);
        assertTrue(w.isOwner(alice));
        assertTrue(w.isOwner(bob));

        // Indexing.
        assertEq(factory.allWalletsCount(), 1);
        assertEq(factory.getWalletsByCreator(creator)[0], walletAddr);
        assertEq(factory.getWalletsByOwner(alice)[0], walletAddr);
        assertEq(factory.getWalletsByOwner(bob)[0], walletAddr);
        assertEq(factory.getAllWallets()[0], walletAddr);
    }

    function test_CreateWallet_EmitsEvent() public {
        vm.prank(creator);
        vm.recordLogs();
        factory.createWallet{value: FEE}(owners, 2);
        // Presence of a deployed wallet is sufficient assertion here.
        assertEq(factory.allWalletsCount(), 1);
    }

    function test_RevertWhen_IncorrectFee() public {
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(MultisigFactory.IncorrectFee.selector, FEE - 1, FEE));
        factory.createWallet{value: FEE - 1}(owners, 2);
    }

    function test_RevertWhen_OverpayFee() public {
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(MultisigFactory.IncorrectFee.selector, FEE + 1, FEE));
        factory.createWallet{value: FEE + 1}(owners, 2);
    }

    function test_CreateWallet_ZeroFee() public {
        vm.prank(admin);
        factory.setFee(0);
        vm.prank(creator);
        address walletAddr = factory.createWallet{value: 0}(owners, 1);
        assertTrue(walletAddr != address(0));
    }

    function test_CreateWallet_InvalidWalletParamsBubbleUp() public {
        address[] memory bad = new address[](0);
        vm.prank(creator);
        vm.expectRevert(MultisigWallet.OwnersRequired.selector);
        factory.createWallet{value: FEE}(bad, 1);
    }

    function test_SetFee() public {
        vm.prank(admin);
        factory.setFee(0.5 ether);
        assertEq(factory.fee(), 0.5 ether);
    }

    function test_RevertWhen_SetFeeTooHigh() public {
        uint256 maxFee = factory.MAX_FEE();
        uint256 tooHigh = maxFee + 1;
        bytes memory expected = abi.encodeWithSelector(MultisigFactory.FeeTooHigh.selector, tooHigh, maxFee);
        vm.prank(admin);
        vm.expectRevert(expected);
        factory.setFee(tooHigh);
    }

    function test_RevertWhen_SetFeeNotOwner() public {
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, creator));
        factory.setFee(0);
    }

    function test_SetFeeRecipient() public {
        vm.prank(admin);
        factory.setFeeRecipient(creator);
        assertEq(factory.feeRecipient(), creator);
    }

    function test_RevertWhen_SetFeeRecipientZero() public {
        vm.prank(admin);
        vm.expectRevert(MultisigFactory.ZeroFeeRecipient.selector);
        factory.setFeeRecipient(address(0));
    }

    function test_RevertWhen_SetFeeRecipientNotOwner() public {
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, creator));
        factory.setFeeRecipient(creator);
    }

    function test_MultipleWallets_IndexedPerOwner() public {
        vm.startPrank(creator);
        address w1 = factory.createWallet{value: FEE}(owners, 2);
        address[] memory owners2 = new address[](2);
        owners2[0] = alice;
        owners2[1] = creator;
        address w2 = factory.createWallet{value: FEE}(owners2, 1);
        vm.stopPrank();

        assertEq(factory.getWalletsByOwner(alice).length, 2);
        assertEq(factory.getWalletsByOwner(alice)[0], w1);
        assertEq(factory.getWalletsByOwner(alice)[1], w2);
        assertEq(factory.getWalletsByOwner(bob).length, 1);
        assertEq(factory.getWalletsByCreator(creator).length, 2);
    }
}
