// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { MockERC20 } from "solmate/src/test/utils/mocks/MockERC20.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { MockPriceFeed } from "../contracts/mocks/MockPriceFeed.sol";
import { Market, Auditor, InterestRateModel } from "../contracts/Market.sol";

contract DeployScript {
  Market public marketDAI;
  Market public marketWBTC;
  Auditor public auditor;
  MockERC20 public dai;
  MockERC20 public wbtc;
  MockPriceFeed public priceFeedDAI;
  MockPriceFeed public priceFeedWBTC;
  InterestRateModel public irmDAI;
  InterestRateModel public irmWBTC;

  function run() external {
    dai = new MockERC20("DAI", "DAI", 18);
    wbtc = new MockERC20("WBTC", "WBTC", 8);

    auditor = Auditor(
      address(
        new ERC1967Proxy(
          address(new Auditor(18)),
          abi.encodeCall(Auditor.initialize, (Auditor.LiquidationIncentive(0.09e18, 0.01e18)))
        )
      )
    );

    irmDAI = new InterestRateModel(0.3617e18, -0.3591e18, 1.0015e18, 0.0263e18, -0.0228e18, 1.0172e18);
    marketDAI = Market(
      address(
        new ERC1967Proxy(
          address(new Market(dai, auditor)),
          abi.encodeCall(
            Market.initialize,
            (3, 1e18, InterestRateModel(address(irmDAI)), 0.02e18 / uint256(1 days), 1e17, 0, 0.0046e18, 0.42e18)
          )
        )
      )
    );
    priceFeedDAI = new MockPriceFeed(18, 1e18);

    irmWBTC = new InterestRateModel(0.3468e18, -0.341e18, 1.0003e18, 0.0438e18, -0.033e18, 1.0173e18);
    marketWBTC = Market(
      address(
        new ERC1967Proxy(
          address(new Market(wbtc, auditor)),
          abi.encodeCall(
            Market.initialize,
            (12, 1e18, InterestRateModel(address(irmWBTC)), 0.02e18 / uint256(1 days), 1e17, 0, 0.0046e18, 0.42e18)
          )
        )
      )
    );
    priceFeedWBTC = new MockPriceFeed(18, 20_000e18);

    auditor.enableMarket(marketDAI, priceFeedDAI, 0.8e18);
    auditor.enableMarket(marketWBTC, priceFeedWBTC, 0.9e18);
  }
}
