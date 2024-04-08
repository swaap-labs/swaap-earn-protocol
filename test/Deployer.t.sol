// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { Deployer } from "src/Deployer.sol";
import "test/resources/MainnetStarter.t.sol";

contract FundTest is MainnetStarterTest {
    function testDeployWithEth() public {
        address[] memory deployers = new address[](1);
        deployers[0] = address(this);

        Deployer deployer = new Deployer(address(this), deployers);
        address deployedContract = deployer.deployContract{ value: 1 ether }(
            "DeployWithEthTest 0.0",
            type(DeployWithEthTest).creationCode,
            abi.encode()
        );

        assertEq(address(deployedContract).balance, 1 ether, "Balance should be 1 ether");
    }
}

contract DeployWithEthTest {
    constructor() payable {
        require(msg.value == 1 ether, "Deployment failed");
    }
}
