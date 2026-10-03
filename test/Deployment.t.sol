// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CatsAlive} from "../src/CatsAlive.sol";

contract CatsAliveDeploymentTest is Test {
    address private constant OWNER = address(0xA11CE);
    uint64 private constant ORIGINAL_TIMESTAMP = 1_708_988_049;

    function test_historicalDateDeploysWithCreateAtRehearsalClock() public {
        vm.warp(1);
        CatsAlive cats = new CatsAlive(OWNER, OWNER, 37, ORIGINAL_TIMESTAMP, 3600);
        assertEq(cats.originalMintTimestamp(), ORIGINAL_TIMESTAMP);
        assertEq(cats.owner(), OWNER);
        assertEq(cats.totalSupply(), 0);
        assertTrue(cats.isStale());

        // Configuration is independent of this clock; reports still must be
        // no earlier than the original mint and no later than the current time.
        vm.startPrank(OWNER);
        vm.expectRevert(CatsAlive.InvalidReport.selector);
        cats.publishCount(34, 1, bytes32(uint256(1)));
        vm.expectRevert(CatsAlive.InvalidReport.selector);
        cats.publishCount(34, ORIGINAL_TIMESTAMP, bytes32(uint256(1)));
        vm.warp(ORIGINAL_TIMESTAMP);
        cats.publishCount(34, ORIGINAL_TIMESTAMP, bytes32(uint256(1)));
        vm.stopPrank();
        assertEq(cats.aliveCats(), 34);
        assertFalse(cats.isStale());
    }

    function test_historicalDateDeploysWithCreate2AtRehearsalClock() public {
        vm.warp(1);
        bytes memory code = abi.encodePacked(
            type(CatsAlive).creationCode, abi.encode(OWNER, OWNER, uint32(37), ORIGINAL_TIMESTAMP, uint32(3600))
        );
        bytes32 salt = keccak256("historical mint deployment regression");
        address deployed;
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), salt)
        }
        assertTrue(deployed != address(0), "application constructor failed under the deployment rehearsal");
        assertGt(deployed.code.length, 0);
        assertEq(CatsAlive(deployed).originalMintTimestamp(), ORIGINAL_TIMESTAMP);
        assertEq(CatsAlive(deployed).originalCats(), 37);
        assertEq(CatsAlive(deployed).owner(), OWNER);
        assertEq(CatsAlive(deployed).reporter(), OWNER);
    }
}
