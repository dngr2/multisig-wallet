// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {MultisigWallet} from "./MultisigWallet.sol";

/// @title MultisigFactory
/// @notice Deploys {MultisigWallet} instances, indexes them by creator and by
///         each owner, and charges a bounded flat fee per deployment which is
///         forwarded to a fee recipient.
contract MultisigFactory is Ownable {
    using Address for address payable;

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Hard upper bound on the deploy fee the factory owner may set.
    /// @dev Guarantees the fee can never be raised to an extortionate value.
    uint256 public constant MAX_FEE = 1 ether;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Flat fee (in wei) required to deploy a wallet.
    uint256 public fee;

    /// @notice Address that receives collected deploy fees.
    address public feeRecipient;

    /// @notice All wallets ever deployed by this factory.
    address[] private _allWallets;

    /// @notice Wallets deployed by a given creator (the caller of createWallet).
    mapping(address => address[]) private _walletsByCreator;

    /// @notice Wallets in which a given address is an owner.
    mapping(address => address[]) private _walletsByOwner;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event WalletCreated(
        address indexed wallet, address indexed creator, address[] owners, uint256 threshold, uint256 feePaid
    );
    event FeeChanged(uint256 fee);
    event FeeRecipientChanged(address indexed feeRecipient);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error FeeTooHigh(uint256 fee, uint256 maxFee);
    error IncorrectFee(uint256 sent, uint256 required);
    error ZeroFeeRecipient();

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param initialOwner The factory admin (can set fee and recipient).
    /// @param feeRecipient_ The initial fee recipient.
    /// @param fee_ The initial deploy fee (must be <= MAX_FEE).
    constructor(address initialOwner, address feeRecipient_, uint256 fee_) Ownable(initialOwner) {
        if (feeRecipient_ == address(0)) revert ZeroFeeRecipient();
        if (fee_ > MAX_FEE) revert FeeTooHigh(fee_, MAX_FEE);
        feeRecipient = feeRecipient_;
        fee = fee_;
    }

    /*//////////////////////////////////////////////////////////////
                            WALLET CREATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Deploy a new {MultisigWallet} and forward the deploy fee.
    /// @dev The exact `fee` must be supplied as `msg.value`. Owner-set and
    ///      threshold validation is performed by the wallet's constructor.
    /// @param owners The initial owner set for the new wallet.
    /// @param threshold The confirmation threshold for the new wallet.
    /// @return wallet The address of the newly deployed wallet.
    function createWallet(address[] calldata owners, uint256 threshold) external payable returns (address wallet) {
        uint256 required = fee;
        if (msg.value != required) revert IncorrectFee(msg.value, required);

        MultisigWallet deployed = new MultisigWallet(owners, threshold);
        wallet = address(deployed);

        _allWallets.push(wallet);
        _walletsByCreator[msg.sender].push(wallet);
        uint256 len = owners.length;
        for (uint256 i = 0; i < len;) {
            _walletsByOwner[owners[i]].push(wallet);
            unchecked {
                ++i;
            }
        }

        if (required > 0) {
            payable(feeRecipient).sendValue(required);
        }

        emit WalletCreated(wallet, msg.sender, owners, threshold, required);
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN (BOUNDED)
    //////////////////////////////////////////////////////////////*/

    /// @notice Set the flat deploy fee. Bounded by MAX_FEE.
    function setFee(uint256 fee_) external onlyOwner {
        if (fee_ > MAX_FEE) revert FeeTooHigh(fee_, MAX_FEE);
        fee = fee_;
        emit FeeChanged(fee_);
    }

    /// @notice Set the fee recipient. Must be non-zero.
    function setFeeRecipient(address feeRecipient_) external onlyOwner {
        if (feeRecipient_ == address(0)) revert ZeroFeeRecipient();
        feeRecipient = feeRecipient_;
        emit FeeRecipientChanged(feeRecipient_);
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Total number of wallets deployed by this factory.
    function allWalletsCount() external view returns (uint256) {
        return _allWallets.length;
    }

    /// @notice Return every wallet deployed by this factory.
    function getAllWallets() external view returns (address[] memory) {
        return _allWallets;
    }

    /// @notice Return the wallets deployed by a given creator.
    function getWalletsByCreator(address creator) external view returns (address[] memory) {
        return _walletsByCreator[creator];
    }

    /// @notice Return the wallets in which `owner` is an owner.
    function getWalletsByOwner(address owner) external view returns (address[] memory) {
        return _walletsByOwner[owner];
    }
}
