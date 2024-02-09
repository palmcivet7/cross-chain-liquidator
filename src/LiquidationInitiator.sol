// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {LinkTokenInterface} from "@chainlink/contracts-ccip/src/v0.8/shared/interfaces/LinkTokenInterface.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {CCIPReceiver} from "@chainlink/contracts-ccip/src/v0.8/ccip/applications/CCIPReceiver.sol";

/**
 * @title LiquidationInitiator
 * @author palmcivet
 * @notice This is one of two contracts in the Cross-Chain Liquidation Protocol. The other is LiquidationExecutor.
 * Users interact with this contract by sending the address of their liquidation target to the LiquidationExecutor.
 * Profits from liquidations will be sent back to this contract.
 */
contract LiquidationInitiator is Ownable, CCIPReceiver {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/
    error LiquidationInitiator__NoZeroAddress();
    error LiquidationInitiator__NoZeroAmount();
    error LiquidationInitiator__DestinationChainNotAllowlisted(uint64 destinationChainSelector);
    error LiquidationInitiator__SourceChainNotAllowed(uint64 destinationChainSelector);
    error LiquidationInitiator__SenderNotAllowed(address sourceChainSender);
    error LiquidationInitiator__NotEnoughLink(uint256 linkBalance, uint256 requiredAmount);
    error LiquidationInitiator__NotEnoughToken(address token, uint256 tokenBalance, uint256 attemptedWithdrawalAmount);
    error LiquidationInitiator__TokenTransferFailed();

    /*//////////////////////////////////////////////////////////////
                               VARIABLES
    //////////////////////////////////////////////////////////////*/
    LinkTokenInterface private immutable i_link;
    uint64 private immutable i_executorChainSelector;

    mapping(address sender => bool isAllowlisted) private s_allowlistedSenders;
    mapping(uint64 chainSelector => bool isAllowlisted) private s_allowlistedDestinationChains;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/
    event LiquidationMessageSent(bytes32 indexed messageId, address indexed liquidationTarget);
    event LiquidationProfitReceived(address indexed tokenReceived, uint256 indexed profitReceived);

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/
    modifier revertIfZeroAddress(address _address) {
        if (_address == address(0)) revert LiquidationInitiator__NoZeroAddress();
        _;
    }

    modifier revertIfZeroAmount(uint256 _amount) {
        if (_amount == 0) revert LiquidationInitiator__NoZeroAmount();
        _;
    }

    modifier onlyAllowlistedSender(uint64 _sourceChainSelector, address _sourceChainSender) {
        if (_sourceChainSelector != i_executorChainSelector) {
            revert LiquidationInitiator__SourceChainNotAllowed(_sourceChainSelector);
        }
        if (!s_allowlistedSenders[_sourceChainSender]) {
            revert LiquidationInitiator__SenderNotAllowed(_sourceChainSender);
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice Initializes the contract
     * @param _router Address of the CCIP Router contract
     * @param _link Address of the LINK token contract
     * @param _executorChainSelector CCIP Chain Selector for the chain the LiquidationExecutor contract exists
     */
    constructor(address _router, address _link, uint64 _executorChainSelector)
        Ownable(msg.sender)
        CCIPReceiver(_router)
        revertIfZeroAddress(_router)
        revertIfZeroAddress(_link)
        revertIfZeroAmount(uint256(_executorChainSelector))
    {
        i_link = LinkTokenInterface(_link);
        i_link.approve(address(this), type(uint256).max);
        i_executorChainSelector = _executorChainSelector;
    }

    /*//////////////////////////////////////////////////////////////
                                  CCIP
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice Primary function for using the Cross-Chain Liquidation Protocol
     * @param _liquidationTarget Address of the liquidation target with an under-collateralized position on Aave
     * @param _liquidationExecutor Address of the LiquidationExecutor contract on the other chain
     * @dev This function uses Chainlink CCIP to send the _liquidationTarget address across chains
     */
    function liquidateCrossChain(address _liquidationTarget, address _liquidationExecutor)
        external
        revertIfZeroAddress(_liquidationTarget)
        revertIfZeroAddress(_liquidationExecutor)
        returns (bytes32 messageId)
    {
        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(_liquidationExecutor),
            data: abi.encode(_liquidationTarget),
            tokenAmounts: new Client.EVMTokenAmount[](0),
            extraArgs: "",
            feeToken: address(i_link)
        });

        uint256 fees = IRouterClient(i_ccipRouter).getFee(i_executorChainSelector, message);
        uint256 linkBalance = i_link.balanceOf(address(this));
        if (fees > linkBalance) {
            revert LiquidationInitiator__NotEnoughLink(linkBalance, fees);
        }

        messageId = IRouterClient(i_ccipRouter).ccipSend(i_executorChainSelector, message);
        emit LiquidationMessageSent(messageId, _liquidationTarget);
        return messageId;
    }

    /**
     * @param _message When this CCIP message is decoded it will contain the address of the token received and how much profit
     * @dev This function is needed to receive CCIP messages
     */
    function _ccipReceive(Client.Any2EVMMessage memory _message)
        internal
        override
        onlyAllowlistedSender(_message.sourceChainSelector, abi.decode(_message.sender, (address)))
    {
        (address tokenReceived, uint256 profitReceived) = abi.decode(_message.data, (address, uint256));
        emit LiquidationProfitReceived(tokenReceived, profitReceived);
    }

    /*//////////////////////////////////////////////////////////////
                                WITHDRAW
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice Withdraw ERC20 tokens - currently only callable by the owner of the contract
     * @param _token Address of the token to withdraw
     * @param _amount Amount of the token to withdraw
     */
    function withdrawToken(address _token, uint256 _amount)
        external
        onlyOwner
        revertIfZeroAddress(_token)
        revertIfZeroAmount(_amount)
    {
        uint256 balance = IERC20(_token).balanceOf(address(this));
        if (balance < _amount) revert LiquidationInitiator__NotEnoughToken(_token, balance, _amount);

        if (!IERC20(_token).transferFrom(address(this), msg.sender, _amount)) {
            revert LiquidationInitiator__TokenTransferFailed();
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 SETTER
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice Maps an address to a boolean, to be used as a check for if that address can send a CCIP message to address(this)
     * @param _sourceChainSender Address of LiquidationExecutor
     * @param _allowed Set to true to allow _sourceChainSender
     */
    function allowlistSourceChainSender(address _sourceChainSender, bool _allowed) external onlyOwner {
        s_allowlistedSenders[_sourceChainSender] = _allowed;
    }
}
