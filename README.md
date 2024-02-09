# Avalanche Frontier Hackathon 2024 Submission

This project is a cross-chain liquidator.

https://dorahacks.io/hackathon/avalanche-frontier/detail#schedule

The user interacts with the `LiquidationInitiator` contract on Avalanche to send the address of their `liquidationTarget` to the `LiquidationExecutor` contract on Ethereum via CCIP.

The `LiquidationExecutor` contract retrieves information about the `liquidationTarget` on Aave and takes out a flash loan to liquidate the target's under-collateralized position.

The `LiquidationExecutor` contract then uses Uniswap to swap the collateral asset received from the liquidation call back to the debt asset borrowed in the flash loan call. Chainlink Pricefeeds are used to compare prices when swapping to protect slippage.

The flash loan is repaid and Chainlink Log Trigger Automation is used to monitor for this event and send the profits back to the `LiquidationInitiator` contract on Avalanche via CCIP.
