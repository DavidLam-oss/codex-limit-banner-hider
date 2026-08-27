# Security policy

## Scope

Codex Limit Banner Hider is a local UI customization. It must not bypass usage limits, click purchase/reset actions, modify the signed Codex bundle, alter account credentials, or expose a remote-debugging TCP listener.

The controller is designed to fail closed when application identity, signature verification, process identity, page identity, or banner structure cannot be established uniquely.

## Reporting a vulnerability

Please open a GitHub security advisory for issues that could:

- attach to an unintended application or renderer;
- expose the DevTools channel to another process;
- click or mutate account/billing actions;
- hide warnings outside the documented target;
- modify the Codex application bundle or credentials;
- cause an established Codex task to be interrupted.

Avoid including account data, cookies, tokens, private task content, or full diagnostic archives in a public issue.
