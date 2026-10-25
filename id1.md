**No single app fully matches your ideal yet**, but several come close by combining human-in-the-loop control, role/complexity/cost-based model assignment, selective shared context (instead of full expensive re-injection), and subscription-backed top-tier models with usage visibility.

### Closest Matches

**AgentsRoom (especially Agent Teams)** is the strongest fit for what you described.

- Visual multi-agent orchestration (n8n-style canvas) where each node is a specialized agent (Dev, QA, Architect, etc.).
- Each agent can use a different LLM/harness/model: Claude Code, Codex, GitHub Copilot CLI, OpenCode, Aider, Cursor, Grok Build, and others (17+ supported). You assign models per role (e.g., stronger reasoning model for architecture, cheaper/faster for implementation or review).
- **Efficient shared context**: Agents get focused sessions + structured handoffs + a shared `NOTES.md` scratchpad (append-only, survives compaction/restarts) + MCP tools for notes, inboxes, timeline, and diffs. They do not re-ingest full expansive histories; they read selective shared state and return compressed payloads.
- Strong human-in-the-middle: Manual handoffs, “await” nodes that pause for your input, conditional edges, quality gates that can route back to you, and review-before-merge. Feedback loops reuse agents with prior memory.
- Subscription-friendly: It drives the native CLIs of the tools you already pay for (Claude Code, Codex, Copilot, etc.), so you use your existing plans. Cost controls include max-cycle guards. Usage monitoring stays with the providers’ dashboards (or aggregators like AgentsView).
- Isolated execution (often with worktrees) plus shared coordination layer keeps agents from stepping on each other while still collaborating.

**Conductor (Melty Labs)** is excellent if you want parallel agents under human review with minimal setup.

- Runs multiple Claude Code, Codex, Cursor, or OpenCode agents in parallel, each in its own isolated git worktree.
- Reuses your existing subscriptions/logins (Claude Pro/Max, ChatGPT/Codex plans, etc.).
- Human stays firmly in the middle: visual dashboard, diff review, comments, and merge decisions.
- Shared context is lighter (mostly via the shared repo and your review process) than AgentsRoom’s scratchpad/messaging, but isolation + worktrees prevents expensive full-context collisions.
- Free app (you pay only via the underlying agent subscriptions). Strong for resource-constrained parallel work where you approve or redirect.

**OpenCode + plugins** is the most flexible open-source option for custom routing and shared memory.

- Native multi-provider support (75+ via Models.dev) plus ChatGPT Plus/Pro and GitHub Copilot subscription logins. Claude is typically API or proxy-based due to Anthropic’s restrictions on third-party subscription use.
- Routing plugins (e.g., opencode-smart-router / model-router variants) do tiered or role-based delegation by task type, complexity, and cost ratios, with budget/quality modes and fallbacks.
- Shared memory plugins (opencode-agent-memory Letta-style blocks, oc-mnemoria hive mind, Magic Context, etc.) give selective, persistent, cross-session/role memory without dumping full context into every call. Agents read/write focused blocks; recent/relevant memories can be injected efficiently.
- Human-in-the-loop via Plan modes, approvals, and your own instructions for the router. Pair with AgentsView for unified usage tracking across tools.

### Supporting Patterns and Tools

- **Efficient context pattern** that matches your preference is now common: isolated agent sessions + shared scratchpad/memory blocks + compressed handoffs/summaries (not full re-injection). Role-scoped views and prompt caching further reduce cost. Full shared transcripts are usually avoided because they bloat tokens and degrade performance.
- **Subscription + monitoring**: Top-tier models via Claude Code (Pro/Max), ChatGPT/Codex plans, GitHub Copilot, Cursor, etc., all have native usage dashboards. **AgentsView** aggregates sessions, tokens, and estimated costs across 50+ agents locally. Enterprise options (JetBrains Air Governance, SuperBased, Databricks AI Gateway) add budgets, limits, and observability.
- **Human-guided routing under constraints**: Most systems still need you (or a lightweight classifier you control) to set the policy—e.g., “use cheap models for exploration/search, mid-tier for implementation, frontier only for architecture/hard debug, and stop if usage hits X.” True fully automatic cost-aware routers under hard subscription limits are improving but not yet seamless across all vendors.

### Practical Recommendation

| Priority | Best starting point | Why it fits |
|----------|---------------------|-------------|
| Visual multi-role teams + selective shared memory + human gates | **AgentsRoom Agent Teams** | Closest to your described ideal |
| Parallel independent agents + simple review | **Conductor** | Lowest friction with existing subscriptions |
| Maximum customization of routing + memory | **OpenCode + smart-router + memory plugins** | Open, BYOK/subscription hybrid, strong plugin ecosystem |
| Unified spend visibility | Add **AgentsView** | Cross-tool monitoring |

No production tool yet delivers fully automatic, perfect cost-aware routing across subscription limits while maintaining rich selective shared memory and zero human guidance. The closest practical stacks put **you** (or a simple policy you approve) in the routing loop, use isolated contexts + shared scratchpads, and lean on the subscriptions and dashboards you already have.

If you tell me your preferred interface (terminal, IDE, visual canvas), primary subscriptions (Claude Max, ChatGPT Pro, Copilot, etc.), and whether you want more parallel independent agents or tightly coordinated sequential teams, I can narrow this further with setup notes.

**Cheap and fast decision models** fit cleanly into the human-in-the-middle multi-agent concept as a dedicated routing/classification layer. They handle the “which agent / which tier / escalate or not” decisions at a fraction of the cost and latency of a full LLM call, while the heavier models (or your subscription-backed top-tier ones) do the actual work. This preserves selective shared context, usage monitoring, and human oversight under resource constraints.

### How decision models slot in

Decision models (examples as of late 2026 include TypeSafe’s Jev, OpenAI’s Decisions API / GPT-6 Luna Decisions, Microsoft-Decision-1, AWS Strands Decider, and various open-weight classifiers) are specialized for typed outputs: classification, choice among options, scoring, or yes/no with confidence. They typically charge only for input tokens (or very low rates), run in tens to a few hundred milliseconds, and do not generate free-form text.

In the overall architecture they act as the lightweight router or gate:

- **Complexity / role routing**: A decision model classifies the incoming task or subtask (simple edit, multi-file implementation, architecture/debug, review, etc.) and routes it to the appropriate agent + model tier. Low-confidence cases escalate to a stronger model or pause for human approval.
- **Cost-aware under restrictions**: The decision model sees remaining subscription quotas, cost ratios, or a simple policy you set (“prefer Haiku/Flash for exploration unless confidence < X or task tagged architecture”). It can choose the cheapest capable option or flag for you.
- **Human-in-the-middle integration**: Decisions that are borderline, high-stakes, or outside policy thresholds surface for your approval before the expensive agent runs. You can override or adjust the policy. High-confidence routine routes proceed automatically.
- **Efficient context**: The decision model receives only a short summary or the latest user message + a compressed shared-state snippet (not the full expansive history). The selected specialist agent then gets its focused context + the relevant shared memory blocks / NOTES.md / handoff payload.
- **Subscription + monitoring**: Routing calls are cheap enough that they rarely threaten subscription limits. The actual work still runs on your Claude Code, Codex, Copilot, etc. sessions, so native dashboards (and aggregators like AgentsView) continue to show real spend. Decision-model usage can be logged separately for visibility.

This is the classic “cascade / route-by-complexity” pattern: most traffic stays on cheap/fast paths; only the minority that needs deep reasoning or fails a quality/confidence check moves to frontier models. Reported savings in similar setups are often 40–80%+ versus always-on frontier models, with quality held by the escalation path.

### Updated tool fit

| Tool / stack | How decision models integrate | Notes |
|--------------|-------------------------------|-------|
| **AgentsRoom** (Agent Teams + Adaptive Mode) | Adaptive Mode already uses a small fast routing model to suggest the cheapest suitable model from the provider’s lineup before you send. Easy to extend with explicit decision-model calls for multi-agent handoffs or quality gates. | Strong human gates and shared NOTES.md already match the selective-context preference. Subscription CLIs stay in place. |
| **OpenCode + plugins** | Multiple plugins (opencode-auto-jev, auto-model, smart-router variants, etc.) already call Jev or similar for per-turn or per-session model/tier selection, often with cost ratios and fallbacks. Pair with memory plugins for shared blocks. | Most mature open ecosystem for custom decision-model routing. Supports ChatGPT/Copilot subscriptions natively. |
| **Conductor** | You (or a thin wrapper) can run a decision model first to assign tasks to specific Claude/Codex workspaces. Less native, but the isolated worktrees + your review still work. | Simpler parallel style; decision layer is easier to add externally. |
| **Custom / framework layer** (LangGraph, OpenHands Model Router, etc.) | Explicit classifier node or tool that calls a decision model, then routes or switches profiles. Human interrupt nodes for low-confidence cases. | Maximum control over shared state and policies. |

### Practical pattern

1. User (or upstream agent) submits a task.
2. Cheap decision model receives a short prompt + relevant shared-memory snippet and returns a structured choice (e.g., `{tier: "medium", agent: "implementer", confidence: 0.87, escalate: false}`).
3. If confidence is high and within your resource policy → dispatch to the matching agent (which loads its focused context + shared notes).
4. If low confidence, high cost impact, or policy boundary → pause for your approval or auto-escalate to a stronger model.
5. Specialist does the work, writes back to the shared scratchpad/memory, and returns a compressed result.
6. Usage is tracked at the provider level; the decision calls stay negligible.

This keeps the human firmly in the middle for policy and exceptions, avoids re-injecting full expensive context everywhere, lets top-tier models run on subscriptions when needed, and uses cheap/fast decision models to make the routing itself inexpensive and quick.

AgentsRoom’s Adaptive Mode and the OpenCode decision-model plugins are the most direct ways to try this today. If you want, I can outline a concrete configuration sketch for one of them (e.g., OpenCode + Jev-style router + memory blocks, or AgentsRoom teams with an explicit decision step).
