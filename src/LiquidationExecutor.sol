// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {CCIPReceiver} from "@chainlink/contracts-ccip/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {LinkTokenInterface} from "@chainlink/contracts-ccip/src/v0.8/shared/interfaces/LinkTokenInterface.sol";
import {IFlashLoanReceiver} from "@aave/core-v3/contracts/flashloan/interfaces/IFlashLoanReceiver.sol";
import {IPool} from "@aave/core-v3/contracts/interfaces/IPool.sol";
import {IPoolAddressesProvider} from "@aave/core-v3/contracts/interfaces/IPoolAddressesProvider.sol";

contract LiquidationExecutor is CCIPReceiver, Ownable, IFlashLoanReceiver {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/
    error LiquidationExecutor__NoZeroAddress();
    error LiquidationExecutor__SourceChainNotAllowed(uint64 sourceChainSelector);
    error LiquidationExecutor__SenderNotAllowed(address sender);
    error LiquidationExecutor__TargetHealthFactorNotLiquidatable(uint256 targetHealthFactor);

    /*//////////////////////////////////////////////////////////////
                               VARIABLES
    //////////////////////////////////////////////////////////////*/
    uint256 private constant HEALTHY_HEALTH_FACTOR = 1e18;
    uint256 private constant MAX_PURCHASING_AMOUNT = type(uint256).max;

    IPoolAddressesProvider private immutable i_addressesProvider;
    LinkTokenInterface private immutable i_link;
    IERC20 private immutable i_collateralAssetToReceive;
    IERC20 private immutable i_debtAssetToBorrowAndPay;

    IPool private s_pool;
    mapping(uint64 chainSelector => bool isAllowlisted) private s_allowlistedSourceChains;
    mapping(address sender => bool isAllowlisted) private s_allowlistedSenders;

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/
    modifier revertIfZeroAddress(address _address) {
        if (_address == address(0)) revert LiquidationExecutor__NoZeroAddress();
        _;
    }

    modifier onlyAllowlisted(uint64 _sourceChainSelector, address _sender) {
        if (!s_allowlistedSourceChains[_sourceChainSelector]) {
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
        address _collateralAssetToReceive,
        address _debtAssetToBorrowAndPay
    )
        CCIPReceiver(_router)
        Ownable(msg.sender)
        revertIfZeroAddress(_addressesProvider)
        revertIfZeroAddress(_link)
        revertIfZeroAddress(_collateralAssetToReceive)
        revertIfZeroAddress(_debtAssetToBorrowAndPay)
    {
        i_addressesProvider = IPoolAddressesProvider(_addressesProvider);
        i_link = LinkTokenInterface(_link);
        i_collateralAssetToReceive = IERC20(_collateralAssetToReceive);
        i_debtAssetToBorrowAndPay = IERC20(_debtAssetToBorrowAndPay);
        s_pool = IPool(i_addressesProvider.getPool());
        i_link.approve(address(this), type(uint256).max);
        i_collateralAssetToReceive.approve(address(this), type(uint256).max);
        i_debtAssetToBorrowAndPay.approve(address(this), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                               FLASH LOAN
    //////////////////////////////////////////////////////////////*/
    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address initiator,
        bytes calldata params
    ) external returns (bool) {}

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
        (, uint256 totalDebtETH,,,, uint256 targetHealthFactor) = pool.getUserAccountData(liquidationTarget);
        if (targetHealthFactor >= HEALTHY_HEALTH_FACTOR) {
            revert LiquidationExecutor__TargetHealthFactorNotLiquidatable(targetHealthFactor);
        }

        (, uint256 currentStableDebt, uint256 currentVariableDebt,,,,,,) =
            pool.getUserReserveData(i_debtAssetToBorrowAndPay, liquidationTarget);

        uint256 liquidationTargetDebt = currentStableDebt + currentVariableDebt;

        address[] memory assets = new address[](1);
        assets[0] = i_debtAssetToBorrowAndPay;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = liquidationTargetDebt;
        uint256[] memory interestRateModes = new uint256[](1);
        interestRateModes[0] = 0;
        pool.flashLoan(address(this), assets, amounts, interestRateModes, address(this), "", 0);

        pool.liquidationCall(
            i_collateralAssetToReceive, i_debtAssetToBorrowAndPay, liquidationTarget, MAX_PURCHASING_AMOUNT, false
        );
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
