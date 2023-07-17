// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { WETH } from "solmate/src/tokens/WETH.sol";
import { ERC20 } from "solmate/src/tokens/ERC20.sol";

contract Swapper {
  /// @notice The factory used to create the liquidity pool.
  address public immutable factory;
  /// @notice The router used to swap assets.
  IRouter public immutable router;
  /// @notice The WETH asset.
  WETH public immutable weth;
  /// @notice The EXA asset.
  ERC20 public immutable exa;

  constructor(address factory_, IRouter router_, WETH weth_, ERC20 exa_) {
    factory = factory_;
    router = router_;
    weth = weth_;
    exa = exa_;
  }

  /// @notice Swaps `msg.value` ETH for EXA and sends it to `account`.
  /// @param account The account to send the EXA to.
  /// @param amountOutMin The minimum amount of EXA to receive.
  /// @param gas The amount of ETH to send to `account` for gas.
  function swap(address payable account, uint256 amountOutMin, uint256 gas) external payable {
    if (gas > msg.value) {
      account.transfer(msg.value);
      return;
    }

    Route[] memory routes = new Route[](1);
    routes[0] = Route({ from: address(weth), to: address(exa), stable: false, factory: factory });
    try router.swapExactETHForTokens{ value: msg.value - gas }(amountOutMin, routes, account, block.timestamp) {
      account.transfer(gas);
    } catch {
      account.transfer(msg.value);
    }
  }
}

struct Route {
  address from;
  address to;
  bool stable;
  address factory;
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

  function swapExactETHForTokens(
    uint256 amountOutMin,
    Route[] calldata routes,
    address to,
    uint256 deadline
  ) external payable returns (uint256[] memory amounts);
}
