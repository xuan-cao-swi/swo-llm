# frozen_string_literal: true

# Copyright The OpenTelemetry Authors
#
# SPDX-License-Identifier: Apache-2.0

module OpenTelemetry
  module Instrumentation
    module Anthropic
      module Patches
        # Determine the operation name from the request path for Anthropic API
        module OperationName
          def determine_operation_name(req)
            path = req[:path].to_s

            case path
            when %r{^v1/messages/count_tokens}
              'messages.count_tokens'
            when %r{^v1/messages/batches}
              'messages.batches'
            when %r{^v1/messages}
              'messages'
            when %r{^v1/complete}
              'completions'
            when %r{^v1/models}
              'models'
            else
              'anthropic.request'
            end
          end
        end
      end
    end
  end
end
