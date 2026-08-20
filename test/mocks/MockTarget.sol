// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Records calls it receives so tests can assert a multisig tx reached
///         its target and mutated external state.
contract MockTarget {
    uint256 public value;
    uint256 public callCount;
    uint256 public lastValueSent;
    address public lastCaller;
    bytes public lastData;

    event Pinged(address caller, uint256 value, uint256 newValue);

    /// @notice Set the stored value; used to assert contract-call execution.
    function setValue(uint256 newValue) external payable {
        value = newValue;
        callCount += 1;
        lastValueSent = msg.value;
        lastCaller = msg.sender;
        emit Pinged(msg.sender, msg.value, newValue);
    }

    /// @notice Always reverts; used to test failed-execution retry behaviour.
    function boom() external payable {
        revert("boom");
    }

    receive() external payable {
        callCount += 1;
        lastValueSent = msg.value;
        lastCaller = msg.sender;
    }
}
