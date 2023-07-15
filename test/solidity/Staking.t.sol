// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { Test, stdJson } from "forge-std/Test.sol";
import { MockERC20 } from "solmate/src/test/utils/mocks/MockERC20.sol";
import { Staking, ERC20, WETH, IPool, IGauge, IVotingEscrow, IVoter } from "../../contracts/Staking.sol";

contract StakingTest is Test {
  using stdJson for string;

  ERC20 internal lp;
  ERC20 internal weth;
  MockERC20 internal exa;
  bool internal stable;
  IGauge internal gauge;
  Staking internal staking;
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
    lp = ERC20(factory.createPool(address(exa), address(weth), stable));
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

    staking = new Staking(
      IPool(address(lp)),
      gauge,
      voter,
      votingEscrow,
      velo,
      WETH(payable(address(weth))),
      exa,
      365 days * 4
    );

    exa.approve(address(staking), type(uint256).max);
    lp.approve(address(gauge), type(uint256).max);
    velo.approve(address(votingEscrow), type(uint256).max);

    gauge.deposit(lp.balanceOf(address(this)));

    address[] memory poolVote = new address[](1);
    poolVote[0] = address(lp);
    uint256[] memory weights = new uint256[](1);
    weights[0] = 100e18;
    voter.vote(votingEscrow.createLock(velo.balanceOf(address(this)), 365 days * 4), poolVote, weights);
  }

  function testStake() external {
    uint256 exaBalance = exa.balanceOf(address(this));
    uint256 etherBalance = address(this).balance;
    uint256 gaugeLpBalance = lp.balanceOf(address(gauge));
    staking.stake{ value: 5 ether }(10_000 ether);

    assertEq(exa.balanceOf(address(this)), exaBalance - 10_000 ether);
    assertEq(address(this).balance, etherBalance - 5 ether);
    assertGt(lp.balanceOf(address(gauge)), gaugeLpBalance);
  }

  function testStakeAndHarvestGaugeEmissions() external {
    staking.stake{ value: 5 ether }(10_000 ether);

    vm.warp(block.timestamp + 1 weeks);
    address[] memory gauges = new address[](1);
    gauges[0] = address(gauge);
    voter.distribute(gauges);

    vm.warp(block.timestamp + 1);
    assertGt(gauge.earned(address(staking)), 0);
    staking.stake{ value: 0.05 ether }(100 ether);
    assertEq(gauge.earned(address(staking)), 0);
  }

  function testStakeWithHigherValueThanNeeded() external {
    uint256 exaBalance = exa.balanceOf(address(this));
    uint256 etherBalance = address(this).balance;
    staking.stake{ value: 500 ether }(10_000 ether);

    assertEq(exa.balanceOf(address(this)), exaBalance - 10_000 ether);
    assertEq(address(this).balance, etherBalance - 5 ether);
  }

  function testStakeWithLowerValueThanNeeded() external {
    vm.expectRevert(bytes(""));
    staking.stake{ value: 0.5 ether }(10_000 ether);
  }

  function testZeroStake() external {
    vm.expectRevert(abi.encodeWithSignature("InsufficientLiquidityMinted()"));
    staking.stake{ value: 0.5 ether }(0);
  }

  function deployment(string memory name) internal returns (address addr) {
    addr = vm.readFile(string.concat("deployments/optimism/", name, ".json")).readAddress(".address");
    vm.label(addr, name);
  }

  receive() external payable {}
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
