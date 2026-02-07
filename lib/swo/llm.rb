# frozen_string_literal: true

require_relative "llm/version"

# OpenTelemetry Instrumentation for LLM providers
require_relative "llm/openai/opentelemetry-instrumentation-openai"
require_relative "llm/langchainrb/opentelemetry-instrumentation-langchainrb"
require_relative "llm/anthropic/opentelemetry-instrumentation-anthropic"
require_relative "llm/ruby_llm/opentelemetry-instrumentation-ruby_llm"

module Swo
  module Llm
    class Error < StandardError; end
  end
end
