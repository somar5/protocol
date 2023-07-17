// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { Test, stdJson } from "forge-std/Test.sol";
import { MockERC20 } from "solmate/src/test/utils/mocks/MockERC20.sol";
import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { Swapper, ERC20, WETH, IRouter } from "../../contracts/periphery/Swapper.sol";

contract StakingTest is Test {
  using stdJson for string;
  using FixedPointMathLib for uint256;

  ERC20 internal weth;
  IPool internal pool;
  MockERC20 internal exa;
  Swapper internal swapper;
  IRouter internal constant router = IRouter(0xa062aE8A9c5e11aaA026fc2670B0D65cCc8B2858);
  IPoolFactory internal constant factory = IPoolFactory(0xF1046053aa5682b4F9a81b5481394DA16BE5FF5a);

  function setUp() external {
    vm.createSelectFork(vm.envString("OPTIMISM_NODE"), 106_835_444);

    weth = ERC20(deployment("WETH"));
    exa = new MockERC20("EXA", "EXA", 18);

    deal(address(weth), address(this), 500 ether);
    exa.mint(address(this), 1_000_000 ether);

    exa.approve(address(router), type(uint256).max);
    weth.approve(address(router), type(uint256).max);
    pool = IPool(factory.createPool(address(exa), address(weth), false));
    router.addLiquidity(
      address(exa),
      address(weth),
      false,
      exa.balanceOf(address(this)),
      weth.balanceOf(address(this)),
      0,
      0,
      address(this),
      block.timestamp + 1
    );
    swapper = new Swapper(address(factory), router, WETH(payable(address(weth))), exa);
  }

  function testSwap() external _checkBalance {
    uint256 ethBalance = address(this).balance;
    (uint256 reserve0, uint256 reserve1, ) = pool.getReserves();
    uint256 amountOut = reserve1.divWadDown(reserve0).mulWadDown(1 ether);
    swapper.swap{ value: 1 ether }(payable(address(this)), 0, 0);

    assertApproxEqRel(exa.balanceOf(address(this)), amountOut, 3 ether);
    assertEq(address(this).balance, ethBalance - 1 ether);
  }

  function testSwapWithGasAmount() external _checkBalance {
    uint256 ethBalance = address(this).balance;
    (uint256 reserve0, uint256 reserve1, ) = pool.getReserves();
    uint256 amountOut = reserve1.divWadDown(reserve0).mulWadDown(0.5 ether);
    swapper.swap{ value: 1 ether }(payable(address(this)), 0, 0.5 ether);

    assertApproxEqRel(exa.balanceOf(address(this)), amountOut, 3 ether);
    assertEq(address(this).balance, ethBalance - 0.5 ether);
  }

  function testSwapWithGasEqualToValue() external _checkBalance {
    uint256 ethBalance = address(this).balance;
    swapper.swap{ value: 2 ether }(payable(address(this)), 0, 2 ether);

    assertEq(exa.balanceOf(address(this)), 0);
    assertEq(address(this).balance, ethBalance);
  }

  function testSwapWithGasHigherThanValue() external _checkBalance {
    uint256 ethBalance = address(this).balance;
    swapper.swap{ value: 1 ether }(payable(address(this)), 0, 2 ether);

    assertEq(exa.balanceOf(address(this)), 0);
    assertEq(address(this).balance, ethBalance);
  }

  function testSwapWithInaccurateSlippageSendsEthToAccount() external _checkBalance {
    uint256 ethBalance = address(this).balance;
    (uint256 reserve0, uint256 reserve1, ) = pool.getReserves();
    uint256 amountOut = reserve1.divWadDown(reserve0).mulWadDown(1 ether);

    swapper.swap{ value: 1 ether }(payable(address(this)), amountOut * 5, 0);
    assertEq(address(this).balance, ethBalance);
    assertEq(exa.balanceOf(address(this)), 0);

    swapper.swap{ value: 1 ether }(payable(address(this)), amountOut - 10 ether, 0);
    assertApproxEqRel(exa.balanceOf(address(this)), amountOut, 3 ether);
    assertEq(address(this).balance, ethBalance - 1 ether);
  }

  modifier _checkBalance() {
    _;
    assertEq(address(swapper).balance, 0);
  }

  function deployment(string memory name) internal returns (address addr) {
    addr = vm.readFile(string.concat("deployments/optimism/", name, ".json")).readAddress(".address");
    vm.label(addr, name);
  }

  receive() external payable {}
}

interface IPool {
  function getReserves() external view returns (uint256 _reserve0, uint256 _reserve1, uint256 _blockTimestampLast);
}

interface IPoolFactory {
  function createPool(address tokenA, address tokenB, bool stable) external returns (address pool);
}
