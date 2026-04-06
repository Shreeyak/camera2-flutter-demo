# Claude Code Memory Plugins

A survey of memory plugins and skills for Claude Code (April 2026).

## Built-in: Auto-Memory

Claude Code has a built-in file-based memory system that persists across sessions.

- **Location:** `~/.claude/projects/<project-hash>/memory/`
- **How it works:** `MEMORY.md` index is loaded at conversation start. Individual memory files are read on demand when relevant.
- **Triggers:** User corrections ("don't do X"), explicit "remember this" requests, or project context worth persisting.
- **Limitations:** Conservative — only saves when prompted. Does not automatically capture tool usage or session history.
- **Docs:** https://code.claude.com/docs/en/memory

## Plugin: claude-mem

- **Repo:** https://github.com/thedotmack/claude-mem
- **What it does:** Automatically captures everything Claude does during coding sessions (tool calls, decisions, observations), compresses it with AI using Claude's agent-sdk, and injects relevant context into future sessions.
- **Key feature:** "Endless Mode" (beta) — biomimetic memory architecture for extended sessions.
- **Difference from built-in:** Automatic capture vs. manual. No user prompting needed.

## Plugin: claude-supermemory

- **Repo:** https://github.com/supermemoryai/claude-supermemory
- **Blog:** https://supermemory.ai/blog/we-added-supermemory-to-claude-code-its-insanely-powerful-now/
- **What it does:** Learns codebase, preferences, team decisions, and cross-tool context in real-time. Uses "hybrid memory" that goes beyond traditional RAG.
- **Difference from built-in:** Semantic understanding of context, not just key-value notes.

## Plugin: memsearch

- **Writeup:** https://milvus.io/blog/adding-persistent-memory-to-claude-code-with-the-lightweight-memsearch-plugin.md
- **What it does:** Lightweight plugin that indexes every conversation. Fully searchable, persistent across sessions.
- **Difference from built-in:** Vector-indexed search over past conversations. Good for "what did I do last week on X?" queries.

## Skill: remember:remember

- **Type:** Built-in skill (ships with superpowers plugin)
- **What it does:** Writes a structured handoff note to `.remember/remember.md` so the next session can pick up where the last one left off.
- **Format:** State / Next / Context sections, under 20 lines.
- **Difference from auto-memory:** Session-to-session continuity tool, not long-term memory.

## Comparison

| Feature                    | Built-in | claude-mem | supermemory | memsearch | remember |
|----------------------------|----------|------------|-------------|-----------|----------|
| Automatic capture          | No       | Yes        | Yes         | Yes       | No       |
| Semantic search            | No       | No         | Yes         | Yes       | No       |
| Session handoff            | No       | Yes        | Yes         | No        | Yes      |
| Compression                | No       | Yes        | Yes         | No        | No       |
| Zero config                | Yes      | No         | No          | No        | Yes      |
| Cross-tool context         | No       | No         | Yes         | No        | No       |

## Curated Skill Lists

- https://github.com/travisvn/awesome-claude-skills — curated list of skills
- https://github.com/alirezarezvani/claude-skills — 220+ skills for Claude Code and other agents
- https://github.com/hesreallyhim/awesome-claude-code — skills, hooks, plugins
