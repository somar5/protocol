// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { SafeTransferLib } from "solmate/src/utils/SafeTransferLib.sol";
import { ERC20 } from "solmate/src/tokens/ERC20.sol";
import { FixedLib } from "./utils/FixedLib.sol";
import { Auditor } from "./Auditor.sol";
import { Market } from "./Market.sol";

contract RewardsController is AccessControl {
  using FixedPointMathLib for uint256;
  using FixedPointMathLib for int256;
  using SafeTransferLib for ERC20;

  /// @custom:oz-upgrades-unsafe-allow  state-variable-immutable
  Auditor public immutable auditor;
  // Map of rewarded operations and their distribution data
  mapping(Market => Distribution) internal distribution;
  // Map of reward assets
  mapping(address => bool) internal isRewardEnabled;
  // Rewards list
  address[] internal rewardList;
  // Map of operations by account
  mapping(address => mapping(Market => Operation[])) public accountOperations;

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor(Auditor auditor_) {
    auditor = auditor_;

    _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
  }

  function handleDeposit(address account) external {
    AccountOperation[] memory ops = new AccountOperation[](1);
    ops[0] = AccountOperation({ operation: Operation.Deposit, balance: Market(msg.sender).balanceOf(account) });
    update(account, Market(msg.sender), ops);
  }

  function handleBorrow(address account) external {
    AccountOperation[] memory ops = new AccountOperation[](1);
    (, , uint256 floatingBorrowShares) = Market(msg.sender).accounts(account);
    ops[0] = AccountOperation({
      operation: Operation.Borrow,
      balance: floatingBorrowShares + accountFixedBorrowShares(Market(msg.sender), account)
    });
    update(account, Market(msg.sender), ops);
  }

  function claimAll(address to) external returns (address[] memory rewardsList, uint256[] memory claimedAmounts) {
    return claim(allAccountOperations(msg.sender), to);
  }

  function claim(
    MarketOperation[] memory operations,
    address to
  ) public returns (address[] memory rewardsList, uint256[] memory claimedAmounts) {
    rewardsList = new address[](rewardList.length);
    claimedAmounts = new uint256[](rewardList.length);

    for (uint256 i = 0; i < operations.length; ++i) {
      update(
        msg.sender,
        operations[i].market,
        accountBalanceOperations(operations[i].market, operations[i].operations, msg.sender)
      );
      for (uint256 r = 0; r < rewardList.length; ++r) {
        if (rewardsList[r] == address(0)) rewardsList[r] = rewardList[r];

        for (uint256 o = 0; o < operations[i].operations.length; ++o) {
          uint256 rewardAmount = distribution[operations[i].market]
          .rewards[rewardsList[r]]
          .accounts[msg.sender][operations[i].operations[o]].accrued;
          if (rewardAmount != 0) {
            claimedAmounts[r] += rewardAmount;
            distribution[operations[i].market]
            .rewards[rewardsList[r]]
            .accounts[msg.sender][operations[i].operations[o]].accrued = 0;
          }
        }
      }
    }
    for (uint256 r = 0; r < rewardsList.length; ++r) {
      ERC20(rewardsList[r]).safeTransfer(to, claimedAmounts[r]);
      emit Claim(msg.sender, rewardsList[r], to, claimedAmounts[r]);
    }
    return (rewardsList, claimedAmounts);
  }

  function rewardsData(
    Market market,
    address reward
  ) external view returns (uint256, uint256, uint256, uint256, uint256) {
    return (
      distribution[market].rewards[reward].lastUpdate,
      distribution[market].rewards[reward].targetDebt,
      distribution[market].rewards[reward].mintingRate,
      distribution[market].rewards[reward].undistributedFactor,
      distribution[market].rewards[reward].lastUndistributed
    );
  }

  function rewardAllocationParams(
    Market market,
    address reward
  ) external view returns (uint256, uint256, uint256, uint256) {
    return (
      distribution[market].rewards[reward].decaySpeed,
      distribution[market].rewards[reward].compensationFactor,
      distribution[market].rewards[reward].borrowConstantReward,
      distribution[market].rewards[reward].depositConstantReward
    );
  }

  function decimals(Market market) external view returns (uint8) {
    return distribution[market].decimals;
  }

  function availableRewardsCount(Market market) external view returns (uint256) {
    return distribution[market].availableRewardsCount;
  }

  function allRewards() external view returns (address[] memory) {
    return rewardList;
  }

  function allAccountOperations(address account) public view returns (MarketOperation[] memory marketOps) {
    Market[] memory marketList = auditor.allMarkets();
    marketOps = new MarketOperation[](marketList.length);
    for (uint256 i = 0; i < marketList.length; ++i) {
      Operation[] memory ops = accountOperations[account][marketList[i]];
      marketOps[i] = MarketOperation({ market: marketList[i], operations: ops });
    }
  }

  function accountOperation(
    address account,
    Market market,
    Operation operation,
    address reward
  ) external view returns (uint256, uint256) {
    return (
      distribution[market].rewards[reward].accounts[account][operation].accrued,
      distribution[market].rewards[reward].accounts[account][operation].index
    );
  }

  function claimable(address account, address reward) external view returns (uint256 unclaimedRewards) {
    MarketOperation[] memory marketOps = allAccountOperations(account);
    for (uint256 i = 0; i < marketOps.length; ++i) {
      if (distribution[marketOps[i].market].availableRewardsCount == 0) continue;

      AccountOperation[] memory ops = accountBalanceOperations(marketOps[i].market, marketOps[i].operations, account);
      for (uint256 o = 0; o < ops.length; ++o) {
        unclaimedRewards += distribution[marketOps[i].market]
        .rewards[reward]
        .accounts[account][ops[o].operation].accrued;
      }
      unclaimedRewards += pendingRewards(
        account,
        reward,
        AccountMarketOperation({ market: marketOps[i].market, accountOperations: ops })
      );
    }
  }

  /// @notice Iterates and accrues all the rewards for the operations of the specific account
  /// @param account The account address
  /// @param market The market address
  /// @param ops The account's balance in the operation's pool
  function update(address account, Market market, AccountOperation[] memory ops) internal {
    uint256 baseUnit;
    unchecked {
      baseUnit = 10 ** distribution[market].decimals;
    }

    if (distribution[market].availableRewardsCount == 0) return;
    for (uint128 r = 0; r < distribution[market].availableRewardsCount; ++r) {
      address reward = distribution[market].availableRewards[r];
      RewardData storage rewardData = distribution[market].rewards[reward];
      {
        (uint256 depositIndex, uint256 borrowIndex, uint256 newUndistributed) = previewAllocation(rewardData, market);
        rewardData.lastUpdate = uint32(block.timestamp);
        rewardData.lastUndistributed = newUndistributed;
        rewardData.floatingDepositIndex = depositIndex;
        rewardData.floatingBorrowIndex = borrowIndex;
      }

      for (uint256 i = 0; i < ops.length; ++i) {
        uint256 accountIndex = rewardData.accounts[account][ops[i].operation].index;
        uint256 newAccountIndex;
        if (ops[i].balance == 0 && accountIndex == 0) {
          accountOperations[account][market].push(ops[i].operation);
        }
        if (ops[i].operation == Operation.Deposit) {
          newAccountIndex = rewardData.floatingDepositIndex;
        } else if (ops[i].operation == Operation.Borrow) {
          newAccountIndex = rewardData.floatingBorrowIndex;
        }
        if (accountIndex != newAccountIndex) {
          rewardData.accounts[account][ops[i].operation].index = uint104(newAccountIndex);
          if (ops[i].balance != 0) {
            uint256 rewardsAccrued = accountRewards(ops[i].balance, newAccountIndex, accountIndex, baseUnit);
            rewardData.accounts[account][ops[i].operation].accrued += uint128(rewardsAccrued);
            emit Accrue(market, reward, account, newAccountIndex, newAccountIndex, rewardsAccrued);
          }
        }
      }
    }
  }

  function totalFixedBorrowShares(Market market) internal view returns (uint256 fixedDebt) {
    uint256 distributionStart = distribution[market].start;
    uint256 firstMaturity = distributionStart - (distributionStart % FixedLib.INTERVAL) + FixedLib.INTERVAL;
    uint256 maxMaturity = block.timestamp -
      (block.timestamp % FixedLib.INTERVAL) +
      (FixedLib.INTERVAL * market.maxFuturePools());

    for (uint256 maturity = firstMaturity; maturity <= maxMaturity; maturity += FixedLib.INTERVAL) {
      fixedDebt += market.fixedPoolBorrowed(maturity);
    }
    fixedDebt = market.previewRepay(fixedDebt);
  }

  function accountFixedBorrowShares(Market market, address account) internal view returns (uint256 fixedDebt) {
    uint256 distributionStart = distribution[market].start;
    uint256 firstMaturity = distributionStart - (distributionStart % FixedLib.INTERVAL) + FixedLib.INTERVAL;
    uint256 maxMaturity = block.timestamp -
      (block.timestamp % FixedLib.INTERVAL) +
      (FixedLib.INTERVAL * market.maxFuturePools());

    for (uint256 maturity = firstMaturity; maturity <= maxMaturity; maturity += FixedLib.INTERVAL) {
      (uint256 principal, ) = market.fixedBorrowPositions(maturity, account);
      fixedDebt += principal;
    }
    fixedDebt = market.previewRepay(fixedDebt);
  }

  function rewardIndexes(Market market, address reward) external view returns (uint256, uint256) {
    return (
      distribution[market].rewards[reward].floatingBorrowIndex,
      distribution[market].rewards[reward].floatingDepositIndex
    );
  }

  /// @notice Calculates the pending (not yet accrued) rewards since the last account action
  /// @param account The address of the account
  /// @param reward The address of the reward token
  /// @param ops Struct with the account balance and total balance of the operation's pool
  /// @return rewards The pending rewards for the account since the last account action
  function pendingRewards(
    address account,
    address reward,
    AccountMarketOperation memory ops
  ) internal view returns (uint256 rewards) {
    RewardData storage rewardData = distribution[ops.market].rewards[reward];
    uint256 baseUnit = 10 ** distribution[ops.market].decimals;
    (uint256 depositIndex, uint256 borrowIndex, ) = previewAllocation(rewardData, ops.market);
    for (uint256 o = 0; o < ops.accountOperations.length; ++o) {
      uint256 nextIndex;
      if (ops.accountOperations[o].operation == Operation.Borrow) {
        nextIndex = borrowIndex;
      } else if (ops.accountOperations[o].operation == Operation.Deposit) {
        nextIndex = depositIndex;
      }

      rewards += accountRewards(
        ops.accountOperations[o].balance,
        nextIndex,
        rewardData.accounts[account][ops.accountOperations[o].operation].index,
        baseUnit
      );
    }
  }

  /// @notice Internal function for the calculation of account's rewards on a distribution
  /// @param balance The account's balance in the operation's pool
  /// @param reserveIndex Current index of the distribution
  /// @param accountIndex Index stored for the account, representation his staking moment
  /// @param baseUnit One unit of the market's asset (10**decimals)
  /// @return The rewards
  function accountRewards(
    uint256 balance,
    uint256 reserveIndex,
    uint256 accountIndex,
    uint256 baseUnit
  ) internal pure returns (uint256) {
    return balance.mulDivDown(reserveIndex - accountIndex, baseUnit);
  }

  function previewAllocation(
    RewardData storage rewardData,
    Market market
  ) internal view returns (uint256 depositIndex, uint256 borrowIndex, uint256 newUndistributed) {
    uint256 totalDebt = market.totalFloatingBorrowAssets();
    uint256 totalDeposits = market.totalAssets();
    {
      uint256 memMaxFuturePools = market.maxFuturePools();
      uint256 latestMaturity = block.timestamp - (block.timestamp % FixedLib.INTERVAL);
      uint256 maxMaturity = latestMaturity + memMaxFuturePools * FixedLib.INTERVAL;
      for (uint256 m = latestMaturity; m <= maxMaturity; m += FixedLib.INTERVAL) {
        (uint256 supplied, uint256 borrowed) = market.fixedPoolBalance(m);
        totalDeposits += supplied;
        totalDebt += borrowed;
      }
    }
    uint256 target;
    {
      uint256 targetDebt = rewardData.targetDebt;
      target = totalDebt < targetDebt ? totalDebt.divWadDown(targetDebt) : 1e18;
    }
    uint256 distributionFactor = rewardData.undistributedFactor.mulWadDown(target);
    if (distributionFactor > 0) {
      uint256 rewards;
      {
        uint256 lastUndistributed = rewardData.lastUndistributed;
        uint256 mintingRate = rewardData.mintingRate;
        uint256 deltaTime = block.timestamp - rewardData.lastUpdate;
        uint256 exponential = uint256((-int256(distributionFactor * deltaTime)).expWad());
        newUndistributed =
          lastUndistributed +
          mintingRate.mulWadDown(1e18 - target).divWadDown(distributionFactor).mulWadDown(1e18 - exponential) -
          lastUndistributed.mulWadDown(1e18 - exponential);
        rewards = rewardData.targetDebt.mulWadDown(
          uint256(int256(mintingRate * deltaTime) - (int256(newUndistributed) - int256(lastUndistributed)))
        );
      }
      {
        AllocationVars memory v;
        v.utilization = totalDeposits > 0 ? totalDebt.divWadDown(totalDeposits) : 0;
        v.adjustFactor = auditor.adjustFactor(market);
        v.sigmoid = v.utilization > 0
          ? uint256(1e18).divWadDown(
            1e18 +
              (1e18 - v.utilization).divWadDown(v.utilization).mulWadDown(
                (v.adjustFactor.mulWadDown(v.adjustFactor)).divWadDown(1e18 - v.adjustFactor.mulWadDown(v.adjustFactor))
              ) **
                rewardData.decaySpeed /
              1e18 ** (rewardData.decaySpeed - 1)
          )
          : 0;
        v.borrowRewardRule = rewardData
          .compensationFactor
          .mulWadDown(
            market.interestRateModel().floatingRate(v.utilization).mulWadDown(
              1e18 - v.utilization.mulWadDown(1e18 - target)
            ) + rewardData.borrowConstantReward
          )
          .mulWadDown(1e18 - v.sigmoid);
        v.depositRewardRule =
          rewardData.depositConstantReward +
          (v.adjustFactor.mulWadDown(v.adjustFactor))
            .divWadDown(1e18 - v.adjustFactor.mulWadDown(v.adjustFactor))
            .mulWadDown(rewardData.borrowConstantReward)
            .mulWadDown(v.sigmoid);
        v.borrowAllocation = v.borrowRewardRule.divWadDown(v.borrowRewardRule + v.depositRewardRule);
        v.depositAllocation = 1e18 - v.borrowAllocation;
        {
          uint256 totalDepositSupply = market.totalSupply();
          uint256 totalBorrowSupply = market.totalFloatingBorrowShares() + totalFixedBorrowShares(market);
          depositIndex =
            rewardData.floatingDepositIndex +
            (
              totalDepositSupply > 0
                ? rewards.mulWadDown(v.depositAllocation).mulDivDown(10 ** market.decimals(), totalDepositSupply)
                : 0
            );
          borrowIndex =
            rewardData.floatingBorrowIndex +
            (
              totalBorrowSupply > 0
                ? rewards.mulWadDown(v.borrowAllocation).mulDivDown(10 ** market.decimals(), totalBorrowSupply)
                : 0
            );
        }
      }
    } else {
      depositIndex = rewardData.floatingDepositIndex;
      borrowIndex = rewardData.floatingBorrowIndex;
      newUndistributed = rewardData.lastUndistributed;
    }
  }

  /// @notice Get account balances and total supply of all the operations specified by the markets and operations
  /// parameters
  /// @param market The address of the market
  /// @param ops List of operations to retrieve account balance and total supply
  /// @param account Address of the account
  /// @return accountMaturityOps contains a list of structs with account balance and total amount of the
  /// operation's pool
  function accountBalanceOperations(
    Market market,
    Operation[] memory ops,
    address account
  ) internal view returns (AccountOperation[] memory accountMaturityOps) {
    accountMaturityOps = new AccountOperation[](ops.length);
    for (uint256 i = 0; i < ops.length; ++i) {
      if (ops[i] == Operation.Deposit) {
        accountMaturityOps[i] = AccountOperation({ operation: ops[i], balance: market.balanceOf(account) });
      } else if (ops[i] == Operation.Borrow) {
        (, , uint256 floatingBorrowShares) = market.accounts(account);
        accountMaturityOps[i] = AccountOperation({
          operation: ops[i],
          balance: floatingBorrowShares + accountFixedBorrowShares(market, account)
        });
      }
    }
  }

  function config(Config[] memory configs) external onlyRole(DEFAULT_ADMIN_ROLE) {
    for (uint256 i = 0; i < configs.length; ++i) {
      RewardData storage rewardConfig = distribution[configs[i].market].rewards[configs[i].reward];

      // Add reward address to distribution data's available rewards if latestUpdateTimestamp is zero
      if (rewardConfig.lastUpdate == 0) {
        distribution[configs[i].market].availableRewards[
          distribution[configs[i].market].availableRewardsCount
        ] = configs[i].reward;
        distribution[configs[i].market].availableRewardsCount++;
        distribution[configs[i].market].decimals = configs[i].market.decimals();
        rewardConfig.floatingDepositIndex = 1;
        rewardConfig.floatingBorrowIndex = 1;
        rewardConfig.lastUpdate = uint32(block.timestamp);
      }
      if (distribution[configs[i].market].start == 0) {
        distribution[configs[i].market].start = uint32(block.timestamp);
      }

      // Add reward address to global rewards list if still not enabled
      if (isRewardEnabled[configs[i].reward] == false) {
        isRewardEnabled[configs[i].reward] = true;
        rewardList.push(configs[i].reward);
      }

      // Configure emission and distribution end of the reward per operation
      rewardConfig.targetDebt = configs[i].targetDebt;
      rewardConfig.undistributedFactor = configs[i].undistributedFactor;
      rewardConfig.decaySpeed = configs[i].decaySpeed;
      rewardConfig.compensationFactor = configs[i].compensationFactor;
      rewardConfig.borrowConstantReward = configs[i].borrowConstantReward;
      rewardConfig.depositConstantReward = configs[i].depositConstantReward;
      rewardConfig.mintingRate = configs[i].totalDistribution.divWadDown(configs[i].targetDebt).mulWadDown(
        uint256(1e18) / configs[i].distributionPeriod
      );

      emit DistributionSet(configs[i].market, configs[i].reward, 0);
    }
  }

  enum Operation {
    Deposit,
    Borrow
  }

  struct AllocationVars {
    uint256 utilization;
    uint256 adjustFactor;
    uint256 sigmoid;
    uint256 borrowRewardRule;
    uint256 depositRewardRule;
    uint256 borrowAllocation;
    uint256 depositAllocation;
  }

  struct AccountOperation {
    Operation operation;
    uint256 balance;
  }

  struct MarketOperation {
    Market market;
    Operation[] operations;
  }

  struct AccountMarketOperation {
    Market market;
    AccountOperation[] accountOperations;
  }

  struct Account {
    // Liquidity index of the reward distribution for the account
    uint104 index;
    // Amount of accrued rewards for the account since last account index update
    uint128 accrued;
  }

  struct Config {
    Market market;
    address reward;
    uint256 targetDebt;
    uint256 totalDistribution;
    uint256 distributionPeriod;
    uint256 undistributedFactor;
    uint256 decaySpeed;
    uint256 compensationFactor;
    uint256 borrowConstantReward;
    uint256 depositConstantReward;
  }

  struct RewardData {
    // distribution model
    uint256 targetDebt;
    uint256 mintingRate;
    uint256 undistributedFactor;
    uint256 lastUndistributed;
    uint32 lastUpdate;
    // allocation model
    uint256 decaySpeed;
    uint256 compensationFactor;
    uint256 borrowConstantReward;
    uint256 depositConstantReward;
    // Liquidity index of the reward distribution
    uint256 floatingBorrowIndex;
    uint256 floatingDepositIndex;
    // Map of account addresses and their rewards data (accountAddress => accounts)
    mapping(address => mapping(Operation => Account)) accounts;
  }

  struct Distribution {
    // Map of reward token addresses and their data (rewardTokenAddress => rewardData)
    mapping(address => RewardData) rewards;
    // List of reward asset addresses for the operation
    mapping(uint128 => address) availableRewards;
    // Count of reward tokens for the operation
    uint128 availableRewardsCount;
    // Number of decimals of the operation's asset
    uint8 decimals;
    uint32 start;
  }

  event Accrue(
    Market indexed market,
    address indexed reward,
    address indexed account,
    uint256 operationIndex,
    uint256 accountIndex,
    uint256 rewardsAccrued
  );
  event Claim(address indexed account, address indexed reward, address indexed to, uint256 amount);
  event DistributionSet(Market indexed market, address indexed reward, uint256 operationIndex);
}
