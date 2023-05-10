// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { Test } from "forge-std/Test.sol";
import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { InterestRateModel } from "../../contracts/InterestRateModel.sol";
import { Market } from "../../contracts/Market.sol";
import { FixedLib } from "../../contracts/utils/FixedLib.sol";

contract InterestRateModelTest is Test {
  using FixedPointMathLib for uint256;

  InterestRateModelHarness internal irm;

  function setUp() external {
    irm = new InterestRateModelHarness(Market(address(0)), 0.023e18, -0.0025e18, 1.02e18, 7e17);
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
    new InterestRateModelHarness(Market(address(0)), 0.023e18, -0.0025e18, 1e18 - 1, 7e17);
  }

  function testFuzzReferenceRate(uint256 v0, uint64 delta) external {
    (uint256 rate, uint256 refRate) = irm.fixedRate(v0, delta);
    assertApproxEqAbs(rate, refRate, 3e3);
  }

  function testModel1() external {
    // curve: { a: 1.4844e-2, b: 1.9964e-4, maxUtilization: 1.002968978, naturalUtilization: 0.7 },
    // A_vr      = 1.3981e-02
    // B_vr      = 1.0577e-03
    // Umax_vr   = 1.002796847
    InterestRateModel newIRM = new InterestRateModel(Market(address(0)), 1.3981e16, 1.0577e15, 1.002796847e18, 7e17);

    // any time uPool > uLiq => rate = 0
    // uPool = 0
    emit log("_________________________________________");
    uint256 floatingUtilization = 0;
    emit log_named_decimal_uint("uPool    ", floatingUtilization, 18);
    emit log("0 <= uLiq <= .2");
    checkM1Rate(newIRM, floatingUtilization, 0, 0.00449991190241703e18);
    checkM1Rate(newIRM, floatingUtilization, 0.01e18, 0.004545365557997e18);
    checkM1Rate(newIRM, floatingUtilization, 0.02e18, 0.00459174683920105e18);
    checkM1Rate(newIRM, floatingUtilization, 0.03e18, 0.00463908443548148e18);
    checkM1Rate(newIRM, floatingUtilization, 0.04e18, 0.00468740823168441e18);
    checkM1Rate(newIRM, floatingUtilization, 0.05e18, 0.0047367493709653e18);
    checkM1Rate(newIRM, floatingUtilization, 0.06e18, 0.00478714032172025e18);
    checkM1Rate(newIRM, floatingUtilization, 0.07e18, 0.00483861494883552e18);
    checkM1Rate(newIRM, floatingUtilization, 0.08e18, 0.00489120858958373e18);
    checkM1Rate(newIRM, floatingUtilization, 0.09e18, 0.00494495813452421e18);
    checkM1Rate(newIRM, floatingUtilization, 0.1e18, 0.0049999021137967e18);
    checkM1Rate(newIRM, floatingUtilization, 0.11e18, 0.00505608078923262e18);
    checkM1Rate(newIRM, floatingUtilization, 0.12e18, 0.00511353625274663e18);
    checkM1Rate(newIRM, floatingUtilization, 0.13e18, 0.00517231253151383e18);
    checkM1Rate(newIRM, floatingUtilization, 0.14e18, 0.00523245570048492e18);
    checkM1Rate(newIRM, floatingUtilization, 0.15e18, 0.00529401400284357e18);
    checkM1Rate(newIRM, floatingUtilization, 0.16e18, 0.0053570379790679e18);
    checkM1Rate(newIRM, floatingUtilization, 0.17e18, 0.00542158060532173e18);
    checkM1Rate(newIRM, floatingUtilization, 0.18e18, 0.00548769744197199e18);
    checkM1Rate(newIRM, floatingUtilization, 0.19e18, 0.00555544679310745e18);
    checkM1Rate(newIRM, floatingUtilization, 0.2e18, 0.00562488987802129e18);

    emit log("_________________________________________");
    floatingUtilization = 0.1e18;
    emit log_named_decimal_uint("uPool    ", floatingUtilization, 18);
    emit log(".1 <= uLiq <= .2");
    checkM1Rate(newIRM, floatingUtilization, 0.1e18, 0.00551467301298329e18);
    checkM1Rate(newIRM, floatingUtilization, 0.11e18, 0.0055766356311067e18);
    checkM1Rate(newIRM, floatingUtilization, 0.12e18, 0.00564000649055109e18);
    checkM1Rate(newIRM, floatingUtilization, 0.13e18, 0.00570483415136202e18);
    checkM1Rate(newIRM, floatingUtilization, 0.14e18, 0.00577116943219181e18);
    checkM1Rate(newIRM, floatingUtilization, 0.15e18, 0.00583906554315877e18);
    checkM1Rate(newIRM, floatingUtilization, 0.16e18, 0.00590857822819638e18);
    checkM1Rate(newIRM, floatingUtilization, 0.17e18, 0.00597976591769272e18);
    checkM1Rate(newIRM, floatingUtilization, 0.18e18, 0.00605268989229873e18);
    checkM1Rate(newIRM, floatingUtilization, 0.19e18, 0.00612741445887032e18);
    checkM1Rate(newIRM, floatingUtilization, 0.2e18, 0.0062040071396062e18);

    emit log("_________________________________________");
    floatingUtilization = 0.2e18;
    emit log_named_decimal_uint("uPool    ", floatingUtilization, 18);
    emit log(".2 <= uLiq <= .3");
    checkM1Rate(newIRM, floatingUtilization, 0.2e18, 0.00692739932298459e18);
    checkM1Rate(newIRM, floatingUtilization, 0.21e18, 0.00701508792200971e18);
    checkM1Rate(newIRM, floatingUtilization, 0.22e18, 0.00710502494665086e18);
    checkM1Rate(newIRM, floatingUtilization, 0.23e18, 0.00719729799790607e18);
    checkM1Rate(newIRM, floatingUtilization, 0.24e18, 0.0072919992873522e18);
    checkM1Rate(newIRM, floatingUtilization, 0.25e18, 0.0073892259445169e18);
    checkM1Rate(newIRM, floatingUtilization, 0.26e18, 0.00748908034917253e18);
    checkM1Rate(newIRM, floatingUtilization, 0.27e18, 0.00759167049094202e18);
    checkM1Rate(newIRM, floatingUtilization, 0.28e18, 0.00769711035887177e18);
    checkM1Rate(newIRM, floatingUtilization, 0.29e18, 0.0078055203639263e18);
    checkM1Rate(newIRM, floatingUtilization, 0.3e18, 0.00791702779769667e18);
    emit log("_____ .5 <= uLiq <= .6 _____");
    checkM1Rate(newIRM, floatingUtilization, 0.5e18, 0.0110838389167753e18);
    checkM1Rate(newIRM, floatingUtilization, 0.51e18, 0.0113100397109952e18);
    checkM1Rate(newIRM, floatingUtilization, 0.52e18, 0.0115456655383077e18);
    checkM1Rate(newIRM, floatingUtilization, 0.53e18, 0.0117913179965695e18);
    checkM1Rate(newIRM, floatingUtilization, 0.54e18, 0.0120476509964949e18);
    checkM1Rate(newIRM, floatingUtilization, 0.55e18, 0.0123153765741948e18);
    checkM1Rate(newIRM, floatingUtilization, 0.56e18, 0.0125952714963356e18);
    checkM1Rate(newIRM, floatingUtilization, 0.57e18, 0.0128881847869481e18);
    checkM1Rate(newIRM, floatingUtilization, 0.58e18, 0.0131950463294945e18);
    checkM1Rate(newIRM, floatingUtilization, 0.59e18, 0.0135168767277748e18);
    checkM1Rate(newIRM, floatingUtilization, 0.6e18, 0.0138547986459692e18);

    emit log("_________________________________________");
    floatingUtilization = 0.5e18;
    emit log_named_decimal_uint("uPool    ", floatingUtilization, 18);
    emit log(".5 <= uLiq <= .6");
    checkM1Rate(newIRM, floatingUtilization, 0.5e18, 0.0173184955056871e18);
    checkM1Rate(newIRM, floatingUtilization, 0.51e18, 0.0176719341894766e18);
    checkM1Rate(newIRM, floatingUtilization, 0.52e18, 0.0180400994850907e18);
    checkM1Rate(newIRM, floatingUtilization, 0.53e18, 0.0184239313890288e18);
    checkM1Rate(newIRM, floatingUtilization, 0.54e18, 0.0188244516366164e18);
    checkM1Rate(newIRM, floatingUtilization, 0.55e18, 0.0192427727840968e18);
    checkM1Rate(newIRM, floatingUtilization, 0.56e18, 0.0196801085291899e18);
    checkM1Rate(newIRM, floatingUtilization, 0.57e18, 0.0201377854717292e18);
    checkM1Rate(newIRM, floatingUtilization, 0.58e18, 0.0206172565543894e18);
    checkM1Rate(newIRM, floatingUtilization, 0.59e18, 0.0211201164703501e18);
    checkM1Rate(newIRM, floatingUtilization, 0.6e18, 0.0216481193821089e18);
    emit log("_____ .8 <= uLiq <= .9 _____");
    checkM1Rate(newIRM, floatingUtilization, 0.8e18, 0.0432962387642177e18);
    checkM1Rate(newIRM, floatingUtilization, 0.81e18, 0.0455749881728608e18);
    checkM1Rate(newIRM, floatingUtilization, 0.82e18, 0.0481069319602419e18);
    checkM1Rate(newIRM, floatingUtilization, 0.83e18, 0.050936751487315e18);
    checkM1Rate(newIRM, floatingUtilization, 0.84e18, 0.0541202984552722e18);
    checkM1Rate(newIRM, floatingUtilization, 0.85e18, 0.0577283183522903e18);
    checkM1Rate(newIRM, floatingUtilization, 0.86e18, 0.0618517696631682e18);
    checkM1Rate(newIRM, floatingUtilization, 0.87e18, 0.0666095980987965e18);
    checkM1Rate(newIRM, floatingUtilization, 0.88e18, 0.0721603979403629e18);
    checkM1Rate(newIRM, floatingUtilization, 0.89e18, 0.0787204341167595e18);
    checkM1Rate(newIRM, floatingUtilization, 0.9e18, 0.0865924775284355e18);

    emit log("_________________________________________");
    floatingUtilization = 0.7e18;
    emit log_named_decimal_uint("uPool    ", floatingUtilization, 18);
    emit log(".7 <= uLiq <= .8");
    checkM1Rate(newIRM, floatingUtilization, 0.7e18, 0.047230571806687e18);
    checkM1Rate(newIRM, floatingUtilization, 0.71e18, 0.0488592122138141e18);
    checkM1Rate(newIRM, floatingUtilization, 0.72e18, 0.0506041840785932e18);
    checkM1Rate(newIRM, floatingUtilization, 0.73e18, 0.0524784131185411e18);
    checkM1Rate(newIRM, floatingUtilization, 0.74e18, 0.0544968136231003e18);
    checkM1Rate(newIRM, floatingUtilization, 0.75e18, 0.0566766861680244e18);
    checkM1Rate(newIRM, floatingUtilization, 0.76e18, 0.0590382147583587e18);
    checkM1Rate(newIRM, floatingUtilization, 0.77e18, 0.061605093660896e18);
    checkM1Rate(newIRM, floatingUtilization, 0.78e18, 0.0644053251909368e18);
    checkM1Rate(newIRM, floatingUtilization, 0.79e18, 0.0674722454381242e18);
    checkM1Rate(newIRM, floatingUtilization, 0.8e18, 0.0708458577100305e18);
  }

  function checkM1Rate(
    InterestRateModel irm_,
    uint256 floatingUtilization,
    uint256 liquidityUtilization,
    uint256 expected
  ) internal {
    uint256 rate = irm_.floatingRate(
      1_000_000 ether,
      uint256(1_000_000 ether).mulWadDown(floatingUtilization),
      uint256(1_000_000 ether).mulWadDown(liquidityUtilization - floatingUtilization)
    );
    emit log("**************");
    emit log_named_decimal_uint("uLiq     ", liquidityUtilization, 18);
    emit log_named_decimal_uint("uPool    ", floatingUtilization, 18);
    emit log_named_decimal_uint("observed ", rate, 18);
    emit log_named_decimal_uint("expected ", expected, 18);
    // emit log_named_int("diff      ", int256(rate - expected));
    emit log_named_decimal_uint("ratio    ", (rate * 1e18) / expected, 18);
  }

  function testModel4UliqFixed() external {
    InterestRateModel newIRM = new InterestRateModel(Market(address(0)), 1.3981e16, 1.0577e15, 1.002796847e18, 7e17);

    uint256 uLiq = 0.7e18;
    checkSigmoidRate(newIRM, 0e18, uLiq, 0.0149997063413901e18);
    checkSigmoidRate(newIRM, 0.01e18, uLiq, 0.0151401379552043e18);
    checkSigmoidRate(newIRM, 0.02e18, uLiq, 0.0152834273643858e18);
    checkSigmoidRate(newIRM, 0.03e18, uLiq, 0.0154296627002451e18);
    checkSigmoidRate(newIRM, 0.04e18, uLiq, 0.0155789357555633e18);
    checkSigmoidRate(newIRM, 0.05e18, uLiq, 0.0157313421767357e18);
    checkSigmoidRate(newIRM, 0.06e18, uLiq, 0.0158869816681429e18);
    checkSigmoidRate(newIRM, 0.07e18, uLiq, 0.0160459582096678e18);
    checkSigmoidRate(newIRM, 0.08e18, uLiq, 0.016208380288356e18);
    checkSigmoidRate(newIRM, 0.09e18, uLiq, 0.016374361145303e18);
    checkSigmoidRate(newIRM, 0.1e18, uLiq, 0.0165440190389499e18);
    checkSigmoidRate(newIRM, 0.11e18, uLiq, 0.0167174775260736e18);
    checkSigmoidRate(newIRM, 0.12e18, uLiq, 0.0168948657618755e18);
    checkSigmoidRate(newIRM, 0.13e18, uLiq, 0.0170763188206979e18);
    checkSigmoidRate(newIRM, 0.14e18, uLiq, 0.0172619780390457e18);
    checkSigmoidRate(newIRM, 0.15e18, uLiq, 0.0174519913827401e18);
    checkSigmoidRate(newIRM, 0.16e18, uLiq, 0.0176465138402113e18);
    checkSigmoidRate(newIRM, 0.17e18, uLiq, 0.0178457078441267e18);
    checkSigmoidRate(newIRM, 0.18e18, uLiq, 0.018049743723765e18);
    checkSigmoidRate(newIRM, 0.19e18, uLiq, 0.0182588001907836e18);
    checkSigmoidRate(newIRM, 0.2e18, uLiq, 0.0184730648612922e18);
    checkSigmoidRate(newIRM, 0.21e18, uLiq, 0.0186927348174379e18);
    checkSigmoidRate(newIRM, 0.22e18, uLiq, 0.0189180172120339e18);
    checkSigmoidRate(newIRM, 0.23e18, uLiq, 0.0191491299201327e18);
    checkSigmoidRate(newIRM, 0.24e18, uLiq, 0.0193863022418496e18);
    checkSigmoidRate(newIRM, 0.25e18, uLiq, 0.0196297756612043e18);
    checkSigmoidRate(newIRM, 0.26e18, uLiq, 0.0198798046662574e18);
    checkSigmoidRate(newIRM, 0.27e18, uLiq, 0.0201366576363993e18);
    checkSigmoidRate(newIRM, 0.28e18, uLiq, 0.0204006178032925e18);
    checkSigmoidRate(newIRM, 0.29e18, uLiq, 0.0206719842927025e18);
    checkSigmoidRate(newIRM, 0.3e18, uLiq, 0.020951073255273e18);
    checkSigmoidRate(newIRM, 0.31e18, uLiq, 0.021238219095232e18);
    checkSigmoidRate(newIRM, 0.32e18, uLiq, 0.0215337758070695e18);
    checkSigmoidRate(newIRM, 0.33e18, uLiq, 0.0218381184314199e18);
    checkSigmoidRate(newIRM, 0.34e18, uLiq, 0.0221516446427391e18);
    checkSigmoidRate(newIRM, 0.35e18, uLiq, 0.0224747764829077e18);
    checkSigmoidRate(newIRM, 0.36e18, uLiq, 0.0228079622566535e18);
    checkSigmoidRate(newIRM, 0.37e18, uLiq, 0.0231516786066918e18);
    checkSigmoidRate(newIRM, 0.38e18, uLiq, 0.0235064327887837e18);
    checkSigmoidRate(newIRM, 0.39e18, uLiq, 0.0238727651695504e18);
    checkSigmoidRate(newIRM, 0.4e18, uLiq, 0.0242512519729087e18);
    checkSigmoidRate(newIRM, 0.41e18, uLiq, 0.0246425083044882e18);
    checkSigmoidRate(newIRM, 0.42e18, uLiq, 0.0250471914874171e18);
    checkSigmoidRate(newIRM, 0.43e18, uLiq, 0.0254660047475295e18);
    checkSigmoidRate(newIRM, 0.44e18, uLiq, 0.0258997012914536e18);
    checkSigmoidRate(newIRM, 0.45e18, uLiq, 0.0263490888273317e18);
    checkSigmoidRate(newIRM, 0.46e18, uLiq, 0.0268150345852542e18);
    checkSigmoidRate(newIRM, 0.47e18, uLiq, 0.0272984709030606e18);
    checkSigmoidRate(newIRM, 0.48e18, uLiq, 0.027800401453209e18);
    checkSigmoidRate(newIRM, 0.49e18, uLiq, 0.0283219081982224e18);
    checkSigmoidRate(newIRM, 0.5e18, uLiq, 0.0288641591761452e18);
    checkSigmoidRate(newIRM, 0.51e18, uLiq, 0.0294284172339112e18);
    checkSigmoidRate(newIRM, 0.52e18, uLiq, 0.0300160498460585e18);
    checkSigmoidRate(newIRM, 0.53e18, uLiq, 0.030628540179482e18);
    checkSigmoidRate(newIRM, 0.54e18, uLiq, 0.0312674995926926e18);
    checkSigmoidRate(newIRM, 0.55e18, uLiq, 0.0319346817913507e18);
    checkSigmoidRate(newIRM, 0.56e18, uLiq, 0.0326319989019071e18);
    checkSigmoidRate(newIRM, 0.57e18, uLiq, 0.0333615397735832e18);
    checkSigmoidRate(newIRM, 0.58e18, uLiq, 0.0341255908776252e18);
    checkSigmoidRate(newIRM, 0.59e18, uLiq, 0.0349266602442627e18);
    checkSigmoidRate(newIRM, 0.6e18, uLiq, 0.0357675049652807e18);
    checkSigmoidRate(newIRM, 0.61e18, uLiq, 0.0366511628976286e18);
    checkSigmoidRate(newIRM, 0.62e18, uLiq, 0.0375809893362886e18);
    checkSigmoidRate(newIRM, 0.63e18, uLiq, 0.0385606995894788e18);
    checkSigmoidRate(newIRM, 0.64e18, uLiq, 0.0395944185950213e18);
    checkSigmoidRate(newIRM, 0.65e18, uLiq, 0.040686738974943e18);
    checkSigmoidRate(newIRM, 0.66e18, uLiq, 0.0418427892514189e18);
    checkSigmoidRate(newIRM, 0.67e18, uLiq, 0.0430683143613795e18);
    checkSigmoidRate(newIRM, 0.68e18, uLiq, 0.0443697711368039e18);
    checkSigmoidRate(newIRM, 0.69e18, uLiq, 0.0457544420998333e18);
    checkSigmoidRate(newIRM, 0.7e18, uLiq, 0.047230571806687e18);
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
    checkSigmoidRate(newIRM, floatingUtilization, 0.0e18, 0.00974980912190357e18);
    checkSigmoidRate(newIRM, floatingUtilization, 0.01e18, 0.00975022939041178e18);
    checkSigmoidRate(newIRM, floatingUtilization, 0.02e18, 0.00975150013348741e18);
    checkSigmoidRate(newIRM, floatingUtilization, 0.03e18, 0.00975363685729815e18);
    checkSigmoidRate(newIRM, floatingUtilization, 0.04e18, 0.00975665589797232e18);
    checkSigmoidRate(newIRM, floatingUtilization, 0.05e18, 0.00976057446138303e18);
    checkSigmoidRate(newIRM, floatingUtilization, 0.06e18, 0.00976541066557046e18);
    checkSigmoidRate(newIRM, floatingUtilization, 0.07e18, 0.00977118358599794e18);
    checkSigmoidRate(newIRM, floatingUtilization, 0.08e18, 0.00977791330385477e18);
    checkSigmoidRate(newIRM, floatingUtilization, 0.09e18, 0.00978562095763709e18);
    checkSigmoidRate(newIRM, floatingUtilization, 0.1e18, 0.00979432879825929e18);
    checkSigmoidRate(newIRM, floatingUtilization, 0.11e18, 0.00980406024797085e18);
    checkSigmoidRate(newIRM, floatingUtilization, 0.12e18, 0.00981483996337871e18);
    checkSigmoidRate(newIRM, floatingUtilization, 0.13e18, 0.00982669390290313e18);
    checkSigmoidRate(newIRM, floatingUtilization, 0.14e18, 0.0098396493990251e18);
    checkSigmoidRate(newIRM, floatingUtilization, 0.15e18, 0.00985373523571778e18);
    checkSigmoidRate(newIRM, floatingUtilization, 0.16e18, 0.00986898173149139e18);
    checkSigmoidRate(newIRM, floatingUtilization, 0.17e18, 0.0098854208285227e18);
    checkSigmoidRate(newIRM, floatingUtilization, 0.18e18, 0.00990308618838623e18);
    checkSigmoidRate(newIRM, floatingUtilization, 0.19e18, 0.00992201329495544e18);
    checkSigmoidRate(newIRM, floatingUtilization, 0.2e18, 0.00994223956509903e18);

    emit log("_________________________________________");
    floatingUtilization = 0.3e18;
    emit log_named_decimal_uint("uPool    ", floatingUtilization, 18);
    emit log(".3 <= uLiq <= .4");
    emit log("_________________________________________");
    checkSigmoidRate(newIRM, floatingUtilization, 0.3e18, 0.0142831005736671e18);
    checkSigmoidRate(newIRM, floatingUtilization, 0.31e18, 0.014335730809025e18);
    checkSigmoidRate(newIRM, floatingUtilization, 0.32e18, 0.014391089706456e18);
    checkSigmoidRate(newIRM, floatingUtilization, 0.33e18, 0.0144492859466998e18);
    checkSigmoidRate(newIRM, floatingUtilization, 0.34e18, 0.0145104350022351e18);
    checkSigmoidRate(newIRM, floatingUtilization, 0.35e18, 0.0145746596558421e18);
    checkSigmoidRate(newIRM, floatingUtilization, 0.36e18, 0.0146420905678676e18);
    checkSigmoidRate(newIRM, floatingUtilization, 0.37e18, 0.0147128668976023e18);
    checkSigmoidRate(newIRM, floatingUtilization, 0.38e18, 0.014787136984878e18);
    checkSigmoidRate(newIRM, floatingUtilization, 0.39e18, 0.0148650590987911e18);
    checkSigmoidRate(newIRM, floatingUtilization, 0.4e18, 0.0149468022613838e18);

    emit log("_________________________________________");
    floatingUtilization = 0.5e18;
    emit log_named_decimal_uint("uPool    ", floatingUtilization, 18);
    emit log(".5 <= uLiq <= .6");
    emit log("_________________________________________");

    checkSigmoidRate(newIRM, floatingUtilization, 0.5e18, 0.0220725923111698e18);
    checkSigmoidRate(newIRM, floatingUtilization, 0.51e18, 0.0222642891078049e18);
    checkSigmoidRate(newIRM, floatingUtilization, 0.52e18, 0.0224658248260592e18);
    checkSigmoidRate(newIRM, floatingUtilization, 0.53e18, 0.0226778076701589e18);
    checkSigmoidRate(newIRM, floatingUtilization, 0.54e18, 0.0229008990134552e18);
    checkSigmoidRate(newIRM, floatingUtilization, 0.55e18, 0.0231358193011106e18);
    checkSigmoidRate(newIRM, floatingUtilization, 0.56e18, 0.0233833547578009e18);
    checkSigmoidRate(newIRM, floatingUtilization, 0.57e18, 0.023644365031483e18);
    checkSigmoidRate(newIRM, floatingUtilization, 0.58e18, 0.0239197919292344e18);
    checkSigmoidRate(newIRM, floatingUtilization, 0.59e18, 0.0242106694316138e18);
    checkSigmoidRate(newIRM, floatingUtilization, 0.6e18, 0.0245181352092824e18);

    emit log("_________________________________________");
    emit log_named_decimal_uint("uPool    ", floatingUtilization, 18);
    emit log(".7 <= uLiq <= .9");
    emit log("_________________________________________");
    checkSigmoidRate(newIRM, floatingUtilization, 0.7e18, 0.0288641591761452e18);
    checkSigmoidRate(newIRM, floatingUtilization, 0.71e18, 0.0294779191042401e18);
    checkSigmoidRate(newIRM, floatingUtilization, 0.72e18, 0.0301381075614928e18);
    checkSigmoidRate(newIRM, floatingUtilization, 0.73e18, 0.0308498569842973e18);
    checkSigmoidRate(newIRM, floatingUtilization, 0.74e18, 0.0316190897699638e18);
    checkSigmoidRate(newIRM, floatingUtilization, 0.75e18, 0.0324526762629091e18);
    checkSigmoidRate(newIRM, floatingUtilization, 0.76e18, 0.0333586322375169e18);
    checkSigmoidRate(newIRM, floatingUtilization, 0.77e18, 0.0343463678983878e18);
    checkSigmoidRate(newIRM, floatingUtilization, 0.78e18, 0.0354270047898764e18);
    checkSigmoidRate(newIRM, floatingUtilization, 0.79e18, 0.0366137832513383e18);

    checkSigmoidRate(newIRM, floatingUtilization, 0.8e18, 0.0379225921090843e18);
    checkSigmoidRate(newIRM, floatingUtilization, 0.81e18, 0.0393726656396153e18);
    checkSigmoidRate(newIRM, floatingUtilization, 0.82e18, 0.040987512854075e18);
    checkSigmoidRate(newIRM, floatingUtilization, 0.83e18, 0.042796174765598e18);
    checkSigmoidRate(newIRM, floatingUtilization, 0.84e18, 0.0448349531320637e18);
    checkSigmoidRate(newIRM, floatingUtilization, 0.85e18, 0.0471498306961115e18);
    checkSigmoidRate(newIRM, floatingUtilization, 0.86e18, 0.0497999286710408e18);
    checkSigmoidRate(newIRM, floatingUtilization, 0.87e18, 0.0528625599896103e18);
    checkSigmoidRate(newIRM, floatingUtilization, 0.88e18, 0.0564408091774208e18);
    checkSigmoidRate(newIRM, floatingUtilization, 0.89e18, 0.0606752467028867e18);
    checkSigmoidRate(newIRM, floatingUtilization, 0.9e18, 0.0657626719374029e18);

    emit log("_________________________________________");
    floatingUtilization = 0.7e18;
    emit log_named_decimal_uint("uPool    ", floatingUtilization, 18);
    emit log(".7 <= uLiq <= .8");
    emit log("_________________________________________");
    checkSigmoidRate(newIRM, floatingUtilization, 0.7e18, 0.047230571806687e18);
    checkSigmoidRate(newIRM, floatingUtilization, 0.71e18, 0.0488592122138141e18);
    checkSigmoidRate(newIRM, floatingUtilization, 0.72e18, 0.0506041840785932e18);
    checkSigmoidRate(newIRM, floatingUtilization, 0.73e18, 0.0524784131185411e18);
    checkSigmoidRate(newIRM, floatingUtilization, 0.74e18, 0.0544968136231003e18);
    checkSigmoidRate(newIRM, floatingUtilization, 0.75e18, 0.0566766861680244e18);
    checkSigmoidRate(newIRM, floatingUtilization, 0.76e18, 0.0590382147583587e18);
    checkSigmoidRate(newIRM, floatingUtilization, 0.77e18, 0.061605093660896e18);
    checkSigmoidRate(newIRM, floatingUtilization, 0.78e18, 0.0644053251909368e18);
    checkSigmoidRate(newIRM, floatingUtilization, 0.79e18, 0.0674722454381242e18);
    checkSigmoidRate(newIRM, floatingUtilization, 0.8e18, 0.0708458577100305e18);

    emit log("_________________________________________");
    floatingUtilization = 0.8e18;
    emit log_named_decimal_uint("uPool    ", floatingUtilization, 18);
    emit log(".8 <= uLiq <= .9");
    emit log("_________________________________________");
    checkSigmoidRate(newIRM, floatingUtilization, 0.8e18, 0.104997921085074e18);
    checkSigmoidRate(newIRM, floatingUtilization, 0.81e18, 0.110524127457973e18);
    checkSigmoidRate(newIRM, floatingUtilization, 0.82e18, 0.116664356761194e18);
    checkSigmoidRate(newIRM, floatingUtilization, 0.83e18, 0.12352696598244e18);
    checkSigmoidRate(newIRM, floatingUtilization, 0.84e18, 0.131247401356343e18);
    checkSigmoidRate(newIRM, floatingUtilization, 0.85e18, 0.139997228113432e18);
    checkSigmoidRate(newIRM, floatingUtilization, 0.86e18, 0.149997030121535e18);
    checkSigmoidRate(newIRM, floatingUtilization, 0.87e18, 0.161535263207806e18);
    checkSigmoidRate(newIRM, floatingUtilization, 0.88e18, 0.17499653514179e18);
    checkSigmoidRate(newIRM, floatingUtilization, 0.89e18, 0.190905311063771e18);
    checkSigmoidRate(newIRM, floatingUtilization, 0.9e18, 0.209995842170148e18);

    emit log("**************");
  }

  function checkSigmoidRate(
    InterestRateModel irm_,
    uint256 floatingUtilization,
    uint256 liquidityUtilization,
    uint256 expected
  ) internal {
    emit log("**************");
    emit log_named_decimal_uint("uLiq           ", liquidityUtilization, 18);
    emit log_named_decimal_uint("uPool          ", floatingUtilization, 18);
    uint256 rate = irm_.floatingRateSigmoid(
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
    newIRM.floatingRateSigmoid(floatingAssets, floatingDebt, backupBorrowed);
  }
}

// FIXME: only for debugging - uncomment
contract InterestRateModelHarness is InterestRateModel /*, Test*/ {
  constructor(
    Market market_,
    uint256 curveA_,
    int256 curveB_,
    uint256 maxUtilization_,
    uint256 naturalUtilization_
  ) InterestRateModel(market_, curveA_, curveB_, maxUtilization_, naturalUtilization_) {}

  function fixedRate(uint256 v0, uint64 delta) public returns (uint256 rate, uint256 refRate) {
    uint256 u0 = v0 % 1e18;
    uint256 u1 = u0 + (delta % (floatingMaxUtilization - u0));

    rate = fixedRate(u0, u1);

    string[] memory ffi = new string[](2);
    ffi[0] = "scripts/irm.sh";
    ffi[1] = encodeHex(abi.encode(u0, u1, floatingCurveA, floatingCurveB, floatingMaxUtilization));
    refRate = abi.decode(vm.ffi(ffi), (uint256));
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
