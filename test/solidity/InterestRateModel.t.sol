// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { Test, stdError } from "forge-std/Test.sol";
import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { InterestRateModel } from "../../contracts/InterestRateModel.sol";
import { Market } from "../../contracts/Market.sol";
import { FixedLib } from "../../contracts/utils/FixedLib.sol";

contract InterestRateModelTest is Test {
  using FixedPointMathLib for uint256;

  InterestRateModel internal irm;

  function setUp() external {
    irm = new InterestRateModel(Market(address(0)), 0.023e18, -0.0025e18, 1.02e18, 7e17);
    // irm = new InterestRateModel(Market(address(0)), 1.3981e16, 1.0577e15, 1.002796847e18, 7e17);
  }

  function testMinFixedRate() external {
    uint256 borrowed = 10 ether;
    uint256 floatingAssetsAverage = 100 ether;
    (uint256 rate, uint256 utilization) = irm.minFixedRate(borrowed, 0, floatingAssetsAverage);
    assertEq(rate, 0.0225 ether);
    assertEq(utilization, 0.1 ether);
  }

  function testFixedBorrowRate() external {
    uint256 assets = 10 ether;
    uint256 floatingAssetsAverage = 100 ether;
    uint256 rate = irm.fixedBorrowRate(FixedLib.INTERVAL, assets, 0, 0, floatingAssetsAverage);
    assertEq(rate, 1628784207150172);
  }

  function testFloatingBorrowRate() external {
    uint256 floatingDebt = 50 ether;
    uint256 floatingAssets = 100 ether;
    uint256 backupBorrowed = 0;
    uint256 rate = irm.floatingRate(floatingAssets, floatingDebt, backupBorrowed);
    assertEq(rate, 25038461538461538);
  }

  function testRevertMaxUtilizationLowerThanWad() external {
    vm.expectRevert();
    new InterestRateModel(Market(address(0)), 0.023e18, -0.0025e18, 1e18 - 1, 7e17);
  }

  function testFuzzReferenceRate(uint256 assets, uint256 debt, uint256 backupBorrowed) external {
    assets = _bound(assets, 0, 1e50);
    debt = _bound(debt, 0, assets.divWadDown(irm.floatingMaxUtilization()));
    backupBorrowed = _bound(backupBorrowed, 0, debt);

    InterestRateModel newIRM = new InterestRateModel(Market(address(0)), 1.3981e16, 1.0577e15, 1.002796847e18, 7e17);

    emit log("---------------------------");
    emit log_named_decimal_uint("assets", assets, 18);
    emit log_named_decimal_uint("debt", debt, 18);
    emit log_named_decimal_uint("backupBorrowed", backupBorrowed, 18);

    if (assets < debt + backupBorrowed) vm.expectRevert(stdError.arithmeticError);
    uint256 rate = newIRM.floatingRate(assets, debt, backupBorrowed);

    string[] memory ffi = new string[](2);
    ffi[0] = "scripts/irm.sh";
    ffi[1] = encodeHex(
      abi.encode(
        assets,
        debt,
        backupBorrowed,
        newIRM.floatingCurveA(),
        newIRM.floatingCurveB(),
        newIRM.floatingMaxUtilization(),
        newIRM.naturalUtilization()
      )
    );
    uint256 refRate = abi.decode(vm.ffi(ffi), (uint256));
    assertApproxEqAbs(rate, refRate, 3e3);

    // emit log("abi-encoded hex");
    // emit log(ffi[1]);
    emit log_named_decimal_uint("rate     ", rate, 18);
    emit log_named_decimal_uint("refRate  ", refRate, 18);
    emit log("---------------------------");
  }

  function testRateAgainstBC() external {
    InterestRateModel newIRM = new InterestRateModel(Market(address(0)), 1.3981e16, 1.0577e15, 1.002796847e18, 7e17);

    uint256 uLiq = 0.9e18;
    uint256 uPool = 0.8e18;

    uint256 assets = 100 ether;
    uint256 debt = assets.mulWadDown(uPool);
    uint256 backupBorrowed = assets.mulWadDown(uLiq - uPool);
    uint256 observedRate = newIRM.floatingRate(assets, debt, backupBorrowed);

    string[] memory ffi = new string[](2);
    ffi[0] = "scripts/irm.sh";
    ffi[1] = encodeHex(
      abi.encode(
        assets,
        debt,
        backupBorrowed,
        newIRM.floatingCurveA(),
        newIRM.floatingCurveB(),
        newIRM.floatingMaxUtilization(),
        newIRM.naturalUtilization()
      )
    );

    uint256 refRate = abi.decode(vm.ffi(ffi), (uint256));

    emit log("_________________________________________");
    emit log_named_decimal_uint("assets         ", assets, 18);
    emit log_named_decimal_uint("debt           ", debt, 18);
    emit log_named_decimal_uint("backupBorrowed ", backupBorrowed, 18);
    emit log_named_decimal_uint("uPool          ", uPool, 18);
    emit log_named_decimal_uint("uLiq           ", uLiq, 18);
    emit log_named_decimal_uint("observedRate   ", observedRate, 18);
    emit log_named_decimal_uint("refRate        ", refRate, 18);
    emit log("_________________________________________");
    emit log(ffi[1]);
    emit log("_________________________________________");
  }

  function testModel4() external {
    // curve: { a: 1.4844e-2, b: 1.9964e-4, maxUtilization: 1.002968978, naturalUtilization: 0.7 },
    InterestRateModel newIRM = new InterestRateModel(Market(address(0)), 1.3981e16, 1.0577e15, 1.002796847e18, 7e17);
    // InterestRateModel newIRM = new InterestRateModel(Market(address(0)), 1.4844e16, 1.9964e14, 1.002968978e18, 7e17);

    // if uPool > uLiq => rate = 0

    uint256 floatingUtilization = 0;
    emit log("_________________________________________");
    emit log_named_decimal_uint("uPool    ", floatingUtilization, 18);
    emit log("0 <= uLiq <= .2");
    emit log("_________________________________________");
    checkFloatingRate(newIRM, floatingUtilization, 0.0e18, 0.00974980912190357e18);
    checkFloatingRate(newIRM, floatingUtilization, 0.01e18, 0.00975022939041178e18);
    checkFloatingRate(newIRM, floatingUtilization, 0.02e18, 0.00975150013348741e18);
    checkFloatingRate(newIRM, floatingUtilization, 0.03e18, 0.00975363685729815e18);
    checkFloatingRate(newIRM, floatingUtilization, 0.04e18, 0.00975665589797232e18);
    checkFloatingRate(newIRM, floatingUtilization, 0.05e18, 0.00976057446138303e18);
    checkFloatingRate(newIRM, floatingUtilization, 0.06e18, 0.00976541066557046e18);
    checkFloatingRate(newIRM, floatingUtilization, 0.07e18, 0.00977118358599794e18);
    checkFloatingRate(newIRM, floatingUtilization, 0.08e18, 0.00977791330385477e18);
    checkFloatingRate(newIRM, floatingUtilization, 0.09e18, 0.00978562095763709e18);
    checkFloatingRate(newIRM, floatingUtilization, 0.1e18, 0.00979432879825929e18);
    checkFloatingRate(newIRM, floatingUtilization, 0.11e18, 0.00980406024797085e18);
    checkFloatingRate(newIRM, floatingUtilization, 0.12e18, 0.00981483996337871e18);
    checkFloatingRate(newIRM, floatingUtilization, 0.13e18, 0.00982669390290313e18);
    checkFloatingRate(newIRM, floatingUtilization, 0.14e18, 0.0098396493990251e18);
    checkFloatingRate(newIRM, floatingUtilization, 0.15e18, 0.00985373523571778e18);
    checkFloatingRate(newIRM, floatingUtilization, 0.16e18, 0.00986898173149139e18);
    checkFloatingRate(newIRM, floatingUtilization, 0.17e18, 0.0098854208285227e18);
    checkFloatingRate(newIRM, floatingUtilization, 0.18e18, 0.00990308618838623e18);
    checkFloatingRate(newIRM, floatingUtilization, 0.19e18, 0.00992201329495544e18);
    checkFloatingRate(newIRM, floatingUtilization, 0.2e18, 0.00994223956509903e18);

    emit log("_________________________________________");
    floatingUtilization = 0.3e18;
    emit log_named_decimal_uint("uPool    ", floatingUtilization, 18);
    emit log(".3 <= uLiq <= .4");
    emit log("_________________________________________");
    checkFloatingRate(newIRM, floatingUtilization, 0.3e18, 0.0142831005736671e18);
    checkFloatingRate(newIRM, floatingUtilization, 0.31e18, 0.014335730809025e18);
    checkFloatingRate(newIRM, floatingUtilization, 0.32e18, 0.014391089706456e18);
    checkFloatingRate(newIRM, floatingUtilization, 0.33e18, 0.0144492859466998e18);
    checkFloatingRate(newIRM, floatingUtilization, 0.34e18, 0.0145104350022351e18);
    checkFloatingRate(newIRM, floatingUtilization, 0.35e18, 0.0145746596558421e18);
    checkFloatingRate(newIRM, floatingUtilization, 0.36e18, 0.0146420905678676e18);
    checkFloatingRate(newIRM, floatingUtilization, 0.37e18, 0.0147128668976023e18);
    checkFloatingRate(newIRM, floatingUtilization, 0.38e18, 0.014787136984878e18);
    checkFloatingRate(newIRM, floatingUtilization, 0.39e18, 0.0148650590987911e18);
    checkFloatingRate(newIRM, floatingUtilization, 0.4e18, 0.0149468022613838e18);

    emit log("_________________________________________");
    floatingUtilization = 0.5e18;
    emit log_named_decimal_uint("uPool    ", floatingUtilization, 18);
    emit log(".5 <= uLiq <= .6");
    emit log("_________________________________________");

    checkFloatingRate(newIRM, floatingUtilization, 0.5e18, 0.0220725923111698e18);
    checkFloatingRate(newIRM, floatingUtilization, 0.51e18, 0.0222642891078049e18);
    checkFloatingRate(newIRM, floatingUtilization, 0.52e18, 0.0224658248260592e18);
    checkFloatingRate(newIRM, floatingUtilization, 0.53e18, 0.0226778076701589e18);
    checkFloatingRate(newIRM, floatingUtilization, 0.54e18, 0.0229008990134552e18);
    checkFloatingRate(newIRM, floatingUtilization, 0.55e18, 0.0231358193011106e18);
    checkFloatingRate(newIRM, floatingUtilization, 0.56e18, 0.0233833547578009e18);
    checkFloatingRate(newIRM, floatingUtilization, 0.57e18, 0.023644365031483e18);
    checkFloatingRate(newIRM, floatingUtilization, 0.58e18, 0.0239197919292344e18);
    checkFloatingRate(newIRM, floatingUtilization, 0.59e18, 0.0242106694316138e18);
    checkFloatingRate(newIRM, floatingUtilization, 0.6e18, 0.0245181352092824e18);

    emit log("_________________________________________");
    emit log_named_decimal_uint("uPool    ", floatingUtilization, 18);
    emit log(".7 <= uLiq <= .9");
    emit log("_________________________________________");
    checkFloatingRate(newIRM, floatingUtilization, 0.7e18, 0.0288641591761452e18);
    checkFloatingRate(newIRM, floatingUtilization, 0.71e18, 0.0294779191042401e18);
    checkFloatingRate(newIRM, floatingUtilization, 0.72e18, 0.0301381075614928e18);
    checkFloatingRate(newIRM, floatingUtilization, 0.73e18, 0.0308498569842973e18);
    checkFloatingRate(newIRM, floatingUtilization, 0.74e18, 0.0316190897699638e18);
    checkFloatingRate(newIRM, floatingUtilization, 0.75e18, 0.0324526762629091e18);
    checkFloatingRate(newIRM, floatingUtilization, 0.76e18, 0.0333586322375169e18);
    checkFloatingRate(newIRM, floatingUtilization, 0.77e18, 0.0343463678983878e18);
    checkFloatingRate(newIRM, floatingUtilization, 0.78e18, 0.0354270047898764e18);
    checkFloatingRate(newIRM, floatingUtilization, 0.79e18, 0.0366137832513383e18);

    checkFloatingRate(newIRM, floatingUtilization, 0.8e18, 0.0379225921090843e18);
    checkFloatingRate(newIRM, floatingUtilization, 0.81e18, 0.0393726656396153e18);
    checkFloatingRate(newIRM, floatingUtilization, 0.82e18, 0.040987512854075e18);
    checkFloatingRate(newIRM, floatingUtilization, 0.83e18, 0.042796174765598e18);
    checkFloatingRate(newIRM, floatingUtilization, 0.84e18, 0.0448349531320637e18);
    checkFloatingRate(newIRM, floatingUtilization, 0.85e18, 0.0471498306961115e18);
    checkFloatingRate(newIRM, floatingUtilization, 0.86e18, 0.0497999286710408e18);
    checkFloatingRate(newIRM, floatingUtilization, 0.87e18, 0.0528625599896103e18);
    checkFloatingRate(newIRM, floatingUtilization, 0.88e18, 0.0564408091774208e18);
    checkFloatingRate(newIRM, floatingUtilization, 0.89e18, 0.0606752467028867e18);
    checkFloatingRate(newIRM, floatingUtilization, 0.9e18, 0.0657626719374029e18);

    emit log("_________________________________________");
    floatingUtilization = 0.7e18;
    emit log_named_decimal_uint("uPool    ", floatingUtilization, 18);
    emit log(".7 <= uLiq <= .8");
    emit log("_________________________________________");
    checkFloatingRate(newIRM, floatingUtilization, 0.7e18, 0.047230571806687e18);
    checkFloatingRate(newIRM, floatingUtilization, 0.71e18, 0.0488592122138141e18);
    checkFloatingRate(newIRM, floatingUtilization, 0.72e18, 0.0506041840785932e18);
    checkFloatingRate(newIRM, floatingUtilization, 0.73e18, 0.0524784131185411e18);
    checkFloatingRate(newIRM, floatingUtilization, 0.74e18, 0.0544968136231003e18);
    checkFloatingRate(newIRM, floatingUtilization, 0.75e18, 0.0566766861680244e18);
    checkFloatingRate(newIRM, floatingUtilization, 0.76e18, 0.0590382147583587e18);
    checkFloatingRate(newIRM, floatingUtilization, 0.77e18, 0.061605093660896e18);
    checkFloatingRate(newIRM, floatingUtilization, 0.78e18, 0.0644053251909368e18);
    checkFloatingRate(newIRM, floatingUtilization, 0.79e18, 0.0674722454381242e18);
    checkFloatingRate(newIRM, floatingUtilization, 0.8e18, 0.0708458577100305e18);

    emit log("_________________________________________");
    floatingUtilization = 0.8e18;
    emit log_named_decimal_uint("uPool    ", floatingUtilization, 18);
    emit log(".8 <= uLiq <= .9");
    emit log("_________________________________________");
    checkFloatingRate(newIRM, floatingUtilization, 0.8e18, 0.104997921085074e18);
    checkFloatingRate(newIRM, floatingUtilization, 0.81e18, 0.110524127457973e18);
    checkFloatingRate(newIRM, floatingUtilization, 0.82e18, 0.116664356761194e18);
    checkFloatingRate(newIRM, floatingUtilization, 0.83e18, 0.12352696598244e18);
    checkFloatingRate(newIRM, floatingUtilization, 0.84e18, 0.131247401356343e18);
    checkFloatingRate(newIRM, floatingUtilization, 0.85e18, 0.139997228113432e18);
    checkFloatingRate(newIRM, floatingUtilization, 0.86e18, 0.149997030121535e18);
    checkFloatingRate(newIRM, floatingUtilization, 0.87e18, 0.161535263207806e18);
    checkFloatingRate(newIRM, floatingUtilization, 0.88e18, 0.17499653514179e18);
    checkFloatingRate(newIRM, floatingUtilization, 0.89e18, 0.190905311063771e18);
    checkFloatingRate(newIRM, floatingUtilization, 0.9e18, 0.209995842170148e18);

    emit log("**************");
  }

  function checkFloatingRate(
    InterestRateModel irm_,
    uint256 floatingUtilization,
    uint256 liquidityUtilization,
    uint256 expected
  ) internal {
    emit log("**************");
    emit log_named_decimal_uint("uLiq           ", liquidityUtilization, 18);
    emit log_named_decimal_uint("uPool          ", floatingUtilization, 18);
    uint256 rate = irm_.floatingRate(
      1_000_000 ether,
      uint256(1_000_000 ether).mulWadDown(floatingUtilization),
      uint256(1_000_000 ether).mulWadDown(liquidityUtilization - floatingUtilization)
    );
    emit log("__");
    emit log_named_decimal_uint("observed       ", rate, 18);
    emit log_named_decimal_uint("expected       ", expected, 18);
    emit log_named_decimal_uint("ratio          ", (rate * 1e18) / expected, 18);
  }

  function testNewIRMGas(uint256 x, uint256 y) external {
    InterestRateModel newIRM = new InterestRateModel(Market(address(0)), 1.4844e16, 1.9964e14, 1.002968978e18, 7e17);
    uint256 floatingUtilization = _bound(x, 0, 1e18);
    uint256 liquidityUtilization = _bound(y, floatingUtilization, 1e18);
    uint256 floatingAssets = 1_000_000 ether;
    uint256 floatingDebt = floatingAssets.mulWadDown(floatingUtilization);
    uint256 backupBorrowed = floatingAssets.mulWadDown(liquidityUtilization - floatingUtilization);

    // run with full verbosity (-vvvvv) and compare the gas consumption of both
    newIRM.floatingRate(floatingAssets, floatingDebt, backupBorrowed);
  }

  function encodeHex(bytes memory raw) internal pure returns (string memory) {
    bytes16 symbols = "0123456789abcdef";
    bytes memory buffer = new bytes(2 * raw.length + 2);
    buffer[0] = "0";
    buffer[1] = "x";
    for (uint256 i = 0; i < raw.length; i++) {
      buffer[2 * i + 2] = symbols[uint8(raw[i]) >> 4];
      buffer[2 * i + 3] = symbols[uint8(raw[i]) & 0xf];
    }
    return string(buffer);
  }
}
