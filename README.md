# FMProxy

A local OpenAI-compatible chat completions proxy for Apple Foundation Models on macOS 26 Tahoe.

## Requirements

- macOS 26.0 or later
- Xcode with the macOS 26 SDK
- Apple Foundation Models must be available on the Mac

## Build

```bash
xcodebuild -project FMProxy.xcodeproj -scheme FMProxy -configuration Release build
```

or use the provided `build.sh` script.

## Run

Build the standalone Apple Silicon binary with the provided script:

```bash
./build.sh
```

Then start the generated binary directly from the repository root:

```bash
./fmproxy-bin
```

The default configuration listens on `127.0.0.1:8080`. Parameters can be supplied when starting the binary:

```bash
./fmproxy-bin --host 127.0.0.1 --port 8080
```

### Command-line options

| Option | Description | Default |
|---|---|---|
| `--host <host>` | Host address to bind to | `127.0.0.1` |
| `--port <port>` | TCP port to listen on | `8080` |
| `--help`, `-h` | Show available options and exit | — |

## Endpoints

- `GET /health`
- `GET /v1/models`
- `POST /v1/chat/completions`

## Logging

Every completed request is logged compactly to the console. Request bodies and model content are not logged.

```text
[2026-09-16T19:30:00Z] POST /v1/chat/completions -> 200 (842 ms)
```

The chat endpoint accepts `messages` with the `system`, `user`, and `assistant` roles. `stream: false` returns a regular JSON response. With `stream: true`, OpenAI-compatible Server-Sent Events (`chat.completion.chunk`) are sent, followed by `data: [DONE]`. OpenAI token statistics are returned as `0` because the Foundation Models API does not provide them in a compatible format.

## Example

```bash
curl --no-buffer http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"apple-foundation-model","stream":true,"messages":[{"role":"user","content":"Explain Swift in one sentence."}]}'
```

## Am I the first one with this idea?

Of course not! Here are some examples of same idea and different approach:

* [tucats/fmProxy](https://github.com/tucats/fmProxy) ==> Swift, but using the Ollama API instead
* [gregbarbosa/fm-proxy](https://github.com/gregbarbosa/fm-proxy) ==> node.js, with more features
* [shibukawa/fmproxy](https://github.com/shibukawa/fmproxy) ==> GoLang
