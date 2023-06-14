import { env } from "process";
import type { DeployFunction } from "hardhat-deploy/types";
import tenderlify from "./.utils/tenderlify";

const func: DeployFunction = async ({ deployments: { deploy, get }, getNamedAccounts }) => {
  const [{ address: debtManager }, { deployer }] = await Promise.all([get("DebtManager"), getNamedAccounts()]);
  await tenderlify(
    "Forwarder",
    await deploy("Forwarder", {
      skipIfAlreadyDeployed: !JSON.parse(env.DEPLOY_FORWARDER ?? "false"),
      args: [debtManager],
      from: deployer,
      log: true,
    }),
  );
};

func.tags = ["Forwarder"];
func.dependencies = ["DebtManager"];

export default func;
