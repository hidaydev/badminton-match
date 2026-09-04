# CRITICAL_ENVIRONMENT_RULES: Token Economy

- Standalone Codex CLI cannot auto-intercept raw shell queries. 
- You MUST manually prepend `rtk` to any command that generates heavy text outputs to prevent polluting the context window.
- MANDATORY MANDATE: Always substitute naked commands with `rtk <command>`.
- CORRECT EXAMPLES: Use `rtk git status`, `rtk git diff`, `rtk grep -rn "search"`, `rtk make check`, and `rtk go test ./...`.
