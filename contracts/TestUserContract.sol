pragma solidity ^0.4.23;

import "./Ownable.sol";
import "./DOSOnChainSDK.sol";

// A user contract asks anything from off-chain world through a url.
contract TestUserContract is Ownable, DOSOnChainSDK {
    string public response;
    // query_id -> valid_status
    mapping(uint => bool) private _valid;
    // Default timeout in seconds: Two blocks.
    uint public timeout = 14 * 2;
    string public lastQueriedUrl;
    string public lastQueriedSelector;

    event SetTimeout(uint previousTimeout, uint newTimeout);
    event QueryResponseReady(uint queryId, string result);
    event RequestSent(bool succ, uint requestId);

    constructor(address addr) DOSOnChainSDK(addr) public {}

    modifier auth(uint id) {
        require(msg.sender == fromDOSProxyContract(),
                "Unauthenticated response from non-DOS.");
        require(_valid[id], "Response with invalid request id!");
        _;
    }

    function setTimeout(uint newTimeout) public onlyOwner {
        emit SetTimeout(timeout, newTimeout);
        timeout = newTimeout;
    }

    // Ask me anything (AMA) off-chain through an api/url.
    function AMA(string memory url, string memory selector) public {
        lastQueriedUrl = url;
        lastQueriedSelector = selector;
        uint id = DOSQuery(timeout, url, selector);
        if (id != 0x0) {
            _valid[id] = true;
            emit RequestSent(true, id);
        } else {
            revert("Invalid query id.");
        }
    }

    // User-defined callback function handling query response.
    function __callback__(uint queryId, bytes memory result) public auth(queryId) {
        response = string(result);
        emit QueryResponseReady(queryId, response);
        delete _valid[queryId];
    }
}
