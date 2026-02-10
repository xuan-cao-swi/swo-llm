# frozen_string_literal: true
# encoding: utf-8

# Copyright The OpenTelemetry Authors
#
# SPDX-License-Identifier: Apache-2.0

require 'bundler/inline'

# Fix encoding issue for ruby_llm
Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

gemfile(true) do
  source 'https://rubygems.org'

  gem 'ruby_llm'
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

RubyLLM.configure do |config|
  config.openai_api_key = ENV.fetch('OPENAI_API_KEY')
end

chat = RubyLLM::Chat.new(model: 'gpt-4o-mini')

puts "=== Example 1: Basic Chat Completion ==="
response = chat.ask('What is 2 + 2? Answer in one sentence.')
puts "Response: #{response.content}"
puts "Tokens: Input=#{response.input_tokens}, Output=#{response.output_tokens}"
