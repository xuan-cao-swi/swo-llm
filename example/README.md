# SWO-LLM Examples

This directory contains example scripts demonstrating how to use `swo-llm` with SolarWinds APM to instrument various LLM clients.

## Overview

These examples show OpenTelemetry instrumentation for:
- **Claude** (Anthropic) - Direct API client
- **OpenAI** - Direct API client
- **Langchain.rb** - Multi-provider LLM framework
- **RubyLLM** - Unified Ruby LLM interface

Each example uses:
- `bundler/inline` for dependency management (no need to install gems separately)
- Console span exporter to display traces directly in the terminal
- SolarWinds APM integration
- ALWAYS_ON sampler to ensure all traces are captured

## Prerequisites

- Ruby 3.x
- API keys for the LLM provider(s) you want to test
- SolarWinds APM service key (for production use)

## Environment Variables

### Required for all examples:
- `SW_APM_SERVICE_KEY` - Your SolarWinds APM service key

### Provider-specific API keys:

| Example | Required API Key |
|---------|-----------------|
| `claude_chat.rb` | `ANTHROPIC_API_KEY` |
| `openai_chat.rb` | `OPENAI_API_KEY` |
| `langchainrb_chat.rb` | `OPENAI_API_KEY` (default) or `ANTHROPIC_API_KEY` or `GOOGLE_GEMINI_API_KEY` |
| `ruby_llm_chat.rb` | `OPENAI_API_KEY` (default) or `ANTHROPIC_API_KEY` or `GEMINI_API_KEY` |

## Running the Examples

### Claude Example

```bash
export ANTHROPIC_API_KEY="your-anthropic-api-key"
export SW_APM_SERVICE_KEY="your-sw-apm-service-key"
ruby example/claude_chat.rb
```

**Expected Output:**
- Multiple `OpenTelemetry::SDK::Trace::SpanData` structs showing:
  - `connect` span from Net::HTTP instrumentation
  - `POST` span for the API request
  - `messages claude-sonnet-4-20250514` span from Claude instrumentation
- Final response: "2 + 2 equals 4."
- Token usage information

### OpenAI Example

```bash
export OPENAI_API_KEY="your-openai-api-key"
export SW_APM_SERVICE_KEY="your-sw-apm-service-key"
ruby example/openai_chat.rb
```

**Expected Output:**
- `connect` and `POST` spans from Net::HTTP instrumentation
- `chat gpt-4o-mini` span from OpenAI instrumentation
- Response with token usage details

### Langchain.rb Example

```bash
export OPENAI_API_KEY="your-openai-api-key"
export SW_APM_SERVICE_KEY="your-sw-apm-service-key"
ruby example/langchainrb_chat.rb
```

**Expected Output:**
- Langchain.rb request/response logs
- `POST` span from Faraday instrumentation
- `chat gpt-4o-mini` span from Langchain instrumentation
- Response with total token count

### RubyLLM Example

```bash
export OPENAI_API_KEY="your-openai-api-key"
export SW_APM_SERVICE_KEY="your-sw-apm-service-key"
ruby example/ruby_llm_chat.rb
```

**Expected Output:**
- `POST` span from Faraday instrumentation
- `chat gpt-4o-mini` span from RubyLLM instrumentation
- Response with input/output token counts

## Understanding the Output

### Span Attributes

Each span contains important GenAI semantic convention attributes:

- `gen_ai.operation.name` - The LLM operation (e.g., "chat", "messages")
- `gen_ai.provider.name` - The LLM provider (e.g., "openai", "anthropic")
- `gen_ai.request.model` - The model requested
- `gen_ai.response.model` - The actual model that responded
- `gen_ai.usage.input_tokens` - Input token count
- `gen_ai.usage.output_tokens` - Output token count
- `gen_ai.response.finish_reasons` - Why the generation stopped
- `gen_ai.response.id` - Unique response identifier

### Instrumentation Scopes

You'll see spans from multiple instrumentation libraries:

- `OpenTelemetry::Instrumentation::Claude` - Claude API instrumentation
- `OpenTelemetry::Instrumentation::OpenAI` - OpenAI API instrumentation
- `OpenTelemetry::Instrumentation::Langchainrb` - Langchain.rb instrumentation
- `OpenTelemetry::Instrumentation::RubyLLM` - RubyLLM instrumentation
- `OpenTelemetry::Instrumentation::Net::HTTP` - HTTP client instrumentation
- `OpenTelemetry::Instrumentation::Faraday` - Faraday HTTP client instrumentation

## Customization

### Using Different Models

Edit the model name in each script:

```ruby
# Claude
model: 'claude-sonnet-4-20250514'

# OpenAI
model: 'gpt-4o-mini'

# Langchain.rb
chat_completion_model_name: 'gpt-4o-mini'

# RubyLLM
model: 'gpt-4o-mini'
```

### Switching LLM Providers

For Langchain.rb, change the LLM client:

```ruby
# Use Anthropic instead
llm = Langchain::LLM::Anthropic.new(
  api_key: ENV.fetch('ANTHROPIC_API_KEY'),
  default_options: {
    chat_completion_model_name: 'claude-sonnet-4-20250514'
  }
)
```

For RubyLLM, configure multiple providers:

```ruby
RubyLLM.configure do |config|
  config.anthropic_api_key = ENV['ANTHROPIC_API_KEY']
end

chat = RubyLLM::Chat.new(model: 'claude-sonnet-4-20250514')
```

## Production Use

These examples use console exporter for demonstration. In production:

1. Remove the console exporter configuration
2. Let SolarWinds APM handle span export automatically
3. Set appropriate environment variables:
   - `SW_APM_SERVICE_KEY` - Your service key
   - `OTEL_SERVICE_NAME` - Your application name
   - `OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT` - Set to `true` to capture message content

## Troubleshooting

### "Missing API key" error
Make sure you've exported the required API key environment variable for your chosen provider.

### "cannot load such file" error
The script uses `bundler/inline` which should install gems automatically. If you see this error, try running with bundler:
```bash
bundle exec ruby example/script_name.rb
```

### Encoding errors (ruby_llm_chat.rb)
The ruby_llm example sets UTF-8 encoding automatically. If you still see encoding issues, check your terminal encoding:
```bash
export LANG=en_US.UTF-8
```

### No spans appearing
Verify that:
1. The console_span_processor is configured before requiring `swo/llm` and `solarwinds_apm`
2. The ALWAYS_ON sampler is set
3. You're looking at STDOUT (spans are printed to standard output)

## Additional Resources

- [OpenTelemetry Semantic Conventions for GenAI](https://opentelemetry.io/docs/specs/semconv/gen-ai/)
- [SolarWinds APM Documentation](https://documentation.solarwinds.com/en/success_center/observability/default.htm)
- [swo-llm GitHub Repository](https://github.com/solarwinds/apm-ruby)
