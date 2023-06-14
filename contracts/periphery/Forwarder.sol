// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { DebtManager, Market, ERC20, Permit } from "./DebtManager.sol";

contract Forwarder {
  DebtManager public immutable debtManager;

  constructor(DebtManager debtManager_) {
    debtManager = debtManager_;
  }

  function deposit(Market market, address account) external {
    market.deposit(transferIn(market.asset(), address(market)), account);
  }

  function leverage(Market market, uint256 ratio, uint256 borrowAssets, Permit calldata marketPermit) external {
    debtManager.leverage(market, transferIn(market.asset(), address(debtManager)), ratio, borrowAssets, marketPermit);
  }

  function transferIn(ERC20 asset, address spender) internal returns (uint256 amount) {
    amount = asset.allowance(msg.sender, address(this));
    asset.transferFrom(msg.sender, address(this), amount);
    asset.approve(spender, amount);
  }
}
