# OSX LLM Tester

Native macOS menu-bar app for testing OpenAI-compatible endpoints. It opens from a `network` template icon and keeps the tester in a compact popover.

## Included

- Add, edit, save, remove, enable/disable, and bookmark endpoints.
- Store endpoint API keys in the macOS Keychain.
- Fetch and select models from `GET /models`, with a manual model-ID fallback.
- Run chat completions, embeddings, multimodal image prompts, and rerank requests.
- Chat controls for thinking, temperature, max tokens, and streaming.
- Live chat and multimodal responses with word-by-word rendering, automatic
  scrolling (Follow), and Stop to cancel while keeping the visible partial text.
- Copyable response panel with HTTP status and elapsed time.

## Run locally

```sh
swift run
```

For a distributable app bundle, use `scripts/build-app.sh`.

## Credential checks

Run `zsh scripts/test.sh` to check saving, replacing, clearing, failure handling,
and authenticated model/chat requests. To also verify the macOS Keychain using
a disposable test item, run `RUN_KEYCHAIN_TESTS=1 zsh scripts/test.sh`.
Test endpoint metadata uses isolated preferences, and the disposable Keychain
item is removed after the check.

## Product decisions to confirm

1. Should endpoint secrets support OAuth, custom headers, or environment-variable references in addition to Bearer API keys?
2. Should request history be saved per endpoint, with export to JSON or cURL?
3. Which provider-specific controls matter first (reasoning effort, seed, top-p, frequency penalty, JSON schema, tools/function calling)?
4. Should the word-by-word streaming speed be configurable?
5. Should models refresh on launch, on endpoint selection, or only when the user clicks Fetch models?
