// SPDX-License-Identifier: Apache-2.0
// WrappedZeto tests (STACK-2757). Exercises shield/unshield against a
// mocked Zeto contract -- real Groth16 proof generation lives in the
// backend, so the on-chain conservation invariant is gated here by
// asserting the wrapper's ERC20 supply moves in lockstep with a
// synthetic "private commitment value sum" tracked by the mock.
//
// What this file does NOT cover (intentionally out of scope):
//   - Real burn-verifier wiring -- exercised in ZetoAnonNullifier.t.sol
//     against the actual Zeto_AnonNullifierBurnable, which is the gate
//     on the Groth16 path. WrappedZeto only forwards into Zeto.burn so
//     wiring is structural, not cryptographic.
//   - Reentrancy hardening -- the mock does not callback into the
//     wrapper. CEI ordering is in place but unproven by these tests.
pragma solidity ^0.8.27;

import "forge-std/Test.sol";

import {WrappedZeto, IZetoBurnable, IZetoFactory} from "../src/WrappedZeto.sol";
import {Commonlib} from "zeto/lib/common/common.sol";

/// @dev Minimal stand-in for {Zeto_AnonNullifierBurnable} that lets
///      these tests exercise WrappedZeto's accounting without dragging
///      in the full Poseidon + SmtLib + Groth16 verifier cascade
///      (which the dedicated ZetoAnonNullifier tests already cover).
///
///      The mock tracks a synthetic `privateValueSum` so the
///      conservation invariant
///        ERC20.totalSupply() + privateValueSum == constant
///      can be asserted across many shield/unshield cycles. `shield`
///      passes the per-commitment `amounts` array via {setNextMintAmounts};
///      `unshield` declares the public-side delta directly via
///      its `amount` argument.
///
///      Ownership: the mock implements just enough of {Ownable2Step}
///      to let the wrapper call {acceptOwnership}.
contract MockZetoBurnable is IZetoBurnable {
    address public owner_;

    // Set by the test harness right before a shield(), since `mint`
    // itself only gets opaque commitments. Lets the mock credit the
    // synthetic private supply by the plaintext amounts the test is
    // asserting against.
    uint256[] private _nextMintAmounts;

    uint256 public privateValueSum;
    uint256 public mintCalls;
    uint256 public burnCalls;

    // If true, the next call to mint() or burn() reverts. Used to
    // assert the wrapper bubbles up Zeto-side failures.
    bool public revertNext;

    constructor(address initialOwner) {
        owner_ = initialOwner;
    }

    function owner() external view override returns (address) {
        return owner_;
    }

    function setNextMintAmounts(uint256[] calldata amounts) external {
        delete _nextMintAmounts;
        for (uint256 i = 0; i < amounts.length; i++) {
            _nextMintAmounts.push(amounts[i]);
        }
    }

    function setRevertNext(bool v) external {
        revertNext = v;
    }

    function mint(uint256[] calldata utxos, bytes calldata /* data */) external override {
        require(msg.sender == owner_, "MockZeto: only owner mints");
        if (revertNext) {
            revertNext = false;
            revert("MockZeto: forced revert");
        }
        require(utxos.length == _nextMintAmounts.length, "MockZeto: amounts not staged");
        for (uint256 i = 0; i < _nextMintAmounts.length; i++) {
            privateValueSum += _nextMintAmounts[i];
        }
        delete _nextMintAmounts;
        mintCalls++;
    }

    function burn(
        uint256[] calldata /* nullifiers */,
        uint256 /* output */,
        uint256 /* root */,
        Commonlib.Proof calldata /* proof */,
        bytes calldata data
    ) external override {
        if (revertNext) {
            revertNext = false;
            revert("MockZeto: forced revert");
        }
        // The test encodes the burn's public-side delta into the `data`
        // blob as a single uint256 so the mock can track conservation
        // without needing to replicate the Zeto burn circuit's
        // (sum(inputs) - output == amount) check.
        require(data.length == 32, "MockZeto: expected uint256 amount in data");
        uint256 publicDelta = abi.decode(data, (uint256));
        require(privateValueSum >= publicDelta, "MockZeto: underflow");
        privateValueSum -= publicDelta;
        burnCalls++;
    }
}

/// @dev Mock factory: deploys a fresh MockZetoBurnable owned by `initialOwner`
///      and tracks it so the test can reach back into the same instance for
///      conservation assertions.
contract MockZetoFactory is IZetoFactory {
    MockZetoBurnable public last;

    function deployZetoFungibleToken(
        string calldata, /* name */
        string calldata, /* symbol */
        string calldata, /* tokenImplementation */
        address initialOwner
    ) external override returns (address) {
        last = new MockZetoBurnable(initialOwner);
        return address(last);
    }
}

contract WrappedZetoTest is Test {
    MockZetoBurnable internal zeto;
    MockZetoFactory internal factory;
    WrappedZeto internal wrapper;

    address internal user = address(0xA11CE);
    address internal otherUser = address(0xB0B);

    Commonlib.Proof internal dummyProof;

    function setUp() public {
        factory = new MockZetoFactory();
        wrapper = new WrappedZeto(address(factory), "Zeto_AnonNullifierBurnable", "Wrapped Zeto", "wZETO", 4);
        zeto = factory.last();
        assertEq(zeto.owner(), address(wrapper), "wrapper should own zeto from inception");
    }

    // ---------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------

    /// @dev Mint wrapper ERC20 to `to`. Cheats around the
    ///      no-direct-mint policy by going through a shield()-then-
    ///      unshield() round-trip would defeat the purpose of giving
    ///      the user a starting balance. Instead, use Foundry's
    ///      `deal()` cheatcode to seed balance + totalSupply atomically.
    function _seedBalance(address to, uint256 amount) internal {
        // deal() with the 4-arg form updates totalSupply too, matching
        // a real ERC20 mint.
        deal(address(wrapper), to, amount, true);
    }

    /// @dev Build commitments/amounts pair: distinct non-zero
    ///      commitments, distinct positive amounts. The commitment
    ///      values are opaque to the wrapper, so any non-zero scheme
    ///      works; the tests use `100 + i` for amounts and
    ///      `keccak256(seed, i)` for commitments.
    function _mkShieldArgs(uint256 seed, uint256 n)
        internal
        pure
        returns (uint256[] memory commitments, uint256[] memory amounts, uint256 total)
    {
        commitments = new uint256[](n);
        amounts = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            commitments[i] = uint256(keccak256(abi.encode(seed, i))) | 1; // ensure non-zero
            amounts[i] = 100 + i + (seed % 13);
            total += amounts[i];
        }
    }

    /// @dev Sum of public ERC20 supply + synthetic private value. This
    ///      is the conservation quantity that must be invariant under
    ///      any shield/unshield sequence.
    function _totalValue() internal view returns (uint256) {
        return wrapper.totalSupply() + zeto.privateValueSum();
    }

    function _doShield(address from, uint256 seed, uint256 n) internal {
        (uint256[] memory commitments, uint256[] memory amounts, uint256 total) =
            _mkShieldArgs(seed, n);
        zeto.setNextMintAmounts(amounts);
        vm.prank(from);
        wrapper.shield(commitments, amounts, "");
        total; // silence unused -- _mkShieldArgs returns it for callers that need it
    }

    function _doUnshield(address to, uint256 amount) internal {
        uint256[] memory inputs = new uint256[](2);
        inputs[0] = uint256(keccak256(abi.encode("nul", amount, to, "0")));
        inputs[1] = uint256(keccak256(abi.encode("nul", amount, to, "1")));
        wrapper.unshield(
            inputs,
            uint256(keccak256(abi.encode("out", amount, to))),
            uint256(keccak256(abi.encode("root", amount, to))),
            dummyProof,
            to,
            amount,
            abi.encode(amount)
        );
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

    /// @dev Sequence of mixed shield/unshield operations. After every
    ///      step, totalSupply() + privateValueSum() must equal the
    ///      starting bag of seeded balance.
    function test_ConservationAcrossManyCycles() public {
        uint256 SEED_BALANCE = 1_000_000;
        _seedBalance(user, SEED_BALANCE);
        uint256 expected = _totalValue();
        assertEq(expected, SEED_BALANCE, "initial conservation");

        // shield 200
        _doShield(user, 1, 2);
        assertEq(_totalValue(), expected, "conservation after shield #1");

        // shield 300
        _doShield(user, 2, 3);
        assertEq(_totalValue(), expected, "conservation after shield #2");

        // unshield 150 to otherUser
        _doUnshield(otherUser, 150);
        assertEq(_totalValue(), expected, "conservation after unshield #1");

        // shield 100 more (one commitment)
        _doShield(user, 3, 1);
        assertEq(_totalValue(), expected, "conservation after shield #3");

        // unshield 50 back to user
        _doUnshield(user, 50);
        assertEq(_totalValue(), expected, "conservation after unshield #2");

        // final: every public token still in circulation must be
        // accounted for by either ERC20 balances or the private bag.
        uint256 publicHeld = wrapper.balanceOf(user) + wrapper.balanceOf(otherUser);
        assertEq(publicHeld + zeto.privateValueSum(), SEED_BALANCE, "final accounting");
    }

    // ---------------------------------------------------------------
    // Round trip: shield(N) then unshield(N) restores starting balance
    // ---------------------------------------------------------------

    function test_RoundTrip() public {
        uint256 N = 12_345;
        _seedBalance(user, N);
        assertEq(wrapper.balanceOf(user), N);

        // Shield the whole balance across 2 commitments (split 5_000 / 7_345).
        uint256[] memory commitments = new uint256[](2);
        commitments[0] = uint256(keccak256("rt-c0"));
        commitments[1] = uint256(keccak256("rt-c1"));
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 5_000;
        amounts[1] = 7_345;
        zeto.setNextMintAmounts(amounts);
        vm.prank(user);
        wrapper.shield(commitments, amounts, "");

        assertEq(wrapper.balanceOf(user), 0, "all wrapped burnt");
        assertEq(zeto.privateValueSum(), N, "private side credited");

        // Unshield the whole amount back to user.
        _doUnshield(user, N);

        assertEq(wrapper.balanceOf(user), N, "wrapped restored");
        assertEq(zeto.privateValueSum(), 0, "private side empty");
        assertEq(wrapper.totalSupply(), N, "no stray supply");
    }

    // ---------------------------------------------------------------
    // Unauthorized mint/burn of the public ERC20
    // ---------------------------------------------------------------

    /// @dev WrappedZeto exposes no public mint() or burn() entry
    ///      point, so the only way for an external account to move
    ///      the ERC20 supply is via shield/unshield. shield burns
    ///      from the *caller* (cannot burn someone else's balance);
    ///      unshield mints to a chosen recipient but requires a Zeto
    ///      burn to first succeed -- which in practice requires a
    ///      valid Groth16 proof gating the private state transition.
    ///
    ///      Concretely, this test asserts:
    ///        (a) a non-shield/unshield mint/burn surface does not exist
    ///            (compile-time guarantee, witnessed by the absence of
    ///            ERC20Burnable / ERC20PresetMinterPauser inheritance);
    ///        (b) shield(amount=N) cannot move tokens belonging to a
    ///            third party -- it strictly drains the caller;
    ///        (c) unshield reverts if the Zeto.burn primitive reverts,
    ///            so no public supply can be conjured without the
    ///            paired private burn completing.
    function test_NonWrapperCannotMintOrBurn() public {
        // (b) shield by `otherUser` does NOT touch `user`'s balance.
        _seedBalance(user, 1_000);
        _seedBalance(otherUser, 500);

        uint256[] memory commitments = new uint256[](1);
        commitments[0] = uint256(keccak256("third-party"));
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 500;
        zeto.setNextMintAmounts(amounts);
        vm.prank(otherUser);
        wrapper.shield(commitments, amounts, "");

        assertEq(wrapper.balanceOf(user), 1_000, "user's balance untouched");
        assertEq(wrapper.balanceOf(otherUser), 0, "other's balance drained");

        // (c) unshield reverts if Zeto.burn reverts -- no ERC20 minted.
        zeto.setRevertNext(true);
        uint256 supplyBefore = wrapper.totalSupply();
        vm.expectRevert(bytes("MockZeto: forced revert"));
        _doUnshield(user, 100);
        assertEq(wrapper.totalSupply(), supplyBefore, "no supply on burn revert");
    }

    // ---------------------------------------------------------------
    // Mismatched shield amount fails
    // ---------------------------------------------------------------

    function test_ShieldRevertsOnLengthMismatch() public {
        _seedBalance(user, 1_000);

        uint256[] memory commitments = new uint256[](2);
        commitments[0] = uint256(keccak256("c0"));
        commitments[1] = uint256(keccak256("c1"));
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 500;

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(WrappedZeto.LengthMismatch.selector, 2, 1));
        wrapper.shield(commitments, amounts, "");
    }

    function test_ShieldRevertsOnZeroCommitment() public {
        _seedBalance(user, 1_000);

        uint256[] memory commitments = new uint256[](2);
        commitments[0] = uint256(keccak256("c0"));
        commitments[1] = 0;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100;
        amounts[1] = 200;

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(WrappedZeto.ZeroCommitment.selector, 1));
        wrapper.shield(commitments, amounts, "");
    }

    function test_ShieldRevertsOnZeroAmount() public {
        _seedBalance(user, 1_000);

        uint256[] memory commitments = new uint256[](2);
        commitments[0] = uint256(keccak256("c0"));
        commitments[1] = uint256(keccak256("c1"));
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100;
        amounts[1] = 0;

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(WrappedZeto.ZeroAmount.selector, 1));
        wrapper.shield(commitments, amounts, "");
    }

    function test_ShieldRevertsOnInsufficientBalance() public {
        _seedBalance(user, 100);

        uint256[] memory commitments = new uint256[](1);
        commitments[0] = uint256(keccak256("c0"));
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 500;
        zeto.setNextMintAmounts(amounts);

        vm.prank(user);
        vm.expectRevert(); // OZ ERC20InsufficientBalance
        wrapper.shield(commitments, amounts, "");
    }

    // ---------------------------------------------------------------
    // Unshield input validation
    // ---------------------------------------------------------------

    function test_UnshieldRevertsOnZeroRecipient() public {
        uint256[] memory inputs = new uint256[](1);
        inputs[0] = 1;
        vm.expectRevert(WrappedZeto.ZeroRecipient.selector);
        wrapper.unshield(inputs, 1, 1, dummyProof, address(0), 100, abi.encode(uint256(100)));
    }

    function test_UnshieldRevertsOnZeroAmount() public {
        uint256[] memory inputs = new uint256[](1);
        inputs[0] = 1;
        vm.expectRevert(WrappedZeto.ZeroUnshieldAmount.selector);
        wrapper.unshield(inputs, 1, 1, dummyProof, user, 0, abi.encode(uint256(0)));
    }

    // ---------------------------------------------------------------
    // seedAndShield (genesis hatch)
    // ---------------------------------------------------------------

    function test_SeedAndShield_HappyPath() public {
        uint256 commitment = uint256(keccak256("genesis")) | 1;
        uint256 amount = 1_000_000;

        // Pre-stage the mock so privateValueSum credits correctly.
        uint256[] memory amts = new uint256[](1);
        amts[0] = amount;
        zeto.setNextMintAmounts(amts);

        wrapper.seedAndShield(commitment, amount, "");

        // Public supply stays 0; private supply jumps to `amount`.
        assertEq(wrapper.totalSupply(), 0, "ERC20 supply must stay 0");
        assertEq(zeto.privateValueSum(), amount, "private supply == amount");
        assertEq(_totalValue(), amount, "conservation constant = amount after seed");
        assertEq(zeto.mintCalls(), 1, "exactly one Zeto.mint call");
    }

    function test_SeedAndShield_OnlyOwner() public {
        uint256[] memory amts = new uint256[](1);
        amts[0] = 100;
        zeto.setNextMintAmounts(amts);

        vm.prank(user);
        vm.expectRevert(); // OZ Ownable: OwnableUnauthorizedAccount(user)
        wrapper.seedAndShield(1, 100, "");
    }

    function test_SeedAndShield_RevertsOnZeroCommitment() public {
        vm.expectRevert(abi.encodeWithSelector(WrappedZeto.ZeroCommitment.selector, uint256(0)));
        wrapper.seedAndShield(0, 100, "");
    }

    function test_SeedAndShield_RevertsOnZeroAmount() public {
        vm.expectRevert(abi.encodeWithSelector(WrappedZeto.ZeroAmount.selector, uint256(0)));
        wrapper.seedAndShield(1, 0, "");
    }

    function test_SeedAndShield_ConservedAcrossSubsequentCycles() public {
        // Seed M directly into private supply.
        uint256 M = 5_000;
        uint256[] memory amts = new uint256[](1);
        amts[0] = M;
        zeto.setNextMintAmounts(amts);
        wrapper.seedAndShield(uint256(keccak256("g")) | 1, M, "");

        uint256 constantBefore = _totalValue();

        // Now run an unshield(N), then shield(N) round-trip. Conservation
        // constant must stay at M throughout.
        uint256 N = 1_500;
        _doUnshield(user, N);
        assertEq(_totalValue(), constantBefore, "constant invariant under unshield");

        _doShield(user, 42, 1);
        assertEq(_totalValue(), constantBefore, "constant invariant under shield");
    }
}
