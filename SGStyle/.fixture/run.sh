#!/bin/sh
# Installs the pod from the current commit into a fixture project and checks, with the pod's own tools,
# that `lint` passes on a formatted file and fails on a mis-formatted one for a style reason.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
SGSTYLE_REPO="$repo"
SGSTYLE_COMMIT=$(git -C "$repo" rev-parse HEAD)
export SGSTYLE_REPO SGSTYLE_COMMIT

cd "$here"
rm -rf Pods Podfile.lock
pod install

for installed in \
  Pods/SGStyle/SGStyle/sgstyle.rb \
  Pods/SGStyle/Sources/AirbnbSwiftFormatTool/airbnb.swiftformat \
  Pods/SGStyle/Sources/AirbnbSwiftFormatTool/swiftlint.yml \
  Pods/SwiftFormat/CommandLineTool/swiftformat \
  Pods/SwiftLint/swiftlint; do
  if [ ! -f "$installed" ]; then
    echo "error: expected $installed to be installed by the SGStyle pod" >&2
    exit 1
  fi
done

lint() {
  SRCROOT="$here" ruby Pods/SGStyle/SGStyle/sgstyle.rb lint --paths "$1"
}

echo "== Good must pass"
lint Good

echo "== Bad must fail with a style finding"
if output=$(lint Bad 2>&1); then
  echo "$output"
  echo "error: lint passed on Bad/, so it cannot detect violations" >&2
  exit 1
fi
echo "$output"
if ! echo "$output" | grep -Eq 'error: \([A-Za-z]+\)'; then
  echo "error: lint failed on Bad/ but not with a SwiftFormat rule finding" >&2
  exit 1
fi
echo "== Pods/ and Generated/ in a client must be ignored by both tools"
scope=$(mktemp -d)
trap 'rm -rf "$scope"' EXIT
mkdir -p "$scope/Pods/Foo" "$scope/App/Generated"
printf 'import Foundation\n\nfunc debugOutput() {\n    print("hi")\n}\n' > "$scope/Pods/Foo/Foo.swift"
cp "$scope/Pods/Foo/Foo.swift" "$scope/App/Generated/Generated.swift"
cp Good/Good.swift "$scope/App/Good.swift"
SRCROOT="$scope" ruby Pods/SGStyle/SGStyle/sgstyle.rb lint

if [ -x /usr/bin/ruby ]; then
  echo "== The macOS system Ruby ($(/usr/bin/ruby -e 'print RUBY_VERSION')) must run the script"
  SRCROOT="$scope" /usr/bin/ruby Pods/SGStyle/SGStyle/sgstyle.rb lint
fi
echo "== fixture checks passed"
