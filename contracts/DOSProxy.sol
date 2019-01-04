pragma solidity ^0.4.23;

import "./Ownable.sol";

contract UserContractInterface {
    function __callback__(uint, bytes) public;
}

contract DOSProxy is Ownable {
    // calling query_id => user contract
    mapping(uint => address) pendingRequests;
    uint requestIdSeed;

    event LogUrl(uint queryId, uint timeout, string dataSource, string selector);
    event LogNonSupportedType(string invalidSelector);
    event LogNonContractCall(address from);
    event LogCallbackTriggeredFor(address callbackAddr);
    event LogRequestFromNonExistentUC();

    function getCodeSize(address addr) constant internal returns (uint size) {
        assembly {
            size := extcodesize(addr)
        }
    }

    function query(address from, uint timeout, string dataSource, string selector) external returns (uint) {
        if (getCodeSize(from) > 0) {
            bytes memory bs = bytes(selector);
            // '': Return whole raw response;
            // Starts with '$': response format is parsed as json.
            // Starts with '/': response format is parsed as xml/html.
            if (bs.length == 0 || bs[0] == '$' || bs[0] == '/') {
                uint queryId = uint(keccak256(abi.encodePacked(
                    ++requestIdSeed, from, timeout, dataSource, selector)));
                    pendingRequests[queryId] = from;
                    emit LogUrl(queryId, timeout, dataSource, selector);
                    return queryId;
            } else {
                emit LogNonSupportedType(selector);
                return 0x0;
            }
        } else {
            // Skip if @from is not contract address.
            emit LogNonContractCall(from);
            return 0x0;
        }
    }

    // There's no sender validation for single node oracle except the owner check.
    // Just for safety purpose...
    function triggerCallback(uint requestId,bytes result) external onlyOwner {
        address ucAddr = pendingRequests[requestId];
        if (ucAddr == address(0x0)) {
            emit LogRequestFromNonExistentUC();
            return;
        }

        emit LogCallbackTriggeredFor(ucAddr);
        delete pendingRequests[requestId];
        UserContractInterface(ucAddr).__callback__(requestId, result);
    }
}
