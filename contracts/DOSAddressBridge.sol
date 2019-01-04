pragma solidity ^0.4.23;

import "./Ownable.sol";

contract DOSAddressBridge is Ownable {
    // Deployed DOSProxy contract address.
    address private _proxyAddress;

    event ProxyAddressUpdated(address previousProxy, address newProxy);

    function getProxyAddress() public view returns (address) {
        return _proxyAddress;
    }

    function setProxyAddress(address newAddr) public onlyOwner {
        emit ProxyAddressUpdated(_proxyAddress, newAddr);
        _proxyAddress = newAddr;
    }
}
