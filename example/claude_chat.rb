# frozen_string_literal: true

# Copyright The OpenTelemetry Authors
#
# SPDX-License-Identifier: Apache-2.0

require 'bundler/inline'

gemfile(true) do
  source 'https://rubygems.org'

  gem 'anthropic'
  gem 'opentelemetry-sdk'
  gem 'swo-llm', path: '../'
  gem 'solarwinds_apm'
end

# Simple setup for demonstration purposes, simple span processor should not be
# used in a production environment
console_span_processor = OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(
  OpenTelemetry::SDK::Trace::Export::ConsoleSpanExporter.new
)

# Replace solarwinds_apm processor with console exporter
::OpenTelemetry.tracer_provider.add_span_processor(console_span_processor)

# Replace solarwinds_apm sampler with always_on sampler
::OpenTelemetry.tracer_provider.sampler = OpenTelemetry::SDK::Trace::Samplers::ALWAYS_ON

client = Anthropic::Client.new(
  api_key: ENV.fetch('ANTHROPIC_API_KEY')
)

puts "=== Example 1: Basic Chat Completion ==="
response = client.messages.create(
  model: 'claude-sonnet-4-20250514',
  messages: [{ role: 'user', content: 'What is 2 + 2? Answer in one sentence.' }],
  max_tokens: 100
)

puts "Response: #{response.content.first.text}"
puts "Usage: Input tokens=#{response.usage.input_tokens}, Output tokens=#{response.usage.output_tokens}"
