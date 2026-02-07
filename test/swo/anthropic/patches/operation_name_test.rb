# frozen_string_literal: true

# Copyright The OpenTelemetry Authors
#
# SPDX-License-Identifier: Apache-2.0

require 'test_helper'

require_relative '../../../../../lib/swo/llm/anthropic/opentelemetry/instrumentation/anthropic/patches/operation_name'

describe OpenTelemetry::Instrumentation::Anthropic::Patches::OperationName do
  let(:operation_name_class) do
    Class.new do
      include OpenTelemetry::Instrumentation::Anthropic::Patches::OperationName
    end.new
  end

  describe '#determine_operation_name' do
    it 'returns messages for v1/messages path' do
      req = { path: 'v1/messages' }
      _(operation_name_class.determine_operation_name(req)).must_equal 'messages'
    end

    it 'returns messages for full messages path with query params' do
      req = { path: 'v1/messages?beta=true' }
      _(operation_name_class.determine_operation_name(req)).must_equal 'messages'
    end

    it 'returns messages.count_tokens for count tokens path' do
      req = { path: 'v1/messages/count_tokens' }
      _(operation_name_class.determine_operation_name(req)).must_equal 'messages.count_tokens'
    end

    it 'returns messages.batches for batches path' do
      req = { path: 'v1/messages/batches' }
      _(operation_name_class.determine_operation_name(req)).must_equal 'messages.batches'
    end

    it 'returns completions for v1/complete path' do
      req = { path: 'v1/complete' }
      _(operation_name_class.determine_operation_name(req)).must_equal 'completions'
    end

    it 'returns models for v1/models path' do
      req = { path: 'v1/models' }
      _(operation_name_class.determine_operation_name(req)).must_equal 'models'
    end

    it 'returns anthropic.request for unknown paths' do
      req = { path: 'v1/unknown/endpoint' }
      _(operation_name_class.determine_operation_name(req)).must_equal 'anthropic.request'
    end

    it 'handles nil path' do
      req = { path: nil }
      _(operation_name_class.determine_operation_name(req)).must_equal 'anthropic.request'
    end

    it 'handles empty path' do
      req = { path: '' }
      _(operation_name_class.determine_operation_name(req)).must_equal 'anthropic.request'
    end
  end
end
