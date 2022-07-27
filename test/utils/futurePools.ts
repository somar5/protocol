import { BigNumber } from "ethers";

export const INTERVAL = 86_400 * 7 * 4;

export default (n = 3, interval = INTERVAL, now = Math.floor(Date.now() / 1_000)) =>
  [...new Array(n)].map((_, i) => BigNumber.from(now - (now % interval) + interval * (i + 1)));
