// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Test, stdError } from "forge-std/Test.sol";
import { WETH } from "solmate/src/tokens/WETH.sol";
import { MockInterestRateModel } from "../../contracts/mocks/MockInterestRateModel.sol";
import { Auditor, IPriceFeed } from "../../contracts/Auditor.sol";
import { InterestRateModel } from "../../contracts/InterestRateModel.sol";
import { Market, FixedLib } from "../../contracts/Market.sol";
import { MarketETHRouter } from "../../contracts/MarketETHRouter.sol";

contract MarketETHRouterTest is Test {
  MarketETHRouter internal router;
  Market internal market;

  function setUp() external {
    Auditor auditor = Auditor(address(new ERC1967Proxy(address(new Auditor(18)), "")));
    auditor.initialize(Auditor.LiquidationIncentive(0.09e18, 0.01e18));
    market = Market(address(new ERC1967Proxy(address(new Market(new WETH(), auditor)), "")));
    market.initialize(
      3,
      1e18,
      InterestRateModel(address(new MockInterestRateModel(0.1e18))),
      0.02e18 / uint256(1 days),
      1e17,
      0,
      0.0046e18,
      0.42e18
    );
    auditor.enableMarket(market, IPriceFeed(auditor.BASE_FEED()), 0.9e18);
    router = MarketETHRouter(payable(address(new ERC1967Proxy(address(new MarketETHRouter(market)), ""))));
    router.initialize();

    market.approve(address(router), type(uint256).max);
  }

  function testDepositToFloatingPool() external {
    vm.expectEmit(true, true, true, true, address(market));
    emit Deposit(address(router), address(this), 1 ether, 1 ether);
    router.deposit{ value: 1 ether }();
  }

  function testWithdrawRedeemFromFloatingPool() external {
    router.deposit{ value: 1 ether }();

    vm.expectEmit(true, true, true, true, address(market));
    emit Withdraw(address(router), address(router), address(this), 0.5 ether, 0.5 ether);
    router.withdraw(0.5 ether);

    vm.expectEmit(true, true, true, true, address(market));
    emit Withdraw(address(router), address(router), address(this), 0.5 ether, 0.5 ether);
    router.redeem(market.balanceOf(address(this)));
  }

  function testBorrowFromFloatingPool() external {
    router.deposit{ value: 1 ether }();

    vm.expectEmit(true, true, true, true, address(market));
    emit Borrow(address(router), address(router), address(this), 0.3 ether, 0.3 ether);
    router.borrow(0.3 ether);
  }

  function testRepayRefundToFloatingPool() external {
    router.deposit{ value: 1 ether }();
    router.borrow(0.3 ether);

    vm.expectEmit(true, true, true, true, address(market));
    emit Repay(address(router), address(this), 0.15 ether, 0.15 ether);
    router.repay{ value: 0.15 ether }(0.15 ether);

    vm.expectEmit(true, true, true, true, address(market));
    emit Repay(address(router), address(this), 0.15 ether, 0.15 ether);
    router.refund{ value: 0.15 ether }(0.15 ether);
  }

  function testDepositAtMaturity() external {
    vm.expectEmit(true, true, true, true, address(market));
    emit DepositAtMaturity(FixedLib.INTERVAL, address(router), address(this), 1 ether, 0);
    router.depositAtMaturity{ value: 1 ether }(FixedLib.INTERVAL, 1 ether);
  }

  function testBorrowRepayAtMaturity() external {
    router.deposit{ value: 1 ether }();

    vm.warp(1 days);
    vm.expectEmit(true, true, true, true, address(market));
    emit BorrowAtMaturity(FixedLib.INTERVAL, address(router), address(router), address(this), 0.1 ether, 0.01 ether);
    router.borrowAtMaturity(FixedLib.INTERVAL, 0.1 ether, 2 ether);

    vm.expectEmit(true, true, true, true, address(market));
    emit RepayAtMaturity(FixedLib.INTERVAL, address(router), address(this), 0.101 ether, 0.11 ether);
    router.repayAtMaturity{ value: 0.11 ether }(FixedLib.INTERVAL, 0.11 ether);
  }

  receive() external payable {}

  event DepositAtMaturity(
    uint256 indexed maturity,
    address indexed caller,
    address indexed owner,
    uint256 assets,
    uint256 fee
  );
  event BorrowAtMaturity(
    uint256 indexed maturity,
    address caller,
    address indexed receiver,
    address indexed borrower,
    uint256 assets,
    uint256 fee
  );
  event RepayAtMaturity(
    uint256 indexed maturity,
    address indexed caller,
    address indexed borrower,
    uint256 assets,
    uint256 positionAssets
  );
  event Deposit(address indexed caller, address indexed owner, uint256 assets, uint256 shares);
  event Withdraw(
    address indexed caller,
    address indexed receiver,
    address indexed owner,
    uint256 assets,
    uint256 shares
  );
  event Borrow(
    address indexed caller,
    address indexed receiver,
    address indexed borrower,
    uint256 assets,
    uint256 shares
  );
  event Repay(address indexed caller, address indexed borrower, uint256 assets, uint256 shares);
}
