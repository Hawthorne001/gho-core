// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import './TestGhoBase.t.sol';

contract TestGsmConverter is TestGhoBase {
  // using PercentageMath for uint256;
  // using PercentageMath for uint128;

  function setUp() public {
    // (gsmSignerAddr, gsmSignerKey) = makeAddrAndKey('gsmSigner');
  }

  function testConstructor() public {
    GsmConverter gsmConverter = new GsmConverter(
      address(GHO_GSM),
      address(REDEMPTION),
      address(BUIDL_TOKEN),
      address(USDC_TOKEN)
    );
    assertEq(gsmConverter.GSM(), address(GHO_GSM), 'Unexpected GSM address');
    assertEq(
      gsmConverter.REDEMPTION_CONTRACT(),
      address(REDEMPTION),
      'Unexpected redemption contract address'
    );
    assertEq(
      gsmConverter.REDEEMABLE_ASSET(),
      address(BUIDL_TOKEN),
      'Unexpected redeemable asset address'
    );
    assertEq(
      gsmConverter.REDEEMED_ASSET(),
      address(USDC_TOKEN),
      'Unexpected redeemed asset address'
    );
  }

  function testRevertConstructorZeroAddressParams() public {
    vm.expectRevert('ZERO_ADDRESS_NOT_VALID');
    new GsmConverter(address(0), address(REDEMPTION), address(BUIDL_TOKEN), address(USDC_TOKEN));

    vm.expectRevert('ZERO_ADDRESS_NOT_VALID');
    new GsmConverter(address(GHO_GSM), address(0), address(BUIDL_TOKEN), address(USDC_TOKEN));

    vm.expectRevert('ZERO_ADDRESS_NOT_VALID');
    new GsmConverter(address(GHO_GSM), address(REDEMPTION), address(0), address(USDC_TOKEN));

    vm.expectRevert('ZERO_ADDRESS_NOT_VALID');
    new GsmConverter(address(GHO_GSM), address(REDEMPTION), address(BUIDL_TOKEN), address(0));
  }
}