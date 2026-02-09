# frozen_string_literal: true

require_relative "lib/swo/llm/version"

Gem::Specification.new do |spec|
  spec.name = "swo-llm"
  spec.version = Swo::Llm::VERSION
  spec.authors = ["xuan-cao-swi"]
  spec.email = ["xuan.cao@solarwinds.com"]

  spec.summary = "OpenTelemetry instrumentation for LLM providers (OpenAI, Langchain, Gemini, Claude)"
  spec.description = "Provides automatic OpenTelemetry instrumentation for popular Large Language Model APIs and frameworks including OpenAI, Langchain.rb, Google Gemini, and Anthropic Claude."
  spec.homepage = "https://github.com/solarwinds/swo-llm"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/solarwinds/swo-llm"
  spec.metadata["changelog_uri"] = "https://github.com/solarwinds/swo-llm/blob/main/CHANGELOG.md"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ test/ spec/ features/ .git .github appveyor Gemfile])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # Runtime dependencies
  spec.add_dependency "opentelemetry-api", "~> 1.0"
  spec.add_dependency "opentelemetry-instrumentation-base", "~> 0.22"

  # For more information and examples about making a new gem, check out our
  # guide at: https://bundler.io/guides/creating_gem.html
end
