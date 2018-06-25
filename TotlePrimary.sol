pragma solidity 0.4.21;

import { Ownable } from "openzeppelin-solidity/contracts/ownership/Ownable.sol";
import { ERC20 as Token } from "openzeppelin-solidity/contracts/token/ERC20/ERC20.sol";
import { Math } from "openzeppelin-solidity/contracts/math/Math.sol";
import { SafeMath } from "openzeppelin-solidity/contracts/math/SafeMath.sol";

import { ExchangeHandler } from "./ExchangeHandler.sol";
import { TokenTransferProxy } from "./TokenTransferProxy.sol";

/// @title The primary contract for Totle Inc
contract TotlePrimary is Ownable {
    // Constants
    uint256 public constant MAX_EXCHANGE_FEE_PERCENTAGE = 0.01 * 10**18; // 1%
    bool constant BUY = false;
    bool constant SELL = true;

    // State variables
    mapping(address => bool) public handlerWhitelist;
    address tokenTransferProxy;

    // Structs
    struct Tokens {
        address[] tokenAddresses;
        bool[]    buyOrSell;
        uint256[] amountToObtain;
        uint256[] amountToGive;
    }

    struct DEXOrders {
        address[] tokenForOrder;
        address[] exchanges;
        address[8][] orderAddresses;
        uint256[6][] orderValues;
        uint256[] exchangeFees;
        uint8[] v;
        bytes32[] r;
        bytes32[] s;
    }

    /// @dev Constructor
    /// @param proxy Address of the TokenTransferProxy
    function TotlePrimary(address proxy) public {
        tokenTransferProxy = proxy;
    }

    /*
    *   Public functions
    */

    /// @dev Set an exchange handler address to true/false
    /// @notice - onlyOwner modifier only allows the contract owner to run the code
    /// @param handler Address of the exchange handler which permission needs changing
    /// @param allowed Boolean value to set whether an exchange handler is allowed/denied
    function setHandler(address handler, bool allowed) public onlyOwner {
        handlerWhitelist[handler] = allowed;
    }

    /// @dev Synchronously executes an array of orders
    /// @notice The first four parameters relate to Token orders, the last eight relate to DEX orders
    /// @param tokenAddresses Array of addresses of ERC20 Token contracts for each Token order
    /// @param buyOrSell Array indicating whether each Token order is a buy or sell
    /// @param amountToObtain Array indicating the amount (in ether or tokens) to obtain in the order
    /// @param amountToGive Array indicating the amount (in ether or tokens) to give in the order
    /// @param tokenForOrder Array of addresses of ERC20 Token contracts for each DEX order
    /// @param exchanges Array of addresses of exchange handler contracts
    /// @param orderAddresses Array of address values needed for each DEX order
    /// @param orderValues Array of uint values needed for each DEX order
    /// @param exchangeFees Array indicating the fee for each DEX order (percentage of fill amount as decimal * 10**18)
    /// @param v ECDSA signature parameter v
    /// @param r ECDSA signature parameter r
    /// @param s ECDSA signature parameter s
    function executeOrders(
        // Tokens
        address[] tokenAddresses,
        bool[]    buyOrSell,
        uint256[] amountToObtain,
        uint256[] amountToGive,
        // DEX Orders
        address[] tokenForOrder,
        address[] exchanges,
        address[8][] orderAddresses,
        uint256[6][] orderValues,
        uint256[] exchangeFees,
        uint8[] v,
        bytes32[] r,
        bytes32[] s
    ) public payable {

        require(
            tokenAddresses.length == buyOrSell.length &&
            buyOrSell.length      == amountToObtain.length &&
            amountToObtain.length == amountToGive.length
        );

        require(
            tokenForOrder.length  == exchanges.length &&
            exchanges.length      == orderAddresses.length &&
            orderAddresses.length == orderValues.length &&
            orderValues.length    == exchangeFees.length &&
            exchangeFees.length   == v.length &&
            v.length              == r.length &&
            r.length              == s.length
        );

        // Wrapping order in structs to reduce local variable count
        internalOrderExecution(
            Tokens(
                tokenAddresses,
                buyOrSell,
                amountToObtain,
                amountToGive
            ),
            DEXOrders(
                tokenForOrder,
                exchanges,
                orderAddresses,
                orderValues,
                exchangeFees,
                v,
                r,
                s
            )
        );
    }

    /*
    *   Internal functions
    */

    /// @dev Synchronously executes an array of orders
    /// @notice The orders in this function have been wrapped in structs to reduce the local variable count
    /// @param tokens Struct containing the arrays of token orders
    /// @param orders Struct containing the arrays of DEX orders
    function internalOrderExecution(Tokens tokens, DEXOrders orders) internal {
        transferTokens(tokens);

        uint256 tokensLength = tokens.tokenAddresses.length;
        uint256 ordersLength = orders.tokenForOrder.length;
        uint256 etherBalance = msg.value;
        uint256 orderIndex = 0;

        for(uint256 tokenIndex = 0; tokenIndex < tokensLength; tokenIndex++) {

            uint256 amountRemaining = tokens.amountToGive[tokenIndex];
            uint256 amountObtained = 0;

            while(orderIndex < ordersLength) {
                require(tokens.tokenAddresses[tokenIndex] == orders.tokenForOrder[orderIndex]);
                require(handlerWhitelist[orders.exchanges[orderIndex]]);

                if(amountRemaining > 0) {
                    if(tokens.buyOrSell[tokenIndex] == BUY) {
                        require(etherBalance >= amountRemaining);
                    }
                    (amountRemaining, amountObtained) = performTrade(
                        tokens.buyOrSell[tokenIndex],
                        amountRemaining,
                        amountObtained,
                        orders,
                        orderIndex
                        );
                }

                orderIndex = SafeMath.add(orderIndex, 1);
                // If this is the last order for this token
                if(orderIndex == ordersLength || orders.tokenForOrder[SafeMath.sub(orderIndex, 1)] != orders.tokenForOrder[orderIndex]) {
                    break;
                }
            }

            uint256 amountGiven = SafeMath.sub(tokens.amountToGive[tokenIndex], amountRemaining);

            require(orderWasValid(amountObtained, amountGiven, tokens.amountToObtain[tokenIndex], tokens.amountToGive[tokenIndex]));

            if(tokens.buyOrSell[tokenIndex] == BUY) {
                // Take away spent ether from refund balance
                etherBalance = SafeMath.sub(etherBalance, amountGiven);
                // Transfer back tokens acquired
                if(amountObtained > 0) {
                    require(Token(tokens.tokenAddresses[tokenIndex]).transfer(msg.sender, amountObtained));
                }
            } else {
                // Add ether to refund balance
                etherBalance = SafeMath.add(etherBalance, amountObtained);
                // Transfer back un-sold tokens
                if(amountRemaining > 0) {
                    require(Token(tokens.tokenAddresses[tokenIndex]).transfer(msg.sender, amountRemaining));
                }
            }
        }

        // Send back acquired/unspent ether - throw on failure
        if(etherBalance > 0) {
            msg.sender.transfer(etherBalance);
        }
    }

    /// @dev Iterates through a list of token orders, transfer the SELL orders to this contract & calculates if we have the ether needed
    /// @param tokens Struct containing the arrays of token orders
    function transferTokens(Tokens tokens) internal {
        uint256 expectedEtherAvailable = msg.value;
        uint256 totalEtherNeeded = 0;

        for(uint256 i = 0; i < tokens.tokenAddresses.length; i++) {
            if(tokens.buyOrSell[i] == BUY) {
                totalEtherNeeded = SafeMath.add(totalEtherNeeded, tokens.amountToGive[i]);
            } else {
                expectedEtherAvailable = SafeMath.add(expectedEtherAvailable, tokens.amountToObtain[i]);
                require(TokenTransferProxy(tokenTransferProxy).transferFrom(
                    tokens.tokenAddresses[i],
                    msg.sender,
                    this,
                    tokens.amountToGive[i]
                ));
            }
        }

        // Make sure we have will have enough ETH after SELLs to cover our BUYs
        require(expectedEtherAvailable >= totalEtherNeeded);
    }

    /// @dev Performs a single trade via the requested exchange handler
    /// @param buyOrSell Boolean value stating whether this is a buy or sell order
    /// @param initialRemaining The remaining value we have left to trade
    /// @param totalObtained The total amount we have obtained so far
    /// @param orders Struct containing all DEX orders
    /// @param index Value indicating the index of the specific DEX order we wish to execute
    /// @return Remaining value left after trade
    /// @return Total value obtained after trade
    function performTrade(bool buyOrSell, uint256 initialRemaining, uint256 totalObtained, DEXOrders orders, uint256 index)
        internal returns (uint256, uint256) {
        uint256 obtained = 0;
        uint256 remaining = initialRemaining;

        require(orders.exchangeFees[index] < MAX_EXCHANGE_FEE_PERCENTAGE);

        uint256 amountToFill = getAmountToFill(remaining, orders, index);

        if(amountToFill > 0) {
            remaining = SafeMath.sub(remaining, amountToFill);

            if(buyOrSell == BUY) {
                obtained = ExchangeHandler(orders.exchanges[index]).performBuy.value(amountToFill)(
                    orders.orderAddresses[index],
                    orders.orderValues[index],
                    orders.exchangeFees[index],
                    amountToFill,
                    orders.v[index],
                    orders.r[index],
                    orders.s[index]
                );
            } else {
                require(Token(orders.tokenForOrder[index]).transfer(
                    orders.exchanges[index],
                    amountToFill
                ));
                obtained = ExchangeHandler(orders.exchanges[index]).performSell(
                    orders.orderAddresses[index],
                    orders.orderValues[index],
                    orders.exchangeFees[index],
                    amountToFill,
                    orders.v[index],
                    orders.r[index],
                    orders.s[index]
                );
            }
        }

        return (obtained == 0 ? initialRemaining: remaining, SafeMath.add(totalObtained, obtained));
    }

    /// @dev Get the amount of this order we are able to fill
    /// @param remaining Amount we have left to spend
    /// @param orders Struct containing all DEX orders
    /// @param index Value indicating the index of the specific DEX order we wish to execute
    /// @return Minimum of the amount we have left to spend and the available amount at the exchange
    function getAmountToFill(uint256 remaining, DEXOrders orders, uint256 index) internal returns (uint256) {

        uint256 availableAmount = ExchangeHandler(orders.exchanges[index]).getAvailableAmount(
            orders.orderAddresses[index],
            orders.orderValues[index],
            orders.exchangeFees[index],
            orders.v[index],
            orders.r[index],
            orders.s[index]
        );

        return Math.min256(remaining, availableAmount);
    }

    /// @dev Checks whether a given order was valid
    /// @param amountObtained Amount of the order which was obtained
    /// @param amountGiven Amount given in return for amountObtained
    /// @param amountToObtain Amount we intended to obtain
    /// @param amountToGive Amount we intended to give in return for amountToObtain
    /// @return Boolean value indicating whether this order was valid
    function orderWasValid(uint256 amountObtained, uint256 amountGiven, uint256 amountToObtain, uint256 amountToGive) internal pure returns (bool) {

        if(amountObtained > 0 && amountGiven > 0) {
            if(amountObtained > amountGiven) {
                return SafeMath.div(amountToObtain, amountToGive) <= SafeMath.div(amountObtained, amountGiven);
            } else {
                return SafeMath.div(amountToGive, amountToObtain) >= SafeMath.div(amountGiven, amountObtained);
            }
        }
        return false;
    }

    function() public payable {
        // Check in here that the sender is a contract! (to stop accidents)
        uint256 size;
        address sender = msg.sender;
        assembly {
            size := extcodesize(sender)
        }
        require(size > 0);
    }
}
