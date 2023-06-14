// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { ForkTest, stdJson } from "./Fork.t.sol";
import {
  DebtManager,
  Market,
  ERC20,
  Permit,
  Auditor,
  IPermit2,
  IBalancerVault,
  IUniswapQuoter
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
              deployment("UniswapV3Factory"),
              IUniswapQuoter(deployment("UniswapQuoter"))
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

  function testSocketLeverage() external {
    usdc.approve(address(debtManager), ASSETS);

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
              ASSETS * 2,
              marketUSDC.nonces(bob),
              block.timestamp
            )
          )
        )
      )
    );

    socketCall(
      address(debtManager),
      abi.encodeCall(ILeverage.leverage, (marketUSDC, ASSETS, 2e18, ASSETS * 2, Permit(bob, block.timestamp, v, r, s)))
    );
    assertEq(marketUSDC.maxWithdraw(bob), ASSETS * 3 - 2);
  }

  function socketCall(address target, bytes memory payload) internal {
    target.functionCall(payload, "");
    assertEq(usdc.balanceOf(address(this)), 0);
  }
}

interface ILeverage {
  function leverage(
    Market market,
    uint256 deposit,
    uint256 multiplier,
    uint256 borrowAssets,
    Permit calldata marketPermit
  ) external;
}
