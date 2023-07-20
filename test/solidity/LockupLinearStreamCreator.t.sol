// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { Vm } from "forge-std/Vm.sol";
import { Test } from "forge-std/Test.sol";
import { MockERC20 } from "solmate/src/test/utils/mocks/MockERC20.sol";
import { LockupLinearStreamCreator, ISablierV2LockupLinear } from "../../contracts/LockupLinearStreamCreator.sol";

contract LockupLinearStreamCreatorTest is Test {
  MockERC20 internal exa;
  LockupLinearStreamCreator internal creator;
  ISablierV2LockupLinear internal constant sablier = ISablierV2LockupLinear(0xB923aBdCA17Aed90EB5EC5E407bd37164f632bFD);

  function setUp() external {
    vm.createSelectFork(vm.envString("OPTIMISM_NODE"), 106_835_444);

    exa = new MockERC20("EXA", "EXA", 18);
    creator = new LockupLinearStreamCreator(exa, sablier);
    exa.mint(address(creator), 1_000_000 ether);
  }

  function testLockupLinearStream() external {
    uint128 totalAmount = 1_000 ether;
    uint256 streamId = creator.createLockupLinearStream(totalAmount);
    assertGt(streamId, 0);
    assertEq(sablier.streamedAmountOf(streamId), 0);

    vm.warp(block.timestamp + 1);
    uint256 claimAmount = sablier.streamedAmountOf(streamId);

    sablier.withdrawMax(streamId, address(this));
    assertEq(exa.balanceOf(address(this)), claimAmount);
    assertEq(sablier.withdrawableAmountOf(streamId), 0);
    assertEq(sablier.streamedAmountOf(streamId), claimAmount);

    vm.warp(block.timestamp + 12 weeks);
    sablier.withdrawMax(streamId, address(this));
    assertEq(exa.balanceOf(address(this)), totalAmount);

    vm.warp(block.timestamp + 1);
    assertEq(sablier.withdrawableAmountOf(streamId), 0);
  }
}
