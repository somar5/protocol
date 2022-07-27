import { expect } from "chai";
import { ethers, deployments } from "hardhat";
import type { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import type { ExactlyOracle, MockERC20, MockPriceFeed, Market } from "../types";
import timelockExecute from "./utils/timelockExecute";

const {
  utils: { parseUnits },
  getUnnamedSigners,
  getNamedSigner,
  getContract,
  provider,
} = ethers;

describe("ExactlyOracle", function () {
  let dai: MockERC20;
  let priceFeedDAI: MockPriceFeed;
  let exactlyOracle: ExactlyOracle;
  let marketDAI: Market;
  let marketWETH: Market;

  let user: SignerWithAddress;
  let owner: SignerWithAddress;
  let timestamp: number;
  let priceExpiration: number;

  before(async () => {
    owner = await getNamedSigner("multisig");
    [user] = await getUnnamedSigners();
  });

  beforeEach(async () => {
    await deployments.fixture(["Markets"]);

    dai = await getContract<MockERC20>("DAI", user);
    priceFeedDAI = await getContract<MockPriceFeed>("PriceFeedDAI", user);
    exactlyOracle = await getContract<ExactlyOracle>("ExactlyOracle", user);
    marketDAI = await getContract<Market>("MarketDAI", user);
    marketWETH = await getContract<Market>("MarketWETH", user);

    await dai.connect(owner).mint(user.address, parseUnits("100000"));
    timestamp = Math.floor(Date.now() / 1_000) + 1_000;
    priceExpiration = (await exactlyOracle.priceExpiration()).toNumber();
  });

  it("GetAssetPrice returns a positive and valid price value", async () => {
    // The price returned by the oracle is previously scaled to an 18-digit decimal
    expect(await exactlyOracle.getAssetPrice(marketDAI.address)).to.equal(10n ** 18n);
    expect(await exactlyOracle.getAssetPrice(marketWETH.address)).to.equal(1_000n * 10n ** 18n);
  });

  it("GetAssetPrice does not fail when Chainlink price is not older than priceExpiration", async () => {
    await priceFeedDAI.setUpdatedAt(timestamp - priceExpiration + 1);
    await provider.send("evm_setNextBlockTimestamp", [timestamp]);
    await provider.send("evm_mine", []);
    await expect(exactlyOracle.getAssetPrice(marketDAI.address)).to.not.be.reverted;
  });

  it("GetAssetPrice does not fail when Chainlink price is equal to priceExpiration", async () => {
    await priceFeedDAI.setUpdatedAt(timestamp - priceExpiration);
    await provider.send("evm_setNextBlockTimestamp", [timestamp]);
    await provider.send("evm_mine", []);
    await expect(exactlyOracle.getAssetPrice(marketDAI.address)).to.not.be.reverted;
  });

  it("GetAssetPrice should fail when Chainlink price is older than priceExpiration", async () => {
    await priceFeedDAI.setUpdatedAt(timestamp - priceExpiration - 1);
    await provider.send("evm_setNextBlockTimestamp", [timestamp]);
    await provider.send("evm_mine", []);
    await expect(exactlyOracle.getAssetPrice(marketDAI.address)).to.be.revertedWith("InvalidPrice()");
  });

  it("GetAssetPrice should fail when price value is zero", async () => {
    await priceFeedDAI.setPrice(0);
    await expect(exactlyOracle.getAssetPrice(marketDAI.address)).to.be.revertedWith("InvalidPrice()");
  });

  it("GetAssetPrice should fail when price value is lower than zero", async () => {
    await priceFeedDAI.setPrice(-10);
    await expect(exactlyOracle.getAssetPrice(marketDAI.address)).to.be.revertedWith("InvalidPrice()");
  });

  it("GetAssetPrice should fail when asset address is invalid", async () => {
    await expect(exactlyOracle.getAssetPrice(user.address)).to.be.revertedWith("0x");
  });

  it("SetPriceFeed should set the address source of an asset", async () => {
    await timelockExecute(owner, exactlyOracle, "grantRole", [await exactlyOracle.DEFAULT_ADMIN_ROLE(), owner.address]);
    const { address } = await deployments.deploy("NewPriceFeed", {
      contract: "MockPriceFeed",
      args: [1],
      from: owner.address,
    });
    await expect(await exactlyOracle.connect(owner).setPriceFeed(marketDAI.address, address))
      .to.emit(exactlyOracle, "PriceFeedSet")
      .withArgs(marketDAI.address, address);
    await priceFeedDAI.setPrice(1);
    await priceFeedDAI.setUpdatedAt(timestamp - 86_400);
    await provider.send("evm_setNextBlockTimestamp", [timestamp]);
    await provider.send("evm_mine", []);
    expect(await exactlyOracle.getAssetPrice(marketDAI.address)).to.equal(1e10);
  });

  it("SetPriceFeed should fail when called from third parties", async () => {
    await expect(exactlyOracle.setPriceFeed(marketDAI.address, await marketDAI.asset())).to.be.revertedWith(
      "AccessControl",
    );
  });
});
