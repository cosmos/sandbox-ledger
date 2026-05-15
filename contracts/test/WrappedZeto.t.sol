// SPDX-License-Identifier: Apache-2.0
// WrappedZeto tests. The wrapper calls Zeto.deposit / Zeto.withdraw, whose
// real Groth16 verifiers gate the `amount` ↔ commitment-value binding. The
// mock in this file pretends to verify; it tracks `privateValueSum` from the
// `amount` parameter directly, which is the same invariant the real
// verifiers enforce. Conservation is asserted by
// `ERC20.totalSupply() + privateValueSum == constant`.
pragma solidity ^0.8.27;

import "forge-std/Test.sol";

import {WrappedZeto, IZetoFungible, IZetoFactory} from "../src/WrappedZeto.sol";

/// @dev Stand-in for Zeto's fungible surface. The real contract verifies a
///      depositVerifier / withdrawVerifier proof over (amount, outputs/inputs);
///      the mock trusts `amount` to assert the wrapper's accounting.
contract MockZetoFungible is IZetoFungible {
    address public owner_;
    uint256 public privateValueSum;
    uint256 public mintCalls;
    uint256 public depositCalls;
    uint256 public withdrawCalls;

    // Stages the amount a subsequent owner-only `mint()` should credit to
    // the private supply. Real Zeto.mint is amount-agnostic (owner is the
    // trusted issuer); the mock needs the value to track conservation.
    uint256 private _nextMintAmount;

    bool public revertNext;

    constructor(address initialOwner) {
        owner_ = initialOwner;
    }

    function owner() external view override returns (address) {
        return owner_;
    }

    function setRevertNext(bool v) external {
        revertNext = v;
    }

    function setNextMintAmount(uint256 amount) external {
        _nextMintAmount = amount;
    }

    function mint(
        uint256[] calldata utxos,
        bytes calldata /* data */
    )
        external
        override
    {
        require(msg.sender == owner_, "MockZeto: only owner mints");
        if (revertNext) {
            revertNext = false;
            revert("MockZeto: forced revert");
        }
        require(utxos.length > 0, "MockZeto: no outputs");
        privateValueSum += _nextMintAmount;
        _nextMintAmount = 0;
        mintCalls++;
    }

    function deposit(
        uint256 amount,
        uint256[] calldata outputs,
        bytes calldata,
        /* proof */
        bytes calldata /* data */
    )
        external
        override
    {
        if (revertNext) {
            revertNext = false;
            revert("MockZeto: forced revert");
        }
        require(outputs.length > 0, "MockZeto: no outputs");
        // Real depositVerifier binds amount to sum(output values). Mock
        // trusts amount and credits the private supply by that exact value.
        privateValueSum += amount;
        depositCalls++;
    }

    function withdraw(
        uint256 amount,
        uint256[] calldata, /* inputs */
        uint256, /* output */
        bytes calldata, /* proof */
        bytes calldata /* data */
    )
        external
        override
    {
        if (revertNext) {
            revertNext = false;
            revert("MockZeto: forced revert");
        }
        require(privateValueSum >= amount, "MockZeto: underflow");
        // Real withdrawVerifier binds amount to (sum(inputs) - output).
        // Mock trusts amount and debits the private supply.
        privateValueSum -= amount;
        withdrawCalls++;
    }
}

contract MockZetoFactory is IZetoFactory {
    MockZetoFungible public last;

    function deployZetoFungibleToken(
        string calldata, /* name */
        string calldata, /* symbol */
        string calldata, /* tokenImplementation */
        address initialOwner
    )
        external
        override
        returns (address)
    {
        last = new MockZetoFungible(initialOwner);
        return address(last);
    }
}

contract WrappedZetoTest is Test {
    MockZetoFungible internal zeto;
    MockZetoFactory internal factory;
    WrappedZeto internal wrapper;

    address internal user = address(0xA11CE);
    address internal otherUser = address(0xB0B);

    function setUp() public {
        factory = new MockZetoFactory();
        wrapper = new WrappedZeto(address(factory), "Zeto_AnonNullifierBurnable", "Wrapped Zeto", "wZETO", 4);
        zeto = factory.last();
        assertEq(zeto.owner(), address(wrapper), "wrapper should own zeto from inception");
    }

    // ---------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------

    /// @dev deal() with the 4-arg form updates totalSupply too, matching
    ///      a real ERC20 mint without needing a round-trip.
    function _seedBalance(address to, uint256 amount) internal {
        deal(address(wrapper), to, amount, true);
    }

    function _totalValue() internal view returns (uint256) {
        return wrapper.totalSupply() + zeto.privateValueSum();
    }

    function _mkCommitments(uint256 seed, uint256 n) internal pure returns (uint256[] memory cs) {
        cs = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            cs[i] = uint256(keccak256(abi.encode(seed, i))) | 1; // non-zero
        }
    }

    function _doShield(address from, uint256 amount, uint256 seed, uint256 n) internal {
        uint256[] memory commitments = _mkCommitments(seed, n);
        vm.prank(from);
        wrapper.shield(amount, commitments, "", "");
    }

    function _doUnshield(address to, uint256 amount) internal {
        uint256[] memory inputs = new uint256[](2);
        inputs[0] = uint256(keccak256(abi.encode("nul", amount, to, "0")));
        inputs[1] = uint256(keccak256(abi.encode("nul", amount, to, "1")));
        wrapper.unshield(amount, inputs, uint256(keccak256(abi.encode("out", amount, to))), "", to, "");
    }

    // ---------------------------------------------------------------
    // Bootstrap / metadata
    // ---------------------------------------------------------------

    function test_Metadata() public view {
        assertEq(wrapper.name(), "Wrapped Zeto");
        assertEq(wrapper.symbol(), "wZETO");
        assertEq(wrapper.decimals(), 4);
        assertEq(address(wrapper.zeto()), address(zeto));
    }

    // ---------------------------------------------------------------
    // Conservation invariant
    // ---------------------------------------------------------------

    function test_ConservationAcrossManyCycles() public {
        uint256 SEED_BALANCE = 1_000_000;
        _seedBalance(user, SEED_BALANCE);
        uint256 expected = _totalValue();
        assertEq(expected, SEED_BALANCE, "initial conservation");

        _doShield(user, 200, 1, 2);
        assertEq(_totalValue(), expected, "conservation after shield #1");

        _doShield(user, 300, 2, 3);
        assertEq(_totalValue(), expected, "conservation after shield #2");

        _doUnshield(otherUser, 150);
        assertEq(_totalValue(), expected, "conservation after unshield #1");

        _doShield(user, 100, 3, 1);
        assertEq(_totalValue(), expected, "conservation after shield #3");

        _doUnshield(user, 50);
        assertEq(_totalValue(), expected, "conservation after unshield #2");

        uint256 publicHeld = wrapper.balanceOf(user) + wrapper.balanceOf(otherUser);
        assertEq(publicHeld + zeto.privateValueSum(), SEED_BALANCE, "final accounting");
    }

    function test_RoundTrip() public {
        uint256 N = 12_345;
        _seedBalance(user, N);

        uint256[] memory commitments = new uint256[](2);
        commitments[0] = uint256(keccak256("rt-c0"));
        commitments[1] = uint256(keccak256("rt-c1"));
        vm.prank(user);
        wrapper.shield(N, commitments, "", "");

        assertEq(wrapper.balanceOf(user), 0, "all wrapped burnt");
        assertEq(zeto.privateValueSum(), N, "private side credited");

        _doUnshield(user, N);

        assertEq(wrapper.balanceOf(user), N, "wrapped restored");
        assertEq(zeto.privateValueSum(), 0, "private side empty");
        assertEq(wrapper.totalSupply(), N, "no stray supply");
    }

    // ---------------------------------------------------------------
    // Caller cannot move third-party balances; underlying revert
    // propagates without minting ERC20.
    // ---------------------------------------------------------------

    function test_ShieldCannotDrainOtherUser() public {
        _seedBalance(user, 1_000);
        _seedBalance(otherUser, 500);

        uint256[] memory commitments = _mkCommitments(99, 1);
        vm.prank(otherUser);
        wrapper.shield(500, commitments, "", "");

        assertEq(wrapper.balanceOf(user), 1_000, "user's balance untouched");
        assertEq(wrapper.balanceOf(otherUser), 0, "other's balance drained");
    }

    function test_UnshieldRevertsIfZetoReverts() public {
        zeto.setRevertNext(true);
        uint256 supplyBefore = wrapper.totalSupply();
        vm.expectRevert(bytes("MockZeto: forced revert"));
        _doUnshield(user, 100);
        assertEq(wrapper.totalSupply(), supplyBefore, "no supply on withdraw revert");
    }

    // ---------------------------------------------------------------
    // shield input validation
    // ---------------------------------------------------------------

    function test_ShieldRevertsOnZeroAmount() public {
        _seedBalance(user, 1_000);
        uint256[] memory commitments = _mkCommitments(0, 1);
        vm.prank(user);
        vm.expectRevert(WrappedZeto.ZeroAmount.selector);
        wrapper.shield(0, commitments, "", "");
    }

    function test_ShieldRevertsOnNoCommitments() public {
        _seedBalance(user, 1_000);
        uint256[] memory commitments = new uint256[](0);
        vm.prank(user);
        vm.expectRevert(WrappedZeto.NoCommitments.selector);
        wrapper.shield(100, commitments, "", "");
    }

    function test_ShieldRevertsOnZeroCommitment() public {
        _seedBalance(user, 1_000);
        uint256[] memory commitments = new uint256[](2);
        commitments[0] = uint256(keccak256("c0"));
        commitments[1] = 0;
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(WrappedZeto.ZeroCommitment.selector, 1));
        wrapper.shield(100, commitments, "", "");
    }

    function test_ShieldRevertsOnInsufficientBalance() public {
        _seedBalance(user, 100);
        uint256[] memory commitments = _mkCommitments(0, 1);
        vm.prank(user);
        vm.expectRevert(); // OZ ERC20InsufficientBalance
        wrapper.shield(500, commitments, "", "");
    }

    // ---------------------------------------------------------------
    // unshield input validation
    // ---------------------------------------------------------------

    function test_UnshieldRevertsOnZeroRecipient() public {
        uint256[] memory inputs = new uint256[](1);
        inputs[0] = 1;
        vm.expectRevert(WrappedZeto.ZeroRecipient.selector);
        wrapper.unshield(100, inputs, 1, "", address(0), "");
    }

    function test_UnshieldRevertsOnZeroAmount() public {
        uint256[] memory inputs = new uint256[](1);
        inputs[0] = 1;
        vm.expectRevert(WrappedZeto.ZeroAmount.selector);
        wrapper.unshield(0, inputs, 1, "", user, "");
    }

    // ---------------------------------------------------------------
    // seedAndShield (genesis hatch)
    // ---------------------------------------------------------------

    function test_SeedAndShield_HappyPath() public {
        uint256 commitment = uint256(keccak256("genesis")) | 1;
        uint256 amount = 1_000_000;

        zeto.setNextMintAmount(amount);
        wrapper.seedAndShield(amount, commitment, "");

        assertEq(wrapper.totalSupply(), 0, "ERC20 supply must stay 0");
        assertEq(zeto.privateValueSum(), amount, "private supply == amount");
        assertEq(_totalValue(), amount, "conservation constant = amount after seed");
        assertEq(zeto.mintCalls(), 1, "exactly one Zeto.mint call");
    }

    function test_SeedAndShield_OnlyOwner() public {
        vm.prank(user);
        vm.expectRevert(); // OZ Ownable: OwnableUnauthorizedAccount(user)
        wrapper.seedAndShield(100, 1, "");
    }

    function test_SeedAndShield_RevertsOnZeroCommitment() public {
        vm.expectRevert(abi.encodeWithSelector(WrappedZeto.ZeroCommitment.selector, uint256(0)));
        wrapper.seedAndShield(100, 0, "");
    }

    function test_SeedAndShield_RevertsOnZeroAmount() public {
        vm.expectRevert(WrappedZeto.ZeroAmount.selector);
        wrapper.seedAndShield(0, 1, "");
    }

    function test_SeedAndShield_ConservedAcrossSubsequentCycles() public {
        uint256 M = 5_000;
        zeto.setNextMintAmount(M);
        wrapper.seedAndShield(M, uint256(keccak256("g")) | 1, "");
        uint256 constantBefore = _totalValue();

        uint256 N = 1_500;
        _doUnshield(user, N);
        assertEq(_totalValue(), constantBefore, "constant invariant under unshield");

        _doShield(user, N, 42, 1);
        assertEq(_totalValue(), constantBefore, "constant invariant under shield");
    }
}
