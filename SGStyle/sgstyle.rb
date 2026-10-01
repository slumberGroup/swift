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
# Lines starting with `#` are comments.

require 'English'

module SGStyle
  USAGE = 'usage: sgstyle.rb (format|lint) [--paths PATH...]'
  EXIT_USAGE = 64
  EXIT_MISSING = 2
  FIXED_EXCLUDES = ['Pods', '**/Generated'].freeze
  OVERRIDES_DIR = 'BuildScripts'

  class MissingFile < StandardError; end

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
      root: present(ENV['SRCROOT']) || Dir.pwd
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

  def self.rule_names(path)
    return [] unless File.file?(path)

    File.readlines(path, chomp: true).flat_map do |line|
      next [] if line.strip.start_with?('#')

      line.split.filter_map { |token| token[/\A--([A-Za-z0-9_]+)\z/, 1] }
    end
  end

  def self.path_lines(path)
    return [] unless File.file?(path)

    File.readlines(path, chomp: true).map(&:strip).reject { |line| line.empty? || line.start_with?('#') }
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

  def self.swiftlint_arguments(env, rules, paths)
    arguments = ['lint', '--config', rules]
    child = env.override('swiftlint_childconfig.yml')
    arguments.push('--config', File.realpath(child)) if File.file?(child)
    arguments + ['--strict', '--quiet', *paths]
  end

  # Returns true when the tool ran and exited 0. Prints an Xcode-parsable error line otherwise.
  def self.run_tool(label, executable, arguments)
    launched = system(executable, *arguments)
    return true if launched

    # `system` returns nil when the process could not be started and false when it exited non-zero.
    detail = launched.nil? ? 'could not be launched' : "exit #{$CHILD_STATUS.exitstatus}"
    report("#{label} failed (#{detail})")
    false
  end

  def self.format(env, paths)
    swiftformat = require_file(env.swiftformat)
    rules = require_file(env.rules('airbnb.swiftformat'))
    run_tool('swiftformat', swiftformat, swiftformat_arguments(env, rules, paths, lint: false)) ? 0 : 1
  end

  # Both tools always run so a single invocation reports every finding.
  def self.lint(env, paths)
    swiftformat = require_file(env.swiftformat)
    swiftlint = require_file(env.swiftlint)
    format_rules = require_file(env.rules('airbnb.swiftformat'))
    lint_rules = require_file(env.rules('swiftlint.yml'))

    results = [
      run_tool('swiftformat --lint', swiftformat, swiftformat_arguments(env, format_rules, paths, lint: true)),
      run_tool('swiftlint --strict', swiftlint, swiftlint_arguments(env, lint_rules, paths))
    ]
    results.all? ? 0 : 1
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
  end
end

exit(SGStyle.main(ARGV)) if $PROGRAM_NAME == __FILE__
