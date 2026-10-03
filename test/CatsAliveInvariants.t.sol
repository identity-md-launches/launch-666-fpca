// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CatsAlive} from "src/CatsAlive.sol";

/// @dev The model records successful user instructions, never copies ownership or balances from the NFT.
contract CatsAliveSequenceHandler is Test {
    CatsAlive public immutable cats;
    address[5] public actors;
    uint256 public ghostSupply;
    mapping(uint256 => address) public ghostTokenOwner;
    mapping(address => uint256) public ghostBalance;
    mapping(uint256 => address) public ghostApproval;
    mapping(address => mapping(address => bool)) public ghostOperator;
    address public ghostOwner;
    address public ghostPendingOwner;
    address public ghostReporter;
    bool public ghostPaused;
    uint32 public ghostAlive;
    uint64 public ghostObservation;
    uint256 public ghostPublication;
    bytes32 public ghostEvidence;

    constructor(CatsAlive cats_) {
        cats = cats_;
        actors = [address(0xA11CE), address(0xB0B), address(0xCA7), address(0xD06), address(0xE11E)];
        ghostOwner = actors[0];
        ghostReporter = actors[1];
    }

    function mint(uint256 actorSeed) public {
        // This is a campaign resource bound, not a claimed collection supply cap.
        if (ghostSupply == 64) return;
        address recipient = _actor(actorSeed);
        vm.prank(recipient);
        (bool ok, bytes memory result) = address(cats).call(abi.encodeCall(CatsAlive.mint, ()));
        assertEq(ok, !ghostPaused, "mint liveness or pause authorization");
        if (ok) {
            ++ghostSupply;
            assertEq(abi.decode(result, (uint256)), ghostSupply, "mint IDs must have no gaps");
            ghostTokenOwner[ghostSupply] = recipient;
            ++ghostBalance[recipient];
        }
    }

    function mintWithPayment(uint256 actorSeed, uint256 valueSeed) external {
        address caller = _actor(actorSeed);
        uint256 value = bound(valueSeed, 1, 1 ether);
        vm.deal(caller, value);
        uint256 heldBefore = address(cats).balance;
        vm.prank(caller);
        (bool ok,) = address(cats).call{value: value}(abi.encodeCall(CatsAlive.mint, ()));
        assertFalse(ok, "free nonpayable mint must reject attached ETH");
        assertEq(caller.balance, value, "failed mint consumed payment");
        assertEq(address(cats).balance, heldBefore, "failed mint retained payment");
    }

    function transfer(uint256 tokenSeed, uint256 callerSeed, uint256 recipientSeed, bool safe, bool wrongFrom)
        external
    {
        uint256 id = bound(tokenSeed, 1, ghostSupply);
        address owner = ghostTokenOwner[id];
        address caller = callerSeed % 6 == 5 ? owner : _actor(callerSeed);
        address to = _actorOrZero(recipientSeed);
        address from = wrongFrom ? _differentActor(owner, callerSeed) : owner;
        bool authorized = caller == owner || ghostApproval[id] == caller || ghostOperator[owner][caller];
        bool expected = authorized && !wrongFrom && to != address(0);
        bytes memory payload = safe
            ? abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", from, to, id)
            : abi.encodeWithSignature("transferFrom(address,address,uint256)", from, to, id);
        vm.prank(caller);
        (bool ok,) = address(cats).call(payload);
        assertEq(ok, expected, "transfer must enforce ownership and approvals even after admin changes");
        if (ok) {
            --ghostBalance[owner];
            ++ghostBalance[to];
            ghostTokenOwner[id] = to;
            ghostApproval[id] = address(0);
        }
        assertEq(cats.ownerOf(id), ghostTokenOwner[id], "failed transfer changed owner");
        assertEq(cats.getApproved(id), ghostApproval[id], "transfer approval clear or rollback failed");
    }

    function approve(uint256 tokenSeed, uint256 callerSeed, uint256 approvedSeed) external {
        uint256 id = bound(tokenSeed, 1, ghostSupply);
        address owner = ghostTokenOwner[id];
        address caller = callerSeed % 6 == 5 ? owner : _actor(callerSeed);
        address approved = _actorOrZero(approvedSeed);
        vm.prank(caller);
        (bool ok,) = address(cats).call(abi.encodeWithSignature("approve(address,uint256)", approved, id));
        assertEq(ok, caller == owner || ghostOperator[owner][caller], "approval authorization");
        if (ok) ghostApproval[id] = approved;
    }

    function setOperator(uint256 ownerSeed, uint256 operatorSeed, bool enabled) external {
        address owner = _actor(ownerSeed);
        address operator = _actorOrZero(operatorSeed);
        vm.prank(owner);
        (bool ok,) = address(cats).call(abi.encodeWithSignature("setApprovalForAll(address,bool)", operator, enabled));
        assertEq(ok, operator != address(0), "operator validation");
        if (ok) ghostOperator[owner][operator] = enabled;
    }

    function setPause(uint256 callerSeed, bool pauseRequested) external {
        address caller = _adminCaller(callerSeed);
        bytes memory payload =
            pauseRequested ? abi.encodeCall(CatsAlive.pause, ()) : abi.encodeCall(CatsAlive.unpause, ());
        vm.prank(caller);
        (bool ok,) = address(cats).call(payload);
        assertEq(ok, caller == ghostOwner && pauseRequested != ghostPaused, "pause transition authorization");
        if (ok) ghostPaused = pauseRequested;
    }

    function rotateReporter(uint256 callerSeed, uint256 reporterSeed) external {
        address caller = _adminCaller(callerSeed);
        address next = _actorOrZero(reporterSeed);
        vm.prank(caller);
        (bool ok,) = address(cats).call(abi.encodeCall(CatsAlive.setReporter, (next)));
        assertEq(ok, caller == ghostOwner && next != address(0), "reporter rotation authorization");
        if (ok) ghostReporter = next;
    }

    function nominateOwner(uint256 callerSeed, uint256 nomineeSeed) external {
        address caller = _adminCaller(callerSeed);
        address nominee = _actorOrZero(nomineeSeed);
        vm.prank(caller);
        (bool ok,) = address(cats).call(abi.encodeWithSignature("transferOwnership(address)", nominee));
        assertEq(ok, caller == ghostOwner, "owner nomination authorization");
        if (ok) ghostPendingOwner = nominee;
    }

    function acceptOwner(uint256 callerSeed) external {
        address caller = callerSeed % 2 == 0 && ghostPendingOwner != address(0) ? ghostPendingOwner : _actor(callerSeed);
        vm.prank(caller);
        (bool ok,) = address(cats).call(abi.encodeWithSignature("acceptOwnership()"));
        assertEq(ok, caller == ghostPendingOwner, "only the current nominee can accept ownership");
        if (ok) {
            ghostOwner = caller;
            ghostPendingOwner = address(0);
        }
    }

    function rejectRenunciation(uint256 callerSeed) external {
        vm.prank(_adminCaller(callerSeed));
        (bool ok,) = address(cats).call(abi.encodeCall(CatsAlive.renounceOwnership, ()));
        assertFalse(ok, "administration cannot be renounced");
    }

    function publish(uint256 aliveSeed, uint256 evidenceSeed) external {
        vm.warp(vm.getBlockTimestamp() + 1);
        uint32 count = uint32(bound(aliveSeed, 0, cats.originalCats()));
        bytes32 evidence = bytes32(bound(evidenceSeed, 1, type(uint256).max));
        uint64 observation = uint64(vm.getBlockTimestamp());
        vm.prank(ghostReporter);
        cats.publishCount(count, observation, evidence);
        ghostAlive = count;
        ghostObservation = observation;
        ghostPublication = vm.getBlockTimestamp();
        ghostEvidence = evidence;
    }

    function rejectReport(uint256 faultSeed, uint256 actorSeed) external {
        vm.warp(vm.getBlockTimestamp() + 1);
        uint32 count = 0;
        uint64 observation = uint64(vm.getBlockTimestamp());
        bytes32 evidence = bytes32(uint256(1));
        address caller = ghostReporter;
        uint256 fault = faultSeed % 6;
        if (fault == 0) observation = ghostObservation; // replay, or zero before the first report
        else if (fault == 1) observation += 1; // future observation
        else if (fault == 2) observation -= cats.maxReportAge() + 1; // just too old
        else if (fault == 3) count = cats.originalCats() + 1;
        else if (fault == 4) evidence = bytes32(0);
        else caller = _differentActor(ghostReporter, actorSeed);
        vm.prank(caller);
        (bool ok,) = address(cats).call(abi.encodeCall(CatsAlive.publishCount, (count, observation, evidence)));
        assertFalse(ok, "invalid report or former/unauthorized reporter accepted");
    }

    function advanceClock(uint256 elapsedSeed) external {
        vm.warp(vm.getBlockTimestamp() + bound(elapsedSeed, 0, 2 hours));
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[seed % actors.length];
    }

    function _actorOrZero(uint256 seed) private view returns (address) {
        uint256 index = seed % (actors.length + 1);
        return index == actors.length ? address(0) : actors[index];
    }

    function _differentActor(address excluded, uint256 seed) private view returns (address) {
        uint256 index = seed % actors.length;
        return actors[index] == excluded ? actors[(index + 1) % actors.length] : actors[index];
    }

    function _adminCaller(uint256 seed) private view returns (address) {
        return seed % 2 == 0 ? ghostOwner : _actor(seed / 2);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract CatsAliveInvariantsTest is Test {
    CatsAlive private cats;
    CatsAliveSequenceHandler private handler;

    function setUp() public {
        vm.warp(1_800_000_000);
        cats = new CatsAlive(address(0xA11CE), address(0xB0B), 3, 1_700_000_000, 3600);
        handler = new CatsAliveSequenceHandler(cats);
        // Ensure transfer/approval selectors always have live tokens, and the NFT supply already
        // exceeds the original game cohort before any randomized sequence begins.
        for (uint256 i; i < 4; ++i) {
            handler.mint(i);
        }

        bytes4[] memory selectors = new bytes4[](13);
        selectors[0] = handler.mint.selector;
        selectors[1] = handler.mintWithPayment.selector;
        selectors[2] = handler.transfer.selector;
        selectors[3] = handler.approve.selector;
        selectors[4] = handler.setOperator.selector;
        selectors[5] = handler.setPause.selector;
        selectors[6] = handler.rotateReporter.selector;
        selectors[7] = handler.nominateOwner.selector;
        selectors[8] = handler.acceptOwner.selector;
        selectors[9] = handler.rejectRenunciation.selector;
        selectors[10] = handler.publish.selector;
        selectors[11] = handler.rejectReport.selector;
        selectors[12] = handler.advanceClock.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_successfulMintsAreTheEntireSupplyAndTransfersConserveIt() public view {
        uint256 minted = handler.ghostSupply();
        assertEq(cats.totalSupply(), minted, "only successful mints may change supply");
        uint256 balances;
        for (uint256 i; i < 5; ++i) {
            address actor = handler.actors(i);
            uint256 owned;
            for (uint256 id = 1; id <= minted; ++id) {
                if (cats.ownerOf(id) == actor) ++owned;
            }
            assertEq(cats.balanceOf(actor), handler.ghostBalance(actor), "balance differs from action ledger");
            assertEq(cats.balanceOf(actor), owned, "balance differs from token ownership");
            balances += owned;
            for (uint256 j; j < 5; ++j) {
                address operator = handler.actors(j);
                assertEq(cats.isApprovedForAll(actor, operator), handler.ghostOperator(actor, operator));
            }
        }
        assertEq(balances, minted, "tokens escaped the complete actor inventory");
        for (uint256 id = 1; id <= minted; ++id) {
            assertEq(cats.ownerOf(id), handler.ghostTokenOwner(id), "unauthorized transfer or missing mint");
            assertEq(cats.getApproved(id), handler.ghostApproval(id), "stale approval after transfer or revocation");
        }
    }

    function invariant_adminAndSnapshotStateMatchOnlyAcceptedActions() public view {
        assertEq(cats.owner(), handler.ghostOwner());
        assertNotEq(cats.owner(), address(0));
        assertEq(cats.pendingOwner(), handler.ghostPendingOwner());
        assertEq(cats.reporter(), handler.ghostReporter());
        assertEq(cats.paused(), handler.ghostPaused());
        assertEq(cats.aliveCats(), handler.ghostAlive());
        assertEq(cats.observedAt(), handler.ghostObservation());
        assertEq(cats.reportedAt(), handler.ghostPublication());
        assertEq(cats.sourceHash(), handler.ghostEvidence());
        assertLe(cats.aliveCats(), cats.originalCats());
        uint256 observation = handler.ghostObservation();
        if (observation == 0) {
            assertTrue(cats.isStale());
            assertEq(cats.reportStatus(), "unreported");
        } else {
            assertLe(observation, vm.getBlockTimestamp());
            bool expired = vm.getBlockTimestamp() - observation > cats.maxReportAge();
            assertEq(cats.isStale(), expired);
            assertEq(cats.reportStatus(), expired ? "stale" : "fresh");
        }
    }
}
