# pr-preview

Reusable GitHub Action to deploy or tear down Docker-based preview environments behind Caddy using a self-hosted runner.

## Usage

Create a workflow that triggers on `pull_request` and `push` events and call the action from a job running on your self-hosted runner:

```yaml
name: PR Preview

on:
  pull_request:
    branches: [ main ]
    types: [opened, synchronize, reopened, closed]
  push:
    branches: [ main ]

jobs:
  preview:
    runs-on: self-hosted
    steps:
      - uses: adamrittercd/pr-preview@main
        with:
          service: hello-cd
          base-domain: ritteradam.com
```

### Behaviour

- `pull_request` events (opened/synchronize/reopened) build the Docker image, run a container, and publish it via Caddy at `https://pr-<number>.<service>.<base-domain>`.
- `pull_request` events with action `closed` tear down the corresponding container and remove the Caddy site.
- `push` events deploy the main branch to `https://<service>.<base-domain>` with Docker choosing an available host port automatically.
- For pull requests, the action posts (or updates) a comment on the PR with the live preview URL and host port. The comment is removed when the PR is closed.

The action performs an `actions/checkout@v4` under the hood, so you don’t need a separate checkout step.

### Requirements

- Runs on a self-hosted Linux runner with Docker, passwordless `sudo`, `curl`, and `jq` available.
- Caddy reads virtual hosts from `/etc/caddy/conf.d` and accepts `systemctl reload caddy` to pick up changes.

## Inputs

| Name | Required | Default | Description |
| --- | --- | --- | --- |
| `service` | ✅ | – | Service identifier used in container names and subdomains. |
| `base-domain` | ✅ | – | Domain suffix (e.g. `example.com`). |

The action exposes containers on ephemeral host ports assigned by Docker and records those ports in the generated Caddy config.

## Outputs

The action writes the following keys to `GITHUB_OUTPUT` when it performs a deployment:

- `container`
- `domain`
- `port`
- `url`

On teardown runs no outputs are produced.

## License

MIT
