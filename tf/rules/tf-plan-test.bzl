def _tf_plan_test_impl(ctx):
    package_file = ctx.file.package

    # Declare the output script
    out_file = ctx.actions.declare_file(ctx.label.name + ".sh")

    extra_args = []
    if ctx.attr.fail_on_diff:
        extra_args.append("-detailed-exitcode")

    script_content = """#!/bin/bash
set -e

# Package Location
PKG="{package_file}"

# Unpack
tar -xzf "$PKG"

# Run Plan
# We use the bundled run.sh
# We disable set -e temporarily to capture exit code 2 (diff present)
set +e
./run.sh --plan {extra_args} "$@"
exit_code=$?
set -e

# If fail_on_diff is false, we might want to mask exit code 2 (diff present)
# But standard terraform plan only returns 2 if -detailed-exitcode is used.
# If -detailed-exitcode IS used (fail_on_diff=True), then 2 means failure for the test.
# If -detailed-exitcode IS NOT used (fail_on_diff=False), then 0 means success (with or without diff).

if [ $exit_code -eq 2 ]; then
  # Detailed exitcode was used and diff was found.
  if [ -n "$TF_EXPECT_CHANGE" ]; then
    # We use grep to check if TF_EXPECT_CHANGE substring is in TEST_TARGET
    # TEST_TARGET is automatically set by Bazel for test rules.
    if echo "$TEST_TARGET" | grep -q "$TF_EXPECT_CHANGE"; then
       echo "WARN: Terraform Plan Diff detected, but ignored because TF_EXPECT_CHANGE='$TF_EXPECT_CHANGE' matches test target '$TEST_TARGET'."
       exit 0
    fi
  fi
  echo "ERROR: Terraform Plan Diff detected! (Exit code 2)"
  exit 1
elif [ $exit_code -ne 0 ]; then
   echo "ERROR: Terraform Plan failed with exit code $exit_code"
   exit $exit_code
fi

exit 0
""".format(
        package_file = package_file.short_path,
        extra_args = " ".join(extra_args),
    )

    ctx.actions.write(out_file, script_content, is_executable=True)

    runfiles = ctx.runfiles(files = [package_file])

    return [DefaultInfo(
        executable = out_file,
        runfiles = runfiles,
    )]

tf_plan_test = rule(
    implementation = _tf_plan_test_impl,
    attrs = {
        "package": attr.label(mandatory = True, allow_single_file = True),
        "fail_on_diff": attr.bool(default = False, doc = "If True, adds -detailed-exitcode to plan, causing the test to fail if changes are detected."),
    },
    test = True,
)
