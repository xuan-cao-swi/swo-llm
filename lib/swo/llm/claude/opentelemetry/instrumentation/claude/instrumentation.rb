# frozen_string_literal: true

# Copyright The OpenTelemetry Authors
#
# SPDX-License-Identifier: Apache-2.0

module OpenTelemetry
  module Instrumentation
    module Claude
      # The Instrumentation class contains logic to detect and install the Anthropic Claude instrumentation
      class Instrumentation < OpenTelemetry::Instrumentation::Base
        MINIMUM_VERSION = Gem::Version.new('1.0.0')
        ALLOWED_OPERATION = %w[messages completions].freeze

        install do |_config|
          require_dependencies
          determine_the_content_mode
          patch_client
        end

        present do
          defined?(::Anthropic)
        end

        compatible do
          gem_version >= MINIMUM_VERSION
        end

        option :capture_content, default: false, validate: :boolean
        option :allowed_operation, default: ALLOWED_OPERATION, validate: :array

        private

        def gem_version
          Gem::Version.new(::Anthropic::VERSION)
        end

        def determine_the_content_mode
          should_capture_content = ENV['OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT'].to_s.downcase == 'true'
          config[:capture_content] = should_capture_content
        end

        def require_dependencies
          require_relative 'patches/client'
        end

        def patch_client
          ::Anthropic::Client.prepend(Patches::Client)
        end
      end
    end
  end
end
