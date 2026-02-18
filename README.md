# Yuruna

**Tools and automation for development environments and cloud deployments.**

Yuruna provides two main capabilities: creating Virtual Development Environments (VDE) for consistent, reproducible workspaces, and deploying containerized applications to Kubernetes across multiple clouds.

## Virtual Development Environment (VDE)

Create consistent, reproducible development workspaces using virtualization. The VDE automates the setup of guest virtual machines on Windows (Hyper-V) and macOS (UTM), with support for Amazon Linux and Ubuntu Desktop guests. Post-setup scripts install development tools like Visual Studio Code, .NET SDK, Java, PostgreSQL, and more.

See the [VDE documentation](vde/README.md) to get started.

## Kubernetes Deployment

Deploy containerized applications to Kubernetes across multiple clouds with a single workflow. Write your configuration once, then deploy to localhost, Azure, AWS, or Google Cloud by changing a single parameter. Yuruna automates infrastructure provisioning (OpenTofu), container building (Docker), and application deployment (Helm).

See the [Kubernetes documentation](docs/kubernetes.md) for setup and usage instructions.

## Documentation

- [VDE Setup](vde/README.md) - Virtual Development Environment
- [Kubernetes Deployment](docs/kubernetes.md) - Multi-cloud Kubernetes automation
- [Requirements](docs/requirements.md) - Full tool installation guide
- [FAQ](docs/faq.md) - Troubleshooting common issues
- [Contributing](docs/contributing.md) - How to contribute

## Important Notes

- **Cost warning**: Cloud resources incur charges. Always [clean up](docs/cleanup.md) resources you're not using.
- Scripts and examples are provided "as is" without guarantees. See [license](license.md).

---

Copyright (c) 2019-2026 by Alisson Sol et al.
