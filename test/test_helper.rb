# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'swo/llm'

require 'minitest/autorun'
require 'webmock/minitest'
require 'opentelemetry/sdk'
require 'opentelemetry-instrumentation-base'

# Don't require actual LLM gems here since:
# 1. Some may have version incompatibilities (e.g., ruby_llm requires Ruby 3.3+)
# 2. Tests can require them individually when needed
# 3. WebMock will handle HTTP requests
# require 'langchain'
# require 'openai'
# require 'ruby_llm'
# require 'anthropic'

# Set up OpenTelemetry with in-memory exporter for testing
EXPORTER = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new

OpenTelemetry::SDK.configure do |c|
  c.add_span_processor(
    OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(EXPORTER)
  )
end
