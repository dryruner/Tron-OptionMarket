pragma solidity >= 0.4.24 < 0.5.0;

contract DOSProxyInterface {
    function query(address, uint, string memory, string memory) public returns (uint);
    function requestRandom(address, uint8, uint) public returns (uint);
}

contract DOSAddressBridgeInterface {
    function getProxyAddress() public view returns (address);
}

contract DOSOnChainSDK {
    DOSProxyInterface dosProxy;
    DOSAddressBridgeInterface dosAddrBridge =
        DOSAddressBridgeInterface(0xe987926A226932DFB1f71FA316461db272E05317);

    modifier resolveAddress {
        dosProxy = DOSProxyInterface(dosAddrBridge.getProxyAddress());
        _;
    }

    function fromDOSProxyContract() internal view returns (address) {
        return dosAddrBridge.getProxyAddress();
    }

    // @dev: Call this function to get a unique queryId to differentiate
    //       parallel requests. A return value of 0x0 stands for error and a
    //       related event would be emitted.
    // @timeout: Estimated timeout in seconds specified by caller; e.g. 15.
    //           Response is not guaranteed if processing time exceeds this.
    // @dataSource: Data source destination specified by caller.
    //              E.g.: 'https://api.coinbase.com/v2/prices/ETH-USD/spot'
    // @selector: A selector expression provided by caller to filter out
    //            specific data fields out of the raw response. The response
    //            data format (json, xml/html, and more) is identified from
    //            the selector expression.
    //            E.g. Use "$.data.amount" to extract "194.22" out.
    //             {
    //                  "data":{
    //                          "base":"ETH",
    //                          "currency":"USD",
    //                          "amount":"194.22"
    //                  }
    //             }
    //            Check below documentation for details.
    //            (https://dosnetwork.github.io/docs/#/contents/blockchains/ethereum?id=selector).
    function DOSQuery(uint timeout, string memory dataSource, string memory selector)
    resolveAddress
    internal
    returns (uint)
    {
        return dosProxy.query(address(this), timeout, dataSource, selector);
    }

    // @dev: Must override __callback__ to process a corresponding response. A
    //       user-defined event could be added to notify the Dapp frontend that
    //       the response is ready.
    // @queryId: A unique queryId returned by DOSQuery() for callers to
    //           differentiate parallel responses.
    // @result: Response for the specified queryId.
    function __callback__(uint queryId, bytes memory result) public {
        // To be overridden in the caller contract.
    }
}
