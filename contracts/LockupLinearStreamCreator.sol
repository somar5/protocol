// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { ERC20 } from "solmate/src/tokens/ERC20.sol";
import { SafeTransferLib } from "solmate/src/utils/SafeTransferLib.sol";

contract LockupLinearStreamCreator {
  using SafeTransferLib for ERC20;

  ERC20 public immutable exa;
  ISablierV2LockupLinear public immutable sablier;

  constructor(ERC20 exa_, ISablierV2LockupLinear sablier_) {
    exa = exa_;
    sablier = sablier_;
    exa.safeApprove(address(sablier), type(uint256).max);
  }

  function createLockupLinearStream(uint128 totalAmount) external returns (uint256 streamId) {
    return
      sablier.createWithDurations(
        ISablierV2LockupLinear.CreateWithDurations({
          sender: msg.sender,
          recipient: msg.sender,
          totalAmount: totalAmount,
          asset: exa,
          cancelable: true,
          durations: ISablierV2LockupLinear.Durations({ cliff: 0, total: 12 weeks }),
          broker: ISablierV2LockupLinear.Broker(address(0), 0)
        })
      );
  }
}

interface ISablierV2LockupLinear {
  struct Durations {
    uint40 cliff;
    uint40 total;
  }

  struct Broker {
    address account;
    uint256 fee;
  }

  struct CreateWithDurations {
    address sender;
    address recipient;
    uint128 totalAmount;
    ERC20 asset;
    bool cancelable;
    Durations durations;
    Broker broker;
  }

  function createWithDurations(CreateWithDurations calldata params) external returns (uint256 streamId);

  function withdraw(uint256 streamId, address to, uint128 amount) external;

  function withdrawMax(uint256 streamId, address to) external;

  function withdrawMaxAndTransfer(uint256 streamId, address newRecipient) external;

  function streamedAmountOf(uint256 streamId) external view returns (uint128 streamedAmount);

  function withdrawableAmountOf(uint256 streamId) external view returns (uint128 withdrawableAmount);
}
