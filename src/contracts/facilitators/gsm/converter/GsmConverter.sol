// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {GPv2SafeERC20} from '@aave/core-v3/contracts/dependencies/gnosis/contracts/GPv2SafeERC20.sol';
import {IERC20} from '@aave/core-v3/contracts/dependencies/openzeppelin/contracts/IERC20.sol';
import {IGhoToken} from '../../../gho/interfaces/IGhoToken.sol';
import {IGsm} from '../interfaces/IGsm.sol';
import {IGsmConverter} from './interfaces/IGsmConverter.sol';
import {IRedemption} from '../dependencies/circle/IRedemption.sol';

/**
 * @title GsmConverter
 * @author Aave
 * @notice Converter that facilitates conversions/redemptions of underlying assets. Integrates with GSM to buy/sell to go to/from an underlying asset to/from GHO.
 */
contract GsmConverter is IGsmConverter {
  using GPv2SafeERC20 for IERC20;

  /// @inheritdoc IGsmConverter
  address public immutable GSM;

  /// @inheritdoc IGsmConverter
  address public immutable REDEEMABLE_ASSET;

  /// @inheritdoc IGsmConverter
  address public immutable REDEEMED_ASSET;

  /// @inheritdoc IGsmConverter
  address public immutable REDEMPTION_CONTRACT;

  /**
   * @dev Constructor
   * @param gsm The address of the associated GSM contract
   * @param redemptionContract The address of the redemption contract associated with the redemption/conversion
   * @param redeemableAsset The address of the asset being redeemed
   * @param redeemedAsset The address of the asset being received from redemption
   */
  constructor(
    address gsm,
    address redemptionContract,
    address redeemableAsset,
    address redeemedAsset
  ) {
    require(gsm != address(0), 'ZERO_ADDRESS_NOT_VALID');
    require(redemptionContract != address(0), 'ZERO_ADDRESS_NOT_VALID');
    require(redeemableAsset != address(0), 'ZERO_ADDRESS_NOT_VALID');
    require(redeemedAsset != address(0), 'ZERO_ADDRESS_NOT_VALID');

    GSM = gsm;
    REDEMPTION_CONTRACT = redemptionContract;
    REDEEMABLE_ASSET = redeemableAsset; // BUIDL
    REDEEMED_ASSET = redeemedAsset; // USDC
  }

  /// @inheritdoc IGsmConverter
  function buyAsset(uint256 minAmount, address receiver) external returns (uint256, uint256) {
    require(minAmount > 0, 'INVALID_MIN_AMOUNT');

    IGhoToken ghoToken = IGhoToken(IGsm(GSM).GHO_TOKEN());
    (, uint256 ghoAmount, , ) = IGsm(GSM).getGhoAmountForBuyAsset(minAmount);

    ghoToken.transferFrom(msg.sender, address(this), ghoAmount);
    ghoToken.approve(address(GSM), ghoAmount);

    (uint256 redeemableAssetAmount, uint256 ghoSold) = IGsm(GSM).buyAsset(minAmount, address(this));
    IERC20(REDEEMABLE_ASSET).approve(address(REDEMPTION_CONTRACT), redeemableAssetAmount);
    IRedemption(REDEMPTION_CONTRACT).redeem(redeemableAssetAmount);
    // redeemableAssetAmount matches redeemedAssetAmount because Redemption exchanges in 1:1 ratio
    IERC20(REDEEMED_ASSET).safeTransfer(receiver, redeemableAssetAmount);

    emit BuyAssetThroughRedemption(msg.sender, receiver, redeemableAssetAmount, ghoSold);
    return (redeemableAssetAmount, ghoSold);
  }

  // TODO:
  // 2) implement sellAsset (sell USDC -> get GHO)
  // - onramp USDC to BUIDL, get BUIDL - unknown how to onramp USDC to BUIDL currently
  // - send BUIDL to GSM, get GHO from GSM
  // - send GHO to user, safeTransfer

  // TODO:
  // rescueTokens function to rescue any ERC20 tokens that are accidentally sent to this contract
}
