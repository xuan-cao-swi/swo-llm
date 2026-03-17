# Swo::Llm

OpenTelemetry instrumentation for Large Language Model (LLM) providers. This gem provides automatic tracing and monitoring for popular LLM APIs and frameworks through OpenTelemetry.

## Rationale

The Ruby LLM observability ecosystem has several existing solutions, each with meaningful gaps:

- **Official OpenTelemetry Ruby contrib** (e.g., the Anthropic instrumentation in `opentelemetry-ruby-contrib`): `Instrumentation::Anthropic` focuses primarily on context propagation rather than creating spans with rich telemetry. It does not capture request/response attributes, token usage, streaming, or tool calls. `Instrumentation::OpenAI` still under the [review](https://github.com/open-telemetry/opentelemetry-ruby-contrib/pull/1797).

- **RubyLLM instrumentation in Rails ** (by [sinaptia](https://github.com/sinaptia)) is a third-party Rails-only solution built on ActiveSupport notifications. It is not available to non-Rails applications, and the notification payload is unstructured rather than conforming to OTel semantic conventions.

- **Third-party instrumentations** such as [thoughtbot's `opentelemetry-instrumentation-ruby_llm`](https://rubyllm.com/ecosystem/#opentelemetry-rubyllm-instrumentation) cover basic chat tracing but are missing streaming response instrumentation, embedding instrumentation, and broader LLM capabilities such as image and audio operations.

`swo-llm` fills these gaps by providing:

1. **Full OTel semantic convention conformance** — span attributes strictly follow (and enrich) the [OpenTelemetry GenAI semantic conventions](https://opentelemetry.io/docs/specs/semconv/gen-ai/), making traces portable across any OTel-compatible backend.
2. **Comprehensive operation coverage** — chat completions, streaming responses, embeddings, tool/function calls, image generation, and audio operations are all instrumented.
3. **Framework-agnostic** — works in any Ruby environment (Rails, Sinatra, plain Ruby, etc.).
4. **Multi-provider, single gem** — OpenAI, Anthropic Claude, RubyLLM, and Langchain.rb are bundled together under a unified interface, eliminating the need to wire up multiple separate instrumentation gems.

## Features

This gem bundles OpenTelemetry instrumentation for multiple LLM providers:

- **OpenAI** - Instrumentation for OpenAI API calls (GPT models, embeddings, etc.)
- **Langchain.rb** - Instrumentation for the Langchain Ruby framework (legacy support)
- **Anthropic Claude** - Instrumentation for Anthropic's Claude API
- **RubyLLM** - Instrumentation for the RubyLLM unified LLM interface
- **Google Gemini** - *(Coming Soon)* Instrumentation for Google's Gemini API

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'swo-llm'
```

And then execute:

```bash
bundle install
```

Or install it yourself as:

```bash
gem install swo-llm
```

## Usage

Simply require the gem in your application to automatically enable all LLM instrumentations:

```ruby
require 'swo/llm'
```

This will automatically instrument:
- OpenAI API calls
- Langchain.rb operations
- Anthropic Claude API calls
- RubyLLM chat and embedding operations

The instrumentation will capture:
- API requests and responses
- Token usage
- Model parameters
- Latency metrics
- Errors and exceptions
- Tool/function calls
- Streaming responses

### Configuration

The instrumentation uses the standard OpenTelemetry SDK configuration. Make sure you have OpenTelemetry properly configured in your application:

```ruby
require 'opentelemetry/sdk'
require 'swo/llm'

OpenTelemetry::SDK.configure do |c|
  c.service_name = 'your-service-name'
  # Add exporters and other configuration
end
```

### Content Capture

By default, message content is not captured for privacy reasons. To enable content capture, set the environment variable:

```bash
export OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT=true
```

### Individual Instrumentation

If you only want to instrument specific providers, you can require them individually:

```ruby
# Only OpenAI
require 'swo/llm/openai/opentelemetry-instrumentation-openai'

# Only Langchain.rb
require 'swo/llm/langchainrb/opentelemetry-instrumentation-langchainrb'

# Only Anthropic Claude
require 'swo/llm/claude/opentelemetry-instrumentation-claude'

# Only RubyLLM
require 'swo/llm/ruby_llm/opentelemetry-instrumentation-ruby_llm'
```

## Semantic Conventions

The instrumentation follows the [OpenTelemetry GenAI semantic conventions](https://opentelemetry.io/docs/specs/semconv/gen-ai/). The tables below list the span attributes and log events captured per provider.

### Span Attributes

| Attribute | Description | OpenAI | Claude | RubyLLM | Langchain.rb |
|-----------|-------------|:------:|:------:|:-------:|:------------:|
| `gen_ai.operation.name` | Operation type (`chat`, `embeddings`, `images.generate`, etc.) | ✓ | ✓ | ✓ | ✓ |
| `gen_ai.provider.name` | Provider name (`openai`, `anthropic`, `ruby_llm`, etc.) | ✓ | ✓ | ✓ | ✓ |
| `gen_ai.request.model` | Model ID used in the request | ✓ | ✓ | ✓ | ✓ |
| `gen_ai.response.model` | Model ID returned in the response | ✓ | ✓ | ✓ | — |
| `gen_ai.response.id` | Response/completion ID | ✓ | ✓ | ✓ | — |
| `gen_ai.response.finish_reasons` | Completion reasons (`stop`, `tool_use`, `length`, etc.) | ✓ | ✓ | ✓ | ✓ |
| `gen_ai.output.type` | Output modality (`text`, `embedding`, `image`, `speech`) | ✓ | ✓ | ✓ | ✓ |
| `gen_ai.usage.input_tokens` | Number of input/prompt tokens consumed | ✓ | ✓ | ✓ | ✓ |
| `gen_ai.usage.output_tokens` | Number of output/completion tokens generated | ✓ | ✓ | ✓ | ✓ |
| `gen_ai.usage.total_tokens` | Total tokens (input + output) | ✓ | — | — | ✓ |
| `gen_ai.request.temperature` | Sampling temperature | ✓ | ✓ | ✓ | ✓ |
| `gen_ai.request.max_tokens` | Maximum tokens limit | ✓ | ✓ | — | ✓ |
| `gen_ai.request.top_p` | Nucleus sampling probability | ✓ | ✓ | — | ✓ |
| `gen_ai.request.top_k` | Top-k sampling (Claude-specific) | — | ✓ | — | — |
| `gen_ai.request.frequency_penalty` | Frequency penalty | ✓ | — | — | — |
| `gen_ai.request.presence_penalty` | Presence penalty | ✓ | — | — | — |
| `gen_ai.request.seed` | Random seed for deterministic outputs | ✓ | — | — | — |
| `gen_ai.request.stop_sequences` | Stop sequences | ✓ | ✓ | — | ✓ |
| `gen_ai.request.choice.count` | Number of completions to generate (`n`) | ✓ | — | — | — |
| `gen_ai.request.encoding_formats` | Embedding encoding format | ✓ | — | — | — |
| `gen_ai.request.dimensions` | Requested embedding dimensions | — | — | ✓ | ✓ |
| `gen_ai.request.tools` | Tool/function names available to the model | — | — | ✓ | — |
| `gen_ai.embeddings.dimension.count` | Actual dimension count of the returned embedding | ✓ | — | ✓ | ✓ |
| `server.address` | API server hostname | ✓ | ✓ | — | — |
| `server.port` | API server port | ✓ | ✓ | — | — |
| `http.request.method` | HTTP method used | ✓ | ✓ | — | — |
| `url.path` | API endpoint path | ✓ | ✓ | — | — |
| `openai.request.service_tier` | OpenAI service tier (when non-default) | ✓ | — | — | — |

### Log Events

When `OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT=true` is set, the following structured log events are emitted on the span to record conversation content:

| Event name | Description |
|------------|-------------|
| `gen_ai.system.message` | System prompt sent to the model |
| `gen_ai.user.message` | User turn message content |
| `gen_ai.assistant.message` | Assistant turn, including tool calls if present |
| `gen_ai.tool.message` | Tool/function result returned to the model |
| `gen_ai.choice` | Individual response choice from the model |

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake test` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/solarwinds/swo-llm. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [code of conduct](https://github.com/solarwinds/swo-llm/blob/main/CODE_OF_CONDUCT.md).

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

## Code of Conduct

Everyone interacting in the Swo::Llm project's codebases, issue trackers, chat rooms and mailing lists is expected to follow the [code of conduct](https://github.com/solarwinds/swo-llm/blob/main/CODE_OF_CONDUCT.md).
