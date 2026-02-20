import type { VercelRequest, VercelResponse } from "@vercel/node";
import { getProvider, readGroupEvents } from "./_lib/chain.js";
import { GROUP_ID, SCOPE, VOTE_QUESTION, SEMAPHORE_ADDRESS } from "./_lib/config.js";

export default async function handler(_req: VercelRequest, res: VercelResponse) {
  try {
    const provider = getProvider();
    const { commitments, yesVotes, noVotes, recentVotes } = await readGroupEvents(provider);
    res.json({
      groupCreated: true,
      memberCount: commitments.length,
      commitments,
      yesVotes,
      noVotes,
      recentVotes,
      question: VOTE_QUESTION,
      scope: SCOPE.toString(),
      groupId: GROUP_ID.toString(),
      contractAddress: SEMAPHORE_ADDRESS,
    });
  } catch (e: any) {
    res.status(500).json({ error: e?.message || "Failed to fetch state" });
  }
}
