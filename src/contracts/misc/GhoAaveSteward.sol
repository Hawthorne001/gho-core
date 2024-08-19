// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {Address} from 'solidity-utils/contracts/oz-common/Address.sol';
import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {IPoolDataProvider} from 'aave-address-book/AaveV3.sol';
import {IPoolAddressesProvider} from '@aave/core-v3/contracts/interfaces/IPoolAddressesProvider.sol';
import {IPool} from '@aave/core-v3/contracts/interfaces/IPool.sol';
import {DataTypes} from '@aave/core-v3/contracts/protocol/libraries/types/DataTypes.sol';
import {ReserveConfiguration} from '@aave/core-v3/contracts/protocol/libraries/configuration/ReserveConfiguration.sol';
import {IPoolConfigurator} from './deps/IPoolConfigurator.sol';
import {IDefaultInterestRateStrategyV2} from './deps/Dependencies.sol';
import {DefaultReserveInterestRateStrategyV2} from './deps/Dependencies.sol';
import {IGhoAaveSteward} from './interfaces/IGhoAaveSteward.sol';
import {RiskCouncilControlled} from './RiskCouncilControlled.sol';

/**
 * @title GhoAaveSteward
 * @author Aave Labs
 * @notice Helper contract for managing parameters of the GHO reserve
 * @dev Only the Risk Council is able to action contract's functions, based on specific conditions that have been agreed upon with the community.
 * @dev Requires role RiskAdmin on the Aave V3 Ethereum Pool
 */
contract GhoAaveSteward is Ownable, RiskCouncilControlled, IGhoAaveSteward {
  using ReserveConfiguration for DataTypes.ReserveConfigurationMap;
  using Address for address;

  /// @inheritdoc IGhoAaveSteward
  uint256 public constant GHO_BORROW_RATE_MAX = 0.25e4; // 25.00%

  uint256 internal constant BPS_MAX = 100_00;

  /// @inheritdoc IGhoAaveSteward
  address public immutable POOL_DATA_PROVIDER;

  /// @inheritdoc IGhoAaveSteward
  uint256 public constant MINIMUM_DELAY = 2 days;

  /// @inheritdoc IGhoAaveSteward
  address public immutable POOL_ADDRESSES_PROVIDER;

  /// @inheritdoc IGhoAaveSteward
  address public immutable GHO_TOKEN;

  BorrowRateConfig internal _borrowRateConfig;

  GhoDebounce internal _ghoTimelocks;

  /**
   * @dev Only methods that are not timelocked can be called if marked by this modifier.
   */
  modifier notTimelocked(uint40 timelock) {
    require(block.timestamp - timelock > MINIMUM_DELAY, 'DEBOUNCE_NOT_RESPECTED');
    _;
  }

  /**
   * @dev Constructor
   * @param owner The address of the contract's owner
   * @param addressesProvider The address of the PoolAddressesProvider of Aave V3 Ethereum Pool
   * @param poolDataProvider The pool data provider of the pool to be controlled by the steward
   * @param ghoToken The address of the GhoToken
   * @param riskCouncil The address of the risk council
   * @param borrowRateConfig The initial borrow rate configuration for the Gho reserve
   */
  constructor(
    address owner,
    address addressesProvider,
    address poolDataProvider,
    address ghoToken,
    address riskCouncil,
    BorrowRateConfig memory borrowRateConfig
  ) RiskCouncilControlled(riskCouncil) {
    require(owner != address(0), 'INVALID_OWNER');
    require(addressesProvider != address(0), 'INVALID_ADDRESSES_PROVIDER');
    require(poolDataProvider != address(0), 'INVALID_DATA_PROVIDER');
    require(ghoToken != address(0), 'INVALID_GHO_TOKEN');

    POOL_ADDRESSES_PROVIDER = addressesProvider;
    POOL_DATA_PROVIDER = poolDataProvider;
    GHO_TOKEN = ghoToken;
    _borrowRateConfig = borrowRateConfig;

    _transferOwnership(owner);
  }

  /// @inheritdoc IGhoAaveSteward
  function updateGhoBorrowRate(
    uint256 optimalUsageRatio,
    uint256 baseVariableBorrowRate,
    uint256 variableRateSlope1,
    uint256 variableRateSlope2
  ) external onlyRiskCouncil notTimelocked(_ghoTimelocks.ghoBorrowRateLastUpdate) {
    _validateRatesUpdate(
      optimalUsageRatio,
      baseVariableBorrowRate,
      variableRateSlope1,
      variableRateSlope2
    );
    _updateRates(optimalUsageRatio, baseVariableBorrowRate, variableRateSlope1, variableRateSlope2);

    _ghoTimelocks.ghoBorrowRateLastUpdate = uint40(block.timestamp);
  }

  /// @inheritdoc IGhoAaveSteward
  function updateGhoBorrowCap(
    uint256 newBorrowCap
  ) external onlyRiskCouncil notTimelocked(_ghoTimelocks.ghoBorrowCapLastUpdate) {
    DataTypes.ReserveConfigurationMap memory configuration = IPool(
      IPoolAddressesProvider(POOL_ADDRESSES_PROVIDER).getPool()
    ).getConfiguration(GHO_TOKEN);
    uint256 currentBorrowCap = configuration.getBorrowCap();
    require(newBorrowCap != currentBorrowCap, 'NO_CHANGE_IN_BORROW_CAP');
    require(
      _isDifferenceLowerThanMax(currentBorrowCap, newBorrowCap, currentBorrowCap),
      'INVALID_BORROW_CAP_UPDATE'
    );

    _ghoTimelocks.ghoBorrowCapLastUpdate = uint40(block.timestamp);

    IPoolConfigurator(IPoolAddressesProvider(POOL_ADDRESSES_PROVIDER).getPoolConfigurator())
      .setBorrowCap(GHO_TOKEN, newBorrowCap);
  }

  /// @inheritdoc IGhoAaveSteward
  function updateGhoSupplyCap(
    uint256 newSupplyCap
  ) external onlyRiskCouncil notTimelocked(_ghoTimelocks.ghoSupplyCapLastUpdate) {
    DataTypes.ReserveConfigurationMap memory configuration = IPool(
      IPoolAddressesProvider(POOL_ADDRESSES_PROVIDER).getPool()
    ).getConfiguration(GHO_TOKEN);
    uint256 currentSupplyCap = configuration.getSupplyCap();
    require(newSupplyCap != currentSupplyCap, 'NO_CHANGE_IN_SUPPLY_CAP');
    require(
      _isDifferenceLowerThanMax(currentSupplyCap, newSupplyCap, currentSupplyCap),
      'INVALID_SUPPLY_CAP_UPDATE'
    );

    _ghoTimelocks.ghoSupplyCapLastUpdate = uint40(block.timestamp);

    IPoolConfigurator(IPoolAddressesProvider(POOL_ADDRESSES_PROVIDER).getPoolConfigurator())
      .setSupplyCap(GHO_TOKEN, newSupplyCap);
  }

  /// @inheritdoc IGhoAaveSteward
  function setBorrowRateConfig(
    uint256 optimalUsageRatioMaxChange,
    uint256 baseVariableBorrowRateMaxChange,
    uint256 variableRateSlope1MaxChange,
    uint256 variableRateSlope2MaxChange
  ) external onlyOwner notTimelocked(_ghoTimelocks.riskConfigLastUpdate) {
    _borrowRateConfig.optimalUsageRatioMaxChange = optimalUsageRatioMaxChange;
    _borrowRateConfig.baseVariableBorrowRateMaxChange = baseVariableBorrowRateMaxChange;
    _borrowRateConfig.variableRateSlope1MaxChange = variableRateSlope1MaxChange;
    _borrowRateConfig.variableRateSlope2MaxChange = variableRateSlope2MaxChange;

    _ghoTimelocks.riskConfigLastUpdate = uint40(block.timestamp);

    emit BorrowRateConfigSet(
      optimalUsageRatioMaxChange,
      baseVariableBorrowRateMaxChange,
      variableRateSlope1MaxChange,
      variableRateSlope2MaxChange
    );
  }

  /// @inheritdoc IGhoAaveSteward
  function getBorrowRateConfig() external view returns (BorrowRateConfig memory) {
    return _borrowRateConfig;
  }

  /// @inheritdoc IGhoAaveSteward
  function getGhoTimelocks() external view returns (GhoDebounce memory) {
    return _ghoTimelocks;
  }

  /// @inheritdoc IGhoAaveSteward
  function RISK_COUNCIL() public view override returns (address) {
    return COUNCIL;
  }

  /**
   * @notice method to update the interest rates params using the config engine and updates the debounce
   * @param optimalUsageRatio The new optimal usage ratio
   * @param baseVariableBorrowRate The new base variable borrow rate
   * @param variableRateSlope1 The new variable rate slope 1
   * @param variableRateSlope2 The new variable rate slope 2
   */
  function _updateRates(
    uint256 optimalUsageRatio,
    uint256 baseVariableBorrowRate,
    uint256 variableRateSlope1,
    uint256 variableRateSlope2
  ) internal {
    IDefaultInterestRateStrategyV2.InterestRateData
      memory rateParams = IDefaultInterestRateStrategyV2.InterestRateData({
        optimalUsageRatio: uint16(optimalUsageRatio),
        baseVariableBorrowRate: uint32(baseVariableBorrowRate),
        variableRateSlope1: uint32(variableRateSlope1),
        variableRateSlope2: uint32(variableRateSlope2)
      });

    IPoolConfigurator(IPoolAddressesProvider(POOL_ADDRESSES_PROVIDER).getPoolConfigurator())
      .setReserveInterestRateData(GHO_TOKEN, abi.encode(rateParams));
  }

  /**
   * @notice method to validate the interest rates update
   * @param optimalUsageRatio The new optimal usage ratio to validate
   * @param baseVariableBorrowRate The new base variable borrow rate to validate
   * @param variableRateSlope1 The new variable rate slope 1 to validate
   * @param variableRateSlope2 The new variable rate slope 2 to validate
   */
  function _validateRatesUpdate(
    uint256 optimalUsageRatio,
    uint256 baseVariableBorrowRate,
    uint256 variableRateSlope1,
    uint256 variableRateSlope2
  ) internal view {
    DataTypes.ReserveData memory ghoReserveData = IPool(
      IPoolAddressesProvider(POOL_ADDRESSES_PROVIDER).getPool()
    ).getReserveData(GHO_TOKEN);
    require(
      ghoReserveData.interestRateStrategyAddress != address(0),
      'GHO_INTEREST_RATE_STRATEGY_NOT_FOUND'
    );

    (
      uint256 currentOptimalUsageRatio,
      uint256 currentBaseVariableBorrowRate,
      uint256 currentVariableRateSlope1,
      uint256 currentVariableRateSlope2
    ) = _getInterestRatesForAsset(GHO_TOKEN);

    require(
      optimalUsageRatio != currentOptimalUsageRatio ||
        baseVariableBorrowRate != currentBaseVariableBorrowRate ||
        variableRateSlope1 != currentVariableRateSlope1 ||
        variableRateSlope2 != currentVariableRateSlope2,
      'NO_CHANGE_IN_RATES'
    );

    require(
      _updateWithinAllowedRange(
        currentOptimalUsageRatio,
        optimalUsageRatio,
        _borrowRateConfig.optimalUsageRatioMaxChange,
        false
      ),
      'INVALID_OPTIMAL_USAGE_RATIO'
    );
    require(
      _updateWithinAllowedRange(
        currentBaseVariableBorrowRate,
        baseVariableBorrowRate,
        _borrowRateConfig.baseVariableBorrowRateMaxChange,
        false
      ),
      'INVALID_BORROW_RATE_UPDATE'
    );
    require(
      _updateWithinAllowedRange(
        currentVariableRateSlope1,
        variableRateSlope1,
        _borrowRateConfig.variableRateSlope1MaxChange,
        false
      ),
      'INVALID_VARIABLE_RATE_SLOPE1'
    );
    require(
      _updateWithinAllowedRange(
        currentVariableRateSlope2,
        variableRateSlope2,
        _borrowRateConfig.variableRateSlope2MaxChange,
        false
      ),
      'INVALID_VARIABLE_RATE_SLOPE2'
    );

    require(
      uint256(baseVariableBorrowRate) + uint256(variableRateSlope1) + uint256(variableRateSlope2) <=
        GHO_BORROW_RATE_MAX,
      'BORROW_RATE_HIGHER_THAN_MAX'
    );
  }

  /**
   * @notice method to fetch the current interest rate params of the asset
   * @param asset the address of the underlying asset
   * @return optimalUsageRatio the current optimal usage ratio of the asset
   * @return baseVariableBorrowRate the current base variable borrow rate of the asset
   * @return variableRateSlope1 the current variable rate slope 1 of the asset
   * @return variableRateSlope2 the current variable rate slope 2 of the asset
   */
  function _getInterestRatesForAsset(
    address asset
  )
    internal
    view
    returns (
      uint256 optimalUsageRatio,
      uint256 baseVariableBorrowRate,
      uint256 variableRateSlope1,
      uint256 variableRateSlope2
    )
  {
    address rateStrategyAddress = IPoolDataProvider(POOL_DATA_PROVIDER)
      .getInterestRateStrategyAddress(asset);
    IDefaultInterestRateStrategyV2.InterestRateData
      memory interestRateData = IDefaultInterestRateStrategyV2(rateStrategyAddress)
        .getInterestRateDataBps(asset);
    return (
      interestRateData.optimalUsageRatio,
      interestRateData.baseVariableBorrowRate,
      interestRateData.variableRateSlope1,
      interestRateData.variableRateSlope2
    );
  }

  /**
   * @dev Ensures that the change difference is lower than max.
   * @param from current value
   * @param to new value
   * @param max maximum difference between from and to
   * @return bool true if difference between values lower than max, false otherwise
   */
  function _isDifferenceLowerThanMax(
    uint256 from,
    uint256 to,
    uint256 max
  ) internal pure returns (bool) {
    return from < to ? to - from <= max : from - to <= max;
  }

  /**
   * @notice Ensures the risk param update is within the allowed range
   * @param from current risk param value
   * @param to new updated risk param value
   * @param maxPercentChange the max percent change allowed
   * @param isChangeRelative true, if maxPercentChange is relative in value, false if maxPercentChange
   *        is absolute in value.
   * @return bool true, if difference is within the maxPercentChange
   */
  function _updateWithinAllowedRange(
    uint256 from,
    uint256 to,
    uint256 maxPercentChange,
    bool isChangeRelative
  ) internal pure returns (bool) {
    // diff denotes the difference between the from and to values, ensuring it is a positive value always
    uint256 diff = from > to ? from - to : to - from;

    // maxDiff denotes the max permitted difference on both the upper and lower bounds, if the maxPercentChange is relative in value
    // we calculate the max permitted difference using the maxPercentChange and the from value, otherwise if the maxPercentChange is absolute in value
    // the max permitted difference is the maxPercentChange itself
    uint256 maxDiff = isChangeRelative ? (maxPercentChange * from) / BPS_MAX : maxPercentChange;

    if (diff > maxDiff) return false;
    return true;
  }
}
