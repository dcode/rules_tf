#!/bin/bash
set -e

# Mock CI/CD Script for Bazel + Terraform GitOps

# Ensure we are in the examples/gitops directory
# Get the absolute path of the script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

echo "=== Mock CI: Running Plan Tests (in $PWD) ==="

# 1. Run test and expect failure
echo "1. Running Plan Check (Expecting Failure)..."
if bazel test //:plan; then
    echo "ERROR: Test passed unexpectedly! It should have failed due to diff."
    exit 1
else
    echo "Test failed as expected (diff detected)."
fi

# 2. Run test with expectation
echo "2. Running Plan Check with TF_EXPECT_CHANGE='plan'..."
if bazel test --test_env=TF_EXPECT_CHANGE=plan //:plan; then
    echo "Test passed! (Diff allowed via expectation)."
else
    echo "ERROR: Test failed despite expectation!"
    exit 1
fi

echo "=== Mock CD: Deploying Changes ==="

echo "3. Building package..."
bazel build //:gitops

PACKAGE_PATH=$(bazel cquery //:gitops --output=files)

echo "4. Deploying (Applying)..."
DEPLOY_DIR=$(mktemp -d)
cp "$PACKAGE_PATH" "$DEPLOY_DIR/pkg.tar.gz"
pushd "$DEPLOY_DIR" > /dev/null

tar -xzf pkg.tar.gz
./run.sh

echo "=== Verifying Deployment ==="
# The file is created in src/foo.txt because the module is at the root of the workspace
if [ -f "src/foo.txt" ]; then
    echo "SUCCESS: File created!"
    cat src/foo.txt
    echo
else
    echo "ERROR: File not created."
    find . -name "foo.txt"
    exit 1
fi

popd > /dev/null
rm -rf "$DEPLOY_DIR"

echo "=== Clean up ==="
# Nothing to clean up in repo since file was created in temp dir
