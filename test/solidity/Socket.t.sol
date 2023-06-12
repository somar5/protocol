// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { ForkTest, stdJson } from "./Fork.t.sol";
import {
  DebtManager,
  Market,
  ERC20,
  Auditor,
  IPermit2,
  IBalancerVault
} from "../../contracts/periphery/DebtManager.sol";

contract SocketTest is ForkTest {
  using Address for address;
  using stdJson for string;

  uint256 internal constant ASSETS = 420_000e6;
  uint256 internal constant BOB_KEY = 0xb0b;
  address internal bob;

  DebtManager internal debtManager;
  Market internal marketUSDC;
  ERC20 internal usdc;

  function setUp() external {
    vm.createSelectFork(vm.envString("OPTIMISM_NODE"), 105_372_119);
    marketUSDC = Market(deployment("MarketUSDC"));
    usdc = marketUSDC.asset();
    debtManager = DebtManager(
      address(
        new ERC1967Proxy(
          address(
            new DebtManager(
              Auditor(deployment("Auditor")),
              IPermit2(deployment("Permit2")),
              IBalancerVault(deployment("BalancerVault")),
              deployment("UniswapV3Factory")
            )
          ),
          abi.encodeCall(DebtManager.initialize, ())
        )
      )
    );

    deal(address(usdc), address(this), ASSETS);
    usdc.approve(address(marketUSDC), ASSETS);

    bob = vm.addr(BOB_KEY);
    vm.label(bob, "bob");
  }

  function testSocketDeposit() external {
    socketCall(address(marketUSDC), abi.encodeCall(marketUSDC.deposit, (ASSETS, bob)));
    assertEq(marketUSDC.maxWithdraw(bob), ASSETS - 1);
  }

  function socketCall(address target, bytes memory payload) internal {
    target.functionCall(payload, "");
    assertEq(usdc.balanceOf(address(this)), 0);
  }
}
