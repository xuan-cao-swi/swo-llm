# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'swo/llm'

require 'minitest/autorun'
require 'webmock/minitest'
require 'opentelemetry/sdk'
require 'opentelemetry-instrumentation-base'

# Set up OpenTelemetry with in-memory exporter for testing
EXPORTER = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new

OpenTelemetry::SDK.configure do |c|
  c.add_span_processor(
    OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(EXPORTER)
  )
end
