# CRITICAL_ENVIRONMENT_RULES: Token Economy

- Standalone Codex CLI cannot auto-intercept raw shell queries. 
- You MUST manually prepend `rtk` to any command that generates heavy text outputs to prevent polluting the context window.
- MANDATORY MANDATE: Always substitute naked commands with `rtk <command>`.
- CORRECT EXAMPLES: Use `rtk git status`, `rtk git diff`, `rtk grep -rn "search"`, and `rtk npm test`.

## graphify

This project has a knowledge graph at graphify-out/ with god nodes, community structure, and cross-file relationships.

When the user types `/graphify`, use the installed graphify skill or instructions before doing anything else.

Rules:
- For codebase questions, first run `graphify query "<question>"` when graphify-out/graph.json exists. Use `graphify path "<A>" "<B>"` for relationships and `graphify explain "<concept>"` for focused concepts. These return a scoped subgraph, usually much smaller than GRAPH_REPORT.md or raw grep output.
- Dirty graphify-out/ files are expected after hooks or incremental updates; dirty graph files are not a reason to skip graphify. Only skip graphify if the task is about stale or incorrect graph output, or the user explicitly says not to use it.
- If graphify-out/wiki/index.md exists, use it for broad navigation instead of raw source browsing.
- Read graphify-out/GRAPH_REPORT.md only for broad architecture review or when query/path/explain do not surface enough context.
- After modifying code, run `graphify update .` to keep the graph current (AST-only, no API cost).

### Common graphify commands

```bash
# Query the graph for architecture questions (BFS traversal)
graphify query "how does session publishing work"

# Trace a specific path between two concepts (DFS)
graphify query "how does Player connect to generator" --dfs

# Explain a single node/concept
graphify explain "generate()"

# Shortest path between two concepts
graphify path "Player" "ScheduleSlot"

# Review impact of changed files
graphify review-analysis --files src/generator/index.ts --graph graphify-out/graph.json

# Check what changed since last graph build
graphify summary --graph graphify-out/graph.json
```

### When to use graphify vs grep/read

| Task | Use |
|------|-----|
| "How does X work?" (architecture) | `graphify query` |
| "Where is X called from?" (impact) | `graphify path` or `graphify review-analysis` |
| "What does X do?" (single function) | `graphify explain` or just `read` the file |
| "Find all usages of X" | `grep` (exact string match) |
| Broad codebase overview | `GRAPH_REPORT.md` or `graphify summary` |
