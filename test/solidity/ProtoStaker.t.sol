// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { ForkTest } from "./Fork.t.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { ITransparentUpgradeableProxy, ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import { ProtoStaker, ERC20, WETH, EXA, IPool, IGauge, Permit } from "../../contracts/periphery/ProtoStaker.sol";
import { RewardsController, ClaimPermit } from "../../contracts/RewardsController.sol";
import { Market } from "../../contracts/Market.sol";

contract ProtoStakerTest is ForkTest {
  address internal pool;
  address internal bob;
  ERC20 internal gauge;
  ERC20 internal weth;
  ERC20 internal exa;
  ProtoStaker internal protoStaker;
  RewardsController internal rewardsController;
  Market internal marketUSDC;

  IVoter internal constant voter = IVoter(0x41C914ee0c7E1A5edCD0295623e6dC557B5aBf3C);
  uint256 internal constant BOB_KEY = 0xb0b;

  function setUp() external _checkBalances {
    vm.createSelectFork(vm.envString("OPTIMISM_NODE"), 107_353_677);

    weth = ERC20(deployment("WETH"));
    exa = ERC20(deployment("EXA"));
    pool = deployment("EXAPool");
    bob = vm.addr(BOB_KEY);
    gauge = ERC20(voter.gauges(pool));
    marketUSDC = Market(deployment("MarketUSDC"));
    deal(address(marketUSDC.asset()), address(this), 100_000e6);
    marketUSDC.asset().approve(address(marketUSDC), type(uint256).max);
    marketUSDC.deposit(100_000e6, bob);

    deal(address(exa), bob, 500 ether);
    payable(bob).transfer(500 ether);

    rewardsController = RewardsController(deployment("RewardsController"));
    protoStaker = ProtoStaker(
      address(
        new ERC1967Proxy(
          address(
            new ProtoStaker(
              rewardsController,
              IGauge(address(gauge)),
              IPool(pool),
              WETH(payable(address(weth))),
              EXA(address(exa))
            )
          ),
          abi.encodeCall(ProtoStaker.initialize, ())
        )
      )
    );
    vm.startPrank(deployment("ProxyAdmin"));
    ITransparentUpgradeableProxy(payable(address(rewardsController))).upgradeTo(address(new RewardsController()));
    vm.stopPrank();
  }

  function testAddLiquidityWithExactETH() external _checkBalances {
    uint256 amountETHBefore = bob.balance;
    uint256 amountEXABefore = exa.balanceOf(address(bob));
    uint256 amountEXA = 100 ether;
    uint256 amountETH = protoStaker.previewETH(amountEXA);
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(
      BOB_KEY,
      keccak256(
        abi.encodePacked(
          "\x19\x01",
          exa.DOMAIN_SEPARATOR(),
          keccak256(
            abi.encode(
              keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
              bob,
              protoStaker,
              amountEXA,
              exa.nonces(bob),
              block.timestamp
            )
          )
        )
      )
    );
    vm.prank(bob);
    protoStaker.addBalance{ value: amountETH }(Permit(payable(bob), amountEXA, block.timestamp, v, r, s));

    assertGt(gauge.balanceOf(address(bob)), 0);
    assertEq(exa.balanceOf(address(bob)), amountEXABefore - amountEXA);
    assertEq(bob.balance, amountETHBefore - amountETH);
  }

  function testAddLiquidityWithLessETH() external _checkBalances {
    uint256 amountETHBefore = bob.balance;
    uint256 amountEXABefore = exa.balanceOf(address(bob));
    uint256 amountEXA = 100 ether;
    uint256 amountETH = protoStaker.previewETH(amountEXA);
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(
      BOB_KEY,
      keccak256(
        abi.encodePacked(
          "\x19\x01",
          exa.DOMAIN_SEPARATOR(),
          keccak256(
            abi.encode(
              keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
              bob,
              protoStaker,
              amountEXA,
              exa.nonces(bob),
              block.timestamp
            )
          )
        )
      )
    );
    vm.prank(bob);
    protoStaker.addBalance{ value: amountETH - 0.05 ether }(Permit(payable(bob), amountEXA, block.timestamp, v, r, s));

    assertEq(gauge.balanceOf(address(bob)), 0);
    assertEq(exa.balanceOf(address(bob)), amountEXABefore);
    assertEq(bob.balance, amountETHBefore);
  }

  function testAddLiquidityWithMoreETH() external _checkBalances {
    uint256 amountETHBefore = bob.balance;
    uint256 amountEXABefore = exa.balanceOf(address(bob));
    uint256 amountEXA = 100 ether;
    uint256 amountETH = protoStaker.previewETH(amountEXA);
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(
      BOB_KEY,
      keccak256(
        abi.encodePacked(
          "\x19\x01",
          exa.DOMAIN_SEPARATOR(),
          keccak256(
            abi.encode(
              keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
              bob,
              protoStaker,
              amountEXA,
              exa.nonces(bob),
              block.timestamp
            )
          )
        )
      )
    );
    vm.prank(bob);
    protoStaker.addBalance{ value: amountETH + 1 ether }(Permit(payable(bob), amountEXA, block.timestamp, v, r, s));

    assertGt(gauge.balanceOf(address(bob)), 0);
    assertEq(exa.balanceOf(address(bob)), amountEXABefore - amountEXA);
    assertEq(bob.balance, amountETHBefore - amountETH);
  }

  function testAddRewardWithExactETH() external _checkBalances {
    skip(4 weeks);
    uint256 amountETHBefore = bob.balance;
    uint256 amountEXA = rewardsController.allClaimable(address(bob), exa);
    uint256 amountETH = protoStaker.previewETH(amountEXA);

    bool[] memory ops = new bool[](2);
    ops[0] = false;
    ops[1] = true;
    ERC20[] memory assets = new ERC20[](1);
    assets[0] = exa;

    ClaimPermit memory permit;
    permit.owner = bob;
    permit.spender = address(protoStaker.pool());
    permit.assets = assets;
    permit.deadline = block.timestamp;
    (permit.v, permit.r, permit.s) = vm.sign(
      BOB_KEY,
      keccak256(
        abi.encodePacked(
          "\x19\x01",
          rewardsController.DOMAIN_SEPARATOR(),
          keccak256(
            abi.encode(
              keccak256("ClaimPermit(address owner,address spender,address[] assets,uint256 deadline)"),
              permit.owner,
              permit.spender,
              permit.assets,
              uint256(keccak256(abi.encode(permit.owner, permit.spender, permit.assets, permit.deadline))),
              permit.deadline
            )
          )
        )
      )
    );

    vm.prank(bob);
    protoStaker.addReward{ value: amountETH }(permit);

    assertGt(gauge.balanceOf(address(bob)), 0);
    assertEq(rewardsController.allClaimable(address(bob), exa), 0);
    assertEq(bob.balance, amountETHBefore - amountETH);
  }

  function testAddRewardWithLessETH() external _checkBalances {
    skip(4 weeks);
    uint256 amountETHBefore = bob.balance;
    uint256 amountEXABefore = exa.balanceOf(address(bob));
    uint256 amountEXA = rewardsController.allClaimable(address(bob), exa);
    uint256 amountETH = protoStaker.previewETH(amountEXA);

    bool[] memory ops = new bool[](2);
    ops[0] = false;
    ops[1] = true;
    ERC20[] memory assets = new ERC20[](1);
    assets[0] = exa;

    ClaimPermit memory permit;
    permit.owner = bob;
    permit.spender = address(protoStaker.pool());
    permit.assets = assets;
    permit.deadline = block.timestamp;
    (permit.v, permit.r, permit.s) = vm.sign(
      BOB_KEY,
      keccak256(
        abi.encodePacked(
          "\x19\x01",
          rewardsController.DOMAIN_SEPARATOR(),
          keccak256(
            abi.encode(
              keccak256("ClaimPermit(address owner,address spender,address[] assets,uint256 deadline)"),
              permit.owner,
              permit.spender,
              permit.assets,
              uint256(keccak256(abi.encode(permit.owner, permit.spender, permit.assets, permit.deadline))),
              permit.deadline
            )
          )
        )
      )
    );

    vm.prank(bob);
    protoStaker.addReward{ value: amountETH - 0.1 ether }(permit);

    assertEq(gauge.balanceOf(address(bob)), 0);
    assertEq(rewardsController.allClaimable(address(bob), exa), 0);
    assertEq(bob.balance, amountETHBefore);
    assertEq(exa.balanceOf(address(bob)), amountEXABefore + amountEXA);
  }

  function testAddRewardWithMoreETH() external _checkBalances {
    skip(4 weeks);
    uint256 amountETHBefore = bob.balance;
    uint256 amountEXA = rewardsController.allClaimable(address(bob), exa);
    uint256 amountETH = protoStaker.previewETH(amountEXA);

    bool[] memory ops = new bool[](2);
    ops[0] = false;
    ops[1] = true;
    ERC20[] memory assets = new ERC20[](1);
    assets[0] = exa;

    ClaimPermit memory permit;
    permit.owner = bob;
    permit.spender = address(protoStaker.pool());
    permit.assets = assets;
    permit.deadline = block.timestamp;
    (permit.v, permit.r, permit.s) = vm.sign(
      BOB_KEY,
      keccak256(
        abi.encodePacked(
          "\x19\x01",
          rewardsController.DOMAIN_SEPARATOR(),
          keccak256(
            abi.encode(
              keccak256("ClaimPermit(address owner,address spender,address[] assets,uint256 deadline)"),
              permit.owner,
              permit.spender,
              permit.assets,
              uint256(keccak256(abi.encode(permit.owner, permit.spender, permit.assets, permit.deadline))),
              permit.deadline
            )
          )
        )
      )
    );

    vm.prank(bob);
    protoStaker.addReward{ value: amountETH + 2 ether }(permit);

    assertGt(gauge.balanceOf(address(bob)), 0);
    assertEq(rewardsController.allClaimable(address(bob), exa), 0);
    assertEq(bob.balance, amountETHBefore - amountETH);
  }

  modifier _checkBalances() {
    _;
    assertEq(ERC20(pool).balanceOf(address(protoStaker)), 0);
    assertEq(gauge.balanceOf(address(protoStaker)), 0);
    assertEq(weth.balanceOf(address(protoStaker)), 0);
    assertEq(exa.balanceOf(address(protoStaker)), 0);
  }

  receive() external payable {}
}

interface IVoter {
  function gauges(address) external view returns (address);
}
