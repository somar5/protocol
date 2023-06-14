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
  Permit,
  IPermit2,
  IBalancerVault,
  IUniswapQuoter
} from "../../contracts/periphery/DebtManager.sol";
import { Forwarder } from "../../contracts/periphery/Forwarder.sol";

contract ForwarderTest is ForkTest {
  using Address for address;
  using stdJson for string;

  uint256 internal constant ASSETS = 420_000e6;
  uint256 internal constant BOB_KEY = 0xb0b;
  address internal bob;

  DebtManager internal debtManager;
  Forwarder internal forwarder;
  Market internal marketUSDC;
  ERC20 internal usdc;

  function setUp() external {
    vm.createSelectFork(vm.envString("OPTIMISM_NODE"), 105_372_119);
    marketUSDC = Market(deployment("MarketUSDC"));
    usdc = ERC20(deployment("USDC"));
    debtManager = DebtManager(
      address(
        new ERC1967Proxy(
          address(
            new DebtManager(
              Auditor(deployment("Auditor")),
              IPermit2(deployment("Permit2")),
              IBalancerVault(deployment("BalancerVault")),
              deployment("UniswapV3Factory"),
              IUniswapQuoter(address(0))
            )
          ),
          abi.encodeCall(DebtManager.initialize, ())
        )
      )
    );
    forwarder = new Forwarder(debtManager);
    vm.label(address(debtManager), "DebtManager");

    deal(address(usdc), address(this), ASSETS);

    bob = vm.addr(BOB_KEY);
    vm.label(bob, "bob");
  }

  function testForwardDeposit() external {
    socketCall(address(forwarder), abi.encodeCall(forwarder.deposit, (marketUSDC, bob)));
    assertEq(marketUSDC.maxWithdraw(bob), ASSETS - 1);
  }

  function testForwardLeverage() external {
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(
      BOB_KEY,
      keccak256(
        abi.encodePacked(
          "\x19\x01",
          marketUSDC.DOMAIN_SEPARATOR(),
          keccak256(
            abi.encode(
              keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
              bob,
              debtManager,
              666_666e6,
              marketUSDC.nonces(bob),
              block.timestamp
            )
          )
        )
      )
    );
    socketCall(
      address(forwarder),
      abi.encodeCall(forwarder.leverage, (marketUSDC, 1.5e18, 666_666e6, Permit(bob, block.timestamp, v, r, s)))
    );
  }

  function socketCall(address target, bytes memory payload) internal {
    usdc.approve(target, ASSETS);
    target.functionCall(payload, "");
    assertEq(usdc.balanceOf(address(this)), 0);
  }
}
