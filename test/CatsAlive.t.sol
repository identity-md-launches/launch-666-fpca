// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {CatsAlive} from "../src/CatsAlive.sol";

contract CatsAliveFactoryFixture {
    function deploy(address owner, address reporter, uint32 originalCats, uint64 originalTimestamp, uint32 maxAge)
        external
        returns (CatsAlive)
    {
        return new CatsAlive(owner, reporter, originalCats, originalTimestamp, maxAge);
    }
}

contract NonReceiver {
    function mint(CatsAlive cats) external {
        cats.mint();
    }
}

contract RejectingReceiver is IERC721Receiver {
    function mint(CatsAlive cats) external {
        cats.mint();
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return bytes4(0);
    }
}

contract ReenteringReceiver is IERC721Receiver {
    CatsAlive public immutable cats;
    bool public reentrySucceeded;
    uint256 public supplySeen;
    address public ownerSeen;

    constructor(CatsAlive cats_) {
        cats = cats_;
    }

    function mint() external {
        cats.mint();
    }

    function onERC721Received(address, address, uint256 tokenId, bytes calldata) external returns (bytes4) {
        require(msg.sender == address(cats));
        supplySeen = cats.totalSupply();
        ownerSeen = cats.ownerOf(tokenId);
        (reentrySucceeded,) = address(cats).call(abi.encodeCall(CatsAlive.mint, ()));
        return IERC721Receiver.onERC721Received.selector;
    }
}

contract CatsAliveTest is Test {
    event BatchMetadataUpdate(uint256 fromTokenId, uint256 toTokenId);

    CatsAlive internal cats;
    address internal constant OWNER = address(0xA11CE);
    address internal constant REPORTER = address(0xB0B);
    address internal constant ALICE = address(0xCA7);
    address internal constant BOB = address(0xD06);
    uint32 internal constant ORIGINAL_CATS = 1000;
    uint64 internal constant ORIGINAL_TIMESTAMP = 1_700_000_000;
    uint32 internal constant MAX_AGE = 3600;
    bytes32 internal constant SOURCE_HASH = keccak256("complete API snapshot fixture");

    function setUp() public {
        vm.warp(1_800_000_000);
        cats = new CatsAlive(OWNER, REPORTER, ORIGINAL_CATS, ORIGINAL_TIMESTAMP, MAX_AGE);
    }

    function test_initialStateHasNoSupplyAndNoInventedCount() public view {
        assertEq(cats.name(), "FPCA");
        assertEq(cats.symbol(), "FPCA");
        assertEq(cats.totalSupply(), 0);
        assertEq(cats.owner(), OWNER);
        assertEq(cats.reporter(), REPORTER);
        assertEq(cats.originalCats(), ORIGINAL_CATS);
        assertEq(cats.originalMintTimestamp(), ORIGINAL_TIMESTAMP);
        assertEq(cats.maxReportAge(), MAX_AGE);
        assertEq(cats.observedAt(), 0);
        assertEq(cats.reportedAt(), 0);
        assertEq(cats.sourceHash(), bytes32(0));
        assertTrue(cats.isStale());
        assertEq(cats.reportStatus(), "unreported");
        assertFalse(cats.paused());
    }

    function test_constructorRejectsInvalidConfiguration() public {
        vm.expectRevert();
        new CatsAlive(address(0), REPORTER, ORIGINAL_CATS, ORIGINAL_TIMESTAMP, MAX_AGE);
        vm.expectRevert();
        new CatsAlive(OWNER, address(0), ORIGINAL_CATS, ORIGINAL_TIMESTAMP, MAX_AGE);
        vm.expectRevert();
        new CatsAlive(OWNER, REPORTER, 0, ORIGINAL_TIMESTAMP, MAX_AGE);
        vm.expectRevert();
        new CatsAlive(OWNER, REPORTER, 100_001, ORIGINAL_TIMESTAMP, MAX_AGE);
        vm.expectRevert();
        new CatsAlive(OWNER, REPORTER, ORIGINAL_CATS, 0, MAX_AGE);
        vm.expectRevert();
        new CatsAlive(OWNER, REPORTER, ORIGINAL_CATS, uint64(block.timestamp + 1), MAX_AGE);
        vm.expectRevert();
        new CatsAlive(OWNER, REPORTER, ORIGINAL_CATS, ORIGINAL_TIMESTAMP, 59);
        vm.expectRevert();
        new CatsAlive(OWNER, REPORTER, ORIGINAL_CATS, ORIGINAL_TIMESTAMP, uint32(7 days + 1));
        vm.warp(4_102_444_800);
        vm.expectRevert();
        new CatsAlive(OWNER, REPORTER, ORIGINAL_CATS, 4_102_444_800, MAX_AGE);
    }

    function test_constructorAcceptsDocumentedBoundaryValues() public {
        CatsAlive minimum = new CatsAlive(OWNER, REPORTER, 1, uint64(block.timestamp), 60);
        CatsAlive maximum = new CatsAlive(OWNER, REPORTER, 100_000, ORIGINAL_TIMESTAMP, uint32(7 days));
        assertEq(minimum.originalCats(), 1);
        assertEq(minimum.maxReportAge(), 60);
        assertEq(maximum.originalCats(), 100_000);
        assertEq(maximum.maxReportAge(), 7 days);
    }

    function test_factoryDeploymentAssignsExplicitOwner() public {
        CatsAliveFactoryFixture factory = new CatsAliveFactoryFixture();
        CatsAlive deployed = factory.deploy(OWNER, REPORTER, ORIGINAL_CATS, ORIGINAL_TIMESTAMP, MAX_AGE);
        assertEq(deployed.owner(), OWNER);
        assertNotEq(deployed.owner(), address(factory));
        assertEq(deployed.reporter(), REPORTER);
        assertEq(deployed.totalSupply(), 0);
        vm.prank(OWNER);
        deployed.pause();
        assertTrue(deployed.paused());
    }

    function test_runtimeFitsDeploymentPolicyAndHasNoEscapeOpcodes() public view {
        bytes memory code = address(cats).code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        assertLe(type(CatsAlive).creationCode.length + 32 * 5, 49_152);
        for (uint256 i; i < code.length; ++i) {
            uint8 opcode = uint8(code[i]);
            if (opcode >= 0x60 && opcode <= 0x7f) {
                i += opcode - 0x5f;
                continue;
            }
            assertTrue(opcode != 0xf4 && opcode != 0xf2 && opcode != 0xff, "forbidden runtime opcode");
        }
    }

    function test_directFreeMintUsesSequentialNumbers() public {
        _mint(ALICE);
        _mint(BOB);
        _mint(ALICE);
        assertEq(cats.totalSupply(), 3);
        assertEq(cats.ownerOf(1), ALICE);
        assertEq(cats.ownerOf(2), BOB);
        assertEq(cats.ownerOf(3), ALICE);
        assertEq(cats.balanceOf(ALICE), 2);
        assertEq(cats.balanceOf(BOB), 1);
        assertEq(address(cats).balance, 0);
    }

    function test_unlimitedMintIsIndependentOfOriginalGameCatCount() public {
        CatsAlive smallOriginal = new CatsAlive(OWNER, REPORTER, 1, ORIGINAL_TIMESTAMP, MAX_AGE);
        vm.startPrank(ALICE);
        for (uint256 i; i < 20; ++i) {
            smallOriginal.mint();
        }
        vm.stopPrank();
        assertEq(smallOriginal.totalSupply(), 20);
        assertEq(smallOriginal.balanceOf(ALICE), 20);
        assertEq(smallOriginal.ownerOf(20), ALICE);
    }

    function testFuzz_repeatMintHasNoPerWalletLimit(uint8 requested) public {
        uint256 amount = bound(requested, 1, 40);
        vm.startPrank(ALICE);
        for (uint256 i; i < amount; ++i) {
            cats.mint();
        }
        vm.stopPrank();
        assertEq(cats.totalSupply(), amount);
        assertEq(cats.balanceOf(ALICE), amount);
        assertEq(cats.ownerOf(amount), ALICE);
    }

    function test_nonpayableMintRejectsPaymentWithoutMinting() public {
        vm.deal(ALICE, 1 ether);
        vm.prank(ALICE);
        (bool success,) = address(cats).call{value: 1}(abi.encodeCall(CatsAlive.mint, ()));
        assertFalse(success);
        assertEq(cats.totalSupply(), 0);
        assertEq(address(cats).balance, 0);
        assertEq(ALICE.balance, 1 ether);
    }

    function test_unsafeAndRejectingReceiverMintRollBackSupply() public {
        NonReceiver unsafeReceiver = new NonReceiver();
        RejectingReceiver rejectingReceiver = new RejectingReceiver();
        vm.expectRevert();
        unsafeReceiver.mint(cats);
        vm.expectRevert();
        rejectingReceiver.mint(cats);
        assertEq(cats.totalSupply(), 0);
        assertEq(cats.balanceOf(address(unsafeReceiver)), 0);
        assertEq(cats.balanceOf(address(rejectingReceiver)), 0);
        _mint(ALICE);
        assertEq(cats.ownerOf(1), ALICE);
    }

    function test_receiverReentryIsBlockedAndOuterMintSucceeds() public {
        ReenteringReceiver receiver = new ReenteringReceiver(cats);
        receiver.mint();
        assertFalse(receiver.reentrySucceeded());
        assertEq(receiver.supplySeen(), 1);
        assertEq(receiver.ownerSeen(), address(receiver));
        assertEq(cats.totalSupply(), 1);
        assertEq(cats.balanceOf(address(receiver)), 1);
        receiver.mint();
        assertEq(cats.totalSupply(), 2);
    }

    function test_pauseOnlyStopsMintAndDoesNotFreezeTransfersOrReports() public {
        _mint(ALICE);
        vm.prank(OWNER);
        cats.pause();
        vm.prank(BOB);
        vm.expectRevert();
        cats.mint();
        vm.prank(ALICE);
        cats.approve(BOB, 1);
        vm.prank(BOB);
        cats.transferFrom(ALICE, BOB, 1);
        assertEq(cats.ownerOf(1), BOB);
        _publish(20, uint64(block.timestamp));
        assertEq(cats.aliveCats(), 20);
        vm.prank(OWNER);
        cats.unpause();
        _mint(ALICE);
        assertEq(cats.totalSupply(), 2);
    }

    function test_onlyOwnerCanPauseUnpauseAndRotateReporter() public {
        vm.startPrank(ALICE);
        vm.expectRevert();
        cats.pause();
        vm.expectRevert();
        cats.unpause();
        vm.expectRevert();
        cats.setReporter(ALICE);
        vm.expectRevert();
        cats.transferOwnership(ALICE);
        vm.stopPrank();
        vm.prank(OWNER);
        vm.expectRevert();
        cats.setReporter(address(0));
        assertEq(cats.reporter(), REPORTER);
    }

    function test_pauseAndUnpauseRejectInvalidTransitions() public {
        vm.startPrank(OWNER);
        vm.expectRevert();
        cats.unpause();
        cats.pause();
        vm.expectRevert();
        cats.pause();
        cats.unpause();
        vm.stopPrank();
    }

    function test_ownershipRequiresAcceptanceAndCannotBeRenounced() public {
        vm.prank(OWNER);
        cats.transferOwnership(ALICE);
        assertEq(cats.owner(), OWNER);
        assertEq(cats.pendingOwner(), ALICE);
        vm.prank(BOB);
        vm.expectRevert();
        cats.acceptOwnership();
        vm.prank(ALICE);
        cats.acceptOwnership();
        assertEq(cats.owner(), ALICE);
        assertEq(cats.pendingOwner(), address(0));
        vm.prank(OWNER);
        vm.expectRevert();
        cats.pause();
        vm.startPrank(ALICE);
        cats.pause();
        vm.expectRevert();
        cats.renounceOwnership();
        vm.stopPrank();
        assertEq(cats.owner(), ALICE);
    }

    function test_transfersRequireAuthorityAndClearApproval() public {
        _mint(ALICE);
        vm.prank(BOB);
        vm.expectRevert();
        cats.transferFrom(ALICE, BOB, 1);
        vm.prank(ALICE);
        cats.approve(BOB, 1);
        assertEq(cats.getApproved(1), BOB);
        vm.prank(BOB);
        cats.transferFrom(ALICE, BOB, 1);
        assertEq(cats.ownerOf(1), BOB);
        assertEq(cats.getApproved(1), address(0));
        assertEq(cats.balanceOf(ALICE), 0);
        assertEq(cats.balanceOf(BOB), 1);
        assertEq(cats.totalSupply(), 1);
        assertEq(address(cats).balance, 0);
    }

    function test_operatorCanTransferAndCanBeRevoked() public {
        _mint(ALICE);
        _mint(ALICE);
        vm.prank(ALICE);
        cats.setApprovalForAll(BOB, true);
        vm.prank(BOB);
        cats.safeTransferFrom(ALICE, BOB, 1);
        vm.prank(ALICE);
        cats.setApprovalForAll(BOB, false);
        vm.prank(BOB);
        vm.expectRevert();
        cats.transferFrom(ALICE, BOB, 2);
        assertEq(cats.ownerOf(2), ALICE);
    }

    function test_invalidTransferAndUnsafeRecipientLeaveOwnershipIntact() public {
        _mint(ALICE);
        RejectingReceiver rejectingReceiver = new RejectingReceiver();
        vm.startPrank(ALICE);
        vm.expectRevert();
        cats.transferFrom(ALICE, address(0), 1);
        vm.expectRevert();
        cats.transferFrom(BOB, BOB, 1);
        vm.expectRevert();
        cats.safeTransferFrom(ALICE, address(rejectingReceiver), 1);
        vm.stopPrank();
        assertEq(cats.ownerOf(1), ALICE);
        assertEq(cats.balanceOf(ALICE), 1);
        assertEq(cats.totalSupply(), 1);
    }

    function test_supportsStandardNFTInterfacesWithoutRoyaltyExtension() public view {
        assertTrue(cats.supportsInterface(0x01ffc9a7));
        assertTrue(cats.supportsInterface(0x80ac58cd));
        assertTrue(cats.supportsInterface(0x5b5e139f));
        assertTrue(cats.supportsInterface(0x49064906));
        assertFalse(cats.supportsInterface(0x2a55205a));
        assertFalse(cats.supportsInterface(0xffffffff));
    }

    function test_reporterPublishesCountWithObservationAndProvenance() public {
        uint64 observation = uint64(block.timestamp - 20);
        _publish(321, observation);
        assertEq(cats.aliveCats(), 321);
        assertEq(cats.observedAt(), observation);
        assertEq(cats.reportedAt(), block.timestamp);
        assertEq(cats.sourceHash(), SOURCE_HASH);
        assertEq(cats.reportStatus(), "fresh");
        assertFalse(cats.isStale());
    }

    function test_newReportNotifiesIndexersForEveryMintedToken() public {
        _mint(ALICE);
        _mint(BOB);
        vm.expectEmit(false, false, false, true, address(cats));
        emit BatchMetadataUpdate(1, 2);
        _publish(13, uint64(block.timestamp));
    }

    function test_ownerCannotReportUnlessDesignatedAndRevokedReporterLosesAccess() public {
        vm.prank(OWNER);
        vm.expectRevert();
        cats.publishCount(10, uint64(block.timestamp), SOURCE_HASH);
        vm.prank(ALICE);
        vm.expectRevert();
        cats.publishCount(10, uint64(block.timestamp), SOURCE_HASH);
        vm.prank(OWNER);
        cats.setReporter(ALICE);
        vm.prank(REPORTER);
        vm.expectRevert();
        cats.publishCount(10, uint64(block.timestamp), SOURCE_HASH);
        vm.prank(ALICE);
        cats.publishCount(10, uint64(block.timestamp), SOURCE_HASH);
        assertEq(cats.aliveCats(), 10);
    }

    function test_zeroCountAndOriginalMaximumAreBothValidReports() public {
        _publish(0, uint64(block.timestamp));
        assertEq(cats.aliveCats(), 0);
        assertFalse(cats.isStale());
        assertEq(cats.reportStatus(), "fresh");
        vm.warp(block.timestamp + 1);
        _publish(ORIGINAL_CATS, uint64(block.timestamp));
        assertEq(cats.aliveCats(), ORIGINAL_CATS);
    }

    function test_invalidReportCountTimeAndHashAreRejected() public {
        vm.startPrank(REPORTER);
        vm.expectRevert();
        cats.publishCount(ORIGINAL_CATS + 1, uint64(block.timestamp), SOURCE_HASH);
        vm.expectRevert();
        cats.publishCount(2, uint64(block.timestamp + 1), SOURCE_HASH);
        vm.expectRevert();
        cats.publishCount(2, uint64(block.timestamp - MAX_AGE - 1), SOURCE_HASH);
        vm.expectRevert();
        cats.publishCount(2, ORIGINAL_TIMESTAMP - 1, SOURCE_HASH);
        vm.expectRevert();
        cats.publishCount(2, uint64(block.timestamp), bytes32(0));
        vm.stopPrank();
        assertEq(cats.observedAt(), 0);
        assertEq(cats.reportStatus(), "unreported");
    }

    function test_olderAndDuplicateReportsCannotOverwriteLatestSnapshot() public {
        uint64 observation = uint64(block.timestamp - 10);
        _publish(123, observation);
        vm.startPrank(REPORTER);
        vm.expectRevert();
        cats.publishCount(20, observation - 1, keccak256("older"));
        vm.expectRevert();
        cats.publishCount(20, observation, keccak256("duplicate"));
        vm.stopPrank();
        assertEq(cats.aliveCats(), 123);
        assertEq(cats.observedAt(), observation);
        assertEq(cats.sourceHash(), SOURCE_HASH);
    }

    function test_freshnessBoundaryUsesObservationTime() public {
        uint64 observation = uint64(block.timestamp - MAX_AGE);
        _publish(42, observation);
        assertFalse(cats.isStale());
        assertEq(cats.reportStatus(), "fresh");
        vm.warp(block.timestamp + 1);
        assertTrue(cats.isStale());
        assertEq(cats.reportStatus(), "stale");
        assertEq(cats.aliveCats(), 42);
        _publish(41, uint64(block.timestamp));
        assertFalse(cats.isStale());
        assertEq(cats.reportStatus(), "fresh");
    }

    function test_observationAtOriginalMintTimeIsAllowed() public {
        CatsAlive recent = new CatsAlive(OWNER, REPORTER, 4, uint64(block.timestamp), MAX_AGE);
        vm.prank(REPORTER);
        recent.publishCount(4, uint64(block.timestamp), SOURCE_HASH);
        assertEq(recent.aliveCats(), 4);
        assertFalse(recent.isStale());
    }

    function testFuzz_validReportRangeIsPreserved(uint32 rawCount, uint32 rawAge) public {
        uint32 count = uint32(bound(rawCount, 0, ORIGINAL_CATS));
        uint64 observation = uint64(block.timestamp - bound(rawAge, 0, MAX_AGE));
        _publish(count, observation);
        assertEq(cats.aliveCats(), count);
        assertEq(cats.observedAt(), observation);
        assertFalse(cats.isStale());
    }

    function test_nonexistentTokenViewsRevert() public {
        vm.expectRevert();
        cats.tokenURI(0);
        vm.expectRevert();
        cats.tokenURI(1);
        vm.expectRevert();
        cats.imageSVG(1);
        vm.expectRevert();
        cats.animationHTML(1);
        _mint(ALICE);
        vm.expectRevert();
        cats.ownerOf(2);
    }

    function test_metadataAndArtAreEmbeddedAndUseLiveSharedReport() public {
        _mint(ALICE);
        _mint(BOB);
        _publish(7, uint64(block.timestamp));
        string memory first = _decodeDataURI(cats.tokenURI(1), "data:application/json;base64,");
        string memory second = _decodeDataURI(cats.tokenURI(2), "data:application/json;base64,");
        assertEq(vm.parseJsonString(first, ".name"), "Cats Alive (Fren Pet) #1");
        assertEq(vm.parseJsonString(second, ".name"), "Cats Alive (Fren Pet) #2");
        assertEq(vm.parseJsonString(first, ".external_url"), "https://pet.game");
        assertEq(vm.parseJsonUint(first, ".alive_cats"), 7);
        assertEq(vm.parseJsonUint(second, ".alive_cats"), 7);
        assertEq(vm.parseJsonString(first, ".status"), "fresh");
        assertEq(vm.parseJsonUint(first, ".observed_at"), block.timestamp);
        assertEq(vm.parseJsonString(first, ".original_mint"), vm.parseJsonString(second, ".original_mint"));
        string memory svg = _decodeDataURI(vm.parseJsonString(first, ".image"), "data:image/svg+xml;base64,");
        string memory html = _decodeDataURI(vm.parseJsonString(first, ".animation_url"), "data:text/html;base64,");
        assertEq(svg, cats.imageSVG(1));
        assertEq(html, cats.animationHTML(1));
        assertTrue(_contains(svg, "#342E2E"));
        assertTrue(_contains(svg, "#DBFEE6"));
        assertTrue(_contains(svg, "Fren Pet Cats Still Alive"));
        vm.warp(block.timestamp + 1);
        _publish(6, uint64(block.timestamp));
        string memory updated = _decodeDataURI(cats.tokenURI(1), "data:application/json;base64,");
        assertEq(vm.parseJsonUint(updated, ".alive_cats"), 6);
    }

    function test_metadataIncludesOriginalCohortDateAndFullProvenance() public {
        _mint(ALICE);
        _publish(31, uint64(block.timestamp - 30));
        string memory metadata = _decodeDataURI(cats.tokenURI(1), "data:application/json;base64,");
        assertEq(
            vm.parseJsonString(metadata, ".original_mint"),
            "1000 cats were originally minted on 2023-11-14 as a one-time mint. No new cats will ever be minted. This refers to the original Fren Pet game cats; FPCA minting is unlimited."
        );
        assertEq(vm.parseJsonUint(metadata, ".original_cats"), ORIGINAL_CATS);
        assertEq(vm.parseJsonUint(metadata, ".original_mint_timestamp"), ORIGINAL_TIMESTAMP);
        assertEq(vm.parseJsonUint(metadata, ".reported_at"), block.timestamp);
        assertEq(vm.parseJsonBytes32(metadata, ".source_hash"), SOURCE_HASH);
        assertEq(vm.parseJsonString(metadata, ".source"), "https://api.pet.game");
    }

    function test_maximumPopulationTokenURIHasBoundedRenderingCost() public {
        CatsAlive maximum = new CatsAlive(OWNER, REPORTER, 100_000, ORIGINAL_TIMESTAMP, MAX_AGE);
        vm.prank(ALICE);
        maximum.mint();
        vm.prank(REPORTER);
        maximum.publishCount(100_000, uint64(block.timestamp), SOURCE_HASH);
        uint256 beforeCall = gasleft();
        string memory uri = maximum.tokenURI(1);
        uint256 renderingGas = beforeCall - gasleft();
        emit log_named_uint("maximum-population tokenURI gas", renderingGas);
        assertLt(renderingGas, 5_000_000, "metadata RPC calls must remain practical at the population cap");
        assertLt(bytes(uri).length, 30_000, "metadata size must not scale with population");
        string memory metadata = _decodeDataURI(uri, "data:application/json;base64,");
        assertEq(vm.parseJsonUint(metadata, ".alive_cats"), 100_000);
        assertEq(vm.parseJsonString(metadata, ".status"), "fresh");
    }

    function test_unreportedAndStaleMetadataDoNotClaimFreshness() public {
        _mint(ALICE);
        string memory unreported = _decodeDataURI(cats.tokenURI(1), "data:application/json;base64,");
        assertEq(vm.parseJsonString(unreported, ".status"), "unreported");
        assertTrue(_contains(unreported, '"alive_cats":null'));
        _publish(0, uint64(block.timestamp));
        string memory freshZero = _decodeDataURI(cats.tokenURI(1), "data:application/json;base64,");
        assertEq(vm.parseJsonUint(freshZero, ".alive_cats"), 0);
        assertEq(vm.parseJsonString(freshZero, ".status"), "fresh");
        vm.warp(block.timestamp + MAX_AGE + 1);
        string memory stale = _decodeDataURI(cats.tokenURI(1), "data:application/json;base64,");
        assertEq(vm.parseJsonString(stale, ".status"), "stale");
    }

    function _mint(address recipient) internal {
        vm.prank(recipient);
        cats.mint();
    }

    function _publish(uint32 alive, uint64 observation) internal {
        vm.prank(REPORTER);
        cats.publishCount(alive, observation, SOURCE_HASH);
    }

    function _contains(string memory value, string memory needle) internal pure returns (bool) {
        bytes memory haystack = bytes(value);
        bytes memory target = bytes(needle);
        if (target.length > haystack.length) return false;
        for (uint256 i; i <= haystack.length - target.length; ++i) {
            bool matches = true;
            for (uint256 j; j < target.length; ++j) {
                if (haystack[i + j] != target[j]) {
                    matches = false;
                    break;
                }
            }
            if (matches) return true;
        }
        return false;
    }

    function _decodeDataURI(string memory uri, string memory prefix) internal pure returns (string memory) {
        bytes memory input = bytes(uri);
        bytes memory header = bytes(prefix);
        require(input.length >= header.length, "short data URI");
        for (uint256 i; i < header.length; ++i) {
            require(input[i] == header[i], "unexpected MIME prefix");
        }
        uint256 encodedLength = input.length - header.length;
        require(encodedLength % 4 == 0, "invalid base64 length");
        uint256 decodedLength = encodedLength / 4 * 3;
        if (encodedLength > 0 && input[input.length - 1] == "=") --decodedLength;
        if (encodedLength > 1 && input[input.length - 2] == "=") --decodedLength;
        bytes memory decoded = new bytes(decodedLength);
        uint256 cursor;
        for (uint256 i = header.length; i < input.length; i += 4) {
            uint256 chunk = (_base64Digit(input[i]) << 18) | (_base64Digit(input[i + 1]) << 12)
                | (_base64Digit(input[i + 2]) << 6) | _base64Digit(input[i + 3]);
            if (cursor < decodedLength) decoded[cursor++] = bytes1(uint8(chunk >> 16));
            if (cursor < decodedLength) decoded[cursor++] = bytes1(uint8(chunk >> 8));
            if (cursor < decodedLength) decoded[cursor++] = bytes1(uint8(chunk));
        }
        return string(decoded);
    }

    function _base64Digit(bytes1 character) private pure returns (uint256) {
        uint8 value = uint8(character);
        if (value >= 65 && value <= 90) return value - 65;
        if (value >= 97 && value <= 122) return value - 71;
        if (value >= 48 && value <= 57) return value + 4;
        if (character == "+") return 62;
        if (character == "/") return 63;
        require(character == "=", "invalid base64 character");
        return 0;
    }
}
