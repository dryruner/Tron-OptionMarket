// pragma solidity >= 0.4.24 < 0.5.0;
pragma solidity ^0.4.23;


import "./SafeMath.sol";
import "./DOSOnChainSDK.sol";
import "./utils.sol";

contract OptionMarket is DOSOnChainSDK {
    using SafeMath for *;
    using utils for *;

    enum State { Open, Filled, Exercised }

    uint constant MIN_COLLATERAL = 1 trx;

    // orderId monotonously increase from 1.
    uint public orderId = 0;

    // amount of attr unable large than 15 
    struct Order {
        uint collateral;      // Collateral in amount of sun. Both option maker and taker need to provide same amount of collateral.
        uint start;           // Open order time in unix epoch format.
        uint expiration;      // An option's expiration time in unix epoch format, after which an option order can be exercised.
        uint strikePrice;     // Strike price specified by option maker (precise to 5 decimals)
        uint exercisePrice;   // Exercise price fetched by oracle (precise to 5 decimals)
        address maker;        // Option maker
        address taker;        // Option taker
        bool maker_position;  // 0: short; 1: long
        bool taker_position;  // !maker_position
        uint8 leverage;       // 1x, 2x, ... , 10x
        string symbol;        // Crypto symbol like ETH, BTC, TRX, etc.; or stock symbol like AMZN, BABA, etc. Usually filled by frontend.
        State status;
        uint makerPayout;
        uint takerPayout;
    }

    // Global on-chain orderbooks, including all open and exercised orders.
    mapping(uint => Order) public orders;
    // Global list of open orders' order id. Build open order dasboard on frontend.
    uint[] public openOrders;
    // Per user open orders, build dashboard on /Personal page.
    mapping(address => uint[]) public openOrderByOwner;
    // Per user's filled orders. Build dashboard on /Personal frontend.
    mapping(address => uint[]) public filledOrderByOwner;
    mapping(uint => uint) queryToOrderId;
    mapping(uint => bool) orderInExercise;

    //event
    event LogOpen(address indexed makerAddr);
    event LogPartialFill(address indexed makerAddr,address indexed takerAddr);
    event LogFill(address indexed makerAddr,address indexed takerAddr);
    event LogCancel(address indexed makerAddr);
    event LogExec(address indexed makerAddr,address indexed takerAddr);

    constructor(address addr) DOSOnChainSDK(addr) public {}

    modifier validId(uint id) {
        require(orders[id].maker != 0);
        _;
    }

    // To get rid of too frequent arbitrage, an order can be filled until:
    // 1. 2h before expiration if window >= 12h
    // 2. 30min before expiration if 12h > window >= 1h
    // 3. anytime before expiration if 1h > window > 0
    modifier canFill(uint id) {
        uint window = orders[id].expiration - orders[id].start;
        uint before = 0;

        if (window >= 12 hours) before = 2 hours;
        else if (window >= 1 hours) before = 30 minutes;
        else before = 0;
        assert(orders[id].expiration - before >= now);
        _;
    }

    //tron vm can not directly return array storage attr...
    function getOrders() public view returns(uint[]) {
        return openOrders;
    }

    function getOpenOrderByOwner() public view returns(uint[]) {
        return openOrderByOwner[msg.sender];
    }

    function getFilledOrderByOwner() public view returns(uint[]) {
        return filledOrderByOwner[msg.sender];
    }

    function open(string symbol, uint strikePrice, uint8 leverage, uint expiration, bool position) public payable returns (uint) {
        require(leverage >= 1 && leverage <= 10);
        require(expiration > now);
        require(msg.value >= MIN_COLLATERAL);

        ++orderId;
        orders[orderId] = Order(msg.value, now, expiration, strikePrice, 0, msg.sender, 0x0, position, !position, leverage, symbol, State.Open, 0, 0);
        openOrders.push(orderId);
        openOrderByOwner[msg.sender].push(orderId);
        emit LogOpen(msg.sender);
        return orderId;
    }

    // Maker can cancel an order if it's not (fully) taken.
    function cancelOrder(uint id) public validId(id) {
        Order memory order = orders[id];
        require(order.taker == 0x0 && order.maker == msg.sender);

        delete orders[id];
        removeByValue(openOrders, id);
        removeByValue(openOrderByOwner[msg.sender], id);
        order.maker.transfer(order.collateral);
        emit LogCancel(msg.sender);
    }

    // Taker can partially take an order before expiration.
    function partialFill(uint id) public payable validId(id) canFill(id) {
        require(orders[id].status == State.Open);
        require(msg.value >= MIN_COLLATERAL && orders[id].collateral.sub(msg.value) >= MIN_COLLATERAL);

        // Adjust partially filled order
        orders[id].collateral -= msg.value;

        // Create a new filled order.
        Order memory newOrder = orders[id];
        ++orderId;
        newOrder.collateral = msg.value;
        newOrder.taker = msg.sender;
        newOrder.status = State.Filled;
        orders[orderId] = newOrder;
        filledOrderByOwner[newOrder.taker].push(orderId);
        filledOrderByOwner[newOrder.maker].push(orderId);
        emit LogPartialFill(orders[id].maker,msg.sender);
    }

    // Taker can take an order before expiration.
    function fill(uint id) public payable validId(id) canFill(id) {
        require(orders[id].status == State.Open);
        // Taker must provide same amount of collateral as deposited by the option maker.
        require(msg.value == orders[id].collateral);

        removeByValue(openOrders, id);
        removeByValue(openOrderByOwner[orders[id].maker], id);

        filledOrderByOwner[orders[id].maker].push(id);
        filledOrderByOwner[msg.sender].push(id);
        orders[id].taker = msg.sender;
        orders[id].status = State.Filled;
        emit LogFill(orders[id].maker,msg.sender);
    }

    // Either maker or taker can exercise a filled order to finalize at any time after expiration.
    // However the maximum profit/loss is the amount of collateral.
    // Contracts queries oracle to get final exercise price at timestamp expiration.
    function exercise(uint id) public validId(id) {
        require(orders[id].status == State.Filled && !orderInExercise[id]);
        require(block.timestamp > orders[id].expiration);
        require(msg.sender == orders[id].maker || msg.sender == orders[id].taker);

        string memory dataSource;
        string memory selector;
        (dataSource, selector) = buildOracleRequest(orders[id].symbol, orders[id].expiration);
        uint queryId = DOSQuery(30, dataSource, selector);
        queryToOrderId[queryId] = id;
        orderInExercise[id] = true;
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

        uint order_id = queryToOrderId[queryId];
        Order storage order = orders[order_id];
        order.exercisePrice = price * 1e4 + fractional;

        uint total = 2 * order.collateral;
        uint payToMaker = 0;
        // condition of Maker Long
        // payToMaker = collateral * (1 + leverage * (exercisePrice - strikePrice) / strikePrice);
        if(order.maker_position){
            if (order.exercisePrice >= order.strikePrice && (order.exercisePrice - order.strikePrice).mul(order.leverage) >= order.strikePrice) {
                payToMaker = total;
            } else if (order.strikePrice >= order.exercisePrice && (order.strikePrice - order.exercisePrice).mul(order.leverage) >= order.strikePrice) {
                payToMaker = 0;
            } else {
                payToMaker = (order.exercisePrice.mul(order.leverage) - (order.leverage - 1).mul(order.strikePrice)).mul(order.collateral).div(order.strikePrice);
            }   
        }
        // condition of Maker short
        else {
            if (order.exercisePrice >= order.strikePrice && (order.exercisePrice - order.strikePrice).mul(order.leverage) >= order.strikePrice) {
                payToMaker = 0;
            } else if (order.strikePrice >= order.exercisePrice && (order.strikePrice - order.exercisePrice).mul(order.leverage) >= order.strikePrice) {
                payToMaker = total;
            } else {
                payToMaker = ((order.leverage + 1).mul(order.strikePrice) - order.exercisePrice.mul(order.leverage)).mul(order.collateral).div(order.strikePrice);
            } 
        }

        uint payToTaker = total.sub(payToMaker);
        order.status = State.Exercised;
        delete orderInExercise[order_id];
        delete queryToOrderId[queryId];

        order.makerPayout = payToMaker;
        order.takerPayout = payToTaker;
        order.maker.transfer(payToMaker);
        order.taker.transfer(payToTaker);
        emit LogExec(order.maker,order.taker);
    }

    // Build oracle request, returns (data source, selector) string.
    function buildOracleRequest(string symbol, uint timestamp) private view returns (string, string) {
        timestamp = min(now, timestamp);
        // Get historial price by https://min-api.cryptocompare.com/data/pricehistorical?e=binance&tsyms=USDT&fsym=ETH&ts=1545868355
        return (
            "https://min-api.cryptocompare.com/data/pricehistorical?e=binance&tsyms=USDT&fsym=".strConcat(symbol).strConcat("&ts=").strConcat(utils.uint2Str(timestamp)),
            "$.".strConcat(symbol).strConcat(".USDT")
        );
    }

    function min(uint a, uint b) private pure returns (uint) {
        return a < b ? a : b;
    }

    function removeByValue(uint[] storage arr, uint val) private {
        uint len = arr.length;
        for (uint i = 0; i < len; i++) {
            if (arr[i] == val) {
                arr[i] = arr[len - 1];
                delete arr[len-1];
                arr.length--;
                return;
            }
        }
    }
}
