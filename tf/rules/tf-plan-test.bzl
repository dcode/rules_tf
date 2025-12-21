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
./run.sh --plan {extra_args} "$@"

exit_code=$?

# If fail_on_diff is false, we might want to mask exit code 2 (diff present)
# But standard terraform plan only returns 2 if -detailed-exitcode is used.
# If -detailed-exitcode IS used (fail_on_diff=True), then 2 means failure for the test.
# If -detailed-exitcode IS NOT used (fail_on_diff=False), then 0 means success (with or without diff).

exit $exit_code
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
