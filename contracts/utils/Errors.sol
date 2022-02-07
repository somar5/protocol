// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "./TSUtils.sol";

error GenericError(ErrorCode error);
error UnmatchedPoolState(TSUtils.State state, TSUtils.State requiredState);
error UnmatchedPoolStateMultiple(
    TSUtils.State state,
    TSUtils.State requiredState,
    TSUtils.State alternativeState
);

enum ErrorCode {
    NO_ERROR,
    MARKET_NOT_LISTED,
    MARKET_ALREADY_LISTED,
    SNAPSHOT_ERROR,
    PRICE_ERROR,
    INSUFFICIENT_LIQUIDITY,
    INSUFFICIENT_SHORTFALL,
    AUDITOR_MISMATCH,
    TOO_MUCH_REPAY,
    REPAY_ZERO,
    TOKENS_MORE_THAN_BALANCE,
    INVALID_POOL_STATE,
    INVALID_POOL_ID,
    LIQUIDATOR_NOT_BORROWER,
    NOT_A_FIXED_LENDER_SENDER,
    INVALID_SET_BORROW_CAP,
    MARKET_BORROW_CAP_REACHED,
    INCONSISTENT_PARAMS_LENGTH,
    REDEEM_CANT_BE_ZERO,
    EXIT_MARKET_BALANCE_OWED,
    CALLER_MUST_BE_FIXED_LENDER,
    CONTRACT_ALREADY_INITIALIZED,
    INSUFFICIENT_PROTOCOL_LIQUIDITY,
    TOO_MUCH_SLIPPAGE,
    SMART_POOL_FUNDS_LOCKED
}
