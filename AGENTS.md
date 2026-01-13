1→# AGENTS.md
2→
3→## Setup
4→```bash
5→yarn install
6→```
7→
8→## Commands
9→- **Run scripts**: `yarn create-components`, `yarn create-applications`, `yarn create-it`, `yarn create-releases`
10→- **Build**: N/A (no build step required)
11→- **Lint**: N/A (no linter configured)
12→- **Test**: N/A (no test suite configured)
13→- **Dev server**: N/A (CLI script tool, not a server application)
14→
15→## Tech Stack
16→- **Language**: JavaScript/Node.js (ES modules)
17→- **Runtime**: Google's `zx` for shell scripting in JS
18→- **Package Manager**: Yarn (v1.22.22)
19→- **Target Platform**: Kubernetes/OpenShift (kubectl-based automation)
20→
21→## Architecture
22→- `/scripts`: Main automation scripts for creating Kubernetes resources (components, applications, integration tests, releases)
23→- `/yamls`: YAML configuration templates for Kubernetes resources
24→- `/dev`: Development helper scripts (shell-based)
25→- `utils.mjs`: Shared utilities for namespace management, resource creation, and safety checks
26→
27→## Code Conventions
28→- ES modules (`import`/`export`, `.mjs` extension)
29→- Use `zx` for shell command execution within JavaScript
30→- Interactive prompts for safety checks when creating >10 resources
31→- Random delays between resource creation to avoid API server overload
32→