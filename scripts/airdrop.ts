import { ethers } from "hardhat";
import { writeFile } from "fs/promises";
import type { BigNumber } from "ethers";
import type { RewardsController } from "../types";
import { address as op } from "../deployments/optimism/OP.json";
import { address as multicallAddress, abi as multicallABI } from "../deployments/optimism/Multicall3.json";

const block = 107_054_000;
const distribution = 100_000n * 10n ** 18n;
const subgraph = "https://api.thegraph.com/subgraphs/name/exactly/optimism";

void (async () => {
  const [rewardsController, accounts, claimed] = await Promise.all([
    ethers.getContract<RewardsController>("RewardsController"),
    allAccounts(),
    opClaimed(),
  ]);

  let totalRewards = 0n;
  const batchSize = 1_000;
  const rewards: Record<string, bigint> = {};
  const multicall = new ethers.Contract(multicallAddress, multicallABI, ethers.provider);
  for (let i = 0; i < accounts.length; i += batchSize) {
    const batch = accounts.slice(i, i + batchSize);
    const [, data] = await multicall.callStatic.aggregate(
      batch.map((account) => ({
        target: rewardsController.address,
        callData: rewardsController.interface.encodeFunctionData("allClaimable", [account, op]),
      })),
      { blockTag: block },
    );
    batch.forEach((account, j) => {
      const [claimable] = rewardsController.interface.decodeFunctionResult("allClaimable", data[j]) as [BigNumber];
      rewards[account] = claimable.add(claimed[account] ?? 0).toBigInt();
      totalRewards += rewards[account];
    });
  }

  const airdrop = Object.fromEntries(
    Object.entries(rewards)
      .filter(([, amount]) => amount)
      .map(([account, amount]) => [account, String((amount * distribution) / totalRewards)]),
  );
  await writeFile("scripts/airdrop.json", JSON.stringify(airdrop, null, 2));
})();

async function allAccounts() {
  let last: string | undefined = "";
  const set = new Set<string>();
  do {
    const { accounts } = (
      await (
        await fetch(subgraph, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            query: `{
              accounts(
                first: 1000
                block: { number: ${block} }
                where: { address_gt: "${last}" }
                orderBy: address
                orderDirection: asc
              ) { address }
            }`,
          }),
        })
      ).json()
    ).data as { accounts: { address: string }[] };
    accounts.forEach(({ address }: { address: string }) => set.add(address));
    last = accounts.length ? [...set][set.size - 1] : undefined;
  } while (last);
  return [...set];
}

async function opClaimed() {
  let last: string | undefined = "";
  const claimed: [string, string][] = [];
  do {
    const { accountClaims } = (
      await (
        await fetch(subgraph, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            query: `{
              accountClaims(
                first: 1000
                block: { number: ${block} }
                where: { reward: "${op}", account_gt: "${last}" }
                orderBy: account
                orderDirection: asc
              ) { account, amount }
            }`,
          }),
        })
      ).json()
    ).data as { accountClaims: { account: string; amount: string }[] };
    last = accountClaims.length ? accountClaims[accountClaims.length - 1]?.account : undefined;
    claimed.push(...accountClaims.map(({ account, amount }) => [account, amount] satisfies [string, string]));
  } while (last);
  return Object.fromEntries(claimed);
}
