#!/usr/bin/env ruby
# frozen_string_literal: true

# Runs the SwiftFormat and SwiftLint versions pinned by the SGStyle pod against a client repo,
# using the rules that ship inside the pod.
#
#   ruby ${PODS_ROOT}/SGStyle/SGStyle/sgstyle.rb format [--paths DIR...]
#   ruby ${PODS_ROOT}/SGStyle/SGStyle/sgstyle.rb lint   [--paths DIR...]
#
# `format` rewrites files. `lint` changes nothing and exits non-zero on any finding.
#
# Environment:
#   SRCROOT    the client repo root (default: the current directory)
#   PODS_ROOT  the Pods directory (default: the parent of this pod's directory)
#
# Optional per-repo overrides live in `<SRCROOT>/BuildScripts/`:
#   SwiftFormatExtraEnables.txt    one `--ruleName` per line, passed as `--enable ruleName`
#   SwiftFormatExtraDisables.txt   one `--ruleName` per line, passed as `--disable ruleName`
#   SwiftFormatExtraExcludes.txt   one path per line, passed as `--exclude path`
#   swiftlint_childconfig.yml      a second SwiftLint `--config`
# Lines starting with `#` are comments, and `#` after whitespace starts a trailing comment. A token that is not
# `--ruleName` is an error, not ignored: a rule that was meant to be enforced must never be dropped silently.

require 'English'
require 'tempfile'

module SGStyle
  USAGE = 'usage: sgstyle.rb (format|lint) [--paths PATH...]'
  EXIT_USAGE = 64
  EXIT_MISSING = 2
  FIXED_EXCLUDES = ['Pods', '**/Generated'].freeze
  OVERRIDES_DIR = 'BuildScripts'

  class MissingFile < StandardError; end
  class InvalidOverride < StandardError; end

  Environment = Struct.new(:pod_dir, :pods_root, :root, keyword_init: true) do
    def rules(name)
      File.join(pod_dir, 'Sources', 'AirbnbSwiftFormatTool', name)
    end

    def swiftformat
      File.join(pods_root, 'SwiftFormat', 'CommandLineTool', 'swiftformat')
    end

    def swiftlint
      File.join(pods_root, 'SwiftLint', 'swiftlint')
    end

    def override(name)
      File.join(root, OVERRIDES_DIR, name)
    end
  end

  def self.environment
    pod_dir = File.expand_path('..', __dir__)
    Environment.new(
      pod_dir: pod_dir,
      pods_root: present(ENV['PODS_ROOT']) || File.dirname(pod_dir),
      root: File.realpath(present(ENV['SRCROOT']) || Dir.pwd)
    )
  end

  def self.present(value)
    value unless value.nil? || value.empty?
  end

  def self.report(message)
    puts "error: SGStyle: #{message}"
  end

  def self.require_file(path)
    raise MissingFile, path unless File.file?(path)

    File.realpath(path)
  end

  # Lines of an override file with BOM, line endings, blank lines and comments removed, as [text, line_number].
  def self.override_lines(path)
    File.readlines(path, chomp: true).each_with_index.map do |line, index|
      text = line.sub(/\A\uFEFF/, '').sub(/(\A|\s)#.*\z/, '').strip
      [text, index + 1]
    end.reject { |text, _| text.empty? }
  end

  def self.rule_names(path)
    return [] unless File.file?(path)

    override_lines(path).flat_map do |text, number|
      text.split.map do |token|
        token[/\A--([A-Za-z0-9_]+)\z/, 1] ||
          raise(InvalidOverride, "#{path}:#{number}: unrecognized rule token '#{token}' (expected --ruleName)")
      end
    end
  end

  def self.path_lines(path)
    return [] unless File.file?(path)

    override_lines(path).map(&:first)
  end

  def self.swiftformat_arguments(env, rules, paths, lint:)
    arguments = [*paths, '--config', rules]
    rule_names(env.override('SwiftFormatExtraEnables.txt')).each { |rule| arguments.push('--enable', rule) }
    rule_names(env.override('SwiftFormatExtraDisables.txt')).each { |rule| arguments.push('--disable', rule) }
    excludes = FIXED_EXCLUDES + path_lines(env.override('SwiftFormatExtraExcludes.txt'))
    excludes.each { |path| arguments.push('--exclude', path) }
    arguments << '--lint' if lint
    arguments
  end

  # SwiftLint resolves `excluded` entries in the pod's rules file relative to that file, so the client's
  # Pods and Generated directories are excluded by absolute path through a second, temporary config.
  # Each Generated directory is listed explicitly: SwiftLint does not match an absolute `**` glob when the
  # repo sits under a symlinked path such as macOS's /var -> /private/var.
  def self.generated_directories(root)
    Dir.glob('**/Generated', base: root)
       .select { |path| File.directory?(File.join(root, path)) && !path.start_with?('Pods/') }
       .sort
  end

  def self.swiftlint_arguments(env, rules, scope_config, paths)
    arguments = ['lint', '--config', rules]
    child = env.override('swiftlint_childconfig.yml')
    arguments.push('--config', File.realpath(child)) if File.file?(child)
    arguments.push('--config', scope_config)
    arguments + ['--strict', '--quiet', *paths]
  end

  def self.with_swiftlint_scope_config(env)
    Tempfile.create(['sgstyle', '.yml']) do |file|
      excluded = ['Pods', *generated_directories(env.root)].map { |path| "  - #{env.root}/#{path}\n" }
      file.write("excluded:\n#{excluded.join}")
      file.flush
      yield file.path
    end
  end

  # Returns true when the tool ran and exited 0. Prints an Xcode-parsable error line otherwise.
  def self.run_tool(label, executable, arguments)
    launched = system(executable, *arguments)
    return true if launched

    report("#{label} failed (#{failure_detail(launched)})")
    false
  end

  # `system` returns nil when the process could not be started and false when it exited non-zero or was signaled.
  def self.failure_detail(launched)
    return 'could not be launched' if launched.nil?

    status = $CHILD_STATUS
    status.exitstatus ? "exit #{status.exitstatus}" : "signal #{status.termsig}"
  end

  def self.format(env, paths)
    swiftformat = require_file(env.swiftformat)
    rules = require_file(env.rules('airbnb.swiftformat'))
    run_tool('swiftformat', swiftformat, swiftformat_arguments(env, rules, paths, lint: false)) ? 0 : 1
  end

  # Both tools always run so a single invocation reports every finding. Every file and override is validated
  # before either tool starts.
  def self.lint(env, paths)
    swiftformat = require_file(env.swiftformat)
    swiftlint = require_file(env.swiftlint)
    format_rules = require_file(env.rules('airbnb.swiftformat'))
    lint_rules = require_file(env.rules('swiftlint.yml'))
    format_arguments = swiftformat_arguments(env, format_rules, paths, lint: true)

    with_swiftlint_scope_config(env) do |scope_config|
      results = [
        run_tool('swiftformat --lint', swiftformat, format_arguments),
        run_tool('swiftlint --strict', swiftlint, swiftlint_arguments(env, lint_rules, scope_config, paths))
      ]
      results.all? ? 0 : 1
    end
  end

  def self.parse(argv)
    command = argv.first
    return nil unless %w[format lint].include?(command)

    marker = argv.index('--paths')
    paths = marker ? argv[(marker + 1)..] : []
    [command, paths.empty? ? ['.'] : paths]
  end

  def self.main(argv)
    parsed = parse(argv)
    unless parsed
      warn USAGE
      return EXIT_USAGE
    end

    command, paths = parsed
    env = environment
    Dir.chdir(env.root)
    public_send(command, env, paths)
  rescue MissingFile => e
    report("missing #{e.message}. Run `pod install` so the SGStyle, SwiftFormat and SwiftLint pods are present.")
    EXIT_MISSING
  rescue InvalidOverride => e
    report(e.message)
    EXIT_MISSING
  end
end

exit(SGStyle.main(ARGV)) if $PROGRAM_NAME == __FILE__
