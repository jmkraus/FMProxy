# FMProxy

A lightweight, local OpenAI-compatible API proxy for Apple Foundation Models.

## Features

- OpenAI-compatible `POST /v1/chat/completions`
- Streaming and non-streaming responses
- Text and base64-encoded image input
- Structured output with `json_object` and `json_schema`
- Optional JSON Schema validation
- No API keys or external services required

## Requirements

- macOS 27.0 or later
- Apple Silicon Mac with Apple Foundation Models available
- Xcode with the macOS 27 SDK

## Build

Build with Xcode:

```bash
xcodebuild \
  -project FMProxy.xcodeproj \
  -scheme FMProxy \
  -configuration Release \
  build
```

Or use the build script:

```bash
./build.sh
```

This creates `fmproxy-bin` in the repository root.

## Run

```bash
./fmproxy-bin
```

The server listens on `127.0.0.1:8080` by default.

```bash
./fmproxy-bin --host 127.0.0.1 --port 8080
```

### Options

| Option | Default | Description |
|---|---:|---|
| `--host <host>` | `127.0.0.1` | Address to bind to |
| `--port <port>` | `8080` | Port to listen on |
| `--no-logs` | — | Disable request logging |
| `--validate-structured-output` | disabled | Validate JSON Schema responses |
| `--help`, `-h` | — | Show help |

## API

### Endpoints

- `GET /health`
- `GET /v1/models`
- `POST /v1/chat/completions`

### Text completion

```bash
curl http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "apple-foundation-model",
    "messages": [
      {"role": "user", "content": "Explain Swift in one sentence."}
    ]
  }'
```

Set `"stream": true` to receive an OpenAI-compatible Server-Sent Events response.

### Image input

Images are accepted as OpenAI-style `image_url` content parts. Use a base64 data URL:

```bash
curl http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "apple-foundation-model",
    "messages": [{
      "role": "user",
      "content": [
        {"type": "text", "text": "What is in this image?"},
        {
          "type": "image_url",
          "image_url": {
            "url": "data:image/png;base64,<base64-data>"
          }
        }
      ]
    }]
  }'
```

Supported image data URLs use the `data:image/...;base64,...` format. Remote image URLs are not downloaded.

### Structured output

Use the OpenAI-compatible `response_format` field with `json_object` or `json_schema`:

```json
{
  "model": "apple-foundation-model",
  "messages": [
    {"role": "user", "content": "Return a person named Ada."}
  ],
  "response_format": {
    "type": "json_object"
  }
}
```

## Limits

- Maximum request body: 10 MiB
- Maximum headers: 64 KiB
- Request timeout: 30 seconds
- Chunked transfer encoding is not supported

## Tests

```bash
xcodebuild \
  -project FMProxy.xcodeproj \
  -scheme FMProxy \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  test
```

## Related Projects

- [tucats/fmProxy](https://github.com/tucats/fmProxy)
- [gregbarbosa/fm-proxy](https://github.com/gregbarbosa/fm-proxy)
- [shibukawa/fmproxy](https://github.com/shibukawa/fmproxy)

## License

See [LICENSE](LICENSE).
