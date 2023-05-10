// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { Market } from "./Market.sol";
import { Test } from "forge-std/Test.sol";

contract InterestRateModel is Test {
  using FixedPointMathLib for uint256;
  using FixedPointMathLib for int256;

  /// @notice Threshold to define which method should be used to calculate the interest rates.
  /// @dev When `eta` (`delta / alpha`) is lower than this value, use simpson's rule for approximation.
  uint256 internal constant PRECISION_THRESHOLD = 7.5e14;

  /// @notice Market where the interest rate model is used. Keeps compatibility with legacy interest rate model.
  Market public immutable market;

  /// @notice Scale factor of the floating curve.
  uint256 public immutable curveA;
  /// @notice Origin intercept of the floating curve.
  int256 public immutable curveB;
  /// @notice Asymptote of the floating curve.
  uint256 public immutable maxUtilization;

  // FIXME: rename vars
  uint256 public immutable cte1;
  uint256 public immutable cte4;
  uint256 public immutable naturalUtilization;
  int256 public immutable x0;
  uint256 public immutable kInt;
  int256 public immutable k;

  /// @notice Scale factor of the fixed curve.
  uint256 public immutable fixedCurveA;
  /// @notice Origin intercept of the fixed curve.
  int256 public immutable fixedCurveB;
  /// @notice Asymptote of the fixed curve.
  uint256 public immutable fixedMaxUtilization;

  /// @notice Scale factor of the floating curve.
  uint256 public immutable floatingCurveA;
  /// @notice Origin intercept of the floating curve.
  int256 public immutable floatingCurveB;
  /// @notice Asymptote of the floating curve.
  uint256 public immutable floatingMaxUtilization;

  constructor(Market market_, uint256 curveA_, int256 curveB_, uint256 maxUtilization_, uint256 naturalUtilization_) {
    assert(maxUtilization_ > 1e18);

    market = market_;

    fixedCurveA = curveA_;
    fixedCurveB = curveB_;
    fixedMaxUtilization = maxUtilization_;

    floatingCurveA = curveA_;
    floatingCurveB = curveB_;
    floatingMaxUtilization = maxUtilization_;

    naturalUtilization = naturalUtilization_;

    curveA = curveA_;
    curveB = curveB_;
    maxUtilization = maxUtilization_;

    cte1 = 1e18 - naturalUtilization_;
    cte4 = 1e18 - naturalUtilization_ / 2;
    x0 = int256(naturalUtilization.divWadDown(1e18 - naturalUtilization)).lnWad();
    kInt = 1;
    k = 1e18;

    // reverts if it's an invalid curve (such as one yielding a negative interest rate).
    fixedRate(0, 0);
    floatingRate(0, 0, 0);
  }

  /// @notice Gets the rate to borrow a certain amount at a certain maturity with supply/demand values in the fixed rate
  /// pool and assets from the backup supplier.
  /// @param maturity maturity date for calculating days left to maturity.
  /// @param amount the current borrow's amount.
  /// @param borrowed ex-ante amount borrowed from this fixed rate pool.
  /// @param supplied deposits in the fixed rate pool.
  /// @param backupAssets backup supplier assets.
  /// @return rate of the fee that the borrower will have to pay (represented with 18 decimals).
  function fixedBorrowRate(
    uint256 maturity,
    uint256 amount,
    uint256 borrowed,
    uint256 supplied,
    uint256 backupAssets
  ) external view returns (uint256) {
    if (block.timestamp >= maturity) revert AlreadyMatured();

    uint256 potentialAssets = supplied + backupAssets;
    uint256 utilizationAfter = (borrowed + amount).divWadUp(potentialAssets);

    if (utilizationAfter > 1e18) revert UtilizationExceeded();

    uint256 utilizationBefore = borrowed.divWadDown(potentialAssets);

    return fixedRate(utilizationBefore, utilizationAfter).mulDivDown(maturity - block.timestamp, 365 days);
  }

  /// @notice Returns the current annualized fixed rate to borrow with supply/demand values in the fixed rate pool and
  /// assets from the backup supplier.
  /// @param borrowed amount borrowed from the fixed rate pool.
  /// @param supplied deposits in the fixed rate pool.
  /// @param backupAssets backup supplier assets.
  /// @return rate of the fee that the borrower will have to pay, with 18 decimals precision.
  /// @return utilization current utilization rate, with 18 decimals precision.
  function minFixedRate(
    uint256 borrowed,
    uint256 supplied,
    uint256 backupAssets
  ) external view returns (uint256 rate, uint256 utilization) {
    utilization = borrowed.divWadUp(supplied + backupAssets);
    rate = fixedRate(utilization, utilization);
  }

  /// @notice Returns the interest rate integral from `u0` to `u1`, using the analytical solution (ln).
  /// @dev Uses the fixed rate curve parameters.
  /// Handles special case where delta utilization tends to zero, using simpson's rule.
  /// @param utilizationBefore ex-ante utilization rate, with 18 decimals precision.
  /// @param utilizationAfter ex-post utilization rate, with 18 decimals precision.
  /// @return the interest rate, with 18 decimals precision.
  function fixedRate(uint256 utilizationBefore, uint256 utilizationAfter) internal view returns (uint256) {
    uint256 alpha = fixedMaxUtilization - utilizationBefore;
    uint256 delta = utilizationAfter - utilizationBefore;
    int256 r = int256(
      delta.divWadDown(alpha) < PRECISION_THRESHOLD
        ? (fixedCurveA.divWadDown(alpha) +
          fixedCurveA.mulDivDown(4e18, fixedMaxUtilization - ((utilizationAfter + utilizationBefore) / 2)) +
          fixedCurveA.divWadDown(fixedMaxUtilization - utilizationAfter)) / 6
        : fixedCurveA.mulDivDown(
          uint256(int256(alpha.divWadDown(fixedMaxUtilization - utilizationAfter)).lnWad()),
          delta
        )
    ) + fixedCurveB;
    assert(r >= 0);
    return uint256(r);
  }

  /// @notice Legacy function, returns the floating rate of the associated market.
  /// @dev Deprecated in favour of floatingRate(uint256,uint256,uint256).
  /// @return the interest rate, with 18 decimals precision.
  function floatingRate(uint256) public view returns (uint256) {
    return floatingRate(market.floatingAssets(), market.floatingDebt(), market.floatingBackupBorrowed());
  }

  /// @notice Returns the interest rate for the state received.
  /// @dev Uses the floating rate curve parameters.
  /// @param assets floating assets deposited in the pool.
  /// @param debt floating debt of the pool.
  /// @param backupBorrowed amount borrowed from the backup supplier.
  /// @return the interest rate, with 18 decimals precision.
  function floatingRate(uint256 assets, uint256 debt, uint256 backupBorrowed) public view returns (uint256) {
    uint256 liquidity = assets - debt - backupBorrowed;
    uint256 utilization = assets > 0 ? (debt).divWadUp(assets) : 0;

    int256 r = int256(floatingCurveA.divWadDown(floatingMaxUtilization - utilization)) + floatingCurveB;
    assert(r >= 0);
    if (liquidity == 0) return uint256(r);

    return cte1.mulWadDown(uint256(r)).mulDivDown(assets, liquidity);

    // # M1
    // ULiq = 1 - (Liq/FA)
    // R = cte/(1-ULiq)(A/(Um - Ui) + B)
    // -> R = r*cte/(Liq/FA)
    // -> R = r*cte*FA/Liq
  }

  function floatingRateSigmoid(uint256 assets, uint256 debt, uint256 backupBorrowed) public returns (uint256) {
    uint256 liquidity = assets - debt - backupBorrowed;
    uint256 utilization = assets > 0 ? (debt).divWadUp(assets) : 0;
    assert(utilization < 1e18);
    int256 r = int256(floatingCurveA.divWadDown(floatingMaxUtilization - utilization)) + floatingCurveB;
    assert(r >= 0);
    emit log_named_decimal_uint("A       ", floatingCurveA, 18);
    emit log_named_decimal_int("B        ", floatingCurveB, 18);
    emit log_named_decimal_uint("UMax     ", floatingMaxUtilization, 18);

    emit log_named_decimal_uint("oldFormula       ", uint(r), 18);
    if (liquidity == 0) return uint256(r);

    uint256 uLiq = 1e18 - liquidity.divWadUp(assets);
    if (uLiq == 0) return uint256(r);

    // TODO: needed?
    assert(uLiq < 1e18);

    uint256 sigmoidOutput = sigmoid(uLiq);
    emit log_named_decimal_uint("sigmoid output   ", sigmoidOutput, 18);

    return (cte4.mulWadDown(uint256(r))).divWadDown(1e18 - sigmoidOutput.mulWadDown(uLiq));
  }

  function sigmoid(uint256 uLiq) internal returns (uint256) {
    // todo: require s != 0
    require(uLiq != 0, "uLiq == 0");

    int256 x = int256(uLiq.divWadDown(1e18 - uLiq)).lnWad();

    emit log_named_decimal_int("x                ", x, 18);
    emit log_named_decimal_int("x0               ", x0, 18);

    return uint256(1e18).divWadDown(uint256(1e18 + (-((k * (x - x0)) / 1e18)).expWad()));
  }
}

error AlreadyMatured();
error UtilizationExceeded();
