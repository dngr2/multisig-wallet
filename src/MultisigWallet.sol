// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title MultisigWallet
/// @notice An m-of-n multisignature wallet using on-chain confirmations
///         (Gnosis-classic style). Owners submit transactions, confirm them,
///         and once the confirmation threshold is reached any owner may execute
///         the transaction as a low-level call.
/// @dev Owner-set and threshold changes are self-governed: the only address
///      permitted to call the management functions is the wallet itself, which
///      means such changes must themselves be routed through a fully-confirmed
///      multisig transaction. No single owner or external admin can alter the
///      owner set.
contract MultisigWallet is ReentrancyGuard {
    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    /// @notice A pending or executed transaction.
    /// @param to Target address of the call.
    /// @param value Amount of wei to send with the call.
    /// @param data Calldata payload for the call.
    /// @param executed Whether the transaction has already been executed.
    /// @param confirmations Number of distinct owners that currently confirm it.
    struct Transaction {
        address to;
        uint256 value;
        bytes data;
        bool executed;
        uint256 confirmations;
    }

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice The list of current owners.
    address[] private _owners;

    /// @notice Whether an address is a current owner.
    mapping(address => bool) public isOwner;

    /// @notice Number of confirmations required to execute a transaction.
    uint256 public threshold;

    /// @notice All submitted transactions, indexed by transaction id.
    Transaction[] private _transactions;

    /// @notice Whether a given owner has confirmed a given transaction.
    /// @dev txId => owner => confirmed
    mapping(uint256 => mapping(address => bool)) public confirmedBy;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event Deposit(address indexed sender, uint256 amount, uint256 balance);
    event SubmitTransaction(address indexed owner, uint256 indexed txId, address indexed to, uint256 value, bytes data);
    event ConfirmTransaction(address indexed owner, uint256 indexed txId);
    event RevokeConfirmation(address indexed owner, uint256 indexed txId);
    event ExecuteTransaction(address indexed owner, uint256 indexed txId);

    event OwnerAdded(address indexed owner);
    event OwnerRemoved(address indexed owner);
    event OwnerReplaced(address indexed previousOwner, address indexed newOwner);
    event ThresholdChanged(uint256 threshold);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error OwnersRequired();
    error ZeroOwner();
    error DuplicateOwner(address owner);
    error InvalidThreshold(uint256 threshold, uint256 ownerCount);
    error NotOwner(address account);
    error OnlyWallet();
    error TxDoesNotExist(uint256 txId);
    error TxAlreadyExecuted(uint256 txId);
    error TxAlreadyConfirmed(uint256 txId);
    error TxNotConfirmed(uint256 txId);
    error NotEnoughConfirmations(uint256 txId);
    error TxExecutionFailed(uint256 txId);
    error AlreadyOwner(address owner);

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyOwner() {
        if (!isOwner[msg.sender]) revert NotOwner(msg.sender);
        _;
    }

    /// @dev Restricts a function so it can only be reached by the wallet
    ///      executing one of its own confirmed transactions.
    modifier onlyWallet() {
        if (msg.sender != address(this)) revert OnlyWallet();
        _;
    }

    modifier txExists(uint256 txId) {
        if (txId >= _transactions.length) revert TxDoesNotExist(txId);
        _;
    }

    modifier notExecuted(uint256 txId) {
        if (_transactions[txId].executed) revert TxAlreadyExecuted(txId);
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param owners_ The initial set of owners. Must be non-empty, contain no
    ///        zero address and no duplicates.
    /// @param threshold_ The number of confirmations required to execute a
    ///        transaction. Must satisfy 1 <= threshold_ <= owners_.length.
    constructor(address[] memory owners_, uint256 threshold_) {
        if (owners_.length == 0) revert OwnersRequired();
        if (threshold_ == 0 || threshold_ > owners_.length) {
            revert InvalidThreshold(threshold_, owners_.length);
        }

        for (uint256 i = 0; i < owners_.length; ++i) {
            address owner = owners_[i];
            if (owner == address(0)) revert ZeroOwner();
            if (isOwner[owner]) revert DuplicateOwner(owner);
            isOwner[owner] = true;
            _owners.push(owner);
        }

        threshold = threshold_;
    }

    /*//////////////////////////////////////////////////////////////
                            ETH RECEPTION
    //////////////////////////////////////////////////////////////*/

    /// @notice Accept plain ETH transfers.
    receive() external payable {
        emit Deposit(msg.sender, msg.value, address(this).balance);
    }

    /*//////////////////////////////////////////////////////////////
                          TRANSACTION LIFECYCLE
    //////////////////////////////////////////////////////////////*/

    /// @notice Submit a new transaction for the owners to confirm.
    /// @param to Target address of the call.
    /// @param value Amount of wei to forward.
    /// @param data Calldata payload.
    /// @return txId The id of the newly created transaction.
    function submitTransaction(address to, uint256 value, bytes calldata data)
        external
        onlyOwner
        returns (uint256 txId)
    {
        txId = _transactions.length;
        _transactions.push(Transaction({to: to, value: value, data: data, executed: false, confirmations: 0}));
        emit SubmitTransaction(msg.sender, txId, to, value, data);
    }

    /// @notice Confirm a pending transaction. One confirmation per owner.
    /// @param txId The transaction id.
    function confirmTransaction(uint256 txId) external onlyOwner txExists(txId) notExecuted(txId) {
        if (confirmedBy[txId][msg.sender]) revert TxAlreadyConfirmed(txId);
        confirmedBy[txId][msg.sender] = true;
        _transactions[txId].confirmations += 1;
        emit ConfirmTransaction(msg.sender, txId);
    }

    /// @notice Revoke a previously-given confirmation, before execution.
    /// @param txId The transaction id.
    function revokeConfirmation(uint256 txId) external onlyOwner txExists(txId) notExecuted(txId) {
        if (!confirmedBy[txId][msg.sender]) revert TxNotConfirmed(txId);
        confirmedBy[txId][msg.sender] = false;
        _transactions[txId].confirmations -= 1;
        emit RevokeConfirmation(msg.sender, txId);
    }

    /// @notice Execute a transaction once it has enough confirmations.
    /// @dev Follows checks-effects-interactions: the executed flag is set before
    ///      the external call and is reverted (together with all state changes)
    ///      if the call fails, so a failed transaction stays retryable. Combined
    ///      with the nonReentrant guard, this prevents any re-execution of the
    ///      same transaction.
    /// @param txId The transaction id.
    function executeTransaction(uint256 txId) external nonReentrant onlyOwner txExists(txId) notExecuted(txId) {
        Transaction storage txn = _transactions[txId];
        if (txn.confirmations < threshold) revert NotEnoughConfirmations(txId);

        // Effect first: mark executed so a reentrant call cannot execute it again.
        txn.executed = true;

        (bool success,) = txn.to.call{value: txn.value}(txn.data);
        // Revert (rolling back the executed flag) if the inner call failed, so
        // the transaction remains executable and can be retried later.
        if (!success) revert TxExecutionFailed(txId);

        emit ExecuteTransaction(msg.sender, txId);
    }

    /*//////////////////////////////////////////////////////////////
                     SELF-GOVERNED OWNER MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Add a new owner. Callable only by the wallet itself.
    /// @param owner The address to add as an owner.
    function addOwner(address owner) external onlyWallet {
        if (owner == address(0)) revert ZeroOwner();
        if (isOwner[owner]) revert AlreadyOwner(owner);
        isOwner[owner] = true;
        _owners.push(owner);
        emit OwnerAdded(owner);
    }

    /// @notice Remove an existing owner. Callable only by the wallet itself.
    /// @dev Rule: an owner may not be removed if doing so would drop the owner
    ///      count below the current threshold. The threshold must be lowered
    ///      first (via changeThreshold) if the set needs to shrink that far.
    ///      This guarantees the m-of-n invariant (threshold <= ownerCount)
    ///      always holds and the wallet can never be bricked into an
    ///      unsatisfiable threshold.
    /// @param owner The owner address to remove.
    function removeOwner(address owner) external onlyWallet {
        if (!isOwner[owner]) revert NotOwner(owner);
        uint256 newCount = _owners.length - 1;
        if (newCount < threshold) revert InvalidThreshold(threshold, newCount);

        isOwner[owner] = false;
        _removeFromOwners(owner);
        emit OwnerRemoved(owner);
    }

    /// @notice Replace an existing owner with a new one in a single call.
    /// @dev Owner count is unchanged, so the threshold invariant is preserved.
    /// @param oldOwner The owner to remove.
    /// @param newOwner The owner to add in its place.
    function replaceOwner(address oldOwner, address newOwner) external onlyWallet {
        if (!isOwner[oldOwner]) revert NotOwner(oldOwner);
        if (newOwner == address(0)) revert ZeroOwner();
        if (isOwner[newOwner]) revert AlreadyOwner(newOwner);

        isOwner[oldOwner] = false;
        isOwner[newOwner] = true;
        uint256 len = _owners.length;
        for (uint256 i = 0; i < len; ++i) {
            if (_owners[i] == oldOwner) {
                _owners[i] = newOwner;
                break;
            }
        }
        emit OwnerReplaced(oldOwner, newOwner);
    }

    /// @notice Change the confirmation threshold. Callable only by the wallet.
    /// @param threshold_ The new threshold; must satisfy
    ///        1 <= threshold_ <= current owner count.
    function changeThreshold(uint256 threshold_) external onlyWallet {
        if (threshold_ == 0 || threshold_ > _owners.length) {
            revert InvalidThreshold(threshold_, _owners.length);
        }
        threshold = threshold_;
        emit ThresholdChanged(threshold_);
    }

    /// @dev Remove `owner` from the `_owners` array by swap-and-pop.
    function _removeFromOwners(address owner) private {
        uint256 len = _owners.length;
        for (uint256 i = 0; i < len; ++i) {
            if (_owners[i] == owner) {
                _owners[i] = _owners[len - 1];
                _owners.pop();
                return;
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Return the current owner set.
    function getOwners() external view returns (address[] memory) {
        return _owners;
    }

    /// @notice Return the number of confirmations a transaction currently has.
    function getConfirmationCount(uint256 txId) external view txExists(txId) returns (uint256) {
        return _transactions[txId].confirmations;
    }

    /// @notice Whether a transaction has reached the confirmation threshold.
    function isConfirmed(uint256 txId) external view txExists(txId) returns (bool) {
        return _transactions[txId].confirmations >= threshold;
    }

    /// @notice Return the full data of a transaction.
    function getTransaction(uint256 txId)
        external
        view
        txExists(txId)
        returns (address to, uint256 value, bytes memory data, bool executed, uint256 confirmations)
    {
        Transaction storage txn = _transactions[txId];
        return (txn.to, txn.value, txn.data, txn.executed, txn.confirmations);
    }

    /// @notice Total number of submitted transactions.
    function transactionCount() external view returns (uint256) {
        return _transactions.length;
    }

    /// @notice Number of current owners.
    function ownerCount() external view returns (uint256) {
        return _owners.length;
    }
}
