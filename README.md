# Swo::Llm

OpenTelemetry instrumentation for Large Language Model (LLM) providers. This gem provides automatic tracing and monitoring for popular LLM APIs and frameworks through OpenTelemetry.

## Features

This gem bundles OpenTelemetry instrumentation for multiple LLM providers:

- **OpenAI** - Instrumentation for OpenAI API calls (GPT models, embeddings, etc.)
- **Langchain.rb** - Instrumentation for the Langchain Ruby framework
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

The instrumentation follows OpenTelemetry GenAI semantic conventions and captures:

| Attribute | Description |
|-----------|-------------|
| `gen_ai.operation.name` | Operation type (chat, embeddings, etc.) |
| `gen_ai.provider.name` | Provider name (openai, anthropic, etc.) |
| `gen_ai.request.model` | Model ID used for the request |
| `gen_ai.response.model` | Model ID returned in the response |
| `gen_ai.usage.input_tokens` | Number of input tokens |
| `gen_ai.usage.output_tokens` | Number of output tokens |
| `gen_ai.response.finish_reasons` | Reasons for completion (stop, tool_use, etc.) |

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake test` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/solarwinds/swo-llm. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [code of conduct](https://github.com/solarwinds/swo-llm/blob/main/CODE_OF_CONDUCT.md).

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

## Code of Conduct

Everyone interacting in the Swo::Llm project's codebases, issue trackers, chat rooms and mailing lists is expected to follow the [code of conduct](https://github.com/solarwinds/swo-llm/blob/main/CODE_OF_CONDUCT.md).
