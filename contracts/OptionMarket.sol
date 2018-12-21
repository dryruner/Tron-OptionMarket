pragma solidity >= 0.4.24 < 0.5.0;

import "./SafeMath.sol";
import "./DOSOnChainSDK.sol";
import "./utils.sol";

contract OptionMarket is DOSOnChainSDK {
    using SafeMath for *;
    using utils for string;

    enum Type { Crypto, Stock }
    enum State { Open, Filled, Exercised }

    uint constant MIN_COLLATERAL = 10 finney; // 0.01 ether
    // uint constant MIN_COLLATERAL = 1 TRX;

    // orderId monotonously increase from 1.
    uint public orderId = 0;

    struct Order {
        uint id;
        uint collateral;      // Collateral in amount of Wei (Sun in Tron). Both option maker and taker need to provide same amount of collateral.
        uint expiration;      // An option's expiration time, before which an option order could be taken and exercised.
        uint strikePrice;     // Strike price specified by option maker (precise to 2 decimals)
        uint exercisePrice;   // Exercise price fetched by oracle (precise to 2 decimals)
        address maker;        // Option maker
        address taker;        // Option taker
        bool maker_position;  // 0: short; 1: long
        bool taker_position;  // !maker_position
        uint8 leverage;       // 1x, 2x, ... , 10x
        string symbol;        // Crypto symbol like ETH, BTC, TRX, etc.; or stock symbol like AMZN, BABA, etc. Usually filled by frontend.
        State status;
        Type assetType;
    }

    // Global on-chain orderbooks, including all open and exercised orders.
    mapping(uint => Order) public orders;
    // Global list of open orders' order id. Build open order dasboard on frontend.
    uint[] public openOrders;
    // Per user's filled orders. Build user order dashboard on frontend.
    mapping(address => uint[]) public filledOrderByOwner;
    mapping(uint => uint) queryToOrderId;

    modifier validId(uint id) {
        require(orders[id].id != 0 && orders[id].id == id);
        _;
    }

    function open(string symbol, uint strikePrice, uint8 leverage, uint expiration, bool position, Type asset) public payable returns (uint) {
        require(leverage >= 1 && leverage <= 10);
        require(msg.value >= MIN_COLLATERAL);

        ++orderId;
        orders[orderId] = Order(orderId, msg.value, expiration, strikePrice, 0, msg.sender, 0x0, position, !position, leverage, symbol, State.Open, asset);
        openOrders.push(orderId);
        return orderId;
    }

    // Maker can cancel an order if it's not (fully) taken.
    function cancelOrder(uint id) public validId(id) {
        Order memory order = orders[id];
        require(order.taker == 0x0 && order.maker == msg.sender);

        delete orders[id];
        removeOpenOrder(id);
        order.maker.transfer(order.collateral);
    }

    function partialFill(uint id) public payable validId(id) {
        require(orders[id].status == State.Open);
        require(msg.value >= MIN_COLLATERAL && orders[id].collateral.sub(msg.value) >= MIN_COLLATERAL);

        // Adjust partially filled order
        orders[id].collateral -= msg.value;

        // Create a new filled order.
        Order memory newOrder = orders[id];
        newOrder.id = ++orderId;
        newOrder.collateral = msg.value;
        newOrder.taker = msg.sender;
        newOrder.status = State.Filled;
        orders[orderId] = newOrder;
        filledOrderByOwner[newOrder.taker].push(orderId);
        filledOrderByOwner[newOrder.maker].push(orderId);
    }

    function fill(uint id) public payable validId(id) {
        require(orders[id].status == State.Open);
        // Taker must provide same amount of collateral as deposited by the option maker.
        require(msg.value == orders[id].collateral);

        removeOpenOrder(id);
        filledOrderByOwner[orders[id].maker].push(id);
        filledOrderByOwner[msg.sender].push(id);
        orders[id].taker = msg.sender;
        orders[id].status = State.Filled;
    }

    // Taker could take profit/loss by exercising a filled order at any time before expiration.
    // However the maximum profit/loss is the amount of collateral.
    // Contracts queries oracle to get final exercise price.
    function exercise(uint id) public validId(id) {
        require(orders[id].status == State.Filled);
        require(block.timestamp < orders[id].expiration);

        string memory dataSource;
        string memory selector;
        (dataSource, selector) = buildOracleRequest(orders[id].assetType, orders[id].symbol);
        uint queryId = DOSQuery(30, dataSource, selector);
        queryToOrderId[queryId] = id;
    }

    function __callback__(uint queryId, bytes memory result) public {
        require(msg.sender == fromDOSProxyContract());
        require(queryToOrderId[queryId] != 0);

        string memory price_str = string(result);
        uint price = price_str.str2Uint();
        uint fractional = 0;
        int delimit_idx = price_str.indexOf('.');
        if (delimit_idx != -1) {
            fractional = price_str.subStr(uint(delimit_idx + 1)).str2Uint();
        }

        Order storage order = orders[queryToOrderId[queryId]];
        order.exercisePrice = price * 100 + fractional;

        uint total = 2 * order.collateral;
        uint payToMaker = 0;
        // payToMaker = collateral * (1 + leverage * (exercisePrice - strikePrice) / strikePrice);
        if (order.exercisePrice >= order.strikePrice && (order.exercisePrice - order.strikePrice).mul(order.leverage) >= order.strikePrice) {
            payToMaker = total;
        } else if (order.strikePrice >= order.exercisePrice && (order.strikePrice - order.exercisePrice).mul(order.leverage) >= order.strikePrice) {
            payToMaker = 0;
        } else {
            payToMaker = (order.exercisePrice.mul(order.leverage) - (order.leverage - 1).mul(order.strikePrice)).mul(order.collateral).div(order.strikePrice);
        }
        uint payToTaker = total.sub(payToMaker);
        order.status = State.Exercised;

        order.maker.transfer(payToMaker);
        order.taker.transfer(payToTaker);
    }

    // Build oracle request, returns (data source, selector) string.
    function buildOracleRequest(Type asset, string symbol) private pure returns (string, string) {
        if (asset == Type.Crypto) {
            return (utils.strConcat("https://min-api.cryptocompare.com/data/price?tsyms=USD&fsym=", symbol), "$.USD");
        } else if (asset == Type.Stock) {
            return (utils.strConcat("https://api.iextrading.com/1.0/stock/", symbol).strConcat("/price"), "$");
        }
    }

    function removeOpenOrder(uint id) private {
        uint len =  openOrders.length;
        for (uint i = 0; i < len; i++) {
            if (openOrders[i] == id) {
                openOrders[i] = openOrders[len - 1];
                delete openOrders[len-1];
                openOrders.length--;
                return;
            }
        }
    }
}
