// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ViewerScript} from "./ViewerScript.sol";

/// @dev All runtime assets are embedded. Helpers are internal and linked into CatsAlive, not deployed separately.
library CatRenderer {
    using Strings for uint256;

    string internal constant CAT =
        "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABcAAAAVCAMAAACaPIWZAAAADFBMVEUAAACsv6sAAADV++ZIYI0RAAAABHRSTlMA////sy1AiAAAAG1JREFUeNp1kVkSwCAIQyHe/85thGFRzI/4UJpYkS1AQq1WDOW/WQqXrs5DhUObMONokHNyLIWrX4JefLspHDkj1jaH+D4P7xznT5/sDbl4WdAV74chLexjmSxTuT0v8k88eL6bJSkNmjAn7ucDva8B5wlHth0AAAAASUVORK5CYII=";

    /// @dev A positive gutter inside each 100x100 cell proves non-intersection regardless of seed.
    function cell(bytes32 seed, uint256 index) internal pure returns (uint256 x, uint256 y, uint256 size) {
        uint256 random = uint256(keccak256(abi.encode(seed, index)));
        size = 45 + random % 36;
        x = 5 + (random >> 32) % (91 - size);
        y = 5 + (random >> 64) % (91 - size);
    }

    function grid(uint256 count) internal pure returns (uint256 columns, uint256 rows) {
        if (count == 0) return (0, 0);
        columns = Math.sqrt(count, Math.Rounding.Ceil);
        rows = (count + columns - 1) / columns;
    }

    /// @dev Repeating a 4x4 tile bounds EVM work even for 100,000 cats. Each painted cell contains exactly one cat.
    /// The final row is an integer number of cells, so there are no partial or extra cats.
    function field(uint256 count, bytes32 seed) internal pure returns (string memory) {
        if (count == 0) return "";
        (uint256 columns, uint256 rows) = grid(count);
        string memory tile;
        for (uint256 i; i < 16; ++i) {
            (uint256 x, uint256 y, uint256 size) = cell(seed, i);
            tile = string.concat(
                tile,
                '<use xlink:href="#cat" transform="translate(',
                (x + (i % 4) * 100).toString(),
                " ",
                (y + (i / 4) * 100).toString(),
                ") scale(0.",
                size.toString(),
                ')"/>'
            );
        }
        return string.concat(
            '<svg x="32" y="54" width="936" height="726" viewBox="0 0 ',
            (columns * 100).toString(),
            " ",
            (rows * 100).toString(),
            '" preserveAspectRatio="xMidYMid meet">'
            '<defs><image id="cat" width="100" height="91.3043478261" xlink:href="',
            CAT,
            '"/><pattern id="catsPattern" width="400" height="400" patternUnits="userSpaceOnUse">',
            tile,
            '</pattern></defs><g id="cats" fill="url(#catsPattern)">' '<rect width="',
            (columns * 100).toString(),
            '" height="',
            ((count / columns) * 100).toString(),
            '"/><rect y="',
            ((count / columns) * 100).toString(),
            '" width="',
            ((count % columns) * 100).toString(),
            '" height="100"/></g></svg>'
        );
    }

    function svg(uint256 tokenId, uint256 count, uint256 observed, string memory status, bytes32 seed)
        internal
        pure
        returns (string memory)
    {
        return string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" '
            'width="1000" height="1000" viewBox="0 0 1000 1000" role="img" '
            'style="font-family:Inter,Arial,Helvetica,sans-serif;image-rendering:pixelated">'
            '<title>Cats Alive (Fren Pet)</title><rect width="1000" height="1000" fill="#342E2E"/>'
            '<g fill="#DBFEE6"><text x="32" y="32" font-size="18">',
            status,
            " report / observed Unix ",
            observed.toString(),
            "</text>" '<text x="968" y="32" text-anchor="end" font-size="18">#',
            tokenId.toString(),
            "</text></g>",
            field(observed == 0 ? 0 : count, seed),
            '<g fill="#DBFEE6" text-anchor="middle"><text x="500" y="868" font-size="36pt">',
            observed == 0 ? "--" : count.toString(),
            "</text>" '<text x="500" y="932" font-size="30pt">Fren Pet Cats Still Alive</text></g></svg>'
        );
    }

    function html(
        uint256 tokenId,
        uint256 count,
        uint256 observed,
        uint256 maxAge,
        uint256 original,
        uint256 originalTimestamp
    ) internal pure returns (string memory) {
        return string.concat(
            '<!doctype html><html lang="en"><meta charset="utf-8">'
            '<meta name="viewport" content="width=device-width,initial-scale=1">'
            "<title>Cats Alive (Fren Pet)</title><style>"
            "html,body{margin:0;background:#342E2E;color:#DBFEE6;height:100%;display:grid;place-items:center}"
            "canvas{max-width:100vw;max-height:100vh;width:100vmin;height:100vmin;object-fit:contain}"
            '</style><canvas id="art" width="1000" height="1000" aria-label="Cats Alive (Fren Pet)"></canvas>'
            "<noscript>Enable JavaScript to view the interactive artwork, or use the onchain SVG image.</noscript><script>",
            "const initial={count:",
            count.toString(),
            ",observed:",
            observed.toString(),
            ",maxAge:",
            maxAge.toString(),
            ',mint:"',
            tokenId.toString(),
            '",original:',
            original.toString(),
            ",originalTimestamp:",
            originalTimestamp.toString(),
            ',sprite:"',
            CAT,
            '"};',
            ViewerScript.SOURCE,
            "</script></html>"
        );
    }

    /// @dev Gregorian conversion for validated UTC timestamps in [1970, 2100).
    function date(uint256 timestamp) internal pure returns (string memory) {
        uint256 daysLeft = timestamp / 1 days;
        uint256 year = 1970;
        while (true) {
            uint256 daysInYear = _leap(year) ? 366 : 365;
            if (daysLeft < daysInYear) break;
            daysLeft -= daysInYear;
            ++year;
        }
        uint256 month = 1;
        uint256[12] memory months = [uint256(31), 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
        if (_leap(year)) months[1] = 29;
        while (daysLeft >= months[month - 1]) {
            daysLeft -= months[month - 1];
            ++month;
        }
        return string.concat(year.toString(), "-", _two(month), "-", _two(daysLeft + 1));
    }

    function _two(uint256 value) private pure returns (string memory) {
        return value < 10 ? string.concat("0", value.toString()) : value.toString();
    }

    function _leap(uint256 year) private pure returns (bool) {
        return year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
    }
}
