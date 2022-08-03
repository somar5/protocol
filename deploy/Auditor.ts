import { UnknownSignerError } from "hardhat-deploy/dist/src/errors";
import type { DeployFunction } from "hardhat-deploy/types";
import type { Auditor } from "../types";
import executeOrPropose from "./.utils/executeOrPropose";
import timelockPropose from "./.utils/timelockPropose";
import validateUpgrade from "./.utils/validateUpgrade";

const func: DeployFunction = async ({
  config: {
    finance: {
      liquidationIncentive: { liquidator: liquidatorIncentive, lenders: lendersIncentive },
    },
  },
  ethers: {
    utils: { parseUnits },
    getContractAt,
    getContract,
    getSigner,
  },
  deployments: { deploy, get },
  getNamedAccounts,
}) => {
  const [{ address: timelockAddress }, { address: oracleAddress }, { deployer }] = await Promise.all([
    get("TimelockController"),
    get("ExactlyOracle"),
    getNamedAccounts(),
  ]);
  const liquidationIncentive = {
    liquidator: parseUnits(String(liquidatorIncentive)),
    lenders: parseUnits(String(lendersIncentive)),
  };

  await validateUpgrade("Auditor", [], async (name, args) => {
    try {
      return await deploy(name, {
        args,
        proxy: {
          owner: timelockAddress,
          proxyContract: "ERC1967Proxy",
          proxyArgs: ["{implementation}", "{data}"],
          execute: {
            init: { methodName: "initialize", args: [timelockAddress, oracleAddress, liquidationIncentive] },
          },
        },
        from: deployer,
        log: true,
      });
    } catch (error) {
      if (error instanceof UnknownSignerError) {
        const { to, contract } = error.data;
        if (!to || !contract) throw error;

        await timelockPropose(await getContractAt(contract.name, to), contract.method, contract.args);
      }

      return { ...(await get(`${name}_Proxy`)), implementation: (await get(`${name}_Implementation`)).address };
    }
  });
  const auditor = await getContract<Auditor>("Auditor", await getSigner(deployer));

  if ((await auditor.oracle()) !== oracleAddress) {
    await executeOrPropose(deployer, auditor, "setOracle", [oracleAddress]);
  }

  const currentLiquidationIncentive = await auditor.liquidationIncentive();
  if (
    !currentLiquidationIncentive.liquidator.eq(liquidationIncentive.liquidator) ||
    !currentLiquidationIncentive.lenders.eq(liquidationIncentive.lenders)
  ) {
    await executeOrPropose(deployer, auditor, "setLiquidationIncentive", [liquidationIncentive]);
  }
};

func.tags = ["Auditor"];
func.dependencies = ["ExactlyOracle", "TimelockController"];

export default func;
