// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CatsAlive} from "src/CatsAlive.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @dev Exercises effects performed by a receiver before it accepts or rejects the token.
contract CatsCallbackProbe is IERC721Receiver {
    enum Action {
        Accept,
        Forward,
        ForwardThenReject,
        ReenterMint,
        PublishThenReject
    }

    error RejectedAfterEffects();

    CatsAlive public immutable cats;
    Action public action;
    address public destination;
    address public operatorSeen;
    address public fromSeen;
    uint256 public idSeen;
    uint256 public supplySeen;
    address public ownerSeen;
    bytes public dataSeen;

    constructor(CatsAlive cats_) {
        cats = cats_;
    }

    function configure(Action next, address to) external {
        action = next;
        destination = to;
    }

    function mint() external returns (uint256) {
        return cats.mint();
    }

    function onERC721Received(address operator, address from, uint256 id, bytes calldata data)
        external
        returns (bytes4)
    {
        require(msg.sender == address(cats), "unexpected collection");
        operatorSeen = operator;
        fromSeen = from;
        idSeen = id;
        dataSeen = data;
        supplySeen = cats.totalSupply();
        ownerSeen = cats.ownerOf(id);
        if (action == Action.Forward || action == Action.ForwardThenReject) {
            cats.transferFrom(address(this), destination, id);
        }
        if (action == Action.ReenterMint) cats.mint();
        if (action == Action.PublishThenReject) {
            cats.publishCount(0, uint64(block.timestamp), keccak256("receiver report"));
        }
        if (action == Action.ForwardThenReject || action == Action.PublishThenReject) {
            revert RejectedAfterEffects();
        }
        return IERC721Receiver.onERC721Received.selector;
    }
}

contract CatsAliveAdversarialTest is Test {
    CatsAlive internal cats;
    CatsCallbackProbe internal receiver;
    address internal constant ADMIN = address(0xA11CE);
    address internal constant REPORTER = address(0xBEEF);
    address internal constant HOLDER = address(0xCA7);
    address internal constant OPERATOR = address(0xD06);
    address internal constant RECIPIENT = address(0xF00D);
    uint64 internal constant ORIGINAL_DATE = 1_700_000_000;
    uint32 internal constant POPULATION = 1000;
    uint32 internal constant MAX_AGE = 3600;
    bytes32 internal constant EVIDENCE = keccak256("first observation");

    function setUp() public {
        vm.warp(1_800_000_000);
        cats = new CatsAlive(ADMIN, REPORTER, POPULATION, ORIGINAL_DATE, MAX_AGE);
        receiver = new CatsCallbackProbe(cats);
    }

    function test_mintCallbackCanForwardSettledTokenWithoutChangingSupply() public {
        receiver.configure(CatsCallbackProbe.Action.Forward, RECIPIENT);
        assertEq(receiver.mint(), 1);
        assertEq(receiver.operatorSeen(), address(receiver));
        assertEq(receiver.fromSeen(), address(0));
        assertEq(receiver.idSeen(), 1);
        assertEq(receiver.ownerSeen(), address(receiver));
        assertEq(receiver.supplySeen(), 1);
        assertEq(receiver.dataSeen(), bytes(""));
        assertEq(cats.ownerOf(1), RECIPIENT);
        assertEq(cats.balanceOf(address(receiver)), 0);
        assertEq(cats.balanceOf(RECIPIENT), 1);
        assertEq(cats.totalSupply(), 1);
    }

    function test_rejectedMintRollsBackNestedTransferAndReusesUnissuedId() public {
        receiver.configure(CatsCallbackProbe.Action.ForwardThenReject, RECIPIENT);
        vm.expectRevert(CatsCallbackProbe.RejectedAfterEffects.selector);
        receiver.mint();
        assertEq(cats.totalSupply(), 0);
        assertEq(cats.balanceOf(RECIPIENT), 0);
        assertEq(cats.balanceOf(address(receiver)), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 1));
        cats.ownerOf(1);
        vm.prank(HOLDER);
        assertEq(cats.mint(), 1);
        assertEq(cats.ownerOf(1), HOLDER);
    }

    function test_uncaughtMintReentryRollsBackOuterMintAndGuardRecovers() public {
        receiver.configure(CatsCallbackProbe.Action.ReenterMint, RECIPIENT);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        receiver.mint();
        assertEq(cats.totalSupply(), 0);
        assertEq(cats.balanceOf(address(receiver)), 0);
        receiver.configure(CatsCallbackProbe.Action.Accept, RECIPIENT);
        assertEq(receiver.mint(), 1);
        assertEq(cats.ownerOf(1), address(receiver));
    }

    function test_rejectedMintRollsBackReportPublishedInsideReceiver() public {
        _publish(17, uint64(vm.getBlockTimestamp() - 1), EVIDENCE);
        vm.prank(ADMIN);
        cats.setReporter(address(receiver));
        bytes32 beforeState = _snapshot();
        receiver.configure(CatsCallbackProbe.Action.PublishThenReject, RECIPIENT);
        vm.expectRevert(CatsCallbackProbe.RejectedAfterEffects.selector);
        receiver.mint();
        assertEq(_snapshot(), beforeState, "outer rejection must undo the nested report too");
        assertEq(cats.totalSupply(), 0);
    }

    function test_rejectedSafeTransferRestoresApprovalAfterNestedForward() public {
        _mintAndApprove();
        receiver.configure(CatsCallbackProbe.Action.ForwardThenReject, RECIPIENT);
        vm.prank(OPERATOR);
        vm.expectRevert(CatsCallbackProbe.RejectedAfterEffects.selector);
        cats.safeTransferFrom(HOLDER, address(receiver), 1, hex"1234");
        assertEq(cats.ownerOf(1), HOLDER);
        assertEq(cats.getApproved(1), OPERATOR);
        assertEq(cats.balanceOf(HOLDER), 1);
        assertEq(cats.balanceOf(address(receiver)), 0);
        assertEq(cats.balanceOf(RECIPIENT), 0);
        assertEq(cats.totalSupply(), 1);
        vm.prank(OPERATOR);
        cats.transferFrom(HOLDER, RECIPIENT, 1);
        assertEq(cats.ownerOf(1), RECIPIENT);
        assertEq(cats.getApproved(1), address(0));
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_safeTransferDeliversOperatorFromAndOpaqueData(bytes32 payload, bool forward) public {
        _mintAndApprove();
        receiver.configure(forward ? CatsCallbackProbe.Action.Forward : CatsCallbackProbe.Action.Accept, RECIPIENT);
        bytes memory data = abi.encode(payload, uint256(1));
        vm.prank(OPERATOR);
        cats.safeTransferFrom(HOLDER, address(receiver), 1, data);
        assertEq(receiver.operatorSeen(), OPERATOR);
        assertEq(receiver.fromSeen(), HOLDER);
        assertEq(receiver.idSeen(), 1);
        assertEq(receiver.dataSeen(), data);
        assertEq(receiver.ownerSeen(), address(receiver));
        assertEq(receiver.supplySeen(), 1);
        assertEq(cats.ownerOf(1), forward ? RECIPIENT : address(receiver));
        assertEq(cats.balanceOf(HOLDER), 0);
        assertEq(cats.totalSupply(), 1);
        assertEq(cats.getApproved(1), address(0));
    }

    function test_selfTransferClearsApprovalAndOldDelegateCannotMoveToken() public {
        _mintAndApprove();
        vm.prank(OPERATOR);
        cats.transferFrom(HOLDER, HOLDER, 1);
        assertEq(cats.ownerOf(1), HOLDER);
        assertEq(cats.balanceOf(HOLDER), 1);
        assertEq(cats.totalSupply(), 1);
        assertEq(cats.getApproved(1), address(0));
        vm.prank(OPERATOR);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, OPERATOR, 1));
        cats.transferFrom(HOLDER, RECIPIENT, 1);
    }

    function test_transferRoundTripDoesNotResurrectTokenApproval() public {
        _mintAndApprove();
        vm.prank(HOLDER);
        cats.transferFrom(HOLDER, RECIPIENT, 1);
        vm.prank(RECIPIENT);
        cats.transferFrom(RECIPIENT, HOLDER, 1);
        assertEq(cats.balanceOf(HOLDER), 1);
        assertEq(cats.balanceOf(RECIPIENT), 0);
        assertEq(cats.getApproved(1), address(0));
        vm.prank(OPERATOR);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, OPERATOR, 1));
        cats.transferFrom(HOLDER, OPERATOR, 1);
    }

    function test_cancelledAndSupersededPendingOwnersCannotAcceptOrAdminister() public {
        vm.startPrank(ADMIN);
        cats.transferOwnership(HOLDER);
        cats.transferOwnership(address(0));
        vm.stopPrank();
        _assertCannotAccept(HOLDER);
        vm.startPrank(ADMIN);
        cats.transferOwnership(HOLDER);
        cats.transferOwnership(RECIPIENT);
        vm.stopPrank();
        _assertCannotAccept(HOLDER);
        vm.prank(RECIPIENT);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, RECIPIENT));
        cats.setReporter(RECIPIENT);
        vm.prank(RECIPIENT);
        cats.acceptOwnership();
        assertEq(cats.owner(), RECIPIENT);
        assertEq(cats.pendingOwner(), address(0));
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ADMIN));
        cats.setReporter(ADMIN);
        assertEq(cats.reporter(), REPORTER);
    }

    function test_handoverWhilePausedPreservesPauseAndNewOwnerCanResume() public {
        vm.startPrank(ADMIN);
        cats.pause();
        cats.transferOwnership(RECIPIENT);
        vm.stopPrank();
        vm.prank(RECIPIENT);
        cats.acceptOwnership();
        assertTrue(cats.paused());
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ADMIN));
        cats.unpause();
        vm.prank(RECIPIENT);
        cats.unpause();
        vm.prank(HOLDER);
        assertEq(cats.mint(), 1);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_invalidReportCannotPartiallyOverwriteSnapshot(uint8 kind, uint32 seed) public {
        _publish(19, uint64(vm.getBlockTimestamp() - 10), EVIDENCE);
        uint32 count = uint32(bound(seed, 0, POPULATION));
        uint64 when = uint64(vm.getBlockTimestamp());
        bytes32 hash = keccak256("replacement");
        uint256 branch = bound(kind, 0, 7);
        if (branch == 0) count = uint32(bound(seed, POPULATION + 1, type(uint32).max));
        if (branch == 1) when = uint64(vm.getBlockTimestamp() + bound(seed, 1, type(uint32).max));
        if (branch == 2) {
            vm.warp(vm.getBlockTimestamp() + MAX_AGE + 1);
            // Newer than the saved report but exactly one second too old.
        }
        if (branch == 3) when = cats.observedAt();
        if (branch == 4) when = cats.observedAt() - 1;
        if (branch == 5) when = ORIGINAL_DATE - 1;
        if (branch == 6) hash = bytes32(0);
        if (branch == 7) when = type(uint64).max;
        bytes32 beforeState = _snapshot();
        vm.prank(REPORTER);
        vm.expectRevert(CatsAlive.InvalidReport.selector);
        cats.publishCount(count, when, hash);
        assertEq(_snapshot(), beforeState);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_freshnessExpiresExactlyAfterConfiguredAge(uint32 ageSeed, uint32 countSeed) public {
        uint32 age = uint32(bound(ageSeed, 60, 7 days));
        CatsAlive other = new CatsAlive(ADMIN, REPORTER, POPULATION, ORIGINAL_DATE, age);
        uint32 count = uint32(bound(countSeed, 0, POPULATION));
        uint64 observation = uint64(vm.getBlockTimestamp());
        vm.prank(REPORTER);
        other.publishCount(count, observation, EVIDENCE);
        vm.warp(uint256(observation) + age);
        assertFalse(other.isStale());
        vm.warp(uint256(observation) + age + 1);
        assertTrue(other.isStale());
        assertEq(other.reportStatus(), "stale");
        assertEq(other.aliveCats(), count, "expiry must not replace a known count with zero");
        assertEq(other.observedAt(), observation);
        assertEq(other.reportedAt(), observation);
        assertEq(other.sourceHash(), EVIDENCE);
    }

    function test_rotatingReporterCannotResetTimestampOrOverwriteWithReplay() public {
        _publish(31, uint64(vm.getBlockTimestamp()), EVIDENCE);
        bytes32 beforeState = _snapshot();
        vm.prank(ADMIN);
        cats.setReporter(RECIPIENT);
        vm.prank(RECIPIENT);
        vm.expectRevert(CatsAlive.InvalidReport.selector);
        cats.publishCount(0, uint64(vm.getBlockTimestamp()), keccak256("same observation"));
        assertEq(_snapshot(), beforeState);
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(REPORTER);
        vm.expectRevert(CatsAlive.UnauthorizedReporter.selector);
        cats.publishCount(0, uint64(vm.getBlockTimestamp()), EVIDENCE);
        vm.prank(RECIPIENT);
        cats.publishCount(30, uint64(vm.getBlockTimestamp()), keccak256("next observation"));
        assertEq(cats.aliveCats(), 30);
    }

    function test_unreportedZeroAndMaximumIntegersAreRejectedWithoutPanic() public {
        vm.startPrank(REPORTER);
        vm.expectRevert(CatsAlive.InvalidReport.selector);
        cats.publishCount(0, 0, EVIDENCE);
        vm.expectRevert(CatsAlive.InvalidReport.selector);
        cats.publishCount(type(uint32).max, uint64(vm.getBlockTimestamp()), EVIDENCE);
        vm.expectRevert(CatsAlive.InvalidReport.selector);
        cats.publishCount(1, type(uint64).max, EVIDENCE);
        vm.stopPrank();
        assertEq(cats.reportStatus(), "unreported");
        assertEq(cats.observedAt(), 0);
        assertEq(cats.sourceHash(), bytes32(0));
    }

    function _mintAndApprove() internal {
        vm.startPrank(HOLDER);
        cats.mint();
        cats.approve(OPERATOR, 1);
        vm.stopPrank();
    }

    function _assertCannotAccept(address account) internal {
        vm.prank(account);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, account));
        cats.acceptOwnership();
        assertEq(cats.owner(), ADMIN);
    }

    function _publish(uint32 count, uint64 when, bytes32 hash) internal {
        vm.prank(REPORTER);
        cats.publishCount(count, when, hash);
    }

    function _snapshot() internal view returns (bytes32) {
        return keccak256(abi.encode(cats.aliveCats(), cats.observedAt(), cats.reportedAt(), cats.sourceHash()));
    }
}
