# AGENTS.md

## Setup
```bash
yarn install
```

## Commands
- **Run scripts**: `yarn create-components`, `yarn create-applications`, `yarn create-it`, `yarn create-releases`
- **Build**: N/A (no build step required)
- **Lint**: N/A (no linter configured)
- **Test**: N/A (no test suite configured)
- **Dev server**: N/A (CLI script tool, not a server application)

## Tech Stack
- **Language**: JavaScript/Node.js (ES modules)
- **Runtime**: Google's `zx` for shell scripting in JS
- **Package Manager**: Yarn (v1.22.22)
- **Target Platform**: Kubernetes/OpenShift (kubectl-based automation)

## Architecture
- `/scripts`: Main automation scripts for creating Kubernetes resources (components, applications, integration tests, releases)
- `/yamls`: YAML configuration templates for Kubernetes resources
- `/dev`: Development helper scripts (shell-based)
- `utils.mjs`: Shared utilities for namespace management, resource creation, and safety checks

## Code Conventions
- ES modules (`import`/`export`, `.mjs` extension)
- Use `zx` for shell command execution within JavaScript
- Interactive prompts for safety checks when creating >10 resources
- Random delays between resource creation to avoid API server overload
