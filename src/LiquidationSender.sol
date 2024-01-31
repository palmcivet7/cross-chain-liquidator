// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {LinkTokenInterface} from "@chainlink/contracts-ccip/src/v0.8/shared/interfaces/LinkTokenInterface.sol";

contract LiquidationSender is Ownable {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/
    error LiquidationSender__NoZeroAddress();
    error LiquidationSender__NoZeroAmount();
    error LiquidationSender__DestinationChainNotAllowlisted(uint64 destinationChainSelector);
    error LiquidationSender__NotEnoughLink(uint256 linkBalance, uint256 requiredAmount);
    error LiquidationSender__LinkTransferFailed();

    /*//////////////////////////////////////////////////////////////
                               VARIABLES
    //////////////////////////////////////////////////////////////*/
    IRouterClient private immutable i_ccipRouter;
    LinkTokenInterface private immutable i_link;

    mapping(uint64 chainSelector => bool isAllowlisted) public s_allowlistedDestinationChains;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/
    event LiquidationMessageSent(
        bytes32 indexed messageId,
        uint64 indexed destinationChainSelector,
        address receiver,
        address liquidationTarget,
        address feeToken,
        uint256 fees
    );

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/
    modifier revertIfZeroAddress(address _address) {
        if (_address == address(0)) revert LiquidationSender__NoZeroAddress();
        _;
    }

    modifier revertIfZeroAmount(uint256 _amount) {
        if (_amount == 0) revert LiquidationSender__NoZeroAmount();
        _;
    }

    modifier onlyAllowlistedDestinationChain(uint64 _destinationChainSelector) {
        if (!s_allowlistedDestinationChains[_destinationChainSelector]) {
            revert LiquidationSender__DestinationChainNotAllowlisted(_destinationChainSelector);
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/
    constructor(address _router, address _link)
        Ownable(msg.sender)
        revertIfZeroAddress(_router)
        revertIfZeroAddress(_link)
    {
        i_ccipRouter = IRouterClient(_router);
        i_link = LinkTokenInterface(_link);
        i_link.approve(address(this), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    function liquidateCrossChain(address _liquidationTarget, address _liquidationReceiver, uint64 _chainSelector)
        external
        revertIfZeroAddress(_liquidationTarget)
        revertIfZeroAddress(_liquidationReceiver)
        onlyAllowlistedDestinationChain(_chainSelector)
        returns (bytes32 messageId)
    {
        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(_liquidationReceiver),
            data: abi.encode(_liquidationTarget),
            tokenAmounts: new Client.EVMTokenAmount[](0),
            extraArgs: "",
            feeToken: address(i_link)
        });

        uint256 fees = i_ccipRouter.getFee(_chainSelector, message);

        if (fees > i_link.balanceOf(address(this))) {
            revert LiquidationSender__NotEnoughLink(i_link.balanceOf(address(this)), fees);
        }

        messageId = i_ccipRouter.ccipSend(_chainSelector, message);

        emit LiquidationMessageSent(
            messageId, _chainSelector, _liquidationReceiver, _liquidationTarget, address(0), fees
        );

        return messageId;
    }

    /*//////////////////////////////////////////////////////////////
                                WITHDRAW
    //////////////////////////////////////////////////////////////*/
    function withdrawLink(uint256 _amount) external onlyOwner revertIfZeroAmount(_amount) {
        uint256 balance = i_link.balanceOf(address(this));
        if (balance < _amount) revert LiquidationSender__NotEnoughLink(balance, _amount);

        if (!i_link.transferFrom(address(this), msg.sender, _amount)) revert LiquidationSender__LinkTransferFailed();
    }

    /*//////////////////////////////////////////////////////////////
                                 SETTER
    //////////////////////////////////////////////////////////////*/
    function allowlistDestinationChain(uint64 _destinationChainSelector, bool _allowed) external onlyOwner {
        s_allowlistedDestinationChains[_destinationChainSelector] = _allowed;
    }
}
