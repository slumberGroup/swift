# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'

# Runs SGStyle/sgstyle.rb as a subprocess against a fake Pods layout:
#
#   <tmp>/Pods/SGStyle/SGStyle/sgstyle.rb              (copy of the script under test)
#   <tmp>/Pods/SGStyle/Sources/AirbnbSwiftFormatTool/  (rule files)
#   <tmp>/Pods/SwiftFormat/CommandLineTool/swiftformat (stub that records its arguments)
#   <tmp>/Pods/SwiftLint/swiftlint                     (stub that records its arguments)
#   <tmp>/project/                                     (the client repo)
class SGStyleTest < Minitest::Test
  SCRIPT = File.expand_path('../sgstyle.rb', __dir__)

  def setup
    @tmp = Dir.mktmpdir('sgstyle')
    @pods = File.join(@tmp, 'Pods')
    @project = File.join(@tmp, 'project')
    @pod_dir = File.join(@pods, 'SGStyle')
    @rules_dir = File.join(@pod_dir, 'Sources', 'AirbnbSwiftFormatTool')
    FileUtils.mkdir_p([File.join(@pod_dir, 'SGStyle'), @rules_dir, @project])
    FileUtils.mkdir_p(File.join(@project, 'BuildScripts'))
    File.write(File.join(@rules_dir, 'airbnb.swiftformat'), "--indent 4\n")
    File.write(File.join(@rules_dir, 'swiftlint.yml'), "disabled_rules: []\n")
    @script = File.join(@pod_dir, 'SGStyle', 'sgstyle.rb')
    FileUtils.cp(SCRIPT, @script) if File.file?(SCRIPT)
    @format_log = File.join(@tmp, 'swiftformat.args')
    @lint_log = File.join(@tmp, 'swiftlint.args')
    install_stub('SwiftFormat/CommandLineTool/swiftformat', @format_log, 'FAKE_SWIFTFORMAT_EXIT')
    install_stub('SwiftLint/swiftlint', @lint_log, 'FAKE_SWIFTLINT_EXIT')
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def install_stub(relative_path, log_path, exit_var)
    path = File.join(@pods, relative_path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, <<~SH)
      #!/bin/sh
      for arg in "$@"; do
        printf '%s\\n' "$arg" >> "#{log_path}"
        case "$arg" in *.yml) [ -f "$arg" ] && { printf '=== %s\\n' "$arg"; cat "$arg"; } >> "#{log_path}.configs" ;; esac
      done
      printf '%s\\n' "$PWD" > "#{log_path}.cwd"
      printf -- '--- end of call\\n' >> "#{log_path}"
      exit "${#{exit_var}:-0}"
    SH
    File.chmod(0o755, path)
  end

  def run_script(*args, env: {}, chdir: @project, ruby: 'ruby')
    full_env = { 'SRCROOT' => @project }.merge(env)
    Open3.capture3(full_env, ruby, @script, *args, chdir: chdir)
  end

  def calls(log_path)
    return [] unless File.file?(log_path)

    File.read(log_path).split("--- end of call\n").map(&:lines).map { |lines| lines.map(&:chomp) }
  end

  def rules_path
    File.join(@rules_dir, 'airbnb.swiftformat')
  end

  # MARK: format

  def test_format_passes_rules_paths_and_fixed_excludes
    _out, _err, status = run_script('format', '--paths', 'SGCommon', 'ExampleApp')

    assert_equal 0, status.exitstatus
    argv = calls(@format_log).fetch(0)
    assert_equal %w[SGCommon ExampleApp], argv.first(2)
    assert_includes argv.each_cons(2).to_a, ['--config', File.realpath(rules_path)]
    assert_includes argv.each_cons(2).to_a, ['--exclude', 'Pods']
    assert_includes argv.each_cons(2).to_a, ['--exclude', '**/Generated']
    refute_includes argv, '--lint'
    assert_empty calls(@lint_log), 'format must not run SwiftLint'
  end

  def test_format_defaults_to_project_root
    run_script('format')

    assert_equal '.', calls(@format_log).fetch(0).first
  end

  def test_format_reads_override_files
    scripts = File.join(@project, 'BuildScripts')
    File.write(File.join(scripts, 'SwiftFormatExtraEnables.txt'),
               "# comment mentioning rules\n--modifierOrder\n--consecutiveBlankLines\n")
    File.write(File.join(scripts, 'SwiftFormatExtraDisables.txt'), "# none\n--preferFinalClasses\n")
    File.write(File.join(scripts, 'SwiftFormatExtraExcludes.txt'), "# paths\nSGCommon/BugsnagLogging/CWLDemangle.swift\n")

    run_script('format')
    pairs = calls(@format_log).fetch(0).each_cons(2).to_a

    assert_includes pairs, %w[--enable modifierOrder]
    assert_includes pairs, %w[--enable consecutiveBlankLines]
    assert_includes pairs, %w[--disable preferFinalClasses]
    assert_includes pairs, ['--exclude', 'SGCommon/BugsnagLogging/CWLDemangle.swift']
  end

  def test_override_files_ignore_comment_lines
    scripts = File.join(@project, 'BuildScripts')
    File.write(File.join(scripts, 'SwiftFormatExtraEnables.txt'), "# prepend rules with --two dashes\n--realRule\n")

    run_script('format')
    argv = calls(@format_log).fetch(0)

    assert_equal ['realRule'], argv.each_cons(2).select { |a, _| a == '--enable' }.map(&:last)
  end

  # MARK: lint

  def test_lint_runs_swiftformat_lint_and_strict_swiftlint
    _out, _err, status = run_script('lint', '--paths', 'SGCommon')

    assert_equal 0, status.exitstatus
    format_argv = calls(@format_log).fetch(0)
    lint_argv = calls(@lint_log).fetch(0)
    assert_includes format_argv, '--lint'
    assert_equal 'lint', lint_argv.first
    assert_includes lint_argv, '--strict'
    assert_includes lint_argv.each_cons(2).to_a, ['--config', File.realpath(File.join(@rules_dir, 'swiftlint.yml'))]
    assert_includes lint_argv, 'SGCommon'
  end

  def test_lint_adds_child_swiftlint_config_only_when_present
    run_script('lint')
    without = calls(@lint_log).fetch(0).count('--config')

    child = File.join(@project, 'BuildScripts', 'swiftlint_childconfig.yml')
    File.write(child, "excluded: []\n")
    FileUtils.rm_f(@lint_log)
    run_script('lint')
    with = calls(@lint_log).fetch(0)

    assert_equal without + 1, with.count('--config')
    assert_includes with, File.realpath(child)
  end

  def test_lint_failure_exits_nonzero_with_xcode_error_line_and_still_runs_both_tools
    _out, err, status = run_script('lint', env: { 'FAKE_SWIFTFORMAT_EXIT' => '1' })
    combined = _out + err

    refute_equal 0, status.exitstatus
    assert_match(/^error: SGStyle: swiftformat/, combined)
    assert_equal 1, calls(@lint_log).length, 'SwiftLint must still run so one run reports every issue'
  end

  def test_failure_message_reports_the_tool_exit_code
    out, err, _status = run_script('lint', env: { 'FAKE_SWIFTFORMAT_EXIT' => '3' })

    assert_match(/^error: SGStyle: swiftformat --lint failed \(exit 3\)$/, out + err)
  end

  def test_unlaunchable_tool_is_reported_as_such
    tool = File.join(@pods, 'SwiftFormat/CommandLineTool/swiftformat')
    File.chmod(0o644, tool)

    out, err, status = run_script('format')

    refute_equal 0, status.exitstatus
    assert_match(/^error: SGStyle: swiftformat failed \(could not be launched\)$/, out + err)
  end

  def test_swiftlint_failure_alone_is_nonzero
    out, err, status = run_script('lint', env: { 'FAKE_SWIFTLINT_EXIT' => '2' })

    refute_equal 0, status.exitstatus
    assert_match(/^error: SGStyle: swiftlint/, out + err)
  end

  def test_format_failure_is_nonzero
    out, err, status = run_script('format', env: { 'FAKE_SWIFTFORMAT_EXIT' => '70' })

    refute_equal 0, status.exitstatus
    assert_match(/^error: SGStyle: swiftformat/, out + err)
  end

  # MARK: failure modes

  def test_missing_tool_exits_2_and_names_the_path
    FileUtils.rm_f(File.join(@pods, 'SwiftFormat/CommandLineTool/swiftformat'))

    out, err, status = run_script('lint')

    assert_equal 2, status.exitstatus
    assert_match(%r{^error: SGStyle: .*SwiftFormat/CommandLineTool/swiftformat}, out + err)
    assert_empty calls(@lint_log), 'nothing may run when a tool is missing'
  end

  def test_missing_rules_file_exits_2
    FileUtils.rm_f(rules_path)

    out, err, status = run_script('format')

    assert_equal 2, status.exitstatus
    assert_match(/^error: SGStyle: .*airbnb\.swiftformat/, out + err)
    assert_empty calls(@format_log)
  end

  def test_unknown_command_prints_usage
    out, err, status = run_script('bogus')

    assert_equal 64, status.exitstatus
    assert_match(/usage/i, out + err)
  end

  def test_pods_root_env_overrides_layout_detection
    other = File.join(@tmp, 'OtherPods')
    FileUtils.mkdir_p(File.join(other, 'SwiftFormat/CommandLineTool'))
    FileUtils.cp(File.join(@pods, 'SwiftFormat/CommandLineTool/swiftformat'), File.join(other, 'SwiftFormat/CommandLineTool/'))
    FileUtils.mkdir_p(File.join(other, 'SwiftLint'))
    FileUtils.cp(File.join(@pods, 'SwiftLint/swiftlint'), File.join(other, 'SwiftLint/'))
    FileUtils.rm_rf(File.join(@pods, 'SwiftFormat'))

    _out, _err, status = run_script('format', env: { 'PODS_ROOT' => other })

    assert_equal 0, status.exitstatus
    assert_equal 1, calls(@format_log).length
  end

  # MARK: override file strictness

  def write_enables(content)
    File.write(File.join(@project, 'BuildScripts', 'SwiftFormatExtraEnables.txt'), content)
  end

  def test_unrecognized_override_tokens_are_errors_not_silently_dropped
    ["--isEmpty,\n", "\u2014isEmpty\n", "--isEmpty#why\n", "isEmpty\n"].each do |content|
      FileUtils.rm_f(@format_log)
      write_enables(content)

      out, err, status = run_script('lint')

      assert_equal 2, status.exitstatus, "expected exit 2 for #{content.inspect}"
      assert_match(/^error: SGStyle: .*SwiftFormatExtraEnables\.txt:1: unrecognized .*#{Regexp.escape(content.split.first)}/, out + err)
      assert_empty calls(@format_log), 'no tool may run when an override file is malformed'
    end
  end

  def test_inline_comment_after_a_rule_is_allowed
    write_enables("--isEmpty # opt-in rule\n")

    _out, _err, status = run_script('format')

    assert_equal 0, status.exitstatus
    assert_includes calls(@format_log).fetch(0).each_cons(2).to_a, %w[--enable isEmpty]
  end

  def test_byte_order_mark_and_crlf_line_endings_are_tolerated
    write_enables("\uFEFF--isEmpty\r\n--modifierOrder\r\n")

    run_script('format')
    pairs = calls(@format_log).fetch(0).each_cons(2).to_a

    assert_includes pairs, %w[--enable isEmpty]
    assert_includes pairs, %w[--enable modifierOrder]
  end

  def test_excludes_file_comments_are_not_passed_as_paths
    File.write(File.join(@project, 'BuildScripts', 'SwiftFormatExtraExcludes.txt'), "# a comment\nGenerated/Thing.swift\n")

    run_script('format')
    excludes = calls(@format_log).fetch(0).each_cons(2).select { |flag, _| flag == '--exclude' }.map(&:last)

    assert_includes excludes, 'Generated/Thing.swift'
    refute_includes excludes, '# a comment'
  end

  # MARK: environment

  def test_relative_srcroot_still_finds_override_files
    write_enables("--isEmpty\n")

    _out, _err, status = run_script('format', env: { 'SRCROOT' => 'project' }, chdir: @tmp)

    assert_equal 0, status.exitstatus
    assert_includes calls(@format_log).fetch(0).each_cons(2).to_a, %w[--enable isEmpty]
  end

  def test_srcroot_is_used_when_the_working_directory_differs
    write_enables("--isEmpty\n")
    elsewhere = Dir.mktmpdir('elsewhere')

    run_script('format', '--paths', 'App', chdir: elsewhere)

    assert_includes calls(@format_log).fetch(0).each_cons(2).to_a, %w[--enable isEmpty]
    assert_equal File.realpath(@project), File.read("#{@format_log}.cwd").chomp,
                 'relative --paths are relative to SRCROOT, so the tool must run there'
  ensure
    FileUtils.remove_entry(elsewhere) if elsewhere
  end

  def test_runs_under_the_system_ruby_with_override_files_present
    system_ruby = '/usr/bin/ruby'
    skip 'no /usr/bin/ruby on this machine' unless File.executable?(system_ruby)
    write_enables("--isEmpty\n")

    out, err, status = run_script('lint', ruby: system_ruby)

    assert_equal 0, status.exitstatus, out + err
    assert_equal 1, calls(@lint_log).length
  end

  # MARK: what is checked before anything runs

  def test_missing_swiftlint_binary_exits_2_before_swiftformat_runs
    FileUtils.rm_f(File.join(@pods, 'SwiftLint/swiftlint'))

    out, err, status = run_script('lint')

    assert_equal 2, status.exitstatus
    assert_match(%r{^error: SGStyle: .*SwiftLint/swiftlint}, out + err)
    assert_empty calls(@format_log)
  end

  def test_missing_swiftlint_rules_exits_2_before_anything_runs
    FileUtils.rm_f(File.join(@rules_dir, 'swiftlint.yml'))

    out, err, status = run_script('lint')

    assert_equal 2, status.exitstatus
    assert_match(/^error: SGStyle: .*swiftlint\.yml/, out + err)
    assert_empty calls(@format_log)
  end

  # MARK: swiftlint scope

  def test_swiftlint_is_quiet
    run_script('lint')

    assert_includes calls(@lint_log).fetch(0), '--quiet'
  end

  def test_swiftlint_skips_pods_and_each_generated_directory_by_absolute_path
    FileUtils.mkdir_p([File.join(@project, 'App', 'Generated'), File.join(@project, 'Pods', 'Thing', 'Generated'),
                       File.join(@project, 'Other', 'Deep', 'Generated')])

    run_script('lint')
    configs = File.read("#{@lint_log}.configs")
    root = File.realpath(@project)

    assert_includes configs, "  - #{root}/Pods\n"
    assert_includes configs, "  - #{root}/App/Generated\n"
    assert_includes configs, "  - #{root}/Other/Deep/Generated\n"
    refute_includes configs, '**', 'SwiftLint does not apply an absolute ** glob consistently across /var and /private/var'
    refute_includes configs, "#{root}/Pods/Thing/Generated", 'Pods is already excluded as a whole'
  end

  def test_generated_swiftlint_config_is_removed_after_the_run
    run_script('lint')
    generated = calls(@lint_log).fetch(0).each_cons(2).select { |flag, _| flag == '--config' }.map(&:last)

    assert generated.any?, 'swiftlint must receive config files'
    assert(generated.none? { |path| File.basename(path).start_with?('sgstyle') && File.exist?(path) },
           'temporary SGStyle config files must not be left behind')
  end

  def test_signal_killed_tool_is_reported_as_a_signal
    tool = File.join(@pods, 'SwiftFormat/CommandLineTool/swiftformat')
    File.write(tool, "#!/bin/sh\nkill -9 $$\n")
    File.chmod(0o755, tool)

    out, err, status = run_script('format')

    refute_equal 0, status.exitstatus
    assert_match(/^error: SGStyle: swiftformat failed \(signal 9\)$/, out + err)
  end

  def test_script_never_touches_the_network
    source = File.read(SCRIPT)

    refute_match(/wget|curl|Net::HTTP|open-uri|URI\.open/, source)
  end
end
