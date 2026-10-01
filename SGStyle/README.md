# SGStyle

SGStyle is a CocoaPods pod, defined by `SGStyle.podspec` at the root of this repository. It delivers the Slumber Group
Swift style to our iOS repos: the rules in `Sources/AirbnbSwiftFormatTool/`, the SwiftFormat and SwiftLint versions that
run them, and `SGStyle/sgstyle.rb`, a script that applies both. The rules and the tool versions ship in one tagged release,
so a ruleset a pinned tool cannot read fails here before it reaches a client.

## Using it in a repo

Add the pod and both tools to the `Podfile`, all Debug-only. The tools need their own lines because CocoaPods adds a pod's
transitive dependencies to every configuration. Leave their versions off; SGStyle pins them.

```ruby
pod 'SwiftFormat/CLI', :configurations => ['Debug']
pod 'SwiftLint', :configurations => ['Debug']
pod 'SGStyle', '= 1.0.0', :configurations => ['Debug']
```

Run the script from a build phase or CI:

```sh
ruby "${PODS_ROOT}/SGStyle/SGStyle/sgstyle.rb" format --paths MyApp MyAppTests
ruby "${PODS_ROOT}/SGStyle/SGStyle/sgstyle.rb" lint --paths MyApp MyAppTests
```

- `format` rewrites files.
- `lint` runs `swiftformat --lint` and `swiftlint --strict`, changes nothing, and exits non-zero on any finding. Both tools
  always run, so one invocation reports everything.
- `lint --allow-warnings` drops `--strict` so SwiftLint's warning-level rules (for example `no_direct_standard_out_logs`, which
  the rules keep at warning so a debug `print` does not break a build) stay warnings. Use it for local builds and keep the
  strict form for CI. SwiftLint errors, SwiftFormat findings and ruleset configuration problems still fail.
- `--paths` defaults to the repo root. `SRCROOT` (default: the current directory) is the repo root and `PODS_ROOT`
  (default: the directory that contains the pod) is the `Pods` directory.
- A missing tool or rules file exits with code 2; a tool that fails prints an `error: SGStyle: ...` line that Xcode parses.

### Per-repo overrides

Optional files in `<repo>/BuildScripts/`. Lines that start with `#` are comments.

| File | Contents |
| --- | --- |
| `SwiftFormatExtraEnables.txt` | one `--ruleName` per line, passed as `--enable ruleName` |
| `SwiftFormatExtraDisables.txt` | one `--ruleName` per line, passed as `--disable ruleName` |
| `SwiftFormatExtraExcludes.txt` | one path per line, passed as `--exclude path` |
| `swiftlint_childconfig.yml` | a second SwiftLint `--config` |

`Pods` and every `Generated` directory are always excluded from both tools. A token on a non-comment line that is not
`--ruleName` is an error that names the file and line; a trailing `# comment` is allowed.

## Developing

```sh
ruby SGStyle/test/sgstyle_test.rb   # script tests, with stubbed tools
sh SGStyle/.fixture/run.sh          # installs the pod from the current commit and runs the real tools on fixtures
```

`run.sh` installs from the current commit, so commit before running it. Its fixtures live in a hidden directory so
SwiftFormat skips them, and the root `Rakefile` excludes `SGStyle` from `swift package format --lint` (the `Test Package Plugin` CI job) because SwiftLint does not skip hidden directories and `Bad.swift` deliberately violates both tools.

## Releasing

A release is a version change in `SGStyle.podspec`, a tag, and a push of the podspec to the private specs repo.

1. Bump `s.version` and, if the rules need a newer tool, the `SwiftFormat/CLI` and `SwiftLint` pins. CI must pass with the pinned tools.
2. Tag the merge commit `sgstyle-X.Y.Z` and push the tag.
3. Run `pod repo push slumberGroupPodSpecs SGStyle.podspec`.
4. Bump the exact `'= X.Y.Z'` pin in each client repo. The first run after a rules change may reformat that repo's code; land that
   reformat as its own commit.
