---
name: model-router
description: Route a substantive task to the cheapest model that can do it well, instead of using one model for everything. Use for self-contained work (a report, script, batch of files, research question, design decision) where model choice affects cost or quality — not quick replies. If the user signals they care a lot about quality ("make this really good," "don't cut corners," "give me your best") without picking a model, ask them to choose low-cost vs. high-cost with tradeoffs explained. Otherwise silently classify task complexity and delegate to a subagent on the right-sized model — cheap for mechanical work, default for everyday work, top-tier for work needing deep reasoning. Trigger on "use the cheapest model that works," "which model should handle this," "don't waste money on this," "I want the best possible answer," or any cost-vs-quality request.
---

# Model Router

Claude cannot change the model of the chat it's currently running in — that's fixed by the user in Settings. What this skill *can* do is decide, per task, which model does the actual work, by delegating to a subagent (the Agent tool) with a specific `model` parameter. Every routing decision below happens through that mechanism, not by trying to reconfigure the current session.

Don't invoke this machinery for small conversational turns — a quick clarifying answer, a one-line edit, a short factual lookup. The overhead of spinning up a subagent only pays off for a discrete, substantive piece of work: something you could hand to a subagent with a self-contained brief and get a self-contained result back.

## Step 1: Is the user explicitly signaling they care about quality?

Watch for phrases like "make this really good," "quality matters here," "don't cut corners," "I want your best work," "take your time and get this right," or similar — cases where the user is telling you the output matters more than usual, but hasn't already told you which model to use.

When that happens, don't guess. Ask, using AskUserQuestion (or just ask in text if that tool isn't available), something like:

- **Low-cost (Haiku)** — fast and cheap, handles well-defined tasks fine, but more likely to miss nuance, edge cases, or subtle tradeoffs on harder problems.
- **High-cost (Opus)** — slower and pricier, but does noticeably better on tasks needing deep reasoning, ambiguity resolution, or careful judgment.

Explain the tradeoff in terms of *this specific task* (what could go wrong with the cheap option, what the expensive option buys), not just in the abstract. Then route to whichever the user picks.

If the user has already told you which model or tier to use anywhere in the conversation, skip the question and just use it.

## Step 2: Otherwise, classify and route silently

For everything else, don't ask — pick the tier yourself and delegate. Most tasks land in the default tier; only route up or down when there's a real signal.

**Haiku (low cost)** — mechanical, low-ambiguity work: reformatting, renaming, simple extraction, boilerplate generation, short factual lookups, running a well-defined script, straightforward data cleanup.

**Sonnet (default)** — the large majority of real work: everyday coding, most writing, standard analysis, multi-step agentic tasks, research summaries. If you're unsure which tier fits, use this one — it's the safe default, not a fallback of last resort.

**Opus (high cost)** — tasks where getting it wrong is expensive or where the reasoning is genuinely hard: security- or money-critical code, ambiguous strategic or architectural decisions, synthesizing conflicting information across many long documents, nuanced or high-stakes writing (legal, medical, executive-facing), anything the user flags as high-stakes without explicitly asking for a model choice.

Route via the Agent tool, setting `model` to `haiku`, `sonnet`, or `opus` and writing a self-contained prompt for the subagent (it has no memory of this conversation — brief it like a new hire, per standard Agent tool usage). Report the result back to the user; you don't need to announce which tier you picked unless it's relevant or the user asks.

## Step 3: Report the approximate savings

Every completed subagent task comes with a usage notification containing `total_tokens`. Use that to give a one-line estimate, at the end of your reply, of what routing saved versus just running everything on Opus (the tier you'd reach for by default if this skill didn't exist).

Blended $/MTok rates (weighted ~75% input / 25% output, a rough agentic-workload mix — not exact, since the usage notification doesn't split input from output):

| Tier | Blended rate |
|------|-------------|
| Haiku | ~$2/MTok |
| Sonnet | ~$4.75/MTok |
| Opus | ~$10/MTok |

(Sourced from published per-token pricing as of July 2026 — check [platform.claude.com/docs/en/about-claude/pricing](https://platform.claude.com/docs/en/about-claude/pricing) if these look stale, since list prices do change.)

For each subagent call: `cost = total_tokens × blended_rate[tier_used] / 1,000,000`. Sum across all subagent calls in the task for the actual total. Compute a baseline by re-pricing that same token total at the Opus rate. Report the difference:

`~$0.03 saved (Sonnet instead of Opus for this task, ~55% cheaper).`

If the task was routed to Opus (no cheaper tier used), there's nothing to report — skip the line entirely rather than saying "$0 saved." If the task didn't go through a subagent at all (handled directly, or too small to delegate), skip it too — this is about the routing decision, not a running total across the whole conversation. Keep it to one line; this is a courtesy footnote, not a report.

## Edge cases

- **Task complexity is genuinely unclear:** default to Sonnet rather than asking — asking adds friction for the majority of tasks where the default is fine. Only escalate to a question when the user's own words signal they care about the quality/cost tradeoff (Step 1).
- **User asks "which model would you use for X" as a question, not a task to do:** just answer directly, explain your reasoning, don't spin up a subagent — there's nothing to delegate.
- **Multi-part request mixing trivial and hard sub-tasks:** it's fine to split it — route the mechanical parts to Haiku and the hard parts to Opus/Sonnet as separate subagent calls, then assemble the results yourself.
