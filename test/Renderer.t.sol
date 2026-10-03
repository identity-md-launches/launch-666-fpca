// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CatRenderer} from "../src/CatRenderer.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

contract RendererHarness {
    function cell(bytes32 seed, uint256 i) external pure returns (uint256, uint256, uint256) {
        return CatRenderer.cell(seed, i);
    }

    function grid(uint256 count) external pure returns (uint256, uint256) {
        return CatRenderer.grid(count);
    }

    function field(uint256 count, bytes32 seed) external pure returns (string memory) {
        return CatRenderer.field(count, seed);
    }

    function date(uint256 timestamp) external pure returns (string memory) {
        return CatRenderer.date(timestamp);
    }
}

contract RendererTest is Test {
    using Strings for uint256;
    RendererHarness private renderer;

    function setUp() public {
        renderer = new RendererHarness();
    }

    function testFuzz_CellsAlwaysHavePositiveGutters(bytes32 seed, uint8 index) public view {
        (uint256 x, uint256 y, uint256 size) = renderer.cell(seed, index);
        assertGe(size, 45);
        assertLe(size, 80);
        assertGe(x, 5);
        assertGe(y, 5);
        assertLe(x + size, 95);
        assertLe(y + size, 95);
        // Cat height is only 21/23 of its width, so these square bounds are conservative.
    }

    function testFuzz_AllBoundingBoxesAreDisjoint(bytes32 seed, uint8 input) public view {
        uint256 count = bound(input, 1, 64);
        (uint256 columns,) = renderer.grid(count);
        for (uint256 i; i < count; ++i) {
            (uint256 xi, uint256 yi, uint256 si) = renderer.cell(seed, i);
            xi += (i % columns) * 100;
            yi += (i / columns) * 100;
            for (uint256 j = i + 1; j < count; ++j) {
                (uint256 xj, uint256 yj, uint256 sj) = renderer.cell(seed, j);
                xj += (j % columns) * 100;
                yj += (j / columns) * 100;
                assertTrue(xi + si < xj || xj + sj < xi || yi + si < yj || yj + sj < yi);
            }
        }
    }

    function testFuzz_GridContainsExactlyCountAndOnlyWholeCells(uint32 input) public view {
        uint256 count = bound(input, 1, 100_000);
        (uint256 columns, uint256 rows) = renderer.grid(count);
        assertGe(columns * columns, count);
        assertLt((columns - 1) * (columns - 1), count);
        uint256 fullRows = count / columns;
        uint256 tail = count % columns;
        assertEq(fullRows * columns + tail, count);
        assertEq(rows, fullRows + (tail == 0 ? 0 : 1));
        assertLt(tail, columns);
    }

    function test_SmallPopulationsRenderEveryIndependentlySeededCat() public view {
        bytes32 seed = keccak256("x");
        uint256[7] memory counts = [uint256(1), 16, 17, 34, 37, 63, 64];
        for (uint256 c; c < counts.length; ++c) {
            uint256 count = counts[c];
            (uint256 columns,) = renderer.grid(count);
            string memory output = renderer.field(count, seed);
            assertEq(_occurrences(output, "<use "), count);
            assertFalse(_contains(output, "<pattern"));
            for (uint256 i; i < count; ++i) {
                (uint256 x, uint256 y, uint256 size) = renderer.cell(seed, i);
                string memory expected = string.concat(
                    '<use xlink:href="#cat" transform="translate(',
                    (x + (i % columns) * 100).toString(),
                    " ",
                    (y + (i / columns) * 100).toString(),
                    ") scale(0.",
                    size.toString(),
                    ')"/>'
                );
                assertTrue(_contains(output, expected), "Every cat uses its own seeded cell");
            }
            assertLt(bytes(output).length, 6_000, "Direct rendering has a fixed size ceiling");
        }
    }

    function test_RenderedRectanglesMatchPopulationIncludingPartialRows() public view {
        uint256[5] memory counts = [uint256(65), 99, 100, 99_999, 100_000];
        for (uint256 i; i < counts.length; ++i) {
            uint256 n = counts[i];
            (uint256 columns,) = renderer.grid(n);
            string memory output = renderer.field(n, bytes32(uint256(1)));
            string memory expected = string.concat(
                '<rect width="',
                (columns * 100).toString(),
                '" height="',
                ((n / columns) * 100).toString(),
                '"/><rect y="',
                ((n / columns) * 100).toString(),
                '" width="',
                ((n % columns) * 100).toString(),
                '" height="100"/>'
            );
            assertTrue(_contains(output, expected));
            assertTrue(_contains(output, 'patternUnits="userSpaceOnUse"'));
            assertEq(_occurrences(output, "<use "), 16, "Large populations retain the bounded tile");
            assertLt(bytes(output).length, 4_000, "Rendering must not grow linearly with population");
        }
    }

    function test_RenderingGasRemainsBoundedAtBothBranchLimits() public view {
        uint256[3] memory counts = [uint256(64), 65, 100_000];
        for (uint256 i; i < counts.length; ++i) {
            uint256 beforeCall = gasleft();
            renderer.field(counts[i], bytes32(uint256(1)));
            assertLt(beforeCall - gasleft(), 1_000_000, "Field rendering must remain practical for RPC reads");
        }
    }

    function test_ZeroHasNoSpritesAndSeedChangesLayout() public view {
        assertEq(renderer.field(0, bytes32(0)), "");
        (uint256 columns, uint256 rows) = renderer.grid(0);
        assertEq(columns, 0);
        assertEq(rows, 0);
        assertNotEq(renderer.field(34, bytes32(uint256(1))), renderer.field(34, bytes32(uint256(2))));
    }

    function test_UTCDateConversionAcrossLeapBoundaries() public view {
        assertEq(renderer.date(1), "1970-01-01");
        assertEq(renderer.date(951_782_400), "2000-02-29");
        assertEq(renderer.date(1_677_628_800), "2023-03-01");
        assertEq(renderer.date(1_709_164_800), "2024-02-29");
        assertEq(renderer.date(4_102_444_799), "2099-12-31");
    }

    function _contains(string memory haystack, string memory needle) private pure returns (bool) {
        bytes memory a = bytes(haystack);
        bytes memory b = bytes(needle);
        if (b.length > a.length) return false;
        for (uint256 i; i <= a.length - b.length; ++i) {
            bool matches = true;
            for (uint256 j; j < b.length; ++j) {
                if (a[i + j] != b[j]) {
                    matches = false;
                    break;
                }
            }
            if (matches) return true;
        }
        return false;
    }

    function _occurrences(string memory haystack, string memory needle) private pure returns (uint256 count) {
        bytes memory a = bytes(haystack);
        bytes memory b = bytes(needle);
        if (b.length > a.length) return 0;
        for (uint256 i; i <= a.length - b.length; ++i) {
            bool matches = true;
            for (uint256 j; j < b.length; ++j) {
                if (a[i + j] != b[j]) {
                    matches = false;
                    break;
                }
            }
            if (matches) ++count;
        }
    }
}
