// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
  SafeERC20Upgradeable as SafeERC20
} from "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import { SafeTransferLib } from "solmate/src/utils/SafeTransferLib.sol";
import { WETH } from "solmate/src/tokens/WETH.sol";
import { ERC20 } from "solmate/src/tokens/ERC20.sol";
import { EXA } from "./EXA.sol";
import { RewardsController, ClaimPermit } from "./../RewardsController.sol";

contract ProtoStaker is Initializable {
  using SafeTransferLib for address payable;
  using SafeTransferLib for ERC20;
  using SafeTransferLib for WETH;
  using SafeERC20 for EXA;

  /// @notice The rewards controller.
  RewardsController public immutable rewardsController;
  /// @notice The gauge used to stake the liquidity pool tokens.
  IGauge public immutable gauge;
  /// @notice The liquidity pool.
  IPool public immutable pool;
  /// @notice The WETH asset.
  WETH public immutable weth;
  /// @notice The EXA asset.
  EXA public immutable exa;

  constructor(RewardsController rewardsController_, IGauge gauge_, IPool pool_, WETH weth_, EXA exa_) {
    rewardsController = rewardsController_;
    gauge = gauge_;
    pool = pool_;
    weth = weth_;
    exa = exa_;
  }

  function initialize() external initializer {
    ERC20(address(pool)).safeApprove(address(gauge), type(uint256).max);
  }

  function addBalance(Permit calldata permit) external payable {
    exa.safePermit(permit.account, address(this), permit.amount, permit.deadline, permit.v, permit.r, permit.s);
    exa.safeTransferFrom(permit.account, address(pool), permit.amount);
    add(permit.account, permit.amount);
  }

  function addReward(ClaimPermit calldata permit) external payable {
    assert(permit.assets.length == 1 && address(permit.assets[0]) == address(exa));
    (, uint256[] memory claimedAmounts) = rewardsController.claim(rewardsController.allMarketsOperations(), permit);
    add(payable(permit.owner), claimedAmounts[0]);
  }

  function add(address payable account, uint256 amountEXA) internal {
    (uint256 reserve0, uint256 reserve1, ) = pool.getReserves();
    uint256 amountWETH = address(exa) < address(weth)
      ? (amountEXA * reserve1) / reserve0
      : (amountEXA * reserve0) / reserve1;
    if (msg.value < amountWETH) {
      pool.skim(account);
      account.safeTransferETH(msg.value);
      return;
    }

    weth.deposit{ value: amountWETH }();
    weth.safeTransfer(address(pool), amountWETH);
    gauge.deposit(pool.mint(address(this)), account);
    account.safeTransferETH(msg.value - amountWETH);
  }

  function previewETH(uint256 amountEXA) external view returns (uint256) {
    (uint256 reserve0, uint256 reserve1, ) = pool.getReserves();
    return address(exa) < address(weth) ? (amountEXA * reserve1) / reserve0 : (amountEXA * reserve0) / reserve1;
  }
}

interface IPool {
  function getReserves() external view returns (uint256 _reserve0, uint256 _reserve1, uint256 _blockTimestampLast);

  function mint(address to) external returns (uint256 liquidity);

  function skim(address to) external;
}

interface IGauge {
  function deposit(uint256 _amount, address _recipient) external;
}

struct Permit {
  address payable account;
  uint256 amount;
  uint256 deadline;
  uint8 v;
  bytes32 r;
  bytes32 s;
}
