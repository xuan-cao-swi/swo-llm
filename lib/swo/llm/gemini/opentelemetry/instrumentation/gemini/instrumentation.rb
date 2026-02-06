# frozen_string_literal: true

# Copyright The OpenTelemetry Authors
#
# SPDX-License-Identifier: Apache-2.0

module OpenTelemetry
  module Instrumentation
    module Gemini
      # Instrumentation class for Google Gemini API
      class Instrumentation < OpenTelemetry::Instrumentation::Base
        install do |_config|
          # TODO: Implement Gemini instrumentation
        end

        present do
          # TODO: Check if Gemini gem is present
          false
        end
      end
    end
  end
end
