// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { Test } from "forge-std/Test.sol";
import { IPriceFeed } from "../../contracts/utils/IPriceFeed.sol";
import { DeployScript, Auditor, Market } from "../../scripts/Deploy.s.sol";

contract DeployTest is Test {
  DeployScript internal deploy;

  function setUp() external {
    deploy = new DeployScript();
    deploy.run();
  }

  function testMarketsAreDeployedAndEnabled() external {
    Auditor auditor = deploy.auditor();
    Market marketDAI = deploy.marketDAI();
    Market marketWBTC = deploy.marketWBTC();
    (, , , bool enabledDAI, IPriceFeed priceFeedDAI) = auditor.markets(marketDAI);
    (, , , bool enabledWBTC, IPriceFeed priceFeedWBTC) = auditor.markets(marketWBTC);
    assertTrue(enabledDAI);
    assertTrue(enabledWBTC);
    assertEq(address(priceFeedDAI), address(deploy.priceFeedDAI()));
    assertEq(address(priceFeedWBTC), address(deploy.priceFeedWBTC()));
  }
}
