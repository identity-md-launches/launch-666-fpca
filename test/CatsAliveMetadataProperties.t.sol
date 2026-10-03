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
    /// Populations above 64 use the repeated tile, so the painted rectangles carry the count.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_PaintedSvgAreaContainsExactlyTheRequestedWholeCells(uint32 input, bytes32 seed) public view {
        uint256 count = bound(input, 65, 100_000);
        string memory svg = renderer.field(count, seed);
        assertNotEq(vm.indexOf(svg, '<pattern id="catsPattern"'), type(uint256).max, "large cohorts must tile");
        assertEq(_occurrences(svg, "<use "), 16, "tile must hold exactly sixteen cats");
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

    /// @dev Populations of at most 64 serialize one independently seeded sprite per cat with no tile. Every
    /// parsed bounding box must sit inside its own grid cell with a gutter, and no two boxes may touch.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_SmallCohortSerializesEveryCatInItsOwnDisjointCell(uint8 input, bytes32 seed) public view {
        uint256 count = bound(input, 1, 64);
        string memory svg = renderer.field(count, seed);
        assertEq(vm.indexOf(svg, "<pattern"), type(uint256).max, "small cohorts must not tile");
        assertEq(vm.indexOf(svg, "<rect"), type(uint256).max, "small cohorts paint sprites, not rectangles");
        assertNotEq(vm.indexOf(svg, '<g id="cats">'), type(uint256).max, "direct sprite group missing");
        bytes memory viewBox = bytes(_suffix(svg, 'viewBox="0 0 '));
        (uint256 viewWidth, uint256 cursor) = _readUint(viewBox, bytes('viewBox="0 0 ').length);
        (uint256 viewHeight,) = _readUint(viewBox, cursor + 1);
        assertEq(viewWidth % 100, 0);
        assertEq(viewHeight % 100, 0);
        uint256 columns = viewWidth / 100;
        uint256 rows = viewHeight / 100;
        assertGe(columns * rows, count, "grid must hold every cat");
        assertLt(columns * (rows - 1), count, "grid must not reserve an empty row");

        uint256[] memory xs = new uint256[](count);
        uint256[] memory ys = new uint256[](count);
        uint256[] memory sizes = new uint256[](count);
        bool[] memory occupied = new bool[](columns * rows);
        string memory remaining = svg;
        for (uint256 i; i < count; ++i) {
            remaining = _suffix(remaining, "translate(");
            bytes memory transform = bytes(remaining);
            (xs[i], cursor) = _readUint(transform, bytes("translate(").length);
            (ys[i],) = _readUint(transform, cursor + 1);
            remaining = _suffix(remaining, "scale(0.");
            (sizes[i],) = _readUint(bytes(remaining), bytes("scale(0.").length);
            assertGt(sizes[i], 0);
            assertLt(sizes[i], 100);
            assertGt(xs[i] % 100, 0, "sprite touches its cell's left edge");
            assertGt(ys[i] % 100, 0, "sprite touches its cell's top edge");
            assertLt(xs[i] % 100 + sizes[i], 100, "sprite touches its cell's right edge");
            assertLt(ys[i] % 100 + sizes[i], 100, "sprite touches its cell's bottom edge");
            assertLt(xs[i], viewWidth, "sprite outside the viewBox");
            assertLt(ys[i], viewHeight, "sprite outside the viewBox");
            uint256 cell = (ys[i] / 100) * columns + xs[i] / 100;
            assertFalse(occupied[cell], "two serialized sprites share a cell");
            occupied[cell] = true;
        }
        assertEq(vm.indexOf(remaining, "translate("), type(uint256).max, "extra serialized sprite");
        for (uint256 i; i < count; ++i) {
            for (uint256 j = i + 1; j < count; ++j) {
                bool separated = xs[i] + sizes[i] < xs[j] || xs[j] + sizes[j] < xs[i] || ys[i] + sizes[i] < ys[j]
                    || ys[j] + sizes[j] < ys[i];
                assertTrue(separated, "serialized sprites overlap or touch");
            }
        }
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

    /// @dev The branch switch must be invisible in what the spec requires: exactly `count` painted cats,
    /// the live number and the caption, whichever renderer path the token image takes.
    function test_RenderingBranchSwitchesAtSixtyFourCatsThroughTokenImage() public {
        CatsAlive cats = new CatsAlive(address(this), address(this), 100_000, 1_700_000_000, 3600);
        vm.prank(address(0xA11CE));
        cats.mint();

        cats.publishCount(64, uint64(vm.getBlockTimestamp()), keccak256("sixty-four"));
        string memory direct = cats.imageSVG(1);
        assertEq(_occurrences(direct, "<use "), 64, "every one of 64 cats gets its own sprite");
        assertEq(vm.indexOf(direct, "<pattern"), type(uint256).max);
        assertEq(vm.indexOf(direct, "<rect y="), type(uint256).max);
        assertTrue(vm.contains(direct, 'font-size="36pt">64</text>'));
        assertTrue(vm.contains(direct, 'viewBox="0 0 800 800"'), "64 cats fill an 8x8 grid");

        vm.warp(vm.getBlockTimestamp() + 1);
        cats.publishCount(65, uint64(vm.getBlockTimestamp()), keccak256("sixty-five"));
        string memory tiled = cats.imageSVG(1);
        assertEq(_occurrences(tiled, "<use "), 16, "65 cats switch to the bounded 4x4 tile");
        assertTrue(vm.contains(tiled, '<pattern id="catsPattern" width="400" height="400"'));
        assertTrue(vm.contains(tiled, '<rect width="900" height="700"/><rect y="700" width="200" height="100"/>'));
        assertTrue(vm.contains(tiled, 'font-size="36pt">65</text>'));
        assertTrue(vm.contains(tiled, 'viewBox="0 0 900 800"'), "65 cats need 9 columns and 8 rows");

        vm.warp(vm.getBlockTimestamp() + 1);
        cats.publishCount(1, uint64(vm.getBlockTimestamp()), keccak256("one"));
        string memory single = cats.imageSVG(1);
        assertEq(_occurrences(single, "<use "), 1);
        assertTrue(vm.contains(single, 'viewBox="0 0 100 100"'));
        assertTrue(vm.contains(single, 'font-size="36pt">1</text>'));
        assertTrue(vm.contains(cats.animationHTML(1), "const initial={count:1,"), "HTML seeds the same count");
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

    function _occurrences(string memory value, string memory needle) private pure returns (uint256 count) {
        bytes memory haystack = bytes(value);
        bytes memory target = bytes(needle);
        if (target.length > haystack.length) return 0;
        for (uint256 i; i <= haystack.length - target.length; ++i) {
            bool matches = true;
            for (uint256 j; j < target.length; ++j) {
                if (haystack[i + j] != target[j]) {
                    matches = false;
                    break;
                }
            }
            if (matches) ++count;
        }
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
