// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { SafeTransferLib } from "solmate/src/utils/SafeTransferLib.sol";
import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { AddressUpgradeable as Address } from "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import { Market, ERC20, FixedLib, Disagreement } from "../Market.sol";
import { Auditor, MarketNotListed } from "../Auditor.sol";

/// @title DebtManager
/// @notice Contract for efficient debt management of accounts interacting with Exactly Protocol.
contract DebtManager is Initializable {
  using FixedPointMathLib for uint256;
  using SafeTransferLib for ERC20;
  using FixedLib for FixedLib.Position;
  using FixedLib for FixedLib.Pool;
  using Address for address;

  /// @dev The minimum value that can be returned from #getSqrtRatioAtTick. Equivalent to getSqrtRatioAtTick(MIN_TICK)
  uint160 internal constant MIN_SQRT_RATIO = 4295128739;
  /// @dev The maximum value that can be returned from #getSqrtRatioAtTick. Equivalent to getSqrtRatioAtTick(MAX_TICK)
  uint160 internal constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

  /// @notice Auditor contract that lists the markets that can be leveraged.
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  Auditor public immutable auditor;
  /// @notice Permit2 contract to be used to transfer assets from accounts.
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  IPermit2 public immutable permit2;
  /// @notice Balancer's vault contract that is used to take flash loans.
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  IBalancerVault public immutable balancerVault;
  /// @notice Factory contract to be used to compute the address of the Uniswap V3 pool.
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  address public immutable uniswapV3Factory;

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor(Auditor auditor_, IPermit2 permit2_, IBalancerVault balancerVault_, address uniswapV3Factory_) {
    auditor = auditor_;
    permit2 = permit2_;
    balancerVault = balancerVault_;
    uniswapV3Factory = uniswapV3Factory_;

    _disableInitializers();
  }

  /// @notice Initializes the contract.
  /// @dev can only be called once.
  function initialize() external initializer {
    Market[] memory markets = auditor.allMarkets();
    for (uint256 i = 0; i < markets.length; i++) {
      markets[i].asset().safeApprove(address(markets[i]), type(uint256).max);
    }
  }

  /// @notice Leverages the floating position of `_msgSender` a certain `multiplier` by taking a flash loan
  /// from Balancer's vault.
  /// @param market The Market to leverage the position in.
  /// @param principal The amount of assets to leverage.
  /// @param deposit The amount of assets to deposit.
  /// @param multiplier The number of times that the `principal` will be leveraged, represented with 18 decimals.
  function leverage(Market market, uint256 principal, uint256 deposit, uint256 multiplier) public msgSender {
    if (deposit != 0) market.asset().safeTransferFrom(_msgSender, address(this), deposit);

    noTransferLeverage(market, principal, deposit, multiplier);
  }

  /// @notice Leverages the floating position of `_msgSender` a certain `multiplier` by taking a flash loan
  /// from Balancer's vault.
  /// @param market The Market to leverage the position in.
  /// @param principal The amount of assets to leverage.
  /// @param deposit The amount of assets to deposit.
  /// @param multiplier The number of times that the `principal` will be leveraged, represented with 18 decimals.
  function noTransferLeverage(Market market, uint256 principal, uint256 deposit, uint256 multiplier) internal {
    uint256[] memory amounts = new uint256[](1);
    ERC20[] memory tokens = new ERC20[](1);
    tokens[0] = market.asset();
    address sender = _msgSender;

    uint256 loopCount;
    {
      uint256 amount = principal.mulWadDown(multiplier);
      loopCount = amount.mulDivUp(1, tokens[0].balanceOf(address(balancerVault)));
      amounts[0] = amount.mulDivUp(1, loopCount);
    }
    bytes[] memory calls = new bytes[](2 * loopCount);
    uint256 callIndex = 0;
    for (uint256 i = 0; i < loopCount; ) {
      calls[callIndex++] = abi.encodeCall(market.deposit, (i == 0 ? amounts[0] + deposit : amounts[0], sender));
      calls[callIndex++] = abi.encodeCall(
        market.borrow,
        (amounts[0], i + 1 == loopCount ? address(balancerVault) : address(this), sender)
      );
      unchecked {
        ++i;
      }
    }

    balancerVault.flashLoan(address(this), tokens, amounts, call(abi.encode(market, calls)));
  }

  /// @notice Cross-leverages the floating position of `_msgSender` a certain `multiplier` by taking a flash swap
  /// from Uniswap's pool.
  /// @param marketIn The Market to deposit the leveraged position.
  /// @param marketOut The Market to borrow the leveraged position.
  /// @param fee The fee of the pool that will be used to swap the assets.
  /// @param principal The amount of `marketIn` underlying assets to leverage.
  /// @param deposit The amount of `marketIn` underlying assets to deposit.
  /// @param multiplier The number of times that the `principal` will be leveraged, represented with 18 decimals.
  function crossLeverage(
    Market marketIn,
    Market marketOut,
    uint24 fee,
    uint256 principal,
    uint256 deposit,
    uint256 multiplier
  ) external msgSender {
    if (deposit != 0) marketIn.asset().safeTransferFrom(_msgSender, address(this), principal);

    noTransferCrossLeverage(marketIn, marketOut, fee, principal, deposit, multiplier);
  }

  /// @notice Cross-leverages the floating position of `_msgSender` a certain `multiplier` by taking a flash loan
  /// from Balancer's vault.
  /// @param marketIn The Market to deposit the leveraged position.
  /// @param marketOut The Market to borrow the leveraged position.
  /// @param fee The fee of the pool that will be used to swap the assets.
  /// @param principal The amount of `marketIn` underlying assets to leverage.
  /// @param deposit The amount of `marketIn` underlying assets to deposit.
  /// @param multiplier The number of times that the `principal` will be leveraged, represented with 18 decimals.
  function noTransferCrossLeverage(
    Market marketIn,
    Market marketOut,
    uint24 fee,
    uint256 principal,
    uint256 deposit,
    uint256 multiplier
  ) internal {
    LeverageVars memory v;
    v.assetIn = address(marketIn.asset());
    v.assetOut = address(marketOut.asset());

    PoolKey memory poolKey = PoolAddress.getPoolKey(v.assetIn, v.assetOut, fee);
    IUniswapV3Pool(PoolAddress.computeAddress(uniswapV3Factory, poolKey)).swap(
      address(this),
      v.assetOut == poolKey.token0,
      -int256(principal.mulWadDown(multiplier)),
      v.assetOut == poolKey.token0 ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1,
      abi.encode(
        SwapCallbackData({
          marketIn: marketIn,
          marketOut: marketOut,
          assetIn: v.assetIn,
          assetOut: v.assetOut,
          principal: deposit,
          account: _msgSender,
          fee: fee,
          leverage: true
        })
      )
    );
  }

  /// @notice Deleverages a `percentage` position of `_msgSender` by taking a flash swap from Uniswap's pool.
  /// @param marketIn The Market to withdraw the leveraged position.
  /// @param marketOut The Market to repay the leveraged position.
  /// @param fee The fee of the pool that will be used to swap the assets.
  /// @param percentage The percentage that the position will be deleveraged.
  function crossDeleverage(Market marketIn, Market marketOut, uint24 fee, uint256 percentage) public msgSender {
    LeverageVars memory v;
    v.assetIn = address(marketIn.asset());
    v.assetOut = address(marketOut.asset());
    address sender = _msgSender;

    (, , uint256 floatingBorrowShares) = marketOut.accounts(sender);
    v.amount = marketOut.previewRefund(floatingBorrowShares.mulWadDown(percentage));

    PoolKey memory poolKey = PoolAddress.getPoolKey(v.assetIn, v.assetOut, fee);
    IUniswapV3Pool(PoolAddress.computeAddress(uniswapV3Factory, poolKey)).swap(
      address(this),
      v.assetIn == poolKey.token0,
      -int256(v.amount),
      v.assetIn == poolKey.token0 ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1,
      abi.encode(
        SwapCallbackData({
          marketIn: marketIn,
          marketOut: marketOut,
          assetIn: v.assetIn,
          assetOut: v.assetOut,
          principal: v.amount,
          account: sender,
          fee: fee,
          leverage: false
        })
      )
    );
  }

  /// @notice Deleverages the position of `_msgSender` a certain `percentage` by taking a flash loan from
  /// Balancer's vault to repay the borrow.
  /// @param market The Market to deleverage the position out.
  /// @param maturity The maturity of the fixed pool that the position is being deleveraged out of, `0` if floating.
  /// @param maxRepayAssets Max amount of fixed debt that the sender is willing to accept.
  /// @param percentage The percentage of the borrow that will be repaid, represented with 18 decimals.
  /// @param withdraw The amount of assets that will be withdrawn to `_msgSender`.
  function deleverage(
    Market market,
    uint256 maturity,
    uint256 maxRepayAssets,
    uint256 percentage,
    uint256 withdraw
  ) public msgSender {
    RollVars memory r;
    r.amounts = new uint256[](1);
    r.tokens = new ERC20[](1);
    r.tokens[0] = market.asset();
    address sender = _msgSender;

    if (maturity == 0) {
      {
        (, , uint256 floatingBorrowShares) = market.accounts(sender);
        uint256 amount = market.previewRefund(floatingBorrowShares.mulWadDown(percentage));
        r.loopCount = amount.mulDivUp(1, r.tokens[0].balanceOf(address(balancerVault)));
        r.amounts[0] = amount.mulDivUp(1, r.loopCount);
      }
      r.calls = new bytes[](2 * r.loopCount + (withdraw == 0 ? 0 : 1));
      uint256 callIndex = 0;
      for (uint256 i = 0; i < r.loopCount; ) {
        r.calls[callIndex++] = abi.encodeCall(market.repay, (r.amounts[0], sender));
        r.calls[callIndex++] = abi.encodeCall(
          market.withdraw,
          (r.amounts[0], i + 1 == r.loopCount ? address(balancerVault) : address(this), sender)
        );
        unchecked {
          ++i;
        }
      }
      if (withdraw != 0) r.calls[callIndex] = abi.encodeCall(market.withdraw, (withdraw, sender, sender));

      balancerVault.flashLoan(address(this), r.tokens, r.amounts, call(abi.encode(market, r.calls)));
    } else {
      r.principal = market.convertToAssets(market.balanceOf(sender));
      (r.repayAssets, r.positionAssets) = repayAtMaturityAssets(market, maturity, percentage);
      r.loopCount = r.repayAssets.mulDivUp(1, r.tokens[0].balanceOf(address(balancerVault)));
      r.positionAssets = r.positionAssets / r.loopCount;
      r.amounts[0] = r.repayAssets.mulDivUp(1, r.loopCount);
      r.calls = new bytes[](2 * r.loopCount + (withdraw == 0 ? 0 : 1));
      for (r.i = 0; r.i < r.loopCount; ) {
        r.calls[r.callIndex++] = abi.encodeCall(
          market.repayAtMaturity,
          (maturity, r.positionAssets, type(uint256).max, sender)
        );
        r.calls[r.callIndex++] = abi.encodeCall(
          market.withdraw,
          (r.amounts[0], r.i + 1 == r.loopCount ? address(balancerVault) : address(this), sender)
        );
        unchecked {
          ++r.i;
        }
      }
      if (withdraw != 0) r.calls[r.callIndex] = abi.encodeCall(market.withdraw, (withdraw, sender, sender));

      balancerVault.flashLoan(address(this), r.tokens, r.amounts, call(abi.encode(market, r.calls)));
      if (maxRepayAssets < r.principal - market.convertToAssets(market.balanceOf(sender))) revert Disagreement();
    }
  }

  /// @notice Rolls a percentage of the floating position of `_msgSender` to a fixed position.
  /// @param market The Market to roll the position in.
  /// @param borrowMaturity The maturity of the fixed pool that the position is being rolled to.
  /// @param maxBorrowAssets Max amount of debt that the sender is willing to accept to be borrowed.
  /// @param percentage The percentage of the position that will be rolled, represented with 18 decimals.
  function rollFloatingToFixed(
    Market market,
    uint256 borrowMaturity,
    uint256 maxBorrowAssets,
    uint256 percentage
  ) public msgSender {
    RollVars memory r;
    r.amounts = new uint256[](1);
    r.tokens = new ERC20[](1);
    r.tokens[0] = market.asset();
    address sender = _msgSender;

    (r.principal, r.fee) = market.fixedBorrowPositions(borrowMaturity, sender);
    (, , uint256 floatingBorrowShares) = market.accounts(sender);
    r.repayAssets = market.previewRefund(
      percentage < 1e18 ? floatingBorrowShares.mulWadDown(percentage) : floatingBorrowShares
    );
    r.loopCount = r.repayAssets.mulDivUp(1, r.tokens[0].balanceOf(address(balancerVault)));

    r.amounts[0] = r.repayAssets.mulDivUp(1, r.loopCount);
    r.calls = new bytes[](2 * r.loopCount);
    for (r.i = 0; r.i < r.loopCount; ) {
      r.calls[r.callIndex++] = abi.encodeCall(market.repay, (r.amounts[0], sender));
      r.calls[r.callIndex++] = abi.encodeCall(
        market.borrowAtMaturity,
        (
          borrowMaturity,
          r.amounts[0],
          type(uint256).max,
          r.i + 1 == r.loopCount ? address(balancerVault) : address(this),
          sender
        )
      );
      unchecked {
        ++r.i;
      }
    }

    balancerVault.flashLoan(address(this), r.tokens, r.amounts, call(abi.encode(market, r.calls)));
    (uint256 newPrincipal, uint256 newFee) = market.fixedBorrowPositions(borrowMaturity, sender);
    if (maxBorrowAssets < newPrincipal + newFee - r.principal - r.fee) revert Disagreement();
  }

  /// @notice Rolls a percentage of the fixed position of `_msgSender` to a floating position.
  /// @param market The Market to roll the position in.
  /// @param repayMaturity The maturity of the fixed pool that the position is being rolled from.
  /// @param maxRepayAssets Max amount of debt that the account is willing to accept to be repaid.
  /// @param percentage The percentage of the position that will be rolled, represented with 18 decimals.
  function rollFixedToFloating(
    Market market,
    uint256 repayMaturity,
    uint256 maxRepayAssets,
    uint256 percentage
  ) public msgSender {
    RollVars memory r;
    r.amounts = new uint256[](1);
    r.tokens = new ERC20[](1);
    r.tokens[0] = market.asset();
    address sender = _msgSender;

    {
      (, , uint256 floatingBorrowShares) = market.accounts(sender);
      r.principal = market.previewRefund(floatingBorrowShares);
    }
    (uint256 repayAssets, uint256 positionAssets) = repayAtMaturityAssets(market, repayMaturity, percentage);
    r.loopCount = repayAssets.mulDivUp(1, r.tokens[0].balanceOf(address(balancerVault)));
    positionAssets = positionAssets / r.loopCount;

    r.amounts[0] = repayAssets.mulDivUp(1, r.loopCount);
    r.calls = new bytes[](2 * r.loopCount);
    for (r.i = 0; r.i < r.loopCount; ) {
      r.calls[r.callIndex++] = abi.encodeCall(
        market.repayAtMaturity,
        (repayMaturity, positionAssets, type(uint256).max, sender)
      );
      r.calls[r.callIndex++] = abi.encodeCall(
        market.borrow,
        (r.amounts[0], r.i + 1 == r.loopCount ? address(balancerVault) : address(this), sender)
      );
      unchecked {
        ++r.i;
      }
    }
    balancerVault.flashLoan(address(this), r.tokens, r.amounts, call(abi.encode(market, r.calls)));
    {
      (, , uint256 floatingBorrowShares) = market.accounts(sender);
      if (maxRepayAssets < market.previewRefund(floatingBorrowShares) - r.principal) revert Disagreement();
    }
  }

  /// @notice Rolls a percentage of the fixed position of `_msgSender` to another fixed pool.
  /// @param market The Market to roll the position in.
  /// @param repayMaturity The maturity of the fixed pool that the position is being rolled from.
  /// @param borrowMaturity The maturity of the fixed pool that the position is being rolled to.
  /// @param maxRepayAssets Max amount of debt that the account is willing to accept to be repaid.
  /// @param maxBorrowAssets Max amount of debt that the sender is willing to accept to be borrowed.
  /// @param percentage The percentage of the position that will be rolled, represented with 18 decimals.
  function rollFixed(
    Market market,
    uint256 repayMaturity,
    uint256 borrowMaturity,
    uint256 maxRepayAssets,
    uint256 maxBorrowAssets,
    uint256 percentage
  ) public msgSender {
    RollVars memory r;
    r.amounts = new uint256[](1);
    r.tokens = new ERC20[](1);
    r.tokens[0] = market.asset();
    address sender = _msgSender;

    (r.principal, r.fee) = market.fixedBorrowPositions(borrowMaturity, sender);
    (r.repayAssets, r.positionAssets) = repayAtMaturityAssets(market, repayMaturity, percentage);

    r.loopCount = r.repayAssets.mulDivUp(1, r.tokens[0].balanceOf(address(balancerVault)));
    if (r.loopCount > 1 && repayMaturity == borrowMaturity) revert InvalidOperation();

    r.amounts[0] = r.repayAssets.mulDivUp(1, r.loopCount);
    r.positionAssets = r.positionAssets / r.loopCount;
    r.calls = new bytes[](2 * r.loopCount);
    for (r.i = 0; r.i < r.loopCount; ) {
      r.calls[r.callIndex++] = abi.encodeCall(
        market.repayAtMaturity,
        (repayMaturity, r.positionAssets, type(uint256).max, sender)
      );
      r.calls[r.callIndex++] = abi.encodeCall(
        market.borrowAtMaturity,
        (
          borrowMaturity,
          r.amounts[0],
          type(uint256).max,
          r.i + 1 == r.loopCount ? address(balancerVault) : address(this),
          sender
        )
      );
      unchecked {
        ++r.i;
      }
    }

    balancerVault.flashLoan(address(this), r.tokens, r.amounts, call(abi.encode(market, r.calls)));
    (uint256 newPrincipal, uint256 newFee) = market.fixedBorrowPositions(borrowMaturity, sender);
    if (
      newPrincipal + newFee >
      (
        maxBorrowAssets < type(uint256).max - r.principal - r.fee
          ? maxBorrowAssets + r.principal + r.fee
          : type(uint256).max
      ) ||
      newPrincipal >
      (maxRepayAssets < type(uint256).max - r.principal ? maxRepayAssets + r.principal : type(uint256).max)
    ) {
      revert Disagreement();
    }
  }

  /// @notice Calculates the actual repay and position assets of a repay operation at maturity.
  /// @param market The Market to calculate the actual repay and position assets.
  /// @param maturity The maturity of the fixed pool in which the position is being repaid.
  /// @param percentage The percentage of the position that will be repaid, represented with 18 decimals.
  /// @return actualRepay The actual amount of assets that will be repaid.
  /// @return positionAssets The amount of principal and fee to be covered.
  function repayAtMaturityAssets(
    Market market,
    uint256 maturity,
    uint256 percentage
  ) internal view returns (uint256 actualRepay, uint256 positionAssets) {
    FixedLib.Position memory position;
    (position.principal, position.fee) = market.fixedBorrowPositions(maturity, _msgSender);
    positionAssets = percentage < 1e18
      ? percentage.mulWadDown(position.principal + position.fee)
      : position.principal + position.fee;
    if (block.timestamp < maturity) {
      FixedLib.Pool memory pool;
      (pool.borrowed, pool.supplied, pool.unassignedEarnings, pool.lastAccrual) = market.fixedPools(maturity);
      pool.unassignedEarnings -= pool.unassignedEarnings.mulDivDown(
        block.timestamp - pool.lastAccrual,
        maturity - pool.lastAccrual
      );
      (uint256 yield, ) = pool.calculateDeposit(
        position.scaleProportionally(positionAssets).principal,
        market.backupFeeRate()
      );
      actualRepay = positionAssets - yield;
    } else {
      actualRepay = positionAssets + positionAssets.mulWadDown((block.timestamp - maturity) * market.penaltyRate());
    }
  }

  /// @notice Hash of the call data that will be used to verify that the flash loan is originated from `this`.
  bytes32 private callHash;

  /// @notice Hashes the data and stores its value in `callHash`.
  /// @param data The calldata to be hashed.
  /// @return Same calldata that was passed as an argument.
  function call(bytes memory data) internal returns (bytes memory) {
    callHash = keccak256(data);
    return data;
  }

  /// @notice Callback function called by the Balancer Vault contract when a flash loan is initiated.
  /// @dev Only the Balancer Vault contract is allowed to call this function.
  /// @param userData Additional data provided by the borrower for the flash loan.
  function receiveFlashLoan(ERC20[] memory, uint256[] memory, uint256[] memory, bytes memory userData) external {
    bytes32 memCallHash = callHash;
    assert(msg.sender == address(balancerVault) && memCallHash != bytes32(0) && memCallHash == keccak256(userData));
    callHash = bytes32(0);

    (Market market, bytes[] memory calls) = abi.decode(userData, (Market, bytes[]));
    for (uint256 i = 0; i < calls.length; ) {
      address(market).functionCall(calls[i], "");
      unchecked {
        ++i;
      }
    }
  }

  /// @notice Callback function called by the Uniswap V3 pool contract when a swap is initiated.
  /// @dev Only the Uniswap V3 pool contract is allowed to call this function.
  /// @param amount0Delta The amount of token0 that was sent (negative) or must be received (positive) by the pool by
  /// the end of the swap. If positive, the callback must send that amount of token0 to the pool.
  /// @param amount1Delta The amount of token1 that was sent (negative) or must be received (positive) by the pool by
  /// the end of the swap. If positive, the callback must send that amount of token1 to the pool.
  /// @param data Any data passed through by the caller via the IUniswapV3PoolActions#swap call
  function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
    SwapCallbackData memory s = abi.decode(data, (SwapCallbackData));
    PoolKey memory poolKey = PoolAddress.getPoolKey(s.assetIn, s.assetOut, s.fee);
    assert(msg.sender == PoolAddress.computeAddress(uniswapV3Factory, poolKey));

    if (s.leverage) {
      s.marketIn.deposit(
        s.principal + uint256(-(s.assetIn == poolKey.token0 ? amount0Delta : amount1Delta)),
        s.account
      );
      s.marketOut.borrow(uint256(s.assetIn == poolKey.token1 ? amount0Delta : amount1Delta), msg.sender, s.account);
    } else {
      s.marketOut.repay(s.principal, s.account);
      s.marketIn.withdraw(
        s.assetIn == poolKey.token1 ? uint256(amount1Delta) : uint256(amount0Delta),
        msg.sender,
        s.account
      );
    }
  }

  address private _msgSender;

  modifier msgSender() {
    if (_msgSender == address(0)) _msgSender = msg.sender;
    _;
    delete _msgSender;
  }

  /// @notice Calls `token.permit` on behalf of `permit.account`.
  /// @param token The `ERC20` to call `permit`.
  /// @param p Arguments for the permit call.
  modifier permit(
    ERC20 token,
    uint256 assets,
    Permit calldata p
  ) {
    token.permit(p.account, address(this), assets, p.deadline, p.v, p.r, p.s);
    {
      address sender = _msgSender;
      if (sender == address(0)) _msgSender = p.account;
      else assert(p.account == sender);
    }
    _;
    assert(_msgSender == address(0));
  }

  /// @notice Calls `token`'s `transferFrom` to transfer `_msgSender` assets.
  /// @param token The `ERC20` to transfer from `_msgSender` to this contract.
  /// @param value The amount of tokens to transfer from `_msgSender`.
  modifier transfer(ERC20 token, uint256 value) {
    token.transferFrom(_msgSender, address(this), value);
    _;
  }

  /// @notice Calls `permit2.permitTransferFrom` to transfer `_msgSender` assets.
  /// @param token The `ERC20` to transfer from `_msgSender` to this contract.
  /// @param assets The amount of assets to transfer from `_msgSender`.
  modifier permitTransfer(
    ERC20 token,
    uint256 assets,
    Permit2 calldata p2
  ) {
    {
      address sender = _msgSender;
      permit2.permitTransferFrom(
        IPermit2.PermitTransferFrom(
          IPermit2.TokenPermissions(address(token), assets),
          uint256(keccak256(abi.encode(sender, token, assets, p2.deadline))),
          p2.deadline
        ),
        IPermit2.SignatureTransferDetails(address(this), assets),
        sender,
        p2.signature
      );
    }
    _;
  }

  /// @notice Leverages the floating position of `_msgSender` a certain `multiplier` by taking a flash loan
  /// from Balancer's vault.
  /// @param market The Market to leverage the position in.
  /// @param principal The amount of assets to leverage.
  /// @param deposit The amount of assets to deposit.
  /// @param multiplier The number of times that the `principal` will be leveraged, represented with 18 decimals.
  function leverage(
    Market market,
    uint256 principal,
    uint256 deposit,
    uint256 multiplier,
    uint256 borrowAssets,
    Permit calldata marketPermit,
    Permit2 calldata assetPermit
  ) external permit(market, borrowAssets, marketPermit) permitTransfer(market.asset(), deposit, assetPermit) msgSender {
    noTransferLeverage(market, principal, deposit, multiplier);
  }

  function leverage(
    Market market,
    uint256 principal,
    uint256 deposit,
    uint256 multiplier,
    uint256 borrowAssets,
    Permit calldata marketPermit,
    Permit calldata assetPermit
  ) external permit(market, borrowAssets, marketPermit) permit(market.asset(), deposit, assetPermit) {
    leverage(market, principal, deposit, multiplier);
  }

  /// @notice Cross-leverages the floating position of `_msgSender` a certain `multiplier` by taking a flash swap
  /// from Uniswap's pool.
  /// @param marketIn The Market to deposit the leveraged position.
  /// @param marketOut The Market to borrow the leveraged position.
  /// @param fee The fee of the pool that will be used to swap the assets.
  /// @param principal The amount of `marketIn` underlying assets to leverage.
  /// @param deposit The amount of `marketIn` underlying assets to deposit.
  /// @param multiplier The number of times that the `principal` will be leveraged, represented with 18 decimals.
  function crossLeverage(
    Market marketIn,
    Market marketOut,
    uint24 fee,
    uint256 principal,
    uint256 deposit,
    uint256 multiplier,
    uint256 borrowAssets,
    Permit calldata marketPermit,
    Permit2 calldata assetPermit
  )
    external
    permit(marketOut, borrowAssets, marketPermit)
    permitTransfer(marketIn.asset(), deposit, assetPermit)
    msgSender
  {
    noTransferCrossLeverage(marketIn, marketOut, fee, principal, deposit, multiplier);
  }

  /// @notice Deleverages a `percentage` position of `_msgSender` by taking a flash swap from Uniswap's pool.
  /// @param marketIn The Market to withdraw the leveraged position.
  /// @param marketOut The Market to repay the leveraged position.
  /// @param fee The fee of the pool that will be used to swap the assets.
  /// @param percentage The percentage that the position will be deleveraged.
  /// @param permitAssets The amount of assets to allow.
  /// @param p Arguments for the permit call to `marketIn` on behalf of `_msgSender`.
  /// Permit `value` should be `permitAssets`.
  function crossDeleverage(
    Market marketIn,
    Market marketOut,
    uint24 fee,
    uint256 percentage,
    uint256 permitAssets,
    Permit calldata p
  ) external permit(marketIn, permitAssets, p) {
    crossDeleverage(marketIn, marketOut, fee, percentage);
  }

  /// @notice Deleverages the position of `_msgSender` a certain `percentage` by taking a flash loan from
  /// Balancer's vault to repay the borrow.
  /// @param market The Market to deleverage the position out.
  /// @param maturity The maturity of the fixed pool that the position is being deleveraged out of, `0` if floating.
  /// @param maxRepayAssets Max amount of fixed debt that the sender is willing to accept.
  /// @param percentage The percentage of the borrow that will be repaid, represented with 18 decimals.
  /// @param withdraw The amount of assets that will be withdrawn to `_msgSender`.
  /// @param permitAssets The amount of assets to allow this contract to withdraw on behalf of `_msgSender`.
  /// @param p Arguments for the permit call to `market` on behalf of `permit.account`.
  /// Permit `value` should be `permitAssets`.
  function deleverage(
    Market market,
    uint256 maturity,
    uint256 maxRepayAssets,
    uint256 percentage,
    uint256 withdraw,
    uint256 permitAssets,
    Permit calldata p
  ) external permit(market, permitAssets, p) {
    deleverage(market, maturity, maxRepayAssets, percentage, withdraw);
  }

  /// @notice Rolls a percentage of the floating position of `_msgSender` to a fixed position
  /// after calling `market.permit`.
  /// @param market The Market to roll the position in.
  /// @param borrowMaturity The maturity of the fixed pool that the position is being rolled to.
  /// @param maxBorrowAssets Max amount of debt that the sender is willing to accept to be borrowed.
  /// @param percentage The percentage of the position that will be rolled, represented with 18 decimals.
  /// @param p Arguments for the permit call to `market` on behalf of `permit.account`.
  /// Permit `value` should be `maxBorrowAssets`.
  function rollFloatingToFixed(
    Market market,
    uint256 borrowMaturity,
    uint256 maxBorrowAssets,
    uint256 percentage,
    Permit calldata p
  ) external permit(market, maxBorrowAssets, p) {
    rollFloatingToFixed(market, borrowMaturity, maxBorrowAssets, percentage);
  }

  /// @notice Rolls a percentage of the fixed position of `_msgSender` to a floating position
  /// after calling `market.permit`.
  /// @param market The Market to roll the position in.
  /// @param repayMaturity The maturity of the fixed pool that the position is being rolled from.
  /// @param maxRepayAssets Max amount of debt that the account is willing to accept to be repaid.
  /// @param percentage The percentage of the position that will be rolled, represented with 18 decimals.
  /// @param p Arguments for the permit call to `market` on behalf of `permit.account`.
  /// Permit `value` should be `maxRepayAssets`.
  function rollFixedToFloating(
    Market market,
    uint256 repayMaturity,
    uint256 maxRepayAssets,
    uint256 percentage,
    Permit calldata p
  ) external permit(market, maxRepayAssets, p) {
    rollFixedToFloating(market, repayMaturity, maxRepayAssets, percentage);
  }

  /// @notice Rolls a percentage of the fixed position of `_msgSender` to another fixed pool
  /// after calling `market.permit`.
  /// @param market The Market to roll the position in.
  /// @param repayMaturity The maturity of the fixed pool that the position is being rolled from.
  /// @param borrowMaturity The maturity of the fixed pool that the position is being rolled to.
  /// @param maxRepayAssets Max amount of debt that the account is willing to accept to be repaid.
  /// @param maxBorrowAssets Max amount of debt that the sender is willing to accept to be borrowed.
  /// @param percentage The percentage of the position that will be rolled, represented with 18 decimals.
  /// @param p Arguments for the permit call to `market` on behalf of `permit.account`.
  /// Permit `value` should be `maxBorrowAssets`.
  function rollFixed(
    Market market,
    uint256 repayMaturity,
    uint256 borrowMaturity,
    uint256 maxRepayAssets,
    uint256 maxBorrowAssets,
    uint256 percentage,
    Permit calldata p
  ) external permit(market, maxBorrowAssets, p) {
    rollFixed(market, repayMaturity, borrowMaturity, maxRepayAssets, maxBorrowAssets, percentage);
  }

  /// @notice Returns Balancer Vault's available liquidity of each enabled underlying asset.
  function availableLiquidity() external view returns (AvailableAsset[] memory availableAssets) {
    uint256 marketsCount = auditor.allMarkets().length;
    availableAssets = new AvailableAsset[](marketsCount);

    for (uint256 i = 0; i < marketsCount; i++) {
      ERC20 asset = auditor.marketList(i).asset();
      availableAssets[i] = AvailableAsset({ asset: asset, liquidity: asset.balanceOf(address(balancerVault)) });
    }
  }

  /// @notice Approves the Market to spend the contract's balance of the underlying asset.
  /// @dev The Market must be listed by the Auditor in order to be valid for approval.
  /// @param market The Market to spend the contract's balance.
  function approve(Market market) external {
    (, , , bool isListed, ) = auditor.markets(market);
    if (!isListed) revert MarketNotListed();

    market.asset().safeApprove(address(market), type(uint256).max);
  }

  struct AvailableAsset {
    ERC20 asset;
    uint256 liquidity;
  }
  struct SwapCallbackData {
    Market marketIn;
    Market marketOut;
    address assetIn;
    address assetOut;
    address account;
    uint256 principal;
    uint24 fee;
    bool leverage;
  }
}

error InvalidOperation();

struct Permit {
  address account;
  uint256 deadline;
  uint8 v;
  bytes32 r;
  bytes32 s;
}

struct Permit2 {
  uint256 deadline;
  bytes signature;
}

struct RollVars {
  uint256[] amounts;
  ERC20[] tokens;
  bytes[] calls;
  uint256 positionAssets;
  uint256 repayAssets;
  uint256 callIndex;
  uint256 loopCount;
  uint256 principal;
  uint256 fee;
  uint256 i;
}

struct LeverageVars {
  address assetIn;
  address assetOut;
  uint256 amount;
}

interface IBalancerVault {
  function flashLoan(
    address recipient,
    ERC20[] memory tokens,
    uint256[] memory amounts,
    bytes memory userData
  ) external;
}

interface IPermit2 {
  struct TokenPermissions {
    address token;
    uint256 amount;
  }

  struct PermitTransferFrom {
    TokenPermissions permitted;
    uint256 nonce;
    uint256 deadline;
  }

  struct SignatureTransferDetails {
    address to;
    uint256 requestedAmount;
  }

  function permitTransferFrom(
    PermitTransferFrom memory permit,
    SignatureTransferDetails calldata transferDetails,
    address owner,
    bytes calldata signature
  ) external;

  // solhint-disable-next-line func-name-mixedcase
  function DOMAIN_SEPARATOR() external view returns (bytes32);
}

interface IUniswapV3Pool {
  function swap(
    address recipient,
    bool zeroForOne,
    int256 amountSpecified,
    uint160 sqrtPriceLimitX96,
    bytes calldata data
  ) external returns (int256 amount0, int256 amount1);
}

// https://github.com/Uniswap/v3-periphery/pull/271
library PoolAddress {
  bytes32 internal constant POOL_INIT_CODE_HASH = 0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54;

  function getPoolKey(address tokenA, address tokenB, uint24 fee) internal pure returns (PoolKey memory) {
    if (tokenA > tokenB) (tokenA, tokenB) = (tokenB, tokenA);
    return PoolKey({ token0: tokenA, token1: tokenB, fee: fee });
  }

  function computeAddress(address uniswapV3Factory, PoolKey memory key) internal pure returns (address pool) {
    assert(key.token0 < key.token1);
    pool = address(
      uint160(
        uint256(
          keccak256(
            abi.encodePacked(
              hex"ff",
              uniswapV3Factory,
              keccak256(abi.encode(key.token0, key.token1, key.fee)),
              POOL_INIT_CODE_HASH
            )
          )
        )
      )
    );
  }
}

struct PoolKey {
  address token0;
  address token1;
  uint24 fee;
}
