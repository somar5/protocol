// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { Test, stdError, stdJson } from "forge-std/Test.sol";

abstract contract ForkTest is Test {
  using stdJson for string;

  address internal proxyAdmin;

  function deployment(string memory name) internal returns (address addr) {
    addr = vm
      .readFile(string.concat("deployments/", getChain(block.chainid).chainAlias, "/", name, ".json"))
      .readAddress(".address");
    vm.label(addr, name);
    if (proxyAdmin == address(0)) {
      proxyAdmin = vm
        .readFile(string.concat("deployments/", getChain(block.chainid).chainAlias, "/ProxyAdmin.json"))
        .readAddress(".address");
      vm.label(proxyAdmin, "ProxyAdmin");
    }
    vm.prank(proxyAdmin);
    (bool success, bytes memory data) = addr.staticcall(abi.encodeCall(IProxy.implementation, ()));
    if (success) vm.label(abi.decode(data, (address)), string.concat(name, "_Impl"));
  }
}

interface IProxy {
  function implementation() external returns (address);
}
