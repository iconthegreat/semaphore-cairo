import type { VercelRequest, VercelResponse } from "@vercel/node";
import { getProvider, getSemaphoreContract, getAccount } from "./_lib/chain.js";

export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (req.method !== "POST") return res.status(405).json({ error: "Method not allowed" });
  const { nullifier } = req.body ?? {};
  if (!nullifier) return res.status(400).json({ error: "nullifier required" });

  try {
    const provider = getProvider();
    const account = getAccount(provider);
    const semaphore = getSemaphoreContract(account);
    const used = await semaphore.call("is_nullifier_used", [BigInt(nullifier)]);
    res.json({ used: !!used, choice: null });
  } catch (e: any) {
    res.status(500).json({ error: e?.message || "Failed to check nullifier" });
  }
}
