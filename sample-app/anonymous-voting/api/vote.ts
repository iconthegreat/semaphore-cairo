import type { VercelRequest, VercelResponse } from "@vercel/node";
import { getProvider, getAccount, getSemaphoreContract } from "./_lib/chain.js";
import { encodeCalldata } from "./_lib/calldata.js";
import { GROUP_ID } from "./_lib/config.js";

export const config = { maxDuration: 60 };

export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (req.method !== "POST") return res.status(405).json({ error: "Method not allowed" });
  const { proof } = req.body ?? {};
  if (!proof) return res.status(400).json({ error: "proof required" });

  try {
    console.log("[vote] Encoding calldata via Garaga...");
    const calldata = await encodeCalldata(proof);
    console.log(`[vote] ${calldata.length} felts. Submitting to Sepolia...`);

    const provider = getProvider();
    const account = getAccount(provider);
    const semaphore = getSemaphoreContract(account);

    const tx = await semaphore.invoke("send_signal", [GROUP_ID, calldata]);
    const receipt: any = await provider.waitForTransaction(tx.transaction_hash);

    if (receipt?.statusReceipt === "REJECTED") {
      return res.status(400).json({ error: "Transaction rejected on-chain" });
    }

    const choice = String(proof.message) === "1" || BigInt(proof.message) === 1n ? "yes" : "no";
    res.json({ txHash: tx.transaction_hash, choice });
  } catch (e: any) {
    const msg = e?.message || "Failed to submit vote";
    if (msg.includes("Nullifier already used") || msg.includes("REVERTED") || msg.includes("reverted")) {
      return res.status(400).json({ error: "Already voted (on-chain)" });
    }
    res.status(500).json({ error: msg });
  }
}
