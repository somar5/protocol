// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { WETH, SafeTransferLib } from "solmate/src/tokens/WETH.sol";
import { ERC20 } from "solmate/src/tokens/ERC20.sol";

contract Staking {
  using SafeTransferLib for WETH;
  using SafeTransferLib for ERC20;

  IPool public immutable pool;
  IGauge public immutable gauge;
  IVoter public immutable voter;
  IVotingEscrow public immutable votingEscrow;
  WETH public immutable weth;
  ERC20 public immutable exa;
  ERC20 public immutable velo;
  uint256 public immutable maxLockTime;

  constructor(
    IPool pool_,
    IGauge gauge_,
    IVoter voter_,
    IVotingEscrow votingEscrow_,
    ERC20 velo_,
    WETH weth_,
    ERC20 exa_,
    uint256 maxLockTime_
  ) {
    pool = pool_;
    gauge = gauge_;
    voter = voter_;
    votingEscrow = votingEscrow_;
    velo = velo_;
    weth = weth_;
    exa = exa_;
    maxLockTime = maxLockTime_;

    ERC20(address(pool)).safeApprove(address(gauge), type(uint256).max);
    velo.safeApprove(address(votingEscrow), type(uint256).max);
  }

  function stake(uint256 amountEXA) external payable {
    (uint256 reserve0, uint256 reserve1, ) = pool.getReserves();
    uint256 amountWETH = address(exa) < address(weth)
      ? (amountEXA * reserve1) / reserve0
      : (amountEXA * reserve0) / reserve1;
    weth.deposit{ value: amountWETH }();
    weth.safeTransfer(address(pool), amountWETH);
    exa.safeTransferFrom(msg.sender, address(pool), amountEXA);
    gauge.deposit(pool.mint(address(this)));

    uint256 earnedVELO = gauge.earned(address(this));
    if (earnedVELO > 0) {
      gauge.getReward(address(this));
      address[] memory poolVote = new address[](1);
      poolVote[0] = address(pool);
      uint256[] memory weights = new uint256[](1);
      weights[0] = 100e18;
      voter.vote(votingEscrow.createLock(earnedVELO, maxLockTime), poolVote, weights);
    }

    if (msg.value > amountWETH) {
      payable(msg.sender).transfer(msg.value - amountWETH);
    }
  }
}

interface IPool {
  function getReserves() external view returns (uint256 _reserve0, uint256 _reserve1, uint256 _blockTimestampLast);

  function mint(address to) external returns (uint256 liquidity);
}

interface IGauge {
  function deposit(uint256 _amount) external;

  function getReward(address _account) external;

  function earned(address _account) external view returns (uint256);
}

interface IVoter {
  function vote(uint256 _tokenId, address[] calldata _poolVote, uint256[] calldata _weights) external;

  function createGauge(address _poolFactory, address _pool) external returns (address);

  function whitelistToken(address _token, bool _bool) external;

  function distribute(address[] memory _gauges) external;

  function governor() external view returns (address);
}

interface IVotingEscrow {
  function createLock(uint256 _value, uint256 _lockDuration) external returns (uint256);
}
