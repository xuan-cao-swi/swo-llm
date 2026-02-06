# frozen_string_literal: true

# Copyright The OpenTelemetry Authors
#
# SPDX-License-Identifier: Apache-2.0

module OpenTelemetry
  module Instrumentation
    module Langchainrb
      # The Instrumentation class contains logic to detect and install the Langchainrb instrumentation
      class Instrumentation < OpenTelemetry::Instrumentation::Base
        MINIMUM_VERSION = Gem::Version.new('0.15.0')

        compatible do
          gem_version >= MINIMUM_VERSION
        end

        install do |_config|
          require_dependencies
          patch_llm_classes
        end

        present do
          defined?(::Langchain::LLM::Base)
        end

        option :capture_content, default: false, validate: :boolean

        private

        def gem_version
          Gem::Version.new(::Langchain::VERSION)
        end

        def require_dependencies
          require_relative 'patch'
        end

        def patch_llm_classes
          # Patch LLM classes that are loaded and tested
          # To add new llm provider, add through patch_class(Provider Name)
          # Make sure it's properly validated and tested
          patch_class('OpenAI')
          patch_class('Anthropic')
          patch_class('GoogleGemini')
          patch_class('MistralAI')
        end

        def patch_class(class_name)
          return unless defined?(::Langchain::LLM.const_get(class_name))

          klass = ::Langchain::LLM.const_get(class_name)
          klass.prepend(Patches::LLMBase)
        rescue NameError
          # Class not loaded, skip
        end
      end
    end
  end
end
