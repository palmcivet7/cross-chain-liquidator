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

contract LiquidationReceiver is CCIPReceiver, Ownable {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/
    error LiquidationReceiver__NoZeroAddress();
    error LiquidationReceiver__SourceChainNotAllowed(uint64 sourceChainSelector);
    error LiquidationReceiver__SenderNotAllowed(address sender);

    /*//////////////////////////////////////////////////////////////
                               VARIABLES
    //////////////////////////////////////////////////////////////*/
    IPoolAddressesProvider private immutable i_addressesProvider;

    IPool private s_pool;
    mapping(uint64 chainSelector => bool isAllowlisted) private s_allowlistedSourceChains;
    mapping(address sender => bool isAllowlisted) private s_allowlistedSenders;

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/
    modifier revertIfZeroAddress(address _address) {
        if (_address == address(0)) revert LiquidationReceiver__NoZeroAddress();
        _;
    }

    modifier onlyAllowlisted(uint64 _sourceChainSelector, address _sender) {
        if (!s_allowlistedSourceChains[_sourceChainSelector]) {
            revert LiquidationReceiver__SourceChainNotAllowed(_sourceChainSelector);
        }
        if (!s_allowlistedSenders[_sender]) revert LiquidationReceiver__SenderNotAllowed(_sender);
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/
    constructor(address _router, address _addressesProvider)
        CCIPReceiver(_router)
        Ownable(msg.sender)
        revertIfZeroAddress(_addressesProvider)
    {
        i_addressesProvider = IPoolAddressesProvider(_addressesProvider);
        s_pool = IPool(i_addressesProvider.getPool());
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
        address liquidationTarget = abi.decode(_message.data, (address));
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
}
