// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CatsAlive} from "src/CatsAlive.sol";
import {CatRenderer} from "src/CatRenderer.sol";

contract CatsAliveMetadataRendererHarness {
    function field(uint256 count, bytes32 seed) external pure returns (string memory) {
        return CatRenderer.field(count, seed);
    }

    function date(uint256 timestamp) external pure returns (string memory) {
        return CatRenderer.date(timestamp);
    }
}

contract CatsAliveMetadataPropertiesTest is Test {
    CatsAliveMetadataRendererHarness private renderer;

    function setUp() public {
        renderer = new CatsAliveMetadataRendererHarness();
        vm.warp(1_800_000_000);
    }

    /// @dev Parse actual SVG output instead of reconstructing expected strings from renderer helpers.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_PaintedSvgAreaContainsExactlyTheRequestedWholeCells(uint32 input, bytes32 seed) public view {
        uint256 count = bound(input, 1, 100_000);
        string memory svg = renderer.field(count, seed);
        string memory full = _suffix(svg, '<rect width="');
        string memory tail = _suffix(svg, '<rect y="');
        uint256 fullWidth = _attribute(full, "width");
        uint256 fullHeight = _attribute(full, "height");
        uint256 tailWidth = _attribute(tail, "width");
        uint256 tailHeight = _attribute(tail, "height");
        uint256 tailY = _attribute(tail, "y");
        bytes memory viewBox = bytes(_suffix(svg, 'viewBox="0 0 '));
        (uint256 viewWidth, uint256 cursor) = _readUint(viewBox, bytes('viewBox="0 0 ').length);
        (uint256 viewHeight,) = _readUint(viewBox, cursor + 1);

        assertEq(fullWidth % 100, 0, "full rows must contain whole cells");
        assertEq(fullHeight % 100, 0, "full rows cannot crop cats");
        assertEq(tailWidth % 100, 0, "last row must contain whole cells");
        assertEq(tailHeight, 100, "last row must be exactly one cell tall");
        assertEq(tailY, fullHeight, "last row must not overlap full rows");
        assertEq((fullWidth * fullHeight + tailWidth * tailHeight) / 10_000, count);
        assertEq(fullWidth, viewWidth);
        assertLe(fullHeight, viewHeight);
        assertLt(tailWidth, viewWidth);
        if (tailWidth > 0) assertEq(tailY + tailHeight, viewHeight);
        else assertEq(fullHeight, viewHeight);
    }

    /// @dev Check the serialized transforms used by the browser, not just the cell helper's return values.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_SerializedSpriteTransformsStayInsideDistinctCells(bytes32 seed) public view {
        string memory remaining = renderer.field(100_000, seed);
        bool[16] memory occupied;
        for (uint256 i; i < 16; ++i) {
            remaining = _suffix(remaining, "translate(");
            bytes memory transform = bytes(remaining);
            (uint256 x, uint256 cursor) = _readUint(transform, bytes("translate(").length);
            (uint256 y,) = _readUint(transform, cursor + 1);
            remaining = _suffix(remaining, "scale(0.");
            (uint256 size,) = _readUint(bytes(remaining), bytes("scale(0.").length);
            assertGt(size, 0);
            assertLt(size, 100);
            assertGt(x % 100, 0);
            assertGt(y % 100, 0);
            assertLt(x % 100 + size, 100);
            assertLt(y % 100 + size, 100);
            assertLt(x, 400);
            assertLt(y, 400);
            uint256 cell = (y / 100) * 4 + x / 100;
            assertFalse(occupied[cell], "serialized sprites share a cell");
            occupied[cell] = true;
        }
        assertEq(vm.indexOf(remaining, "translate("), type(uint256).max, "extra serialized sprite");
    }

    /// @dev Construct UTC timestamps independently using a closed-form March-based Gregorian calendar.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_OriginalMintDateRoundTripsAcrossSupportedCalendar(
        uint16 yearInput,
        uint8 monthInput,
        uint8 dayInput,
        uint32 secondInput
    ) public view {
        uint256 year = bound(yearInput, 1970, 2099);
        uint256 month = bound(monthInput, 1, 12);
        uint256[12] memory lengths = [uint256(31), 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
        if (year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)) lengths[1] = 29;
        uint256 day = bound(dayInput, 1, lengths[month - 1]);
        uint256 timestamp = _epochDays(year, month, day) * 1 days + bound(secondInput, 0, 1 days - 1);
        string memory expected = string.concat(vm.toString(year), "-", _two(month), "-", _two(day));
        assertEq(renderer.date(timestamp), expected);
    }

    function test_CollectionArtworkDiffersOnlyByMintNumberAndSurvivesTransfer() public {
        CatsAlive cats = new CatsAlive(address(this), address(this), 100_000, 1_700_000_000, 3600);
        address alice = address(0xA11CE);
        address bob = address(0xB0B);
        vm.prank(alice);
        cats.mint();
        vm.prank(bob);
        cats.mint();
        cats.publishCount(99_999, uint64(block.timestamp), keccak256("shared report"));
        string memory firstSvg = cats.imageSVG(1);
        string memory firstHtml = cats.animationHTML(1);
        assertEq(vm.replace(firstSvg, "#1</text>", "#2</text>"), cats.imageSVG(2));
        assertEq(vm.replace(firstHtml, 'mint:"1"', 'mint:"2"'), cats.animationHTML(2));
        vm.prank(alice);
        cats.transferFrom(alice, bob, 1);
        assertEq(cats.imageSVG(1), firstSvg, "ownership must not change shared art");
        assertEq(cats.animationHTML(1), firstHtml, "ownership must not change embedded data");
        cats.pause();
        assertEq(cats.imageSVG(1), firstSvg, "mint pause must not alter existing art");
        assertEq(cats.animationHTML(1), firstHtml);
    }

    function test_UnknownAndConfirmedZeroHaveDifferentVisibleMeaning() public {
        CatsAlive cats = new CatsAlive(address(this), address(this), 1, 1_700_000_000, 60);
        vm.prank(address(0xA11CE));
        cats.mint();
        string memory unknown = cats.imageSVG(1);
        assertTrue(vm.contains(unknown, 'font-size="36pt">--</text>'));
        assertFalse(vm.contains(unknown, 'id="cats"'));
        cats.publishCount(0, uint64(block.timestamp), bytes32(uint256(1)));
        string memory zero = cats.imageSVG(1);
        assertTrue(vm.contains(zero, 'font-size="36pt">0</text>'));
        assertFalse(vm.contains(zero, 'id="cats"'));
        assertTrue(vm.contains(zero, 'fill="#DBFEE6" text-anchor="middle"'));
        assertTrue(vm.contains(zero, 'y="932" font-size="30pt">Fren Pet Cats Still Alive</text>'));
    }

    function _attribute(string memory value, string memory name) private pure returns (uint256 number) {
        string memory marker = string.concat(name, '="');
        string memory tail = _suffix(value, marker);
        (number,) = _readUint(bytes(tail), bytes(marker).length);
    }

    function _suffix(string memory value, string memory marker) private pure returns (string memory) {
        uint256 start = vm.indexOf(value, marker);
        require(start != type(uint256).max, "SVG marker missing");
        bytes memory source = bytes(value);
        bytes memory tail = new bytes(source.length - start);
        for (uint256 i; i < tail.length; ++i) {
            tail[i] = source[start + i];
        }
        return string(tail);
    }

    function _readUint(bytes memory value, uint256 start) private pure returns (uint256 result, uint256 end) {
        end = start;
        while (end < value.length && value[end] >= "0" && value[end] <= "9") {
            result = result * 10 + uint8(value[end]) - 48;
            ++end;
        }
        require(end > start, "SVG integer missing");
    }

    function _epochDays(uint256 year, uint256 month, uint256 day) private pure returns (uint256) {
        uint256 adjustedYear = year - (month <= 2 ? 1 : 0);
        uint256 era = adjustedYear / 400;
        uint256 yearOfEra = adjustedYear - era * 400;
        uint256 marchMonth = month > 2 ? month - 3 : month + 9;
        uint256 dayOfYear = (153 * marchMonth + 2) / 5 + day - 1;
        uint256 dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear;
        return era * 146_097 + dayOfEra - 719_468;
    }

    function _two(uint256 value) private pure returns (string memory) {
        return value < 10 ? string.concat("0", vm.toString(value)) : vm.toString(value);
    }
}
