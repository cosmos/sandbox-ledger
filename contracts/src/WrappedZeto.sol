// SPDX-License-Identifier: Apache-2.0
// ERC20 wrapper paired 1:1 with a Zeto_AnonNullifierBurnable. The wrapper
// deploys its own Zeto via the factory in the constructor with itself as
// owner. Public ↔ private flows go through Zeto.deposit / Zeto.withdraw,
// whose Groth16 verifiers (depositVerifier / withdrawVerifier) bind the
// public `amount` to the commitment values — so ERC20 supply moves in
// lockstep with the private side. Conservation:
// ERC20.totalSupply() + private_commitment_value_sum == constant.
pragma solidity ^0.8.27;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

interface IZetoFungible {
    function mint(uint256[] calldata utxos, bytes calldata data) external;

    function deposit(
        uint256 amount,
        uint256[] calldata outputs,
        bytes calldata proof,
        bytes calldata data
    ) external;

    function withdraw(
        uint256 amount,
        uint256[] calldata inputs,
        uint256 output,
        bytes calldata proof,
        bytes calldata data
    ) external;

    function owner() external view returns (address);
}

interface IZetoFactory {
    function deployZetoFungibleToken(
        string calldata name,
        string calldata symbol,
        string calldata tokenImplementation,
        address initialOwner
    ) external returns (address);
}

contract WrappedZeto is ERC20, Ownable {
    IZetoFungible public immutable zeto;
    uint8 private immutable _decimals;

    error ZeroCommitment(uint256 index);
    error ZeroAmount();
    error ZeroRecipient();
    error NoCommitments();

    event Shielded(address indexed from, uint256 amount, uint256 commitmentCount);
    event Unshielded(address indexed to, uint256 amount, uint256 nullifierCount);

    /// @param factory     ZetoTokenFactory with the registered impls.
    /// @param zetoImpl    Implementation name registered with the factory.
    constructor(
        address factory,
        string memory zetoImpl,
        string memory name_,
        string memory symbol_,
        uint8 decimals_
    ) ERC20(name_, symbol_) Ownable(msg.sender) {
        require(factory != address(0), "WrappedZeto: zero factory");
        address z = IZetoFactory(factory).deployZetoFungibleToken(
            name_, symbol_, zetoImpl, address(this)
        );
        zeto = IZetoFungible(z);
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    /// @notice Genesis hatch. Owner-only — the admin is the asset issuer and
    ///         the trust anchor for the initial supply. Calls Zeto.mint with
    ///         the admin's chosen commitment; `amount` is the admin's
    ///         self-declared issuance value, surfaced in the event for
    ///         downstream indexers. Not cryptographically bound to the
    ///         commitment (a deposit proof would be tautological here since
    ///         the admin picks both inputs).
    function seedAndShield(
        uint256 amount,
        uint256 commitment,
        bytes calldata data
    ) external onlyOwner {
        if (amount == 0) revert ZeroAmount();
        if (commitment == 0) revert ZeroCommitment(0);

        uint256[] memory outs = new uint256[](1);
        outs[0] = commitment;
        zeto.mint(outs, data);

        emit Shielded(msg.sender, amount, 1);
    }

    /// @notice Public → private. Burns `amount` ERC20 from caller; the
    ///         deposit verifier binds `amount` to sum(commitment values).
    function shield(
        uint256 amount,
        uint256[] calldata commitments,
        bytes calldata depositProof,
        bytes calldata data
    ) external {
        if (amount == 0) revert ZeroAmount();
        if (commitments.length == 0) revert NoCommitments();
        for (uint256 i = 0; i < commitments.length; i++) {
            if (commitments[i] == 0) revert ZeroCommitment(i);
        }

        // CEI: burn before external call.
        _burn(msg.sender, amount);
        zeto.deposit(amount, commitments, depositProof, data);

        emit Shielded(msg.sender, amount, commitments.length);
    }

    /// @notice Private → public. Calls Zeto.withdraw, whose verifier binds
    ///         `amount` to (sum(input values) − output value). Then mints
    ///         `amount` ERC20 — safe because the binding is cryptographic.
    function unshield(
        uint256 amount,
        uint256[] calldata inputs,
        uint256 output,
        bytes calldata withdrawProof,
        address recipient,
        bytes calldata data
    ) external {
        if (recipient == address(0)) revert ZeroRecipient();
        if (amount == 0) revert ZeroAmount();

        // Consume private side first so a reentrant callback sees the public
        // supply un-credited, never double-credited.
        zeto.withdraw(amount, inputs, output, withdrawProof, data);
        _mint(recipient, amount);

        emit Unshielded(recipient, amount, inputs.length);
    }
}
