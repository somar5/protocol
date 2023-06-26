// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { MathUpgradeable as Math } from "@openzeppelin/contracts-upgradeable/utils/math/MathUpgradeable.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { DebtManager, IUniswapV3Pool, ERC20, PoolKey, PoolAddress } from "./DebtManager.sol";
import { Auditor, IPriceFeed } from "../Auditor.sol";
import { Market } from "../Market.sol";

/// @title DebtPreviewer
/// @notice Contract to be consumed by Exactly's front-end dApp as a helper for `DebtManager`.
contract DebtPreviewer is OwnableUpgradeable {
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
    __Ownable_init();

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
      uniswapV3Quoter.quoteExactOutputSingle(
        assetIn,
        assetOut,
        fee,
        amountOut,
        assetIn == PoolAddress.getPoolKey(assetIn, assetOut, fee).token0 ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1
      );
  }

  /// @notice Returns extended data useful to leverage or deleverage an account principal position.
  /// @param marketIn The deposit Market.
  /// @param marketOut The borrow Market.
  /// @param account The account operating with the `DebtManager`.
  /// @return extended leverage data.
  function leverage(Market marketIn, Market marketOut, address account) external returns (Leverage memory) {
    (, , uint256 floatingBorrowShares) = marketOut.accounts(account);
    uint256 debt = marketOut.previewRefund(floatingBorrowShares);
    uint256 collateral = marketIn.maxWithdraw(account);
    uint256 principal = crossedPrincipal(marketIn, marketOut, account);
    uint256 ratio = principal > 0 ? collateral.divWadDown(principal) : 1e18;
    PoolKey memory poolKey = PoolAddress.getPoolKey(address(marketIn.asset()), address(marketOut.asset()), 0);
    poolKey.fee = poolFees[poolKey.token0][poolKey.token1];
    uint256 sqrtPriceX96;
    if (address(marketIn) != address(marketOut)) {
      (sqrtPriceX96, , , , , , ) = IUniswapV3Pool(PoolAddress.computeAddress(debtManager.uniswapV3Factory(), poolKey))
        .slot0();
    }

    return
      Leverage({
        debt: debt,
        collateral: collateral,
        principal: principal,
        ratio: ratio,
        maxRatio: maxRatio(marketIn, marketOut, account, principal),
        maxWithdraw: maxWithdraw(marketIn, marketOut, account),
        pool: poolKey,
        sqrtPriceX96: sqrtPriceX96,
        availableAssets: balancerAvailableLiquidity()
      });
  }

  /// @notice Returns the maximum ratio that an account can leverage its principal plus `assets` amount.
  /// @param marketIn The deposit Market.
  /// @param marketOut The borrow Market.
  /// @param account The account that will be leveraged.
  /// @param assets The amount of assets that will be added to the principal.
  function previewDeposit(
    Market marketIn,
    Market marketOut,
    address account,
    uint256 assets
  ) external view returns (uint256) {
    return maxRatio(marketIn, marketOut, account, crossedPrincipal(marketIn, marketOut, account) + assets);
  }

  /// @notice Sets a pool fee to the mapping of pool fees.
  /// @param pool The pool to be added.
  /// @param fee The fee of the pool to be added.
  function setPoolFee(Pool memory pool, uint24 fee) external onlyOwner {
    PoolKey memory poolKey = PoolAddress.getPoolKey(pool.tokenA, pool.tokenB, fee);
    poolFees[poolKey.token0][poolKey.token1] = poolKey.fee;
  }

  /// @notice Returns the amount of `marketOut` underlying assets considering `amountIn` and both assets oracle prices.
  /// @param marketIn The market of the assets accounted as `amountIn`.
  /// @param marketOut The market of the assets that will be returned.
  /// @param amountIn The amount of `marketIn` underlying assets.
  function previewAssetsOut(Market marketIn, Market marketOut, uint256 amountIn) internal view returns (uint256) {
    (, , , , IPriceFeed priceFeedIn) = debtManager.auditor().markets(marketIn);
    (, , , , IPriceFeed priceFeedOut) = debtManager.auditor().markets(marketOut);
    return
      amountIn.mulDivDown(debtManager.auditor().assetPrice(priceFeedIn), 10 ** marketIn.decimals()).mulDivDown(
        10 ** marketOut.decimals(),
        debtManager.auditor().assetPrice(priceFeedOut)
      );
  }

  /// @notice Returns the maximum ratio that an account can leverage its principal position.
  /// @param marketIn The deposit Market.
  /// @param marketOut The borrow Market.
  /// @param account The account that will be leveraged.
  /// @param principal The principal amount that will be leveraged.
  function maxRatio(
    Market marketIn,
    Market marketOut,
    address account,
    uint256 principal
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

        if (market == marketOut) {
          (, , uint256 floatingBorrowShares) = market.accounts(account);
          vars.borrowBalance -= market.previewRefund(floatingBorrowShares);
        }
        r.adjustedDebt += vars.borrowBalance.mulDivUp(vars.price, 10 ** m.decimals).divWadUp(m.adjustFactor);
      }
      unchecked {
        ++i;
      }
    }

    (r.adjustFactorIn, , , , ) = auditor.markets(marketIn);
    (r.adjustFactorOut, , , , ) = auditor.markets(marketOut);
    (, , , , IPriceFeed priceFeedIn) = auditor.markets(marketIn);
    if (principal == 0) return uint256(1e18).divWadDown(1e18 - r.adjustFactorIn.mulWadDown(r.adjustFactorOut));
    return
      (principal -
        r.adjustedDebt.mulWadDown(r.adjustFactorOut).mulDivDown(
          10 ** marketIn.decimals(),
          auditor.assetPrice(priceFeedIn)
        )).divWadDown(principal - principal.mulWadDown(r.adjustFactorIn).mulWadDown(r.adjustFactorOut));
  }

  struct MaxWithdrawVars {
    uint256 collateralAdjusted;
    uint256 floatingDebtAdjusted;
    uint256 totalCollateralAdjusted;
    uint256 amountForRepaying;
    IPriceFeed priceFeedIn;
    uint256 marketMap;
    // iterable vars: FIXME: remove from here
    uint256 i;
    Market market;
    // ratio vars:
    uint256 adjustedDebt;
    uint256 adjustFactorIn;
    uint256 adjustFactorOut;
  }

  function floatingBorrowAssets(Market market, address account) internal view returns (uint256) {
    (, , uint256 floatingBorrowShares) = market.accounts(account);
    return market.previewRefund(floatingBorrowShares);
  }

  function maxWithdraw(Market marketIn, Market marketOut, address account) internal returns (uint256) {
    Auditor auditor = debtManager.auditor();

    MaxWithdrawVars memory mw;
    mw.marketMap = auditor.accountMarkets(account);
    for (mw.i = 0; mw.marketMap != 0; mw.marketMap >>= 1) {
      if (mw.marketMap & 1 != 0) {
        mw.market = auditor.marketList(mw.i);

        Auditor.MarketData memory m;
        Auditor.AccountLiquidity memory vars;
        (m.adjustFactor, m.decimals, , , m.priceFeed) = auditor.markets(mw.market);
        (vars.balance, vars.borrowBalance) = mw.market.accountSnapshot(account);
        vars.price = auditor.assetPrice(m.priceFeed);

        mw.totalCollateralAdjusted += vars.balance.mulDivDown(vars.price, 10 ** m.decimals).mulWadDown(m.adjustFactor);
        mw.adjustedDebt += vars.borrowBalance.mulDivUp(vars.price, 10 ** m.decimals).divWadUp(m.adjustFactor);
        if (mw.market == marketOut) {
          mw.floatingDebtAdjusted = floatingBorrowAssets(mw.market, account)
            .mulDivUp(vars.price, 10 ** m.decimals)
            .divWadUp(m.adjustFactor);
        } else if (mw.market == marketIn) {
          mw.amountForRepaying = floatingBorrowAssets(marketOut, account) > 0
            ? previewOutputSwap(
              address(mw.market.asset()),
              address(marketOut.asset()),
              floatingBorrowAssets(marketOut, account),
              500
            ).mulDivDown(vars.price, 10 ** m.decimals).mulWadDown(m.adjustFactor)
            : 0;
          mw.collateralAdjusted =
            (mw.market.maxWithdraw(account)).mulDivDown(vars.price, 10 ** m.decimals).mulWadDown(m.adjustFactor) -
            mw.amountForRepaying;
        }
      }
      unchecked {
        ++mw.i;
      }
    }
    (mw.adjustFactorIn, , , , mw.priceFeedIn) = auditor.markets(marketIn);

    return
      Math
        .min(
          mw.totalCollateralAdjusted - mw.adjustedDebt + mw.floatingDebtAdjusted - mw.amountForRepaying,
          mw.collateralAdjusted
        )
        .mulDivDown(10 ** marketIn.decimals(), auditor.assetPrice(mw.priceFeedIn))
        .divWadDown(mw.adjustFactorIn);
  }

  /// @notice Calculates the crossed principal amount for a given `account` in the input and output markets.
  /// @param marketIn The Market to withdraw the leveraged position.
  /// @param marketOut The Market to repay the leveraged position.
  /// @param account The account that will be deleveraged.
  function crossedPrincipal(Market marketIn, Market marketOut, address account) internal view returns (uint256) {
    (, , , , IPriceFeed priceFeedIn) = debtManager.auditor().markets(marketIn);
    (, , , , IPriceFeed priceFeedOut) = debtManager.auditor().markets(marketOut);
    uint256 assetPriceIn = debtManager.auditor().assetPrice(priceFeedIn);

    uint256 collateralUSD = marketIn.maxWithdraw(account).mulWadDown(assetPriceIn) * 10 ** (18 - marketIn.decimals());
    (, , uint256 floatingBorrowShares) = marketOut.accounts(account);
    uint256 debtUSD = marketOut.previewRefund(floatingBorrowShares).mulWadDown(
      debtManager.auditor().assetPrice(priceFeedOut)
    ) * 10 ** (18 - marketOut.decimals());
    return (collateralUSD - debtUSD).divWadDown(assetPriceIn) / 10 ** (18 - marketIn.decimals());
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

  struct Leverage {
    uint256 debt;
    uint256 collateral;
    uint256 principal;
    uint256 ratio;
    uint256 maxRatio;
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

  struct RatioVars {
    uint256 adjustedDebt;
    uint256 adjustFactorIn;
    uint256 adjustFactorOut;
  }
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
