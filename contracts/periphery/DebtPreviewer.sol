// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { MathUpgradeable as Math } from "@openzeppelin/contracts-upgradeable/utils/math/MathUpgradeable.sol";
import { Previewer, FixedLib } from "./Previewer.sol";
import {
  ERC20,
  Market,
  Auditor,
  IPriceFeed,
  DebtManager,
  IUniswapV3Pool,
  PoolAddress,
  PoolKey
} from "./DebtManager.sol";

/// @title DebtPreviewer
/// @notice Contract to be consumed by Exactly's front-end dApp as a helper for `DebtManager`.
contract DebtPreviewer is Initializable {
  using FixedPointMathLib for uint256;

  /// @dev The minimum value that can be returned from #getSqrtRatioAtTick. Equivalent to getSqrtRatioAtTick(MIN_TICK)
  uint160 internal constant MIN_SQRT_RATIO = 4295128739;
  /// @dev The maximum value that can be returned from #getSqrtRatioAtTick. Equivalent to getSqrtRatioAtTick(MAX_TICK)
  uint160 internal constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

  /// @notice DebtManager contract to be used to get Auditor, BalancerVault and UniswapV3Factory addresses.
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  DebtManager public immutable debtManager;
  /// @notice Quoter contract to be used to preview the amount of assets to be swapped.
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  IUniswapQuoter public immutable uniswapV3Quoter;
  /// @notice Mapping of Uniswap pools to their respective pool fee.
  mapping(address => mapping(address => uint24)) public poolFees;

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor(DebtManager debtManager_, IUniswapQuoter uniswapV3Quoter_) {
    debtManager = debtManager_;
    uniswapV3Quoter = uniswapV3Quoter_;
  }

  /// @notice Initializes the contract.
  /// @dev can only be called once.
  function initialize(Pool[] memory pools, uint24[] memory fees) external initializer {
    assert(pools.length == fees.length);
    for (uint256 i = 0; i < pools.length; ) {
      PoolKey memory poolKey = PoolAddress.getPoolKey(pools[i].tokenA, pools[i].tokenB, fees[i]);
      poolFees[poolKey.token0][poolKey.token1] = poolKey.fee;

      unchecked {
        ++i;
      }
    }
  }

  /// @notice Returns the output received for a given exact amount of a single pool swap.
  /// @param assetIn The address of the token to be swapped.
  /// @param assetOut The address of the token to receive.
  /// @param amountIn The exact amount of `assetIn` to be swapped.
  /// @param fee The fee of the pool that will be used to swap the assets.
  /// @return amountOut The amount of `assetOut` received.
  function previewInputSwap(
    address assetIn,
    address assetOut,
    uint256 amountIn,
    uint24 fee
  ) external returns (uint256) {
    return
      uniswapV3Quoter.quoteExactInputSingle(
        assetIn,
        assetOut,
        fee,
        amountIn,
        assetIn == PoolAddress.getPoolKey(assetIn, assetOut, fee).token0 ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1
      );
  }

  /// @notice Returns the input for an exact amount out of a single pool swap.
  /// @param assetIn The address of the token to be swapped.
  /// @param assetOut The address of the token to receive.
  /// @param amountOut The exact amount of `amountOut` to be swapped.
  /// @param fee The fee of the pool that will be used to swap the assets.
  /// @return amountIn The amount of `amountIn` received.
  function previewOutputSwap(
    address assetIn,
    address assetOut,
    uint256 amountOut,
    uint24 fee
  ) public returns (uint256) {
    return
      amountOut > 0
        ? uniswapV3Quoter.quoteExactOutputSingle(
          assetIn,
          assetOut,
          fee,
          amountOut,
          assetIn == PoolAddress.getPoolKey(assetIn, assetOut, fee).token0 ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1
        )
        : 0;
  }

  /// @notice Returns extended data useful to leverage or deleverage an account principal position.
  /// @param marketDeposit The deposit Market.
  /// @param marketBorrow The borrow Market.
  /// @param account The account operating with the `DebtManager`.
  /// @param minHealthFactor The minimum health factor that the account must have after the leverage.
  /// @return extended leverage data.
  function leverage(
    Market marketDeposit,
    Market marketBorrow,
    address account,
    uint256 minHealthFactor
  ) external returns (Leverage memory) {
    (, , uint256 floatingBorrowShares) = marketBorrow.accounts(account);
    uint256 deposit = marketDeposit.maxWithdraw(account);
    uint256 memMinDeposit = minDeposit(marketDeposit, marketBorrow, account, minHealthFactor);
    int256 principal = crossPrincipal(marketDeposit, marketBorrow, account);
    PoolKey memory poolKey = PoolAddress.getPoolKey(address(marketDeposit.asset()), address(marketBorrow.asset()), 0);
    poolKey.fee = poolFees[poolKey.token0][poolKey.token1];
    uint256 sqrtPriceX96;
    if (address(marketDeposit) != address(marketBorrow)) {
      (sqrtPriceX96, , , , , , ) = IUniswapV3Pool(PoolAddress.computeAddress(debtManager.uniswapV3Factory(), poolKey))
        .slot0();
    }

    return
      Leverage({
        borrow: marketBorrow.previewRefund(floatingBorrowShares),
        deposit: deposit,
        principal: principal,
        ratio: principal > 0 ? deposit.divWadDown(uint256(principal)) : 0,
        maxRatio: maxRatio(
          marketDeposit,
          marketBorrow,
          account,
          principal > 0 ? uint256(principal) : 0,
          minHealthFactor
        ),
        minDeposit: deposit >= memMinDeposit ? 0 : memMinDeposit - deposit,
        maxWithdraw: principal > 0 ? maxWithdraw(marketDeposit, marketBorrow, account) : 0,
        pool: poolKey,
        sqrtPriceX96: sqrtPriceX96,
        availableAssets: balancerAvailableLiquidity()
      });
  }

  /// @notice Returns minimum deposit based on account's current debt and a given health factor.
  /// @param marketDeposit The deposit Market.
  /// @param marketBorrow The borrow Market.
  /// @param account The account operating with the markets.
  /// @param minHealthFactor The health factor that the account must have with the minimum deposit, isolated.
  function minDeposit(
    Market marketDeposit,
    Market marketBorrow,
    address account,
    uint256 minHealthFactor
  ) internal view returns (uint256) {
    MinDepositVars memory vars;
    Auditor auditor = debtManager.auditor();
    (vars.adjustFactorIn, , , , vars.priceFeedIn) = auditor.markets(marketDeposit);
    (vars.adjustFactorOut, , , , vars.priceFeedOut) = auditor.markets(marketBorrow);

    return
      minHealthFactor
        .mulWadDown(floatingBorrowAssets(marketBorrow, account))
        .mulDivDown(auditor.assetPrice(vars.priceFeedOut), 10 ** marketBorrow.decimals())
        .divWadDown(vars.adjustFactorOut.mulWadDown(vars.adjustFactorIn))
        .mulDivUp(10 ** marketDeposit.decimals(), auditor.assetPrice(vars.priceFeedIn));
  }

  /// @notice Returns the maximum ratio that an account can leverage its principal plus `assets` amount.
  /// @param marketDeposit The deposit Market.
  /// @param marketBorrow The borrow Market.
  /// @param account The account that will be leveraged.
  /// @param deposit The amount of assets that will be added to the principal.
  /// @param ratio The ratio to be previewed.
  /// @param minHealthFactor The minimum health factor that the account must have after the leverage.
  function previewLeverage(
    Market marketDeposit,
    Market marketBorrow,
    address account,
    uint256 deposit,
    uint256 ratio,
    uint256 minHealthFactor
  ) external returns (Limit memory limit) {
    uint256 currentRatio;
    (limit.principal, currentRatio, limit.maxRatio) = previewRatio(
      marketDeposit,
      marketBorrow,
      account,
      int256(deposit),
      minHealthFactor
    );

    limit.ratio = (ratio < currentRatio || ratio > limit.maxRatio) ? currentRatio : ratio;
    PoolKey memory poolKey = PoolAddress.getPoolKey(address(marketDeposit.asset()), address(marketBorrow.asset()), 0);
    poolKey.fee = poolFees[poolKey.token0][poolKey.token1];
    if (limit.principal <= 0) {
      limit.borrow = floatingBorrowAssets(marketBorrow, account);
      limit.deposit = marketDeposit.maxWithdraw(account) + deposit;
      return limit;
    }
    limit.deposit = uint256(limit.principal).mulWadUp(limit.ratio);
    limit.borrow = address(marketDeposit) == address(marketBorrow)
      ? uint256(limit.principal).mulWadDown(limit.ratio - 1e18)
      : floatingBorrowAssets(marketBorrow, account) +
        previewOutputSwap(
          address(marketBorrow.asset()),
          address(marketDeposit.asset()),
          limit.deposit - marketDeposit.maxWithdraw(account) - deposit,
          poolKey.fee
        );
  }

  /// @notice Returns the maximum ratio that an account can deleverage its principal minus `assets` amount.
  /// @param marketDeposit The deposit Market.
  /// @param marketBorrow The borrow Market.
  /// @param account The account that will be deleveraged.
  /// @param withdraw The amount of assets that will be withdrawn from the principal.
  /// @param ratio The ratio to be previewed.
  /// @param minHealthFactor The minimum health factor that the account must have after the leverage.
  function previewDeleverage(
    Market marketDeposit,
    Market marketBorrow,
    address account,
    uint256 withdraw,
    uint256 ratio,
    uint256 minHealthFactor
  ) external returns (Limit memory limit) {
    if ((limit.principal = crossPrincipal(marketDeposit, marketBorrow, account)) < 0) revert InvalidPreview();
    uint256 memMaxWithdraw = maxWithdraw(marketDeposit, marketBorrow, account);
    if (withdraw <= uint256(limit.principal)) {
      limit.principal -= int256(withdraw);
      limit.maxRatio = maxRatio(marketDeposit, marketBorrow, account, uint256(limit.principal), minHealthFactor);
    } else if (withdraw <= memMaxWithdraw) {
      limit.principal = int256(memMaxWithdraw - withdraw);
      limit.maxRatio = limit.principal > 0
        ? maxRatio(marketDeposit, marketBorrow, account, uint256(limit.principal), minHealthFactor)
        : 1e18;
    } else revert InvalidPreview();

    limit.ratio = ratio > limit.maxRatio ? limit.maxRatio : ratio;

    uint256 borrowRepay = floatingBorrowAssets(marketBorrow, account) -
      previewAssetsOut(marketDeposit, marketBorrow, uint256(limit.principal).mulWadDown(limit.ratio - 1e18));

    PoolKey memory poolKey = PoolAddress.getPoolKey(address(marketDeposit.asset()), address(marketBorrow.asset()), 0);
    limit.borrow = floatingBorrowAssets(marketBorrow, account) - borrowRepay;
    limit.deposit =
      marketDeposit.maxWithdraw(account) -
      withdraw -
      (
        marketDeposit == marketBorrow
          ? borrowRepay
          : previewOutputSwap(
            address(marketDeposit.asset()),
            address(marketBorrow.asset()),
            borrowRepay,
            poolFees[poolKey.token0][poolKey.token1]
          )
      );
  }

  /// @notice Returns principal, current ratio and max ratio, considering assets to add or substract.
  /// @param marketDeposit The deposit Market.
  /// @param marketBorrow The borrow Market.
  /// @param account The account to preview the ratio.
  /// @param assets The amount of assets that will be added or subtracted to the principal.
  /// @param minHealthFactor The minimum health factor that the account should have with the max ratio.
  function previewRatio(
    Market marketDeposit,
    Market marketBorrow,
    address account,
    int256 assets,
    uint256 minHealthFactor
  ) internal view returns (int256 principal, uint256 current, uint256 max) {
    principal = crossPrincipal(marketDeposit, marketBorrow, account) + assets;
    if (principal > 0) {
      current = uint256(int256(marketDeposit.maxWithdraw(account)) + assets).divWadUp(uint256(principal));
      max = maxRatio(marketDeposit, marketBorrow, account, uint256(principal), minHealthFactor);
    } else {
      max = maxRatio(marketDeposit, marketBorrow, account, 0, minHealthFactor);
    }
  }

  /// @notice Returns the amount of `marketBorrow` underlying assets considering `amountIn` and assets oracle prices.
  /// @param marketDeposit The market of the assets accounted as `amountIn`.
  /// @param marketBorrow The market of the assets that will be returned.
  /// @param amountIn The amount of `marketDeposit` underlying assets.
  function previewAssetsOut(
    Market marketDeposit,
    Market marketBorrow,
    uint256 amountIn
  ) internal view returns (uint256) {
    (, , , , IPriceFeed priceFeedIn) = debtManager.auditor().markets(marketDeposit);
    (, , , , IPriceFeed priceFeedOut) = debtManager.auditor().markets(marketBorrow);
    return
      amountIn.mulDivDown(debtManager.auditor().assetPrice(priceFeedIn), 10 ** marketDeposit.decimals()).mulDivDown(
        10 ** marketBorrow.decimals(),
        debtManager.auditor().assetPrice(priceFeedOut)
      );
  }

  /// @notice Returns the maximum ratio that an account can leverage its principal position.
  /// @param marketDeposit The deposit Market.
  /// @param marketBorrow The borrow Market.
  /// @param account The account that will be leveraged.
  /// @param principal The principal amount that will be leveraged.
  /// @param minHealthFactor The minimum health factor that the account must have after the leverage.
  function maxRatio(
    Market marketDeposit,
    Market marketBorrow,
    address account,
    uint256 principal,
    uint256 minHealthFactor
  ) internal view returns (uint256) {
    RatioVars memory r;
    Auditor auditor = debtManager.auditor();

    uint256 marketMap = auditor.accountMarkets(account);
    for (uint256 i = 0; marketMap != 0; marketMap >>= 1) {
      if (marketMap & 1 != 0) {
        Market market = auditor.marketList(i);
        Auditor.MarketData memory m;
        Auditor.AccountLiquidity memory vars;
        (m.adjustFactor, m.decimals, , , m.priceFeed) = auditor.markets(market);
        vars.price = auditor.assetPrice(m.priceFeed);
        (, vars.borrowBalance) = market.accountSnapshot(account);

        if (market == marketBorrow) {
          (, , uint256 floatingBorrowShares) = market.accounts(account);
          vars.borrowBalance -= market.previewRefund(floatingBorrowShares);
        }
        r.adjustedDebt += vars.borrowBalance.mulDivUp(vars.price, 10 ** m.decimals).divWadUp(m.adjustFactor);
      }
      unchecked {
        ++i;
      }
    }

    (r.adjustFactorIn, , , , ) = auditor.markets(marketDeposit);
    (r.adjustFactorOut, , , , ) = auditor.markets(marketBorrow);
    (, , , , IPriceFeed priceFeedIn) = auditor.markets(marketDeposit);
    r.adjustedDebt = r.adjustedDebt.mulWadDown(r.adjustFactorOut).mulDivDown(
      10 ** marketDeposit.decimals(),
      auditor.assetPrice(priceFeedIn)
    );
    if (
      principal == 0 ||
      r.adjustedDebt > principal ||
      (principal - r.adjustedDebt).divWadDown(
        principal - principal.mulWadDown(r.adjustFactorIn).mulWadDown(r.adjustFactorOut).divWadDown(minHealthFactor)
      ) <
      1e18
    ) {
      return minHealthFactor.divWadDown(minHealthFactor - r.adjustFactorIn.mulWadDown(r.adjustFactorOut));
    }
    return
      (principal - r.adjustedDebt).divWadDown(
        principal - principal.mulWadDown(r.adjustFactorIn).mulWadDown(r.adjustFactorOut).divWadDown(minHealthFactor)
      );
  }

  function floatingBorrowAssets(Market market, address account) internal view returns (uint256) {
    (, , uint256 floatingBorrowShares) = market.accounts(account);
    return market.previewRefund(floatingBorrowShares);
  }

  /// @notice Returns the maximum amount that an account can withdraw when leveraged, repaying the full borrow.
  /// @param marketDeposit The deposit Market.
  /// @param marketBorrow The borrow Market.
  /// @param account The account to preview.
  function maxWithdraw(Market marketDeposit, Market marketBorrow, address account) internal returns (uint256) {
    Auditor auditor = debtManager.auditor();

    MaxWithdrawVars memory mw;
    mw.marketMap = auditor.accountMarkets(account);
    for (mw.i = 0; mw.marketMap != 0; mw.marketMap >>= 1) {
      if (mw.marketMap & 1 != 0) {
        Auditor.MarketData memory md;
        Auditor.AccountLiquidity memory vars;

        mw.market = auditor.marketList(mw.i);
        (md.adjustFactor, md.decimals, , , md.priceFeed) = auditor.markets(mw.market);
        (vars.balance, vars.borrowBalance) = mw.market.accountSnapshot(account);
        vars.price = auditor.assetPrice(md.priceFeed);

        mw.adjustedCollateral += vars.balance.mulDivDown(vars.price, 10 ** md.decimals).mulWadDown(md.adjustFactor);
        mw.adjustedDebt += vars.borrowBalance.mulDivUp(vars.price, 10 ** md.decimals).divWadUp(md.adjustFactor);

        uint256 borrowAssets = floatingBorrowAssets(marketBorrow, account);

        if (mw.market == marketBorrow) {
          mw.adjustedRepay = borrowAssets.mulDivUp(vars.price, 10 ** md.decimals).divWadUp(md.adjustFactor);
        }
        if (mw.market == marketDeposit) {
          mw.adjustedPrincipalToRepayDebt = (
            borrowAssets > 0 && marketBorrow != marketDeposit
              ? previewOutputSwap(address(marketDeposit.asset()), address(marketBorrow.asset()), borrowAssets, 500)
              : borrowAssets
          ).mulDivDown(vars.price, 10 ** md.decimals).mulWadDown(md.adjustFactor);
          mw.adjustedPrincipal =
            (mw.market.maxWithdraw(account)).mulDivDown(vars.price, 10 ** md.decimals).mulWadDown(md.adjustFactor) -
            mw.adjustedPrincipalToRepayDebt;
        }
      }
      unchecked {
        ++mw.i;
      }
    }
    (mw.adjustFactorIn, , , , mw.priceFeedIn) = auditor.markets(marketDeposit);

    return
      Math
        .min(
          mw.adjustedCollateral + mw.adjustedRepay - mw.adjustedDebt - mw.adjustedPrincipalToRepayDebt,
          mw.adjustedPrincipal
        )
        .mulDivDown(10 ** marketDeposit.decimals(), auditor.assetPrice(mw.priceFeedIn))
        .divWadDown(mw.adjustFactorIn);
  }

  /// @notice Calculates the crossed principal amount for a given `account` in the input and output markets.
  /// @param marketDeposit The Market to withdraw the leveraged position.
  /// @param marketBorrow The Market to repay the leveraged position.
  /// @param account The account that will be deleveraged.
  function crossPrincipal(Market marketDeposit, Market marketBorrow, address account) internal view returns (int256) {
    (, , , , IPriceFeed priceFeedIn) = debtManager.auditor().markets(marketDeposit);
    (, , , , IPriceFeed priceFeedOut) = debtManager.auditor().markets(marketBorrow);

    uint256 collateral = marketDeposit.maxWithdraw(account);
    uint256 debt = floatingBorrowAssets(marketBorrow, account)
      .mulDivDown(debtManager.auditor().assetPrice(priceFeedOut), 10 ** marketBorrow.decimals())
      .mulDivDown(10 ** marketDeposit.decimals(), debtManager.auditor().assetPrice(priceFeedIn));
    return int256(collateral) - int256(debt);
  }

  /// @notice Returns Balancer Vault's available liquidity of each enabled underlying asset.
  function balancerAvailableLiquidity() internal view returns (AvailableAsset[] memory availableAssets) {
    uint256 marketsCount = debtManager.auditor().allMarkets().length;
    availableAssets = new AvailableAsset[](marketsCount);

    for (uint256 i = 0; i < marketsCount; i++) {
      ERC20 asset = debtManager.auditor().marketList(i).asset();
      availableAssets[i] = AvailableAsset({
        asset: asset,
        liquidity: asset.balanceOf(address(debtManager.balancerVault()))
      });
    }
  }

  /// @notice returns rates based on inputs and leverage ratio impact on the borrow market
  /// @param marketDeposit The deposit Market.
  /// @param marketBorrow The borrow Market.
  /// @param account The account to preview.
  /// @param assets The amount of assets that should be added or substracted to the principal.
  /// @param targetRatio The target ratio to preview.
  /// @param depositRate The current deposit rate of the deposit market.
  /// @param nativeRate The current native rate of the deposit market.
  function leverageRates(
    Market marketDeposit,
    Market marketBorrow,
    address account,
    int256 assets,
    uint256 targetRatio,
    uint256 depositRate,
    uint256 nativeRate
  ) external view returns (Rates memory rates) {
    int256 principal = crossPrincipal(marketDeposit, marketBorrow, account) + assets;
    if (principal <= 0) revert InvalidPreview();

    uint256 currentRatio = uint256(int256(marketDeposit.maxWithdraw(account)) + assets).divWadDown(uint256(principal));
    uint256 utilization;
    if (targetRatio < currentRatio) {
      uint256 depositDecrease = uint256(principal).mulWadDown(currentRatio - targetRatio);
      uint256 borrowRepay = previewAssetsOut(marketDeposit, marketBorrow, depositDecrease);
      utilization = (marketBorrow.totalFloatingBorrowAssets() - borrowRepay).divWadUp(
        marketBorrow.totalAssets() - (marketDeposit == marketBorrow ? depositDecrease : 0)
      );
    } else {
      uint256 depositIncrease = uint256(principal).mulWadDown(targetRatio - currentRatio);
      uint256 newBorrow = previewAssetsOut(marketDeposit, marketBorrow, depositIncrease);
      utilization = (marketBorrow.totalFloatingBorrowAssets() + newBorrow).divWadUp(
        marketBorrow.totalAssets() + (marketDeposit == marketBorrow ? depositIncrease : 0)
      );
    }
    rates.borrow = marketBorrow.interestRateModel().floatingRate(utilization).mulWadDown(targetRatio - 1e18);
    rates.deposit = depositRate.mulWadDown(targetRatio);
    rates.native = nativeRate.mulWadDown(targetRatio);

    {
      uint256 i;
      if (marketDeposit == marketBorrow) {
        RewardRate[] memory rewards = rewardRates(marketDeposit);
        rates.rewards = new RewardRate[](rewards.length);
        for (; i < rewards.length; ) {
          rates.rewards[i].deposit = rewards[i].deposit.mulWadDown(targetRatio);
          rates.rewards[i].borrow = rewards[i].borrow.mulWadDown(targetRatio - 1e18);
          rates.rewards[i].asset = rewards[i].asset;
          rates.rewards[i].assetName = rewards[i].assetName;
          rates.rewards[i].assetSymbol = rewards[i].assetSymbol;
          unchecked {
            ++i;
          }
        }
      } else {
        RewardRate[] memory depositRewards = rewardRates(marketDeposit);
        RewardRate[] memory borrowRewards = rewardRates(marketBorrow);
        rates.rewards = new RewardRate[](depositRewards.length + borrowRewards.length);
        for (i = 0; i < depositRewards.length; ) {
          rates.rewards[i].deposit = depositRewards[i].deposit.mulWadDown(targetRatio);
          rates.rewards[i].asset = depositRewards[i].asset;
          rates.rewards[i].assetName = depositRewards[i].assetName;
          rates.rewards[i].assetSymbol = depositRewards[i].assetSymbol;
          unchecked {
            ++i;
          }
        }
        for (i = 0; i < borrowRewards.length; ) {
          rates.rewards[i + depositRewards.length].borrow = borrowRewards[i].borrow.mulWadDown(targetRatio - 1e18);
          rates.rewards[i + depositRewards.length].asset = borrowRewards[i].asset;
          rates.rewards[i + depositRewards.length].assetName = borrowRewards[i].assetName;
          rates.rewards[i + depositRewards.length].assetSymbol = borrowRewards[i].assetSymbol;
          unchecked {
            ++i;
          }
        }
      }
    }
  }

  function rewardRates(Market market) internal view returns (RewardRate[] memory rewards) {
    Previewer.RewardsVars memory r;
    r.controller = market.rewardsController();
    if (address(r.controller) != address(0)) {
      (, r.underlyingDecimals, , , r.underlyingPriceFeed) = market.auditor().markets(market);
      unchecked {
        r.underlyingBaseUnit = 10 ** r.underlyingDecimals;
      }
      r.deltaTime = 1 hours;
      r.rewardList = r.controller.allRewards();
      rewards = new RewardRate[](r.rewardList.length);
      for (r.i = 0; r.i < r.rewardList.length; ++r.i) {
        r.config = r.controller.rewardConfig(market, r.rewardList[r.i]);
        (r.borrowIndex, r.depositIndex, ) = r.controller.rewardIndexes(market, r.rewardList[r.i]);
        (r.projectedBorrowIndex, r.projectedDepositIndex, ) = r.controller.previewAllocation(
          market,
          r.rewardList[r.i],
          block.timestamp > r.config.start ? r.deltaTime : 0
        );
        (r.start, , ) = r.controller.distributionTime(market, r.rewardList[r.i]);
        r.firstMaturity = r.start - (r.start % FixedLib.INTERVAL) + FixedLib.INTERVAL;
        r.maxMaturity =
          block.timestamp -
          (block.timestamp % FixedLib.INTERVAL) +
          (FixedLib.INTERVAL * market.maxFuturePools());
        r.maturities = new uint256[]((r.maxMaturity - r.firstMaturity) / FixedLib.INTERVAL + 1);
        r.start = 0;
        for (r.maturity = r.firstMaturity; r.maturity <= r.maxMaturity; ) {
          (uint256 borrowed, ) = market.fixedPoolBalance(r.maturity);
          r.fixedDebt += borrowed;
          r.maturities[r.start] = r.maturity;
          unchecked {
            r.maturity += FixedLib.INTERVAL;
            ++r.start;
          }
        }
        rewards[r.i] = RewardRate({
          asset: address(r.rewardList[r.i]),
          assetName: r.rewardList[r.i].name(),
          assetSymbol: r.rewardList[r.i].symbol(),
          borrow: (market.totalFloatingBorrowAssets() + r.fixedDebt) > 0
            ? (r.projectedBorrowIndex - r.borrowIndex)
              .mulDivDown(market.totalFloatingBorrowShares() + market.previewRepay(r.fixedDebt), r.underlyingBaseUnit)
              .mulWadDown(market.auditor().assetPrice(r.config.priceFeed))
              .mulDivDown(
                r.underlyingBaseUnit,
                (market.totalFloatingBorrowAssets() + r.fixedDebt).mulWadDown(
                  market.auditor().assetPrice(r.underlyingPriceFeed)
                )
              )
              .mulDivDown(365 days, r.deltaTime)
            : 0,
          deposit: market.totalAssets() > 0
            ? (r.projectedDepositIndex - r.depositIndex)
              .mulDivDown(market.totalSupply(), r.underlyingBaseUnit)
              .mulWadDown(market.auditor().assetPrice(r.config.priceFeed))
              .mulDivDown(
                r.underlyingBaseUnit,
                market.totalAssets().mulWadDown(market.auditor().assetPrice(r.underlyingPriceFeed))
              )
              .mulDivDown(365 days, r.deltaTime)
            : 0
        });
      }
    }
  }
}

error InvalidPreview();

struct Leverage {
  uint256 ratio;
  uint256 borrow;
  uint256 deposit;
  int256 principal;
  uint256 maxRatio;
  uint256 minDeposit;
  uint256 maxWithdraw;
  PoolKey pool;
  uint256 sqrtPriceX96;
  AvailableAsset[] availableAssets;
}

struct AvailableAsset {
  ERC20 asset;
  uint256 liquidity;
}

struct Pool {
  address tokenA;
  address tokenB;
}

struct Limit {
  uint256 ratio;
  uint256 borrow;
  uint256 deposit;
  int256 principal;
  uint256 maxRatio;
}

struct RatioVars {
  uint256 adjustedDebt;
  uint256 adjustFactorIn;
  uint256 adjustFactorOut;
}

struct MaxWithdrawVars {
  uint256 adjustedDebt;
  uint256 adjustedRepay;
  uint256 adjustedPrincipal;
  uint256 adjustedCollateral;
  uint256 adjustedPrincipalToRepayDebt;
  IPriceFeed priceFeedIn;
  uint256 marketMap;
  uint256 adjustFactorIn;
  uint256 adjustFactorOut;
  uint256 i;
  Market market;
}

struct MinDepositVars {
  uint256 adjustFactorIn;
  uint256 adjustFactorOut;
  IPriceFeed priceFeedIn;
  IPriceFeed priceFeedOut;
}

struct Rates {
  uint256 native;
  uint256 borrow;
  uint256 deposit;
  RewardRate[] rewards;
}

struct RewardRate {
  address asset;
  string assetName;
  string assetSymbol;
  uint256 borrow;
  uint256 deposit;
}

interface IUniswapQuoter {
  function quoteExactInputSingle(
    address tokenIn,
    address tokenOut,
    uint24 fee,
    uint256 amountIn,
    uint160 sqrtPriceLimitX96
  ) external returns (uint256 amountOut);

  function quoteExactOutputSingle(
    address tokenIn,
    address tokenOut,
    uint24 fee,
    uint256 amountOut,
    uint160 sqrtPriceLimitX96
  ) external returns (uint256 amountIn);
}
