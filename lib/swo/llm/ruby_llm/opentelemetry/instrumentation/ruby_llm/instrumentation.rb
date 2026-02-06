# frozen_string_literal: true

# Copyright The OpenTelemetry Authors
#
# SPDX-License-Identifier: Apache-2.0

module OpenTelemetry
  module Instrumentation
    module RubyLLM
      # The Instrumentation class contains logic to detect and install the ruby_llm instrumentation
      class Instrumentation < OpenTelemetry::Instrumentation::Base
        MINIMUM_VERSION = Gem::Version.new('1.0.0')
        ALLOWED_OPERATION = %w[chat embeddings].freeze

        install do |_config|
          require_dependencies
          determine_the_content_mode
          patch_classes
        end

        present do
          defined?(::RubyLLM)
        end

        compatible do
          gem_version >= MINIMUM_VERSION
        end

        option :capture_content, default: false, validate: :boolean
        option :allowed_operation, default: ALLOWED_OPERATION, validate: :array

        private

        def gem_version
          Gem::Version.new(::RubyLLM::VERSION)
        end

        def determine_the_content_mode
          should_capture_content = ENV['OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT'].to_s.downcase == 'true'
          config[:capture_content] = should_capture_content
        end

        def require_dependencies
          require_relative 'patches/chat'
          require_relative 'patches/embedding'
        end

        def patch_classes
          ::RubyLLM::Chat.prepend(Patches::Chat)
          ::RubyLLM::Embedding.singleton_class.prepend(Patches::Embedding)
        end
      end
    end
  end
end
