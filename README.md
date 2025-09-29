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
      - uses: actions/checkout@v4
      - uses: adamrittercd/pr-preview@main
        with:
          service: hello-cd
          base-domain: ritteradam.com
          main-port: '11000'
          preview-port-base: '13000'
```

### Behaviour

- `pull_request` events (opened/synchronize/reopened) build the Docker image, run a container, and publish it via Caddy at `https://pr-<number>.<service>.<base-domain>`.
- `pull_request` events with action `closed` tear down the corresponding container and remove the Caddy site.
- `push` events deploy the main branch to `https://<service>.<base-domain>` using the provided `main-port`.

### Requirements

- Runs on a self-hosted Linux runner with Docker and passwordless `sudo` available.
- Caddy reads virtual hosts from `/etc/caddy/conf.d` and accepts `systemctl reload caddy` to pick up changes.
- `jq` must be installed on the runner to parse GitHub event payloads.

## Inputs

| Name | Required | Default | Description |
| --- | --- | --- | --- |
| `service` | ✅ | – | Service identifier used in container names and subdomains. |
| `base-domain` | ✅ | – | Domain suffix (e.g. `example.com`). |
| `main-port` | ❌ | `11000` | Host port for the main branch deployment. |
| `preview-port-base` | ❌ | `13000` | Base host port for previews; PR number modulo 1000 is added. |

## Outputs

The action writes the following keys to `GITHUB_OUTPUT` when it performs a deployment:

- `container`
- `domain`
- `port`
- `url`

On teardown runs no outputs are produced.

## License

MIT
