// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { Test, stdJson } from "forge-std/Test.sol";
import { MockERC20 } from "solmate/src/test/utils/mocks/MockERC20.sol";
import { ERC20 } from "solmate/src/tokens/ERC20.sol";

contract StakingTest is Test {
  using stdJson for string;

  ERC20 internal weth;
  MockERC20 internal exa;
  bool internal stable;
  IGauge internal gauge;
  ERC20 internal constant velo = ERC20(0x9560e827aF36c94D2Ac33a39bCE1Fe78631088Db);
  IVoter internal constant voter = IVoter(0x41C914ee0c7E1A5edCD0295623e6dC557B5aBf3C);
  IRouter internal constant router = IRouter(0xa062aE8A9c5e11aaA026fc2670B0D65cCc8B2858);
  IPoolFactory internal constant factory = IPoolFactory(0xF1046053aa5682b4F9a81b5481394DA16BE5FF5a);
  IVotingEscrow internal constant votingEscrow = IVotingEscrow(0xFAf8FD17D9840595845582fCB047DF13f006787d);

  function setUp() external {
    vm.createSelectFork(vm.envString("OPTIMISM_NODE"), 106_835_444);

    weth = ERC20(deployment("WETH"));
    exa = new MockERC20("EXA", "EXA", 18);
    stable = false;

    deal(address(velo), address(this), 10_000_000 ether);
    deal(address(weth), address(this), 500 ether);
    exa.mint(address(this), 10_000_000 ether);

    exa.approve(address(router), type(uint256).max);
    weth.approve(address(router), type(uint256).max);
    ERC20 lp = ERC20(factory.createPool(address(exa), address(weth), stable));
    router.addLiquidity(
      address(exa),
      address(weth),
      stable,
      1_000_000 ether,
      500 ether,
      0,
      0,
      address(this),
      block.timestamp + 1
    );
    vm.prank(voter.governor());
    voter.whitelistToken(address(exa), true);
    gauge = IGauge(voter.createGauge(address(factory), address(lp)));
    lp.approve(address(gauge), type(uint256).max);
    gauge.deposit(lp.balanceOf(address(this)));
    velo.approve(address(votingEscrow), type(uint256).max);
    uint256 veVELOTokenId = votingEscrow.createLock(velo.balanceOf(address(this)), 365 days * 4);
    address[] memory poolVote = new address[](1);
    poolVote[0] = address(lp);
    uint256[] memory weights = new uint256[](1);
    weights[0] = 100e18;
    voter.vote(veVELOTokenId, poolVote, weights);
  }

  function testClaimGaugeEmissions() external {
    assertEq(gauge.earned(address(this)), 0);
    assertEq(velo.balanceOf(address(this)), 0);
    address[] memory gauges = new address[](1);
    gauges[0] = address(gauge);

    vm.warp(block.timestamp + 1 weeks);
    voter.distribute(gauges);

    vm.warp(block.timestamp + 1);
    uint256 emissions = gauge.earned(address(this));
    assertGt(emissions, 0);
    gauge.getReward(address(this));
    assertEq(velo.balanceOf(address(this)), emissions);
  }

  function deployment(string memory name) internal returns (address addr) {
    addr = vm.readFile(string.concat("deployments/optimism/", name, ".json")).readAddress(".address");
    vm.label(addr, name);
  }
}

interface IRouter {
  function addLiquidity(
    address tokenA,
    address tokenB,
    bool stable,
    uint256 amountADesired,
    uint256 amountBDesired,
    uint256 amountAMin,
    uint256 amountBMin,
    address to,
    uint256 deadline
  ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);
}

interface IPoolFactory {
  function createPool(address tokenA, address tokenB, bool stable) external returns (address pool);
}

interface IVoter {
  function vote(uint256 _tokenId, address[] calldata _poolVote, uint256[] calldata _weights) external;

  function createGauge(address _poolFactory, address _pool) external returns (address);

  function whitelistToken(address _token, bool _bool) external;

  function distribute(address[] memory _gauges) external;

  function governor() external view returns (address);
}

interface IGauge {
  function deposit(uint256 _amount) external;

  function getReward(address _account) external;

  function earned(address _account) external view returns (uint256);
}

interface IVotingEscrow {
  function createLock(uint256 _value, uint256 _lockDuration) external returns (uint256);
}
