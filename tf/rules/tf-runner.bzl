load("@rules_tf//tf/rules:providers.bzl", "TfModuleInfo")
load("@bazel_skylib//lib:paths.bzl", "paths")

def _tf_runner_impl(ctx):
    tf_runtime = ctx.toolchains["@rules_tf//:tf_toolchain_type"].runtime
    module = ctx.attr.module[TfModuleInfo]

    # Collect all transitive sources
    all_srcs = module.transitive_srcs.to_list()
    var_files = ctx.files.tf_vars_files
    backend_config = ctx.file.tf_backend_config

    out_file = ctx.actions.declare_file(ctx.label.name + ".sh")

    # Build arguments for init and execution
    tf_bin_path = tf_runtime.tf.short_path
    plugin_mirror_path = tf_runtime.mirror.short_path

    # Calculate relative paths for the runtime
    # When running with 'bazel run', we are in the runfiles root.
    # The short_path is relative to the runfiles root.

    var_args_list = []
    for vf in var_files:
         var_args_list.append("-var-file=$(pwd)/" + vf.short_path)

    var_args_str = " ".join(var_args_list)

    backend_args_str = ""
    if backend_config:
        backend_args_str = "-backend-config=$(pwd)/" + backend_config.short_path
    elif ctx.attr.tf_backend_config_vals:
        vals = []
        for kv in ctx.attr.tf_backend_config_vals.split(","):
            vals.append("-backend-config=" + kv)
        backend_args_str = " ".join(vals)

    script_content = """#!/bin/bash
set -e

# Resolve the runfiles directory
if [[ ! -d "${RUNFILES_DIR}" ]]; then
    if [[ -n "${TEST_SRCDIR}" ]]; then
        RUNFILES_DIR="${TEST_SRCDIR}"
    else
        RUNFILES_DIR="$0.runfiles"
    fi
fi

# If we are not in the runfiles dir (e.g. bazel run), we need to handle paths carefully
# However, bazel run usually executes from the execroot or similar, but the binaries are in runfiles.
# For simplicity, we use the short_paths which are relative to the workspace root in runfiles.

# Workspace Name
WORKSPACE_NAME="{workspace_name}"

# TF binary location
TF_BIN="${RUNFILES_DIR}/${WORKSPACE_NAME}/{tf_bin_path}"
PLUGIN_DIR="${RUNFILES_DIR}/${WORKSPACE_NAME}/{plugin_mirror_path}"

# Source directory (where the root module is)
# We need to resolve this relative to the runfiles
SRC_DIR="${RUNFILES_DIR}/${WORKSPACE_NAME}/{module_package}"

export TF_IN_AUTOMATION=1

# Propagate Credentials
if [ -n "$GOOGLE_APPLICATION_CREDENTIALS" ]; then
  export GOOGLE_APPLICATION_CREDENTIALS
fi
if [ -n "$HOME" ]; then
  export HOME
fi
if [ -n "$AWS_ACCESS_KEY_ID" ]; then
    export AWS_ACCESS_KEY_ID
fi
if [ -n "$AWS_SECRET_ACCESS_KEY" ]; then
    export AWS_SECRET_ACCESS_KEY
fi
if [ -n "$AWS_SESSION_TOKEN" ]; then
    export AWS_SESSION_TOKEN
fi

echo "Initializing Terraform..."
"$TF_BIN" -chdir="$SRC_DIR" init -input=false -plugin-dir="$PLUGIN_DIR" {backend_args} > /dev/null

echo "Running Terraform $@"
"$TF_BIN" -chdir="$SRC_DIR" "$@" {var_args}
""".format(
        tf_bin_path = tf_bin_path,
        plugin_mirror_path = plugin_mirror_path,
        module_package = module.module_path,
        backend_args = backend_args_str,
        var_args = var_args_str,
        workspace_name = ctx.workspace_name,
    )

    ctx.actions.write(out_file, script_content, is_executable=True)

    runfiles = ctx.runfiles(
        files = all_srcs + var_files + tf_runtime.deps + ([backend_config] if backend_config else [])
    )

    return [DefaultInfo(
        executable = out_file,
        runfiles = runfiles,
    )]

tf_runner = rule(
    implementation = _tf_runner_impl,
    attrs = {
        "module": attr.label(providers = [TfModuleInfo], mandatory = True),
        "tf_vars_files": attr.label_list(allow_files = True),
        "tf_backend_config": attr.label(allow_single_file = True),
        "tf_backend_config_vals": attr.string(),
    },
    executable = True,
    toolchains = ["@rules_tf//:tf_toolchain_type"],
)
