// SPDX-License-Identifier: Apache-2.0
// ERC20 wrapper paired 1:1 with a Zeto_AnonNullifierBurnable. The wrapper
// deploys its own Zeto via the factory in the constructor with itself as
// owner — no two-step ownership handoff. Sole minter and burner of its own
// supply; sole owner of the paired Zeto. Conservation:
// ERC20.totalSupply() + private_commitment_value_sum == constant.
pragma solidity ^0.8.27;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Commonlib} from "zeto/lib/common/common.sol";

interface IZetoBurnable {
    function mint(uint256[] calldata utxos, bytes calldata data) external;

    function burn(
        uint256[] calldata nullifiers,
        uint256 output,
        uint256 root,
        Commonlib.Proof calldata proof,
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
    IZetoBurnable public immutable zeto;
    uint8 private immutable _decimals;

    error LengthMismatch(uint256 commitments, uint256 amounts);
    error ZeroCommitment(uint256 index);
    error ZeroAmount(uint256 index);
    error ZeroRecipient();
    error ZeroUnshieldAmount();

    event Shielded(address indexed from, uint256 totalAmount, uint256 commitmentCount);
    event Unshielded(address indexed to, uint256 amount, uint256 nullifierCount);

    /// @param factory     ZetoTokenFactory holding the registered impls.
    /// @param zetoImpl    Implementation name registered with the factory,
    ///                    e.g. "Zeto_AnonNullifierBurnable".
    constructor(
        address factory,
        string memory zetoImpl,
        string memory name_,
        string memory symbol_,
        uint8 decimals_
    ) ERC20(name_, symbol_) Ownable(msg.sender) {
        require(factory != address(0), "WrappedZeto: zero factory");
        // Wrapper is the Zeto's initialOwner from inception. No 2-step handoff.
        address z = IZetoFactory(factory).deployZetoFungibleToken(
            name_, symbol_, zetoImpl, address(this)
        );
        zeto = IZetoBurnable(z);
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    /// @notice Genesis hatch: mint one commitment on the paired Zeto with no
    ///         ERC20 round-trip. Used once at asset-creation time.
    function seedAndShield(uint256 commitment, uint256 amount, bytes calldata data) external onlyOwner {
        if (commitment == 0) revert ZeroCommitment(0);
        if (amount == 0) revert ZeroAmount(0);

        uint256[] memory cs = new uint256[](1);
        cs[0] = commitment;
        zeto.mint(cs, data);

        emit Shielded(msg.sender, amount, 1);
    }

    /// @notice Public → private. Burns `sum(amounts)` ERC20 from the caller
    ///         and mints `commitments` on the paired Zeto.
    function shield(
        uint256[] calldata commitments,
        uint256[] calldata amounts,
        bytes calldata data
    ) external {
        if (commitments.length != amounts.length) {
            revert LengthMismatch(commitments.length, amounts.length);
        }

        uint256 total = 0;
        for (uint256 i = 0; i < amounts.length; i++) {
            if (commitments[i] == 0) revert ZeroCommitment(i);
            if (amounts[i] == 0) revert ZeroAmount(i);
            total += amounts[i];
        }

        // CEI: burn before external call.
        _burn(msg.sender, total);
        zeto.mint(commitments, data);

        emit Shielded(msg.sender, total, commitments.length);
    }

    /// @notice Private → public. Consumes input nullifiers via Zeto.burn
    ///         (Groth16-gated) and mints `amount` ERC20 to `evm_recipient`.
    function unshield(
        uint256[] calldata inputs,
        uint256 output,
        uint256 root,
        Commonlib.Proof calldata proof,
        address evm_recipient,
        uint256 amount,
        bytes calldata data
    ) external {
        if (evm_recipient == address(0)) revert ZeroRecipient();
        if (amount == 0) revert ZeroUnshieldAmount();

        // Consume private side first so a reentrant callback sees the public
        // supply un-credited, never double-credited.
        zeto.burn(inputs, output, root, proof, data);
        _mint(evm_recipient, amount);

        emit Unshielded(evm_recipient, amount, inputs.length);
    }
}
