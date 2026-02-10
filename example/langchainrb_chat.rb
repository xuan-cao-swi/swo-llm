# frozen_string_literal: true

# Copyright The OpenTelemetry Authors
#
# SPDX-License-Identifier: Apache-2.0

require 'bundler/inline'

gemfile(true) do
  source 'https://rubygems.org'

  gem 'langchainrb'
  gem 'ruby-openai'
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

# Use OpenAI as default (change to ANTHROPIC_API_KEY or GOOGLE_GEMINI_API_KEY as needed)
llm = Langchain::LLM::OpenAI.new(
  api_key: ENV.fetch('OPENAI_API_KEY'),
  default_options: {
    chat_completion_model_name: 'gpt-4o-mini',
    temperature: 0.7,
    max_tokens: 100
  }
)

puts "=== Example 1: Basic Chat Completion ==="
response = llm.chat(messages: [{ role: 'user', content: 'What is 2 + 2? Answer in one sentence.' }])
puts "Response: #{response.chat_completion}"
puts "Total tokens: #{response.total_tokens}"
