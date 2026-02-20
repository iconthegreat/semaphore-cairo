import type { VercelRequest, VercelResponse } from "@vercel/node";
import { Group } from "@semaphore-protocol/group";
import { getProvider, getAccount, getSemaphoreContract, readGroupEvents } from "./_lib/chain.js";
import { GROUP_ID } from "./_lib/config.js";

export const config = { maxDuration: 30 };

export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (req.method !== "POST") return res.status(405).json({ error: "Method not allowed" });
  const { commitment } = req.body ?? {};
  if (!commitment) return res.status(400).json({ error: "commitment required" });

  try {
    const provider = getProvider();
    const { commitments } = await readGroupEvents(provider);

    if (commitments.includes(commitment)) {
      return res.json({ alreadyMember: true, commitments, memberCount: commitments.length });
    }

    const allMembers = [...commitments, commitment].map(BigInt);
    const group = new Group(allMembers);
    const newRoot = group.root;

    const account = getAccount(provider);
    const semaphore = getSemaphoreContract(account);
    const tx = await semaphore.invoke("add_member", [GROUP_ID, BigInt(commitment), newRoot]);
    await provider.waitForTransaction(tx.transaction_hash);

    res.json({
      alreadyMember: false,
      txHash: tx.transaction_hash,
      commitments: [...commitments, commitment],
      memberCount: commitments.length + 1,
    });
  } catch (e: any) {
    res.status(500).json({ error: e?.message || "Failed to join" });
  }
}
