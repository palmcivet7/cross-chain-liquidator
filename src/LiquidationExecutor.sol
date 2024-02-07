// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {CCIPReceiver} from "@chainlink/contracts-ccip/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {LinkTokenInterface} from "@chainlink/contracts-ccip/src/v0.8/shared/interfaces/LinkTokenInterface.sol";
import {IFlashLoanSimpleReceiver} from "@aave/core-v3/contracts/flashloan/interfaces/IFlashLoanSimpleReceiver.sol";
import {IPool} from "@aave/core-v3/contracts/interfaces/IPool.sol";
import {IPoolAddressesProvider} from "@aave/core-v3/contracts/interfaces/IPoolAddressesProvider.sol";
import {ISwapRouter} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {IStableDebtToken} from "@aave/core-v3/contracts/interfaces/IStableDebtToken.sol";
import {AutomationBase} from "@chainlink/contracts/src/v0.8/automation/AutomationBase.sol";
import {ILogAutomation, Log} from "@chainlink/contracts/src/v0.8/automation/interfaces/ILogAutomation.sol";
import {IAutomationRegistryConsumer} from
    "@chainlink/contracts/src/v0.8/automation/interfaces/IAutomationRegistryConsumer.sol";
import {IAutomationRegistrar, RegistrationParams} from "./interfaces/IAutomationRegistrar.sol";

contract LiquidationExecutor is CCIPReceiver, Ownable, IFlashLoanSimpleReceiver, AutomationBase {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/
    error LiquidationExecutor__NoZeroAddress();
    error LiquidationExecutor__SourceChainNotAllowed(uint64 sourceChainSelector);
    error LiquidationExecutor__SenderNotAllowed(address sender);
    error LiquidationExecutor__TargetHealthFactorNotLiquidatable(uint256 targetHealthFactor);
    error LiquidationExecutor__NoZeroAmount();
    error LiquidationExecutor__OperationCanOnlyBeExecutedByAavePool(address caller);
    error LiquidationExecutor__AssetMustMatchDebtAsset(address asset);
    error LiquidationExecutor__NotEnoughToCoverFlashLoan(uint256 balance, uint256 amountOwed);
    error LiquidationExecutor__AutomationRegistrationFailed();
    error LiquidationExecutor__OnlyForwarder(address caller);

    /*//////////////////////////////////////////////////////////////
                               VARIABLES
    //////////////////////////////////////////////////////////////*/
    uint256 private constant HEALTHY_HEALTH_FACTOR = 1e18;
    uint256 private constant MAX_PURCHASING_AMOUNT = type(uint256).max;
    uint256 private constant MIN_AMOUNT_OUT_PERCENTAGE = 95_000;
    uint256 private constant MIN_AMOUNT_OUT_DIVISOR = 100_000;
    uint256 private constant PRICE_FEED_DECIMAL_PRECISION = 1e8;
    uint24 private constant POOL_FEE = 3000;

    IPoolAddressesProvider private immutable i_addressesProvider;
    LinkTokenInterface private immutable i_link;
    ISwapRouter private immutable i_swapRouter;
    IERC20 private immutable i_collateralAssetToReceive;
    IERC20 private immutable i_debtAssetToBorrowAndPay;
    address private immutable i_collateralPriceFeed;
    address private immutable i_debtPriceFeed;
    IStableDebtToken private immutable i_aaveStableDebtToken;
    IAutomationRegistryConsumer private immutable i_automationConsumer;
    uint256 private immutable i_subId;
    uint64 private immutable i_initiatorChainSelector;

    IPool private s_pool;
    address private s_forwarderAddress;
    mapping(address sender => bool isAllowlisted) private s_allowlistedSenders;
    mapping(uint64 chainSelector => bool isAllowlisted) private s_allowlistedSourceChains;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/
    event CCIPMessageReceivedAndFlashLoanCalled(address liquidationTarget);
    event CollateralAssetSwappedForDebtAsset(uint256 amountIn, uint256 amountOut);
    event FlashLoanExecuted(uint256 profitAmount);
    event CCIPMessageSent();

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/
    modifier revertIfZeroAddress(address _address) {
        if (_address == address(0)) revert LiquidationExecutor__NoZeroAddress();
        _;
    }

    modifier onlyAllowlisted(uint64 _sourceChainSelector, address _sender) {
        if (_sourceChainSelector != i_initiatorChainSelector) {
            revert LiquidationExecutor__SourceChainNotAllowed(_sourceChainSelector);
        }
        if (!s_allowlistedSenders[_sender]) revert LiquidationExecutor__SenderNotAllowed(_sender);
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/
    constructor(
        address _router,
        address _addressesProvider,
        address _link,
        address _swapRouter,
        address _collateralAssetToReceive,
        address _debtAssetToBorrowAndPay,
        address _collateralPriceFeed,
        address _debtPriceFeed,
        address _aaveStableDebtToken,
        address _automationConsumer,
        address _automationRegistrar,
        uint64 _initiatorChainSelector
    )
        CCIPReceiver(_router)
        Ownable(msg.sender)
        revertIfZeroAddress(_addressesProvider)
        revertIfZeroAddress(_link)
        revertIfZeroAddress(_swapRouter)
        revertIfZeroAddress(_collateralAssetToReceive)
        revertIfZeroAddress(_debtAssetToBorrowAndPay)
        revertIfZeroAddress(_collateralPriceFeed)
        revertIfZeroAddress(_debtPriceFeed)
        revertIfZeroAddress(_aaveStableDebtToken)
        revertIfZeroAddress(_automationConsumer)
        revertIfZeroAddress(_automationRegistrar)
    {
        i_addressesProvider = IPoolAddressesProvider(_addressesProvider);
        i_link = LinkTokenInterface(_link);
        i_swapRouter = ISwapRouter(_swapRouter);
        i_collateralAssetToReceive = IERC20(_collateralAssetToReceive);
        i_debtAssetToBorrowAndPay = IERC20(_debtAssetToBorrowAndPay);
        s_pool = IPool(i_addressesProvider.getPool());
        i_link.approve(address(this), type(uint256).max);
        i_collateralAssetToReceive.approve(address(this), type(uint256).max);
        i_debtAssetToBorrowAndPay.approve(address(this), type(uint256).max);
        i_collateralAssetToReceive.approve(address(i_swapRouter), type(uint256).max);
        i_debtAssetToBorrowAndPay.approve(address(s_pool), type(uint256).max);
        i_collateralPriceFeed = _collateralPriceFeed;
        i_debtPriceFeed = _debtPriceFeed;
        i_aaveStableDebtToken = IStableDebtToken(_aaveStableDebtToken);
        i_initiatorChainSelector = _initiatorChainSelector;

        RegistrationParams memory params = RegistrationParams({
            name: "",
            encryptedEmail: hex"",
            upkeepContract: address(this),
            gasLimit: 2000000,
            adminAddress: owner(),
            triggerType: 0,
            checkData: hex"",
            triggerConfig: hex"",
            offchainConfig: hex"",
            amount: 1000000000000000000
        });
        i_link.approve(_automationRegistrar, params.amount);
        uint256 upkeepID = IAutomationRegistrar(_automationRegistrar).registerUpkeep(params);
        if (upkeepID == 0) revert LiquidationExecutor__AutomationRegistrationFailed();
        i_subId = upkeepID;
    }

    /*//////////////////////////////////////////////////////////////
                               FLASH LOAN
    //////////////////////////////////////////////////////////////*/
    function executeOperation(
        address _asset,
        uint256 _amount,
        uint256 _premium,
        address, /* _initiator */
        bytes calldata _params
    ) external returns (bool) {
        IPool pool = s_pool;
        if (msg.sender != address(pool)) revert LiquidationExecutor__OperationCanOnlyBeExecutedByAavePool(msg.sender);
        if (_asset != address(i_debtAssetToBorrowAndPay)) revert LiquidationExecutor__AssetMustMatchDebtAsset(_asset);

        (address liquidationTarget, uint256 debtToCover) = abi.decode(_params, (address, uint256));
        pool.liquidationCall(address(i_collateralAssetToReceive), _asset, liquidationTarget, debtToCover, false);

        uint256 collateralReceived = i_collateralAssetToReceive.balanceOf(address(this));
        uint256 debtAssetAmount = _tradeCollateralReceivedForDebtBorrowed(collateralReceived);
        uint256 amountToPay = _amount + _premium;
        if (debtAssetAmount < amountToPay) {
            revert LiquidationExecutor__NotEnoughToCoverFlashLoan(debtAssetAmount, amountToPay);
        }

        uint256 profit = i_debtAssetToBorrowAndPay.balanceOf(address(this));
        emit FlashLoanExecuted(profit);
        return true;
    }

    /*//////////////////////////////////////////////////////////////
                                  CCIP
    //////////////////////////////////////////////////////////////*/
    function _ccipReceive(Client.Any2EVMMessage memory _message)
        internal
        override
        onlyRouter
        onlyAllowlisted(_message.sourceChainSelector, abi.decode(_message.sender, (address)))
    {
        (address liquidationTarget) = abi.decode(_message.data, (address));
        IPool pool = s_pool;
        (,,,,, uint256 targetHealthFactor) = pool.getUserAccountData(liquidationTarget);
        if (targetHealthFactor >= HEALTHY_HEALTH_FACTOR) {
            revert LiquidationExecutor__TargetHealthFactorNotLiquidatable(targetHealthFactor);
        }

        uint256 liquidationTargetDebt = i_aaveStableDebtToken.principalBalanceOf(liquidationTarget);
        if (liquidationTargetDebt == 0) revert LiquidationExecutor__NoZeroAmount();

        bytes memory liquidationTargetInfo = abi.encode(liquidationTarget, liquidationTargetDebt);

        emit CCIPMessageReceivedAndFlashLoanCalled(liquidationTarget);

        pool.flashLoanSimple(
            address(this), address(i_debtAssetToBorrowAndPay), liquidationTargetDebt, liquidationTargetInfo, 0
        );
    }

    function _ccipSendProfitBackToInitiator(bytes _encodedProfit) private {}

    /*//////////////////////////////////////////////////////////////
                               AUTOMATION
    //////////////////////////////////////////////////////////////*/
    function checkLog(Log calldata _log, bytes memory /* _checkData */ )
        external
        view
        cannotExecute
        returns (bool upkeepNeeded, bytes memory performData)
    {
        bytes32 eventSignature = keccak256("FlashLoanExecuted(uint256)");
        if (_log.source == address(this) && _log.topics[0] == eventSignature) {
            (uint256 profit) = abi.decode(_log.data, (uint256));
            performData = abi.encode(profit);
            upkeepNeeded = true;
        } else {
            upkeepNeeded = false;
        }
    }

    function performUpkeep(bytes calldata _performData) external {
        if (msg.sender != s_forwarderAddress) revert LiquidationExecutor__OnlyForwarder(msg.sender);
        _ccipSendProfitBackToInitiator(_performData);
    }

    /*//////////////////////////////////////////////////////////////
                                UNISWAP
    //////////////////////////////////////////////////////////////*/
    function _tradeCollateralReceivedForDebtBorrowed(uint256 _amountIn) private returns (uint256) {
        uint256 amountOut = _calculateAmountOutMinimum(_amountIn);
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: address(i_collateralAssetToReceive),
            tokenOut: address(i_debtAssetToBorrowAndPay),
            fee: POOL_FEE,
            recipient: address(this),
            deadline: block.timestamp + 2 minutes,
            amountIn: _amountIn,
            amountOutMinimum: amountOut,
            sqrtPriceLimitX96: 0
        });
        emit CollateralAssetReceivedSwappedForDebtAssetBorrowed(_amountIn, amountOut);
        return i_swapRouter.exactInputSingle(params);
    }

    /*//////////////////////////////////////////////////////////////
                               PRICEFEED
    //////////////////////////////////////////////////////////////*/
    function _calculateAmountOutMinimum(uint256 _amountIn) private view returns (uint256) {
        uint256 priceInUSDTokenIn = _getPriceFeedData(i_collateralPriceFeed);
        uint256 priceInUSDTokenOut = _getPriceFeedData(i_debtPriceFeed);

        uint256 valueInUSD = (_amountIn * priceInUSDTokenIn) / PRICE_FEED_DECIMAL_PRECISION;
        uint256 minValueInUSD = (valueInUSD * MIN_AMOUNT_OUT_PERCENTAGE) / MIN_AMOUNT_OUT_DIVISOR;
        uint256 amountOutMinimum = (minValueInUSD * PRICE_FEED_DECIMAL_PRECISION) / priceInUSDTokenOut;

        return amountOutMinimum;
    }

    function _getPriceFeedData(address _priceFeedAddress) private view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(_priceFeedAddress);
        (, int256 price,,,) = priceFeed.latestRoundData();
        return uint256(price);
    }

    /*//////////////////////////////////////////////////////////////
                                 SETTER
    //////////////////////////////////////////////////////////////*/
    function allowlistSourceChain(uint64 _sourceChainSelector, bool _allowed) external onlyOwner {
        s_allowlistedSourceChains[_sourceChainSelector] = _allowed;
    }

    function allowlistSender(address _sender, bool _allowed) external onlyOwner {
        s_allowlistedSenders[_sender] = _allowed;
    }

    /*//////////////////////////////////////////////////////////////
                                 GETTER
    //////////////////////////////////////////////////////////////*/
    function ADDRESSES_PROVIDER() external view returns (IPoolAddressesProvider) {
        return i_addressesProvider;
    }

    function POOL() external view returns (IPool) {
        return s_pool;
    }
}
